import SwiftUI
import UIKit

// Long-press reaction + actions menu, the any-emoji picker, and the "who reacted"
// sheet. Signal's logic (one emoji per user, recents, full picker, reactor list),
// our own Kulan design.

// Recently-used reaction emoji, persisted so the quick bar adapts to the user.
enum ReactionRecents {
    private static let key = "reactionRecents"
    static func get() -> [String] {
        (UserDefaults.standard.string(forKey: key) ?? "").split(separator: " ").map(String.init)
    }
    static func add(_ emoji: String) {
        var r = get().filter { $0 != emoji }
        r.insert(emoji, at: 0)
        UserDefaults.standard.set(r.prefix(10).joined(separator: " "), forKey: key)
    }
}

// The full native Apple emoji set, enumerated from Unicode (so we render the same
// glyphs the system keyboard does), grouped into categories and searchable by name.
enum EmojiCatalog {
    struct Item: Hashable { let char: String; let name: String }

    static let sections: [(title: String, items: [Item])] = [
        ("Smileys & People", build([0x1F600...0x1F64F, 0x1F910...0x1F92F, 0x1F970...0x1F97A, 0x1F9D0...0x1F9DF])),
        ("Animals & Nature", build([0x1F400...0x1F43E, 0x1F980...0x1F9AE, 0x1F330...0x1F335])),
        ("Food & Drink",     build([0x1F32D...0x1F37F, 0x1F950...0x1F96B])),
        ("Activity & Travel", build([0x1F380...0x1F3CF, 0x1F680...0x1F6D2, 0x1F30D...0x1F320])),
        ("Objects",          build([0x1F4A1...0x1F4FF, 0x1F526...0x1F53D])),
        ("Symbols",          build([0x2600...0x26FF, 0x2700...0x27BF, 0x1F500...0x1F525, 0x2764...0x2764])),
    ]
    static let all: [Item] = sections.flatMap { $0.items }

    private static func build(_ ranges: [ClosedRange<Int>]) -> [Item] {
        ranges.flatMap { Array($0) }.compactMap { code in
            guard let s = Unicode.Scalar(code),
                  s.properties.isEmoji, s.properties.isEmojiPresentation else { return nil }
            return Item(char: String(s), name: (s.properties.name ?? "").lowercased())
        }
    }
}

// Floating dim overlay: a quick-emoji bar on top, message actions below.
// Emoji press feedback (Signal scales the focused reaction up): a quick pop on touch-down.
private struct ReactionPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 1.35 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct ReactionMenuOverlay: View {
    let message: Message
    let cid: String
    let dark: Bool
    let isMe: Bool
    let myReaction: String?
    var anchorFrame: CGRect = .zero   // the tapped bubble's GLOBAL frame (Signal anchors bar above / menu below)
    var isGroup: Bool = false
    var canPin: Bool = true
    var isPinned: Bool = false
    var onPick: (String) -> Void
    var onMore: () -> Void
    var onReply: () -> Void
    var onForward: () -> Void
    var onPin: () -> Void
    var onCopy: () -> Void
    var onSelect: () -> Void = {}
    var onInfo: () -> Void = {}
    var onSaveImage: () -> Void = {}
    var onEdit: () -> Void
    var onDelete: () -> Void
    var onReport: () -> Void
    var onDismiss: () -> Void
    @State private var shown = false

    // Signal's default reaction set: recents first, then the 6 defaults, deduped, capped at 6.
    private var quick: [String] {
        var set = ReactionRecents.get()
        for e in ["❤️", "👍", "👎", "😂", "😮", "😢"] where !set.contains(e) { set.append(e) }
        return Array(set.prefix(6))
    }

    // How many action rows the menu will show (drives clamping math).
    private var rowCount: Int {
        var n = 1                                   // Reply
        if !message.isCall { n += 1 }               // Forward
        if !message.text.isEmpty { n += 1 }         // Copy
        if message.isImage { n += 1 }               // Save Image
        n += 1                                       // Select
        if isGroup && isMe && message.sendState == nil { n += 1 }   // Info
        if canPin { n += 1 }                         // Pin
        if isMe && !message.isImage && !message.isAudio && !message.isCall && message.sendState == nil { n += 1 }   // Edit
        n += 1                                       // Delete / Report
        return n
    }

    private let barH: CGFloat = 60      // reaction pill height + shadow room
    private let rowH: CGFloat = 44      // action row height
    private let gap: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let safeTop = geo.safeAreaInsets.top + 8
            let safeBottom = geo.size.height - geo.safeAreaInsets.bottom - 8
            let menuH = CGFloat(rowCount) * rowH
            let bubbleH = min(anchorFrame.height, geo.size.height * 0.5)
            // Desired: bubble stays where it was; bar 12pt above it, menu 12pt below.
            var groupTop = anchorFrame.minY - barH - 12
            let groupBottom = anchorFrame.minY + bubbleH + 12 + menuH
            // Clamp into the safe content area (Signal shifts the whole group up/down to fit).
            if groupBottom > safeBottom { groupTop -= (groupBottom - safeBottom) }
            if groupTop < safeTop { groupTop = safeTop }

            ZStack(alignment: .topLeading) {
                // Blurred + dimmed backdrop (Signal: UIBlurEffect .regular + a light/dark tint).
                Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                    .overlay((dark ? Color.white : Color.black).opacity(0.12).ignoresSafeArea())
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }

                VStack(alignment: isMe ? .trailing : .leading, spacing: 12) {
                    emojiBar
                    liftedBubble
                    actions
                }
                .frame(width: geo.size.width - 32, alignment: isMe ? .trailing : .leading)
                .offset(x: 16, y: groupTop)
                // Spring from the bubble's side (Signal: scale 0.2 → 1, damping 0.8).
                .scaleEffect(shown ? 1 : 0.4, anchor: isMe ? .topTrailing : .topLeading)
                .opacity(shown ? 1 : 0)
            }
            .onAppear { withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) { shown = true } }
        }
        .ignoresSafeArea()
    }

    private func dismiss() { withAnimation(.easeOut(duration: 0.18)) { shown = false }; onDismiss() }

    // The ACTUAL tapped message lifted above the menu (native "peek" feel): the real
    // image, the real voice widget, or the real text bubble — never a placeholder string.
    @ViewBuilder private var liftedBubble: some View {
        Group {
            if message.isImage {
                imageLift
            } else if message.isAudio {
                VoiceMessageView(message: message, cid: cid, isMe: isMe, dark: dark)
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background(isMe ? Theme.accent(dark) : Theme.received(dark))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .frame(maxWidth: 260, alignment: isMe ? .trailing : .leading)
            } else {
                Text(message.text)
                    .font(.body)
                    .foregroundColor(isMe ? Theme.onAccent(dark) : (dark ? .white : .black))
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background(isMe ? Theme.accent(dark) : Theme.received(dark))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .frame(maxWidth: 260, alignment: isMe ? .trailing : .leading)
            }
        }
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }

    @ViewBuilder private var imageLift: some View {
        Group {
            if let data = message.localImageData, let ui = UIImage(data: data) {
                Image(uiImage: ui).resizable().scaledToFill()
            } else if let url = message.imageUrl {
                SecureImageView(imageUrl: url, enc: message.enc, cid: cid)
            }
        }
        .frame(maxWidth: 240, maxHeight: 280)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func haptic() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }

    // Signal's reaction pill: 32pt glyphs, glass capsule, the 6 defaults + a trailing "…" more button.
    // The selected emoji gets a circular highlight (Signal's selectedBackground).
    private var emojiBar: some View {
        HStack(spacing: 6) {
            ForEach(quick, id: \.self) { e in
                Button { haptic(); onPick(e) } label: {
                    Text(e).font(.system(size: 30))
                        .frame(width: 40, height: 44)
                        .background(myReaction == e ? Color.accentColor.opacity(0.25) : .clear, in: Circle())
                }
                .buttonStyle(ReactionPressStyle())
            }
            Button { haptic(); onMore() } label: {
                Image(systemName: "plus").font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .background(dark ? Color.white.opacity(0.12) : Color.black.opacity(0.06), in: Circle())
            }
            .buttonStyle(ReactionPressStyle())
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .liquidGlass(Capsule())   // real iOS 26 Liquid Glass
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)   // float above the chat
    }

    // Menu order matches the mockup: Reply · Forward · Copy · (Save) · Select · Info · Pin · Edit · Delete/Report.
    private var actions: some View {
        VStack(spacing: 0) {
            row("Reply", "arrowshape.turn.up.left", onReply)
            if !message.isCall {
                menuDivider; row("Forward", "arrowshape.turn.up.right", onForward)
            }
            if !message.text.isEmpty {
                menuDivider; row("Copy", "doc.on.doc") { UIPasteboard.general.string = message.text; onCopy() }
            }
            if message.isImage {
                menuDivider; row("Save Image", "square.and.arrow.down", onSaveImage)
            }
            menuDivider; row("Select", "checkmark.circle", onSelect)
            if isGroup && isMe && message.sendState == nil {
                menuDivider; row("Info", "info.circle", onInfo)
            }
            if canPin {
                menuDivider; row(isPinned ? "Unpin" : "Pin", isPinned ? "pin.slash" : "pin", onPin)
            }
            if isMe && !message.isImage && !message.isAudio && !message.isCall && message.sendState == nil {
                menuDivider; row("Edit", "pencil", onEdit)
            }
            menuDivider
            if isMe { row("Delete", "trash", onDelete, destructive: true) }
            else { row("Report", "flag", onReport, destructive: true) }   // flag for review (App Store 1.2)
        }
        .frame(width: 250)
        .liquidGlass(RoundedRectangle(cornerRadius: 22, style: .continuous))   // rounder, Apple-style
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
    }

    // Full-width hairline between rows — matches the native context-menu separators.
    private var menuDivider: some View {
        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
    }

    @ViewBuilder
    private func row(_ title: String, _ icon: String, _ action: @escaping () -> Void, destructive: Bool = false) -> some View {
        Button(action: { haptic(); action() }) {
            HStack(spacing: 14) {
                Image(systemName: icon).frame(width: 24)   // icon on the left, like Signal/iOS menus
                Text(title)
                Spacer(minLength: 8)
            }
            .font(.system(size: 17))   // native context-menu metrics
            .foregroundStyle(destructive ? Color.red : Color.primary)
            .padding(.horizontal, 16).padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// Full native-emoji grid for "more": categories when idle, name-search when typing.
struct EmojiMorePicker: View {
    var onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)

    private var filtered: [EmojiCatalog.Item] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return EmojiCatalog.all.filter { $0.name.contains(q) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if query.isEmpty {
                    ForEach(EmojiCatalog.sections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.title).font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary).padding(.horizontal, 4).padding(.top, 6)
                            grid(section.items)
                        }
                        .padding(.horizontal)
                    }
                } else {
                    grid(filtered).padding()
                }
            }
            .searchable(text: $query, prompt: "Search emoji")
            .navigationTitle("React")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { dismiss() } label: { Image(systemName: "xmark") }.tint(.primary) } }
        }
        .presentationDetents([.medium, .large])
    }

    private func grid(_ items: [EmojiCatalog.Item]) -> some View {
        LazyVGrid(columns: cols, spacing: 10) {
            ForEach(items, id: \.self) { item in
                Button { onPick(item.char); dismiss() } label: { Text(item.char).font(.system(size: 30)) }
                    .buttonStyle(.plain)
            }
        }
    }
}

// "Who reacted" — reactor name + their emoji. Real data, no fakes.
struct ReactorsSheet: View {
    let reactions: [String: String]      // uid -> emoji
    let nameFor: (String) -> String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(reactions.sorted { $0.key < $1.key }, id: \.key) { uid, emoji in
                    HStack {
                        Text(nameFor(uid)).font(.body)
                        Spacer()
                        Text(emoji).font(.title3)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Reactions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}
