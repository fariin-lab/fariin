import Foundation
import FirebaseAuth
import FirebaseFirestore

/// The owner's side of profile photo privacy — owner, 2026-09-25.
///
///  · The AUDIENCE (Everyone / My Chats / No One) lives in `users/{uid}.privacy.photo`, as before.
///  · HIDE FROM is new: people who never see the photo whatever the audience says, one document each
///    in `users/{uid}/photoHiddenFrom/{viewer}` (owner-only; see firestore.rules).
///
/// Both are ENFORCED by `storage.rules` (`canSeePhoto`), not by the screens. This type only edits the
/// list and, after any change, asks `ProfileStore.republishPhoto()` to give the photo a new name so
/// every viewer's cached copy is bypassed and the rules are asked again.
@MainActor @Observable
final class PhotoPrivacy {
    static let shared = PhotoPrivacy()

    /// Hidden account ids, newest first. Empty until `load()` has run.
    private(set) var hidden: [String] = []
    private(set) var loaded = false
    private var loadedFor: String?

    private func col(_ uid: String) -> CollectionReference {
        Firestore.firestore().collection("users").document(uid).collection("photoHiddenFrom")
    }

    func load() async {
        guard let uid = Auth.auth().currentUser?.uid else { hidden = []; loaded = false; return }
        guard let snap = try? await col(uid).order(by: "at", descending: true).getDocuments() else { return }
        hidden = snap.documents.map(\.documentID)
        loaded = true
        loadedFor = uid
    }

    func add(_ uids: [String]) async throws {
        guard let me = Auth.auth().currentUser?.uid else { return }
        let fresh = uids.filter { $0 != me && !hidden.contains($0) }
        guard !fresh.isEmpty else { return }
        let batch = Firestore.firestore().batch()
        for u in fresh { batch.setData(["at": FieldValue.serverTimestamp()], forDocument: col(me).document(u)) }
        try await batch.commit()
        hidden.insert(contentsOf: fresh, at: 0)
        await ProfileStore.shared.republishPhoto()
    }

    func remove(_ uid: String) async throws {
        guard let me = Auth.auth().currentUser?.uid else { return }
        try await col(me).document(uid).delete()
        hidden.removeAll { $0 == uid }
        await ProfileStore.shared.republishPhoto()
    }

    /// The blurry cover (`photoThumb`) sits in the user record, which any signed-in account can read,
    /// so it may only be published when the photo itself is visible to everybody: audience Everyone
    /// and nobody on the Hide From list.
    func publishesCover() async -> Bool {
        guard PrivacyPrefs.mine("photo") == .everyone else { return false }
        if !loaded || loadedFor != Auth.auth().currentUser?.uid { await load() }
        return loaded && hidden.isEmpty
    }

    /// Sign-out: the next account starts with nothing.
    func reset() { hidden = []; loaded = false; loadedFor = nil }
}
