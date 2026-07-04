import Foundation
import Observation
import FirebaseAuth
import FirebaseFirestore

/// Live chat list. Native Firestore disk persistence handles offline/cold-start,
/// so there is no manual AsyncStorage cache to maintain.
@Observable
final class ConversationsRepository {
    static let shared = ConversationsRepository()
    private init() {}

    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?

    var conversations: [Conversation] = []
    var hasLoaded = false   // false until the first real snapshot -> drives the skeleton

    func start() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        stop()
        // Safety net: always clear the skeleton after a few seconds. On a fresh/empty account only an
        // empty CACHED snapshot arrives (ignored below to protect offline chats), so without this the
        // skeleton spins forever when the server is slow/unreachable — e.g. a cloud simulator
        // (Appetize) or a brand-new user's first launch. Real chats load before this and clear it sooner.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.hasLoaded = true }
        // Attach the listener IMMEDIATELY — never block the chat list behind ensureReady.
        // Cached chats render instantly (hasLoaded flips on the first non-empty snapshot);
        // a true cold start shows the skeleton until the server responds.
        listener = db.collection("conversations")
            .whereField("users", arrayContains: uid)
            .addSnapshotListener { [weak self] snap, error in
                guard let self, let snap else {
                    if let error { print("conversations listen error:", error) }
                    return
                }
                // Offline cold-start: ignore an empty cached snapshot so the
                // last-known chats stay visible (parity with the RN fromCache guard).
                if snap.metadata.isFromCache && snap.documents.isEmpty { return }

                // No sort here — every consumer (ChatsView, SearchViews) applies its own
                // richer comparator (pins, recency). Sorting twice was wasted CPU.
                let convs = snap.documents.map { Conversation(id: $0.documentID, data: $0.data()) }
                self.conversations = convs
                self.hasLoaded = true

                // Warm recipient public keys so last-message previews can decrypt — CONCURRENTLY
                // (was N sequential round-trips → slow cold start). preloadKey is cached, so the
                // re-run on later snapshots is mostly hits.
                Task {
                    await withTaskGroup(of: Void.self) { group in
                        for c in convs {
                            let key = c.isGroup ? c.lastSender : c.otherUid(uid)
                            guard !key.isEmpty else { continue }
                            group.addTask { _ = await Crypto.shared.preloadKey(key) }
                        }
                    }
                }
            }
        Task { try? await Crypto.shared.ensureReady() }   // key setup in the background
    }

    func stop() {
        listener?.remove()
        listener = nil
    }
}
