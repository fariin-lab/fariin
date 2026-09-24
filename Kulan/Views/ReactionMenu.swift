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
                        VerifiedMark(uid: uid, size: 13)
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
