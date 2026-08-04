import Foundation
import FirebaseFirestore

/// Who has switched calls off, answered SYNCHRONOUSLY.
///
/// `startCall` runs on the frame you press the button and has to decide there and then whether to
/// ring or to say "Can't Call" — it cannot await a document. So the answer is kept here, filled by
/// work the app is already doing: every users document the app reads passes through
/// `ProfilePhotoIndex.record`, which hands the privacy map straight to this. Opening a chat, opening
/// a profile, listing group members — all of them warm this for free.
///
/// A MISS MEANS RING, never refuse. If we have not seen this person's settings we place the call and
/// let their own device decline it, which is the behaviour that existed before this index and is the
/// one that cannot wrongly block a legitimate call on a stale guess.
///
/// NOT A SECURITY BOUNDARY. The callee refuses on their own side and the rules stand behind that.
/// This exists so the caller gets a sentence instead of a call that dies silently.
enum CallPrivacyIndex {
    private static var refusing: Set<String> = []
    private static var allowing: Set<String> = []

    /// Record what a users document said about calls. Called from the one hook every profile read
    /// already passes through.
    static func record(uid: String, privacy: [String: String]) {
        guard !uid.isEmpty else { return }
        if privacy["calls"] == Audience.nobody.rawValue {
            refusing.insert(uid); allowing.remove(uid)
        } else {
            allowing.insert(uid); refusing.remove(uid)
        }
    }

    /// True only when we have SEEN this person say no. Unknown answers false — see the note above.
    static func refuses(_ uid: String) -> Bool { refusing.contains(uid) }

    /// Freshen one person's answer in the background. Fired after a call is placed, so the next
    /// press is decided on something current rather than on whatever was cached at first sight.
    static func refresh(_ uid: String) async {
        guard !uid.isEmpty else { return }
        guard let snap = try? await Firestore.firestore().collection("users").document(uid).getDocument(),
              let p = snap.data()?["privacy"] as? [String: String] else { return }
        await MainActor.run { record(uid: uid, privacy: p) }
    }

    /// Sign-out: the next account must not inherit a map of who refuses calls.
    static func clear() {
        refusing.removeAll(); allowing.removeAll()
    }
}
