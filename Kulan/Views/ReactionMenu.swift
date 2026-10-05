import SwiftUI
import UIKit

// Long-press reaction + actions menu, the any-emoji picker, and the "who reacted"
// sheet. The standard reaction logic (one emoji per user, recents, full picker, reactor list),
// our own Fariin design.

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
    /// 2026-09-24 feature-audit: the quick bar's emoji. The user's recent reactions first, topped
    /// up with the default set, no repeats — `add` was written on every pick and read by nothing.
    static func quickBar(count: Int = 6) -> [String] {
        var out: [String] = []
        for e in get() + QuickReaction.choices where !e.isEmpty && !out.contains(e) {
            out.append(e)
            if out.count == count { break }
        }
        return out
    }
}

// The full Apple emoji set, the keyboard's eight groups in the keyboard's order, searchable by
// name. The list itself is Unicode's (`EmojiCatalogData`); it used to be walked out of a handful
// of code-point ranges, which can never find a flag, a keycap or any joined emoji, and missed
// whole blocks besides (owner, 2026-10-05: no flags, many missing).
enum EmojiCatalog {
    struct Item: Hashable { let char: String; let name: String }

    static let sections: [(title: String, items: [Item])] = EmojiCatalogData.sections.map { s in
        // Any line break, not just "\n": "\r\n" is ONE Character in Swift and would never split.
        (s.title, s.lines.split(whereSeparator: \.isNewline).compactMap { line -> Item? in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return Item(char: String(parts[0]), name: String(parts[1]))
        })
    }
    static let all: [Item] = sections.flatMap { $0.items }
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

// 2026-09-24 feature-audit: EDIT HISTORY, like the reference app — a message's earlier versions,
// newest first under the current text, in the Reactions sheet's style. The versions are read from
// the message document (`ChatService.editHistory`) and opened on this phone; a version this phone
// cannot open (sealed for an older group roster) says so instead of showing ciphertext.
struct EditHistorySheet: View {
    let cid: String
    let message: Message
    @Environment(\.dismiss) private var dismiss
    @State private var versions: [(text: String, at: Date)]? = nil
    @State private var failed = false

    var body: some View {
        NavigationStack {
            List {
                row(message.text, caption: "Current")
                if let versions {
                    if versions.isEmpty {
                        Text("No earlier versions").font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(Array(versions.enumerated().reversed()), id: \.offset) { _, v in
                        let readable = !(v.text.isEmpty || v.text == "…" || v.text == "🔒")
                        row(readable ? v.text : "Unavailable",
                            caption: v.at == .distantPast ? "" : v.at.formatted(date: .abbreviated, time: .shortened),
                            dim: !readable)
                    }
                } else if failed {
                    Text("Couldn't load the edit history").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Edit History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .task {
            do { versions = try await ChatService.editHistory(cid: cid, messageId: message.id) }
            catch { failed = true }
        }
    }

    private func row(_ text: String, caption: String, dim: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(text).font(.body).foregroundStyle(dim ? .secondary : .primary)
            if !caption.isEmpty {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// "Who reacted" — reactor name + their emoji. Real data, no fakes.
// 2026-09-24 feature-audit: per-emoji tabs ("All" first, then each emoji most-popular first, the
// bubble pill's own order), and reactors sorted by display name. It was sorted by raw uid, which
// reads as shuffled. The data carries no reaction time, so recency is not available to sort by.
struct ReactorsSheet: View {
    let reactions: [String: String]      // uid -> emoji
    let nameFor: (String) -> String
    /// The reactor's photo url, for the round avatar in front of the name (owner, 2026-09-28).
    var photoFor: (String) -> String? = { _ in nil }
    /// ⛔ MY ROW TAKES MY REACTION BACK — owner, 2026-09-29: reactions on older messages "sometimes
    /// cannot be removed". Tapping the chip opens this list, and nothing in it could remove one; the
    /// long-press bar was the only way. The reference app's list does it: my row reads "Tap to
    /// remove". Same write as every other removal (`ThreadView.react`).
    var me: String = ""
    var onRemoveMine: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var selected: String?  // nil = All

    /// (emoji, count), most-popular first, ties by emoji: the same order as the bubble's pills.
    private var tabs: [(emoji: String, count: Int)] {
        Dictionary(grouping: reactions.values, by: { $0 })
            .map { (emoji: $0.key, count: $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.emoji > $1.emoji }
    }

    /// A tab whose last reactor took their reaction back falls back to All.
    private var activeEmoji: String? {
        guard let s = selected, reactions.values.contains(s) else { return nil }
        return s
    }

    private var rows: [(uid: String, emoji: String, name: String)] {
        reactions
            .filter { activeEmoji == nil || $0.value == activeEmoji }
            .map { (uid: $0.key, emoji: $0.value, name: nameFor($0.key)) }
            .sorted {
                let c = $0.name.localizedCaseInsensitiveCompare($1.name)
                return c != .orderedSame ? c == .orderedAscending : $0.uid < $1.uid
            }
    }

    private func tab(_ label: String, emoji: String?) -> some View {
        let on = activeEmoji == emoji
        return Button { selected = emoji } label: {
            Text(label)
                .font(.subheadline.weight(on ? .semibold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(on ? Color.secondary.opacity(0.22) : Color.clear))
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        NavigationStack {
            List {
                if !tabs.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            tab("All \(reactions.count)", emoji: nil)
                            ForEach(tabs, id: \.emoji) { t in tab("\(t.emoji) \(t.count)", emoji: t.emoji) }
                        }
                        .padding(.horizontal, 16)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowSeparator(.hidden)
                }
                ForEach(rows, id: \.uid) { r in
                    let mine = r.uid == me && onRemoveMine != nil
                    HStack(spacing: 12) {
                        // The same avatar and size the message info list uses for its people.
                        AvatarView(name: r.name, photoUrl: photoFor(r.uid), size: 40)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(r.name).font(.body)
                                VerifiedMark(uid: r.uid, size: 13)
                            }
                            if mine {
                                Text("Tap to remove").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(r.emoji).font(.title3)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard mine else { return }
                        onRemoveMine?()
                        dismiss()
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
