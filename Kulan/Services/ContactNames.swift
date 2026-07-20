import Foundation
import Observation

// Local, per-device custom display names for contacts. Kulan has no server-side address book
// (and no phone numbers) — accounts are username-based — so when you add a contact with a
// First/Last name, we store that name here keyed by their uid and let it override the profile
// name in the chat list + headers. Purely local; never sent anywhere.
//
// @Observable so setting a nickname updates the chat header + list + profile INSTANTLY (no refresh):
// any SwiftUI view that reads `ContactNames.shared.name(for:)` in its body tracks the `names` dict and
// re-renders the moment it changes.
@Observable final class ContactNames {
    static let shared = ContactNames()
    private static let key = "contactCustomNames"

    private var names: [String: String]

    private init() {
        names = (UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String]) ?? [:]
    }

    func name(for uid: String) -> String? {
        let n = names[uid]?.trimmingCharacters(in: .whitespaces)
        return (n?.isEmpty == false) ? n : nil
    }

    func set(_ name: String, for uid: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { names.removeValue(forKey: uid) } else { names[uid] = trimmed }
        UserDefaults.standard.set(names, forKey: Self.key)
    }

    /// Sign-out/delete: nicknames belong to the account that set them.
    func clear() {
        names = [:]
        UserDefaults.standard.removeObject(forKey: Self.key)
    }
}
