import Foundation

/// WHICH KEY WE HAVE SEEN FOR A PERSON, and whether it has changed since.
///
/// THE HOLE THIS CLOSES (owner asked for it 2026-08-14, after asking what we are missing against
/// the reference protocol): the app has a safety number you can compare by hand, and nothing that ever
/// looks at it for you. `Crypto.fetchKey` takes whatever public key the server hands over and
/// overwrites the cached one in silence, so a key that changes — a new phone, a reinstall, or
/// someone swapping it — arrives without a word. That silence is the whole attack: a server that
/// hands out a different public key can read everything sent afterwards, and the only thing that
/// would ever betray it is the number changing under your nose.
///
/// This is deliberately NOT the working key cache. That cache is cleared on purpose when a decrypt
/// fails (see `refreshKeyAfterFailure` — a contact who reinstalls must be able to heal), so it
/// cannot answer "what did we use to see?". This one is append-only: the first key we ever see for
/// somebody is recorded, and every later key is compared against it.
///
/// ⚠️ A CHANGE IS NOT A VERDICT. Reinstalling the app is a key change too, and it is by far the
/// commonest one. The notice says what happened and offers the safety number; it never claims
/// anybody is being attacked, and nothing is blocked. The reference app's own wording is the same shape.
enum SafetyKeyLog {
    private static let seenDefaultsKey = "crypto.seenPeerKeys.v1"
    /// The PENDING notice — cleared the moment the user has seen it.
    private static let changedDefaultsKey = "crypto.peerKeyChangedAt.v1"
    /// THE RECORD ITSELF, which `acknowledge` must never touch.
    ///
    /// These were one key, and dismissing the bar deleted the only evidence the change had ever
    /// happened — so a safety number could be replaced, the notice tapped away in a second, and
    /// afterwards nothing anywhere in the app could say it had occurred. A warning you can erase by
    /// acknowledging it is not a record. Every other messenger writes the event permanently into the
    /// conversation for exactly this reason.
    private static let lastChangedDefaultsKey = "crypto.peerKeyLastChangedAt.v1"

    /// Record the key we just fetched. Returns true only when it REPLACES a different key we had
    /// already seen — the first sighting of a person is never a change.
    @discardableResult
    static func note(uid: String, key: Data) -> Bool {
        guard !uid.isEmpty else { return false }
        let b64 = key.base64EncodedString()
        var seen = (UserDefaults.standard.dictionary(forKey: seenDefaultsKey) as? [String: String]) ?? [:]
        guard let previous = seen[uid] else {
            seen[uid] = b64
            UserDefaults.standard.set(seen, forKey: seenDefaultsKey)
            return false                     // first time we have ever seen this person
        }
        guard previous != b64 else { return false }
        seen[uid] = b64
        UserDefaults.standard.set(seen, forKey: seenDefaultsKey)
        let now = Date().timeIntervalSince1970
        var changed = (UserDefaults.standard.dictionary(forKey: changedDefaultsKey) as? [String: Double]) ?? [:]
        changed[uid] = now
        UserDefaults.standard.set(changed, forKey: changedDefaultsKey)
        // The permanent half. Written together, cleared apart.
        var lastChanged = (UserDefaults.standard.dictionary(forKey: lastChangedDefaultsKey) as? [String: Double]) ?? [:]
        lastChanged[uid] = now
        UserDefaults.standard.set(lastChanged, forKey: lastChangedDefaultsKey)
        return true
    }

    /// When this person's key last changed, whether or not the notice was dismissed. Survives
    /// `acknowledge` on purpose — this is the answer to "did this ever happen", which the bar alone
    /// could not give once it had been tapped away. Cleared only by signing out.
    static func lastChangedAt(_ uid: String) -> Date? {
        guard !uid.isEmpty,
              let last = UserDefaults.standard.dictionary(forKey: lastChangedDefaultsKey) as? [String: Double],
              let t = last[uid] else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    /// Which of these people have a notice still waiting to be seen. A group chat has no single
    /// "other person", so the bar there has to ask about every member at once.
    static func pendingAmong(_ uids: [String]) -> [String] {
        guard let changed = UserDefaults.standard.dictionary(forKey: changedDefaultsKey) as? [String: Double] else { return [] }
        return uids.filter { changed[$0] != nil }
    }

    /// When this person's key last changed, if the notice has not been dismissed.
    static func changedAt(_ uid: String) -> Date? {
        guard !uid.isEmpty,
              let changed = UserDefaults.standard.dictionary(forKey: changedDefaultsKey) as? [String: Double],
              let t = changed[uid] else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    /// Dismiss the notice — they have seen it, or they have just compared the numbers.
    static func acknowledge(_ uid: String) {
        guard var changed = UserDefaults.standard.dictionary(forKey: changedDefaultsKey) as? [String: Double],
              changed.removeValue(forKey: uid) != nil else { return }
        UserDefaults.standard.set(changed, forKey: changedDefaultsKey)
    }

    /// Signing out clears the record with everything else: the next person on this phone must not
    /// inherit a stranger's key history, and their own first fetch has to count as a first sighting.
    static func wipe() {
        UserDefaults.standard.removeObject(forKey: seenDefaultsKey)
        UserDefaults.standard.removeObject(forKey: changedDefaultsKey)
        UserDefaults.standard.removeObject(forKey: lastChangedDefaultsKey)
    }
}

extension Notification.Name {
    /// Posted with the peer's uid when their identity key is replaced by a different one.
    static let peerKeyChanged = Notification.Name("peerKeyChanged")
}
