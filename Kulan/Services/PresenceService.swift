import Foundation
import FirebaseAuth
import FirebaseFirestore
import os

// Writes my online/last-active state so the other person sees "online" / "last seen".
//
// IT LIVES IN A SUBCOLLECTION, NOT ON THE USER DOCUMENT, and that is the whole point of this file's
// current shape. `users/{uid}` is readable by ANY signed-in account — it has to be, so a stranger can
// look up a handle to start a chat. So while presence sat on the user document, "Last Seen: My
// Contacts" was enforced only by the READING app: anybody querying Firestore directly, rather than
// through Fariin, got your last-seen time no matter what you had chosen. The old comment here said
// as much in passing ("reader clients enforce who qualifies") without saying that a reader client is
// not something we control.
//
// `users/{uid}/presence/state` can carry its own rule, and it does: readable by you, by anyone if
// your audience is "everyone", and otherwise only by somebody you actually have a conversation with.
// That is the same definition of "contact" the rest of the app uses, and now the SERVER applies it.
enum PresenceService {
    /// What was last written, as "uid|online|share" (perf audit 2026-11-11, E7). One write per real
    /// change, the way the reference app sends its status only when it actually flips: going home and
    /// back, or a privacy page re-asserting the same state, no longer costs a write each time.
    private static let lastWritten = OSAllocatedUnfairLock<String?>(initialState: nil)
    private static func legacyClearedKey(_ uid: String) -> String { "presence.legacyCleared.\(uid)" }

    /// `onlyFor`: write only while this uid is the one signed in (sign-out passes its own, so a late
    /// "offline" can never land on the next account).
    static func set(online: Bool, onlyFor expected: String? = nil) async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        if let expected, uid != expected { return }
        // Privacy: audience "No One" (or the legacy toggle off) publishes offline AND never
        // updates lastActive (otherwise the timestamp still leaks "was just online").
        let legacyShare = UserDefaults.standard.object(forKey: "shareLastSeen") as? Bool ?? true
        let share = PrivacyPrefs.mine("lastSeen") != .nobody && legacyShare
        var data: [String: Any] = ["online": share ? online : false]
        if share { data["lastActive"] = FieldValue.serverTimestamp() }

        let key = "\(uid)|\(share ? online : false)|\(share)"
        let isNew = lastWritten.withLock { last -> Bool in
            guard last != key else { return false }
            last = key
            return true
        }
        guard isNew else { return }

        let db = FirestoreHub.db
        do {
            try await db.collection("users").document(uid)
                .collection("presence").document("state").setData(data, merge: true)
        } catch {
            // Not written: forget it, so the next call with the same state tries again.
            lastWritten.withLock { if $0 == key { $0 = nil } }
            return
        }

        // CLEAR THE OLD FIELDS. Every account that has ever run an older build has `online` and
        // `lastActive` sitting on its user document, where anybody can still read them — and a stale
        // "last seen 10:42" is exactly the thing somebody set to My Contacts in order to hide. Moving
        // where we WRITE would leave the leak behind; this removes it once per account on this install
        // (it used to run on every presence write, a no-op write on users/{uid} each time).
        guard !UserDefaults.standard.bool(forKey: legacyClearedKey(uid)) else { return }
        do {
            try await db.collection("users").document(uid).setData([
                "online": FieldValue.delete(),
                "lastActive": FieldValue.delete(),
            ], merge: true)
            UserDefaults.standard.set(true, forKey: legacyClearedKey(uid))
        } catch { /* try again on the next write */ }
    }
}
