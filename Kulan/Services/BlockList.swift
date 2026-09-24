import Foundation
import Observation
import FirebaseAuth
import FirebaseFirestore

/// 2026-09-24 decision D8: MY ACCOUNT-LEVEL BLOCK LIST, `users/{me}/blocked/{uid}`.
///
/// A block used to live only on the conversation (`blockedBy`), so somebody with no chat could not
/// be blocked at all. `ChatService.setBlocked` now writes one document per blocked person here as
/// well. The rules read it to refuse that person's CALLS only; their new chat and messages still
/// land (blocking is silent), and this list is what hides them: `ConversationsRepository` drops
/// their chat, `onNewMessage` skips the push. It also feeds the screens that show the list
/// (Settings › Blocked Users, a profile's Block row). Started by `ConversationsRepository.start`.
/// Only I can read it; the person blocked is never able to see that they are on it.
@Observable
final class BlockList {
    static let shared = BlockList()
    private init() {}

    /// uid → when I blocked them, in ms (0 while the server's time is still on its way).
    private(set) var entries: [String: Double] = [:]
    @ObservationIgnored private var listener: ListenerRegistration?
    @ObservationIgnored private var listenerUid: String?

    func contains(_ uid: String) -> Bool { entries[uid] != nil }

    /// Idempotent: a second call for the same account keeps the running listener.
    func start() {
        guard let uid = Auth.auth().currentUser?.uid, !uid.isEmpty else { return }
        if listener != nil, listenerUid == uid { return }
        listener?.remove()
        listenerUid = uid
        listener = Firestore.firestore().collection("users").document(uid).collection("blocked")
            .addSnapshotListener { [weak self] snap, _ in
                // A late snapshot must not hand one account's list to the next one on this phone.
                guard let snap, Auth.auth().currentUser?.uid == uid else { return }
                var m: [String: Double] = [:]
                for d in snap.documents {
                    let at = (d.data(with: .estimate)["at"] as? Timestamp)?.dateValue().timeIntervalSince1970 ?? 0
                    m[d.documentID] = at * 1000
                }
                DispatchQueue.main.async {
                    self?.entries = m
                    // 2026-09-24 decision D8: re-filter the chat list (silent block, see there).
                    ConversationsRepository.shared.blockListChanged()
                }
            }
    }

    /// Sign-out (SessionWipe): the next account must not inherit this one's list.
    func stop() {
        listener?.remove()
        listener = nil
        listenerUid = nil
        entries = [:]
    }
}
