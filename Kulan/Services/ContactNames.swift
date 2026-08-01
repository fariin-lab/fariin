import Foundation
import Observation

/// One person's local card: the name YOU gave them, plus a private note.
struct ContactCard: Equatable {
    var first: String = ""
    var last: String = ""
    var note: String = ""

    /// What the app shows in headers and the chat list — nil when you have not renamed them.
    var displayName: String? {
        let n = [first, last]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return n.isEmpty ? nil : n
    }
    var isEmpty: Bool {
        displayName == nil && note.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

// Local, per-device contact cards. Kulan has no server-side address book (and no phone numbers) —
// accounts are username-based — so a nickname you set here overrides the profile name in the chat
// list + headers, and the note is a private reminder. Purely local; NEVER sent anywhere, which is
// what lets the sheet promise "only visible to you" honestly.
//
// @Observable so setting a nickname updates the chat header + list + profile INSTANTLY (no refresh):
// any SwiftUI view that reads `ContactNames.shared.name(for:)` in its body tracks the store and
// re-renders the moment it changes.
@Observable final class ContactNames {
    static let shared = ContactNames()
    private static let key = "contactCards.v2"
    private static let legacyKey = "contactCustomNames"   // [uid: String], names only

    private var cards: [String: ContactCard]

    private init() {
        var loaded: [String: ContactCard] = [:]
        if let raw = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: [String: String]] {
            for (uid, d) in raw {
                loaded[uid] = ContactCard(first: d["f"] ?? "", last: d["l"] ?? "", note: d["n"] ?? "")
            }
        }
        // MIGRATION: the old store held one flat name per uid. It becomes the FIRST name, so nobody
        // loses a nickname they set before first/last existed. The legacy key is left in place —
        // deleting it would strand anyone who downgrades mid-rollout.
        if loaded.isEmpty,
           let legacy = UserDefaults.standard.dictionary(forKey: Self.legacyKey) as? [String: String] {
            for (uid, name) in legacy where !name.trimmingCharacters(in: .whitespaces).isEmpty {
                loaded[uid] = ContactCard(first: name)
            }
        }
        cards = loaded
    }

    /// The display name you gave them, or nil.
    func name(for uid: String) -> String? { cards[uid]?.displayName }
    /// Your private note about them, or nil.
    func note(for uid: String) -> String? {
        let n = cards[uid]?.note.trimmingCharacters(in: .whitespaces)
        return (n?.isEmpty == false) ? n : nil
    }
    /// The whole card, for the editor.
    func card(for uid: String) -> ContactCard { cards[uid] ?? ContactCard() }

    func setCard(_ card: ContactCard, for uid: String) {
        if card.isEmpty { cards.removeValue(forKey: uid) } else { cards[uid] = card }
        persist()
    }

    /// "Delete Nickname?" — drops the name AND the note, which is what the sheet warns it does.
    func remove(for uid: String) {
        cards.removeValue(forKey: uid)
        persist()
    }

    /// Convenience for the older single-name callers (Add Contact).
    func set(_ name: String, for uid: String) {
        var c = card(for: uid)
        let parts = name.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
        c.first = parts.first.map(String.init) ?? ""
        c.last = parts.count > 1 ? String(parts[1]) : ""
        setCard(c, for: uid)
    }

    private func persist() {
        let raw = cards.mapValues { ["f": $0.first, "l": $0.last, "n": $0.note] }
        UserDefaults.standard.set(raw, forKey: Self.key)
    }

    /// Sign-out/delete: cards belong to the account that set them.
    func clear() {
        cards = [:]
        UserDefaults.standard.removeObject(forKey: Self.key)
        UserDefaults.standard.removeObject(forKey: Self.legacyKey)
    }
}
