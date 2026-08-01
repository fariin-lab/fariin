import Foundation
import FirebaseAuth
import FirebaseFirestore

// Writes my online/last-active state so the other person sees "online" / "last seen".
enum PresenceService {
    static func set(online: Bool) async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        // Privacy: audience "No One" (or the legacy toggle off) publishes offline AND never
        // updates lastActive (otherwise the timestamp still leaks "was just online").
        // "My Contacts" still publishes — reader clients enforce who qualifies.
        let legacyShare = UserDefaults.standard.object(forKey: "shareLastSeen") as? Bool ?? true
        let share = PrivacyPrefs.mine("lastSeen") != .nobody && legacyShare
        var data: [String: Any] = ["online": share ? online : false]
        if share { data["lastActive"] = FieldValue.serverTimestamp() }
        try? await Firestore.firestore().collection("users").document(uid).setData(data, merge: true)
    }
}
