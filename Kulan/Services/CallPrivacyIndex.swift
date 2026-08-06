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
    /// What each person we have SEEN chose for calls. Absent from this map means we have never read
    /// their document, which must mean ring.
    private static var audiences: [String: Audience] = [:]

    /// Record what a users document said about calls. Called from the one hook every profile read
    /// already passes through.
    ///
    /// ⚠️ TWO THINGS THIS USED TO GET WRONG, and both made the warning miss.
    ///
    /// It stored a BOOLEAN — refusing or allowing — so "My Friends" was filed as allowing. That is
    /// the commonest restriction there is, it is the DEFAULT, and a caller was never once warned
    /// about it. The owner's report was a call to somebody on My Friends.
    ///
    /// And an ABSENT `calls` key was treated as allowing, when the callee's own gate reads the
    /// default for a missing value — `.contacts`, not `.everyone`. So for anybody who had never
    /// opened the privacy screen, this index confidently disagreed with the very phone it exists to
    /// predict.
    static func record(uid: String, privacy: [String: String]) {
        guard !uid.isEmpty else { return }
        audiences[uid] = Audience(rawValue: privacy["calls"] ?? "")
            ?? PrivacyPrefs.defaultAudience(for: "calls")
    }

    /// What we know, or nil when this person has never been seen.
    static func audience(for uid: String) -> Audience? { audiences[uid] }

    /// Would their phone refuse a call from me right now, as far as we can tell?
    ///
    /// `iAmTheirContact` must be the SAME test the callee runs in `CallService.callAllowed`: is
    /// there a 1:1 conversation carrying a last message. It is ONE shared document, so both sides
    /// read the same answer — the caller just reads its local copy instead of fetching.
    ///
    /// UNKNOWN ANSWERS FALSE, always. Never having seen them means place the call and let their own
    /// device decide, which is the behaviour that existed before this index and the one that cannot
    /// wrongly block a legitimate call on a guess.
    static func refuses(_ uid: String, iAmTheirContact: Bool) -> Bool {
        switch audiences[uid] {
        case .nobody:   return true
        case .contacts: return !iAmTheirContact
        case .everyone: return false
        case nil:       return false
        }
    }

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
        audiences.removeAll()
    }
}
