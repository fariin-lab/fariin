import Foundation
import FirebaseAuth
import FirebaseFirestore

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
    static func set(online: Bool) async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        // Privacy: audience "No One" (or the legacy toggle off) publishes offline AND never
        // updates lastActive (otherwise the timestamp still leaks "was just online").
        let legacyShare = UserDefaults.standard.object(forKey: "shareLastSeen") as? Bool ?? true
        let share = PrivacyPrefs.mine("lastSeen") != .nobody && legacyShare
        var data: [String: Any] = ["online": share ? online : false]
        if share { data["lastActive"] = FieldValue.serverTimestamp() }

        let db = Firestore.firestore()
        try? await db.collection("users").document(uid)
            .collection("presence").document("state").setData(data, merge: true)

        // CLEAR THE OLD FIELDS. Every account that has ever run an older build has `online` and
        // `lastActive` sitting on its user document, where anybody can still read them — and a stale
        // "last seen 10:42" is exactly the thing somebody set to My Contacts in order to hide. Moving
        // where we WRITE would leave the leak behind; this removes it, once, on the next presence
        // write, which happens on every launch.
        try? await db.collection("users").document(uid).setData([
            "online": FieldValue.delete(),
            "lastActive": FieldValue.delete(),
        ], merge: true)
    }
}
