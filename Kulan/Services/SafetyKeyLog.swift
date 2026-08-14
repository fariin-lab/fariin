import Foundation

/// WHICH KEY WE HAVE SEEN FOR A PERSON, and whether it has changed since.
///
/// THE HOLE THIS CLOSES (owner asked for it 2026-08-14, after asking what we are missing against
/// Signal's protocol): the app has a safety number you can compare by hand, and nothing that ever
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
/// anybody is being attacked, and nothing is blocked. Signal's own wording is the same shape.
enum SafetyKeyLog {
    private static let seenDefaultsKey = "crypto.seenPeerKeys.v1"
    private static let changedDefaultsKey = "crypto.peerKeyChangedAt.v1"

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
        var changed = (UserDefaults.standard.dictionary(forKey: changedDefaultsKey) as? [String: Double]) ?? [:]
        changed[uid] = Date().timeIntervalSince1970
        UserDefaults.standard.set(changed, forKey: changedDefaultsKey)
        return true
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
    }
}

extension Notification.Name {
    /// Posted with the peer's uid when their identity key is replaced by a different one.
    static let peerKeyChanged = Notification.Name("peerKeyChanged")
}
