import Foundation
import Observation
import FirebaseAuth
import FirebaseFirestore

/// Live chat list.
///
/// ⚠️ This used to say that Firestore's own disk persistence handled cold start "so there is no
/// manual cache to maintain". That was wrong in one specific way that mattered: Firestore's cache is
/// on disk, but it answers through a CALLBACK, and a callback cannot land in the first frame. The
/// list was therefore empty for the first frames of every cold launch no matter how warm the cache
/// was — which is what the splash and the shimmer were covering. `ConversationsDiskCache` is read
/// synchronously in `start()` for exactly that window; Firestore still owns everything after it.
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
        // The full demo takeover (the demo login) has already put its data in; there is no account
        // to listen to. This is NOT the "Demo chats" switch, which leaves the real listener running
        // and has its rows added in `publish`.
        if DemoMode.active { hasLoaded = true; return }
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
        // THE FIRST FRAME, BEFORE ANY CALLBACK. Read straight off disk, on this thread, right here.
        //
        // Everything below is asynchronous — the listener, and Firestore's own persistent cache with
        // it. A callback cannot land in the first frame no matter how quick it is, so before this
        // there was always a moment with no chats in it, and the splash and the shimmer existed to
        // cover that moment. This fills it with the real list instead. The snapshot that arrives a
        // beat later replaces this, and `publish` skips it outright if nothing actually changed.
        //
        // ⚠️ `hasLoaded` is set here as well, which is what disarms the skeleton: having chats on
        // screen IS being loaded, and the shimmer must never appear over rows that are already there.
        if conversations.isEmpty {
            let cached = ConversationsDiskCache.shared.load(uid: uid)
            if !cached.isEmpty {
                conversations = cached
                hasLoaded = true
            }
        }
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
                let docs = snap.documents.map { (id: $0.documentID, data: $0.data(with: .estimate)) }
                let convs = docs.map { Conversation(id: $0.id, data: $0.data) }
                // Keep the launch cache current. The RAW documents go in, so the cache is rebuilt by
                // the same initializer the live path uses and cannot drift from it as fields are
                // added. Written off the main thread; see ConversationsDiskCache.
                ConversationsDiskCache.shared.store(docs, uid: uid)
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

    // MARK: - Arrival voice prefetch
    //
    // His "what makes them fast" order: the reference downloads a voice note when it ARRIVES, so
    // the first tap never spins. The in-chat sweep covers the chat you are inside; this covers
    // every other chat, straight off the list's own snapshots — a chat whose newest message
    // becomes a voice note from the other side gets its recent notes pulled into the AudioCache
    // before the chat is ever opened. The stamp map makes each new marker fire exactly once.
    private var voicePrefetchStamp: [String: String] = [:]
    private var voicePrefetchInFlight = Set<String>()

    private func prefetchArrivedVoice(_ convs: [Conversation]) {
        let me = Auth.auth().currentUser?.uid ?? ""
        guard !me.isEmpty else { return }
        for c in convs {
            let marker = c.lastMessageCipher
            // The voice marker is written PLAIN (sendAudio), so the prefix test needs no decrypt.
            // One-time notes also carry the 🎤 prefix and are filtered inside the fetch — they are
            // never cached anywhere, arrival included.
            guard marker.hasPrefix("🎤"), !c.lastSender.isEmpty, c.lastSender != me else { continue }
            guard voicePrefetchStamp[c.id] != marker else { continue }
            voicePrefetchStamp[c.id] = marker
            guard !voicePrefetchInFlight.contains(c.id) else { continue }
            voicePrefetchInFlight.insert(c.id)
            let cid = c.id
            Task { @MainActor [weak self] in
                await ChatService.prefetchNewestVoice(cid: cid)
                self?.voicePrefetchInFlight.remove(cid)
            }
        }
    }

    private func publish(_ raw: [Conversation]) {
        // The demo chats are added HERE and nowhere else. The live listener reassigns the whole
        // array on every snapshot, so injecting them at the switch would have them wiped a second
        // later by the next presence or typing flag. A no-op unless the switch is on.
        let convs = DemoMode.withDemoChats(raw)
        if !convs.isEmpty { rememberHadChats() }
        prefetchArrivedVoice(convs)
        // Warm the chats that just changed, so opening one lands on a full screen instead of drawing
        // a beat after the push settles. Cheap when nothing went stale — see ChatHistoryPreloader.
        // Hopped rather than called straight: this snapshot handler is not statically main-isolated,
        // and the preloader builds ThreadRepository objects, which belong to the main actor. Same
        // shape as the voice prefetch a few lines up.
        let warmList = convs
        let warmMe = Auth.auth().currentUser?.uid ?? ""
        Task { @MainActor in ChatHistoryPreloader.shared.refresh(warmList, me: warmMe) }
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

    /// The "Demo chats" switch was flipped. Redraw the list from what is already in memory rather
    /// than asking the server for anything: `publish` is where the demo rows are added and removed,
    /// so handing it the real ones is the whole operation.
    ///
    /// The filter matters on the way OFF. `publish` bails early when the array it is given equals
    /// the one on screen, and the array on screen still has the demo rows in it, so passing the
    /// current value unfiltered would compare equal and nothing would happen.
    @MainActor
    func refreshForDemo() {
        publish(conversations.filter { !DemoMode.isDemoConversation($0.id) })
    }

    /// Sign-out/delete: drop the previous account's chats so the next account on this
    /// device starts empty. Without this the singleton kept the old list alive — and the
    /// empty-cache guard in the listener then preserved it for the NEW user forever.
    func reset() {
        stop()
        pendingConvs = nil
        conversations = []
        hasLoaded = false
        // The warm-up listeners belong to an account that just went away.
        Task { @MainActor in ChatHistoryPreloader.shared.stopAll() }

    }
}
