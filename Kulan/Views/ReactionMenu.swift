import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
        guard !CustomReaction.isCustom(emoji) else { return }   // belongs to one channel's list
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

    /// What a channel may offer as reactions: the reference app's free set, in its order, 73 emoji
    /// (owner 2026-11-01: the whole keyboard was too many). Names come from the catalog for search;
    /// the variation selector is ignored there, because the two lists spell some hearts differently.
    static let channelReactions: [Item] = {
        let names = Dictionary(all.map { (bare($0.char), $0.name) }, uniquingKeysWith: { first, _ in first })
        return """
        ❤️ 👍 👎 🔥 🥰 👏 😁 🤔 🤯 😱 🤬 😢 🎉 🤩 🤮 💩 🙏 👌 🕊️ 🤡 🥱 🥴 😍 🐳 ❤️‍🔥 🌚 🌭 💯 🤣 ⚡️ 🍌 🏆 💔 🤨 😐 \
        🍓 🍾 💋 🖕 😈 😴 😭 🤓 👻 👨‍💻 👀 🎃 🙈 😇 😨 🤝 ✍️ 🤗 🫡 🎅 🎄 ☃️ 💅 🤪 🗿 🆒 💘 🙉 🦄 😘 💊 🙊 😎 👾 \
        🤷‍♂️ 🤷 🤷‍♀️ 😡
        """.split(separator: " ").map { Item(char: String($0), name: names[bare(String($0))] ?? "") }
    }()

    /// The channel set, led by any of `picks` it does not hold (custom reactions aside: they have
    /// their own tab), so a pick from outside the set can still be unticked.
    static func channelOffer(including picks: [String]) -> [Item] {
        let known = Set(channelReactions.map { bare($0.char) })
        let names = Dictionary(all.map { (bare($0.char), $0.name) }, uniquingKeysWith: { first, _ in first })
        let extras = picks.filter { !known.contains(bare($0)) && !CustomReaction.isCustom($0) }
            .map { Item(char: $0, name: names[bare($0)] ?? "") }
        return extras + channelReactions
    }

    private static func bare(_ emoji: String) -> String {
        String(String.UnicodeScalarView(emoji.unicodeScalars.filter { $0.value != 0xFE0F }))
    }
}

// Full native-emoji grid for "more": categories when idle, name-search when typing.
struct EmojiMorePicker: View {
    /// owner 2026-10-18: the Role editor picks its emoji here too, under its own title.
    var title: String = "React"
    /// How tall the sheet opens (owner 2026-10-31: the channel's reaction bar must stay in sight).
    var detents: Set<PresentationDetent> = [.medium, .large]
    /// A short list to choose from instead of the whole keyboard, as one grid with no headings.
    var only: [EmojiCatalog.Item]? = nil
    /// The Normal / Custom tabs (owner 2026-11-02): the animated set, for the one account allowed.
    var showsCustom = false
    /// MANY AT ONCE (owner 2026-11-06, channel Reactions: "adding one by one is too slow, and the x
    /// is tapped by mistake"). With a list here the sheet stays open: a tap turns an emoji on or off
    /// in it, picks wear a ring and a tick, the title counts them, and Done closes. `onPick` unused.
    var multi: Binding<[String]>? = nil
    var maxPicks = 12
    var onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var customTab = false
    /// Adding .tgs files from this phone (owner 2026-11-06): the Files sheet, how many are up so far
    /// (nil when nothing is uploading), and what to tell when it is done.
    @State private var pickingFiles = false
    @State private var uploadedSoFar: Int?
    @State private var uploadNote: String?
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)

    private var filtered: [EmojiCatalog.Item] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return (only ?? EmojiCatalog.all).filter { $0.name.contains(q) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if showsCustom {
                    Picker("Emoji set", selection: $customTab) {
                        Text("Normal").tag(false)
                        Text("Custom").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                }
                if showsCustom && customTab {
                    customGrid.padding()
                } else if query.isEmpty, let only {
                    grid(only).padding()
                } else if query.isEmpty {
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
            // Many at once: the count is the title ("6 of 12"), and Done, not an x, closes.
            .navigationTitle(multi.map { "\($0.wrappedValue.count) of \(maxPicks)" } ?? title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if multi != nil {
                        Button("Done") { dismiss() }.fontWeight(.semibold)
                    } else {
                        Button { dismiss() } label: { Image(systemName: "xmark") }.tint(.primary)
                    }
                }
            }
        }
        .presentationDetents(detents)
        // Any file: iOS has no type for .tgs, so a .tgs filter would grey them all out. The server
        // checks every file and names any it refuses.
        .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            var files: [(name: String, data: Data)] = []
            for u in urls {
                let scoped = u.startAccessingSecurityScopedResource()
                defer { if scoped { u.stopAccessingSecurityScopedResource() } }
                if let d = try? Data(contentsOf: u) { files.append((u.lastPathComponent, d)) }
            }
            guard !files.isEmpty else { uploadNote = "Couldn't read those files."; return }
            uploadedSoFar = 0
            Task {
                do {
                    let n = try await UploadedEmoji.upload(files) { uploadedSoFar = $0 }
                    uploadNote = n == 1 ? "1 emoji added." : "\(n) emoji added."
                } catch {
                    uploadNote = (error as NSError).localizedDescription
                }
                uploadedSoFar = nil
            }
        }
        .alert(uploadNote ?? "", isPresented: Binding(get: { uploadNote != nil }, set: { if !$0 { uploadNote = nil } })) {
            Button("OK", role: .cancel) { uploadNote = nil }
        }
    }

    /// Half rate: a full sheet plays about 70 at once. Only the ones on screen play.
    /// Owner 2026-11-06: a "+" first, to add .tgs files from this phone (`UploadedEmoji.upload`);
    /// they appear here by themselves once the server has them.
    private var customGrid: some View {
        LazyVGrid(columns: cols, spacing: 10) {
            Button { pickingFiles = true } label: {
                ZStack {
                    Circle().fill(Color(.tertiarySystemFill)).frame(width: 40, height: 40)
                    if uploadedSoFar != nil { ProgressView() }
                    else { Image(systemName: "plus").font(.system(size: 18, weight: .semibold)).foregroundStyle(.secondary) }
                }
            }
            .buttonStyle(.plain)
            .disabled(uploadedSoFar != nil)
            .accessibilityLabel("Add custom emoji from Files")
            ForEach(CustomReaction.all, id: \.self) { key in
                Button { tapped(key) } label: {
                    CustomReactionTile(key: key, side: 40, motion: .loop(step: 2))
                        .overlay { pickMark(key) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(CustomReaction.spoken(key))
            }
        }
    }

    private func grid(_ items: [EmojiCatalog.Item]) -> some View {
        LazyVGrid(columns: cols, spacing: 10) {
            ForEach(items, id: \.self) { item in
                Button { tapped(item.char) } label: {
                    Text(item.char).font(.system(size: 30))
                        .frame(width: 44, height: 44)
                        .overlay { pickMark(item.char) }
                }
                    .buttonStyle(.plain)
            }
        }
    }

    /// One pick: closes the sheet with it, or (many at once) turns it on or off in the list.
    private func tapped(_ e: String) {
        guard let multi else { onPick(e); dismiss(); return }
        var list = multi.wrappedValue
        if let i = list.firstIndex(where: { ChannelEmoji.same($0, e) }) {
            // The last one stays: none at all is "No Reactions", chosen above, not by accident here.
            guard list.count > 1 else { uploadNote = "Keep at least one. To turn reactions off, choose No Reactions."; return }
            list.remove(at: i)
        } else {
            guard list.count < maxPicks else { uploadNote = "Up to \(maxPicks) reactions."; return }
            list.append(e)
        }
        Haptics.impact(.light)
        multi.wrappedValue = list
    }

    /// The ring and tick on an emoji that is in the list (many-at-once mode only).
    @ViewBuilder private func pickMark(_ e: String) -> some View {
        if let multi, multi.wrappedValue.contains(where: { ChannelEmoji.same($0, e) }) {
            ZStack(alignment: .bottomTrailing) {
                Circle().fill(Color.accentColor.opacity(0.18))
                Circle().strokeBorder(Color.accentColor, lineWidth: 2)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white, Color.accentColor)
                    .offset(x: 3, y: 3)
            }
            .frame(width: 46, height: 46)
            .allowsHitTesting(false)
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
                    Text("Couldn't load the edit history. Check your connection and try again.").font(.subheadline).foregroundStyle(.secondary)
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
