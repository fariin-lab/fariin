import Foundation
import FirebaseAuth
import FirebaseFirestore
import StoryUI

/// GET NOTIFICATIONS FOR ONE PERSON'S STORIES — owner, 2026-10-16: "by default always need to click
/// Get notifications if you want to get that user every time upload story notification, but never
/// one button to open all users". The reference app's "Notify About Stories", per person.
///
/// Off for everybody until it is turned on for someone, and there is deliberately no switch for
/// everybody at once. Each person turned on is one document `{at, author}` at
/// `users/{me}/storyNotify/{them}`, which only I can read (firestore.rules), so nobody can learn who
/// follows their stories. The push itself is the server's (`onStoryCreated` → `notifyStoryFollowers`):
/// it goes only to people the story was sent to, and never to someone who has blocked the author.
@MainActor @Observable
final class StoryNotifyStore {
    static let shared = StoryNotifyStore()
    private init() {}

    /// The authors whose new stories notify this account.
    private(set) var on: Set<String> = []
    @ObservationIgnored private var loadedFor: String?
    @ObservationIgnored private var loadingFor: String?

    /// Read by the story menu while it draws, so it only ever SCHEDULES the load: writing observed
    /// state in the middle of a view update is not allowed.
    func isOn(_ author: String) -> Bool {
        let me = Auth.auth().currentUser?.uid
        if me != loadedFor, me != loadingFor { Task { await load() } }
        // Not gated on `loadedFor`: a bell turned on before the list arrived must read as on.
        return me != nil && on.contains(author)
    }

    /// Turns it on or off for `author` and answers the new state. The menu changes at once; a write
    /// the server refuses puts it back.
    @discardableResult
    func toggle(_ author: String) -> Bool {
        guard let me = Auth.auth().currentUser?.uid, !author.isEmpty, author != me else { return false }
        let ref = Firestore.firestore().collection("users").document(me)
            .collection("storyNotify").document(author)
        if on.contains(author) {
            on.remove(author)
            ref.delete { err in
                guard err != nil else { return }
                Task { @MainActor in if Auth.auth().currentUser?.uid == me { StoryNotifyStore.shared.on.insert(author) } }
            }
            return false
        }
        on.insert(author)
        // `author` is how the server finds this follow (stories carry hashed audiences, not uids).
        ref.setData(["at": FieldValue.serverTimestamp(), "author": author]) { err in
            guard err != nil else { return }
            Task { @MainActor in if Auth.auth().currentUser?.uid == me { StoryNotifyStore.shared.on.remove(author) } }
        }
        return true
    }

    private func load() async {
        guard let me = Auth.auth().currentUser?.uid else { on = []; loadedFor = nil; return }
        loadingFor = me
        defer { if loadingFor == me { loadingFor = nil } }
        // Another account's list goes the moment the account changes, not when this one arrives.
        if loadedFor != me { on = []; loadedFor = nil }
        guard let snap = try? await Firestore.firestore().collection("users").document(me)
            .collection("storyNotify").getDocuments(),
              Auth.auth().currentUser?.uid == me else { return }
        // Union, not replace: one tapped while this was on its way is already in `on` and its write
        // may not be in the snapshot yet.
        on.formUnion(snap.documents.map(\.documentID))
        loadedFor = me
    }

    /// The story menu's question, answered for the viewer package. Nil = not offered: my own story
    /// and the official account.
    static func installSeam() {
        // Asked from the menu's body, which is always the main thread.
        StoryNotifySeam.isOn = { author in
            MainActor.assumeIsolated {
                guard !author.isEmpty, author != Auth.auth().currentUser?.uid,
                      !OfficialChannel.isOfficial(author) else { return nil }
                return StoryNotifyStore.shared.isOn(author)
            }
        }
    }
}
