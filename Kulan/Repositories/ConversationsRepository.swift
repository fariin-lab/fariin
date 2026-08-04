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

    /// The skeleton is for a genuinely COLD load, not for the ~100ms Firestore's persistent cache
    /// takes to hand back chats it already has on disk. Shown immediately, it flashed shimmer rows
    /// on EVERY launch and replaced them almost at once, which reads as the app struggling to find
    /// its own data (owner screenshots). It is armed only if the first snapshot has still not
    /// arrived after a beat, so a warm launch goes straight from splash to real rows.
    var skeletonArmed = false

    // "Has this account ever shown a non-empty chat list on this device?" — decides whether the FIRST
    // load may show the skeleton. A fresh sign-up has nothing coming, and shimmer rows there fake
    // content that does not exist (user report: "first time sign up have this loading, what is this");
    // they go straight to the empty state instead. A returning account, whose chats really are on the
    // way, keeps the skeleton. Keyed per uid so switching accounts on one device stays honest.
    var expectsChats: Bool {
        guard let uid = Auth.auth().currentUser?.uid else { return false }
        return UserDefaults.standard.bool(forKey: "everHadChats-\(uid)")
    }
    private func rememberHadChats() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let key = "everHadChats-\(uid)"
        if !UserDefaults.standard.bool(forKey: key) { UserDefaults.standard.set(true, forKey: key) }
    }

    func start() {
        #if DEBUG
        if DemoMode.active { hasLoaded = true; return }   // demo data already injected; don't let Firebase overwrite it
        #endif
        // Safety net FIRST — before the uid guard / listener — so the chat-list skeleton can NEVER spin
        // forever: even if auth isn't ready yet, or Firestore's realtime channel is blocked/slow (a cloud
        // simulator like Appetize, or a brand-new user on a poor connection). Real chats clear it sooner.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.hasLoaded = true }
        skeletonArmed = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !self.hasLoaded else { return }   // cache already answered; never flash
            self.skeletonArmed = true
        }
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
                // .estimate: an offline send leaves updatedAt as a PENDING server timestamp,
                // which plain data() reads as nil → updatedAtMillis 0 → isCleared() treats the
                // chat as delete-for-me and it vanishes from the list until the server acks.
                let convs = snap.documents.map { Conversation(id: $0.documentID, data: $0.data(with: .estimate)) }
                // "Automatically Archive new chats from unknown users" (Settings > Chats). Here
                // rather than inside publish() because publish coalesces and can skip a snapshot
                // outright — this must see every one, since the request it has to catch may arrive
                // in a snapshot that changes nothing else. No-op while the setting is off.
                UnknownChatArchiver.sweep(convs)
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

    // Coalesced publish (change-observer idea): the conversations query fires on EVERY
    // hot-field change in ANY chat (typing flags, lastRead, presence-adjacent fields), and reassigning
    // the whole array each time forces a full SwiftUI chat-list recomputation. Publish immediately when
    // idle, but collapse bursts to one publish per interval — and skip no-op snapshots entirely.
    private var pendingConvs: [Conversation]?
    private var lastPublish = Date.distantPast
    private var flushScheduled = false
    private let minPublishInterval: TimeInterval = 0.15

    private func publish(_ convs: [Conversation]) {
        if !convs.isEmpty { rememberHadChats() }
        guard convs != conversations else { hasLoaded = true; return }   // no-op snapshot → no re-render
        if Date().timeIntervalSince(lastPublish) >= minPublishInterval {
            lastPublish = Date()
            conversations = convs
            hasLoaded = true
            // Drop anything the flush was still holding (audit): an immediate publish left an older
            // buffered snapshot armed, and the scheduled flush then assigned it OVER this newer one —
            // the list regressed up to 150ms and stayed wrong until the next server event, which on a
            // quiet account can be minutes. Newest wins is the whole point of the coalescer.
            pendingConvs = nil
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

    /// Sign-out/delete: drop the previous account's chats so the next account on this
    /// device starts empty. Without this the singleton kept the old list alive — and the
    /// empty-cache guard in the listener then preserved it for the NEW user forever.
    func reset() {
        stop()
        pendingConvs = nil
        conversations = []
        hasLoaded = false

    }
}
