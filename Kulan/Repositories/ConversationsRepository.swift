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
        #if DEBUG
        if DemoMode.active { hasLoaded = true; return }   // demo data already injected; don't let Firebase overwrite it
        #endif
        // Safety net FIRST — before the uid guard / listener — so the chat-list skeleton can NEVER spin
        // forever: even if auth isn't ready yet, or Firestore's realtime channel is blocked/slow (a cloud
        // simulator like Appetize, or a brand-new user on a poor connection). Real chats clear it sooner.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.hasLoaded = true }
        guard let uid = Auth.auth().currentUser?.uid else { return }
        stop()
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
                self.publish(convs)

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

    // Coalesced publish (Signal's DatabaseChangeObserver idea): the conversations query fires on EVERY
    // hot-field change in ANY chat (typing flags, lastRead, presence-adjacent fields), and reassigning
    // the whole array each time forces a full SwiftUI chat-list recomputation. Publish immediately when
    // idle, but collapse bursts to one publish per interval — and skip no-op snapshots entirely.
    private var pendingConvs: [Conversation]?
    private var lastPublish = Date.distantPast
    private var flushScheduled = false
    private let minPublishInterval: TimeInterval = 0.15

    private func publish(_ convs: [Conversation]) {
        guard convs != conversations else { hasLoaded = true; return }   // no-op snapshot → no re-render
        if Date().timeIntervalSince(lastPublish) >= minPublishInterval {
            lastPublish = Date()
            conversations = convs
            hasLoaded = true
        } else {
            pendingConvs = convs
            guard !flushScheduled else { return }
            flushScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + minPublishInterval) { [weak self] in
                guard let self else { return }
                self.flushScheduled = false
                if let p = self.pendingConvs {
                    self.pendingConvs = nil
                    self.lastPublish = Date()
                    if p != self.conversations { self.conversations = p }
                    self.hasLoaded = true
                }
            }
        }
    }

    func stop() {
        listener?.remove()
        listener = nil
    }
}
