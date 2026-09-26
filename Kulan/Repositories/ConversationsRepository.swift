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
    /// 2026-09-24 audit: the listener ended in an error and no snapshot has arrived since. A failed
    /// listener used to print and nothing else, and the 3s safety net below then flipped `hasLoaded`,
    /// so a returning account whose chats could not load was shown the first-run welcome. The chat
    /// list reads this ahead of its empty state and offers a retry instead. Firestore ends a listener
    /// for good once it errors, so the retry is a fresh `start()`.
    var loadFailed = false

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

    // MARK: - Window (2026-09-24 fix-all #6)
    //
    // The query used to have no bound at all: every conversation this account was ever a member of
    // (cleared, declined, long dead) was downloaded on every attach, for the life of the account.
    // It is now the newest `pageSize` by `updatedAt`, and the list asks for the next page when it
    // is scrolled to its end (`loadOlder`). Needs the composite index users(CONTAINS) +
    // updatedAt(DESC) in firestore.indexes.json, deployed before an app build that carries this.
    static let pageSize = 300
    /// 2026-09-24 feature-audit: the ceiling on the window. One listener over this many documents is
    /// already far past any real account; past it the paging stops instead of growing without end.
    static let maxWindow = pageSize * 20
    @ObservationIgnored private var windowLimit = ConversationsRepository.pageSize
    /// The last snapshot filled the window, so there may be older chats on the server.
    /// 2026-09-24 feature-audit: only a SERVER answer may lower this; see the listener.
    var hasOlder = false
    /// A bigger window has been asked for and its first snapshot has not landed yet.
    var loadingOlder = false
    @ObservationIgnored private var listenerUid: String?

    /// 2026-09-24 feature-audit: there is an older page and the window may still grow to fetch it.
    var canLoadOlder: Bool { hasOlder && windowLimit < Self.maxWindow }

    /// 2026-09-24 fix-all #6: the next page. The listener is re-attached with a bigger limit, so the
    /// chats already on screen come straight back from the local cache and only the older ones cost
    /// reads. A no-op while a page is already on its way or there is nothing older.
    func loadOlder() {
        guard canLoadOlder, !loadingOlder, listener != nil, !DemoMode.active else { return }
        loadingOlder = true
        // 2026-09-24 feature-audit: one page at a time, never past the ceiling.
        windowLimit = min(windowLimit + Self.pageSize, Self.maxWindow)
        attach()
    }

    // MARK: - Whole-list modes (2026-09-24 feature-audit)
    //
    // Nothing a person owns may become unreachable. A search, a filter other than All, the Message
    // Requests page and the Archive page all need EVERY chat, not the newest page of them, so while
    // any of them is showing the window keeps growing, one page per server answer, until the server
    // says there is nothing older. The plain All list still pages only when scrolled to its end.
    @ObservationIgnored private var wholeListHolders = Set<String>()
    /// A screen needs the whole list and older pages are still coming in. The screens show a
    /// loading row while this is true, and hold back an empty state that is not settled yet.
    var loadingWholeList = false

    /// `holder` names the screen (or mode) so two of them can overlap without one switching the
    /// other off.
    func needWholeList(_ holder: String, _ on: Bool) {
        if on { wholeListHolders.insert(holder) } else { wholeListHolders.remove(holder) }
        continueWholeList()
    }

    /// Asks for the next page while a holder still needs one. Called again after every server answer.
    private func continueWholeList() {
        let want = !wholeListHolders.isEmpty && canLoadOlder && !loadFailed && !DemoMode.active
        if loadingWholeList != want { loadingWholeList = want }
        if want { loadOlder() }
    }

    func start() {
        // The full demo takeover (the demo login) has already put its data in; there is no account
        // to listen to. This is NOT the "Demo chats" switch, which leaves the real listener running
        // and has its rows added in `publish`.
        if DemoMode.active { hasLoaded = true; return }
        // 2026-09-24 fix-all #57: ONE LISTENER FOR THE APP, NOT ONE PER SCREEN. The Chats tab, the
        // Archive, and both search pages each call this from their own `onAppear`, and every call
        // used to tear the running listener down and attach a fresh one (a full re-fetch, just for
        // pushing a screen that reads the same data). Decision: the listener lives for the signed-in
        // session (the tab badge and the unread total read it on every tab), so no screen releases
        // it and a count of holders would never reach zero; `start()` is simply idempotent. It
        // re-attaches only when nothing is attached, the account changed, or the last one failed
        // (Firestore ends a listener for good on an error, which is what "Try Again" relies on).
        if listener != nil, !loadFailed, let uid = Auth.auth().currentUser?.uid, uid == listenerUid { return }
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
        // 2026-09-24 decision D8: my account block list, which `hideAccountBlocked` reads. Idempotent.
        BlockList.shared.start()
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
            // 2026-09-26 block rebuild: through the block filter too. The disk copy is the RAW list,
            // and `BlockList.start()` above has already put this account's saved list in memory.
            let cached = hideAccountBlocked(ConversationsDiskCache.shared.load(uid: uid), me: uid)
            if !cached.isEmpty {
                conversations = cached
                hasLoaded = true
            }
        }
        // 2026-09-24 fix-all #6: a new account (or the first attach) starts from one page again.
        if listenerUid != uid { windowLimit = Self.pageSize; hasOlder = false; loadingOlder = false }
        attach()
        Task { try? await Crypto.shared.ensureReady() }   // key setup in the background
    }

    /// 2026-09-24 fix-all #6: the listener itself, split out of `start()` so `loadOlder` can widen
    /// the window without re-running the launch-only work above.
    private func attach() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        stop()
        listenerUid = uid
        let limit = windowLimit
        // Attach the listener IMMEDIATELY — never block the chat list behind ensureReady.
        // Cached chats render instantly (hasLoaded flips on the first non-empty snapshot);
        // a true cold start shows the skeleton until the server responds.
        listener = db.collection("conversations")
            .whereField("users", arrayContains: uid)
            .order(by: "updatedAt", descending: true)
            .limit(to: limit)
            .addSnapshotListener { [weak self] snap, error in
                guard let self, let snap else {
                    if let error {
                        print("conversations listen error:", error)
                        // 2026-09-24 audit: see `loadFailed`. `hasLoaded` too, because we HAVE heard
                        // back, and it is what takes the skeleton down so the error can show.
                        self?.loadFailed = true
                        self?.hasLoaded = true
                        self?.loadingOlder = false
                        self?.loadingWholeList = false   // 2026-09-24 feature-audit: no page is coming now
                    }
                    return
                }
                if self.loadFailed { self.loadFailed = false }
                // 2026-09-24 fix-all #6: a full window means there may be more behind it. Only a
                // server answer settles a page request; the cache can hand back fewer than exist.
                // 2026-09-24 feature-audit: and only a server answer may say "nothing older". A cache
                // snapshot right after the window widened holds fewer than the limit, and used to
                // flip this off, stop the paging and drop every pinned chat kept below the window.
                let fromServer = !snap.metadata.isFromCache
                let full = snap.documents.count >= limit
                if fromServer || full { self.hasOlder = full }
                if fromServer {
                    self.loadingOlder = false
                    // 2026-09-24 feature-audit: the next page for a whole-list screen, after this
                    // snapshot has been published (hopped, so it never re-attaches from inside it).
                    DispatchQueue.main.async { [weak self] in self?.continueWholeList() }
                }
                // ⚠️ REPORTED BEFORE THE GUARD BELOW, on purpose. The empty-cached case is exactly
                // the offline cold start, and it is the one the header most needs to hear about —
                // returning first would make this listener silent precisely when it has the most to
                // say. One line, no extra read; see `ConnectionStatus`.
                Task { @MainActor in ConnectionStatus.shared.noteSnapshot(fromCache: snap.metadata.isFromCache) }
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
                // 2026-09-24 decision D8: the raw list is kept so a block list change can re-filter it.
                self.lastRaw = convs
                // 2026-09-24 fix-all #6: a pinned chat older than the window stays on the list.
                self.syncPinnedExtras(convs, uid: uid, fromServer: !snap.metadata.isFromCache)
                // 2026-09-26 block rebuild: NOTHING IS PUBLISHED BEFORE MY BLOCK LIST HAS ANSWERED.
                // This listener can beat the block list's own; a chat from somebody I blocked, and
                // its preview, would be on screen for that moment. `blockListChanged` publishes the
                // held list the instant the block list lands (from its saved copy, usually at once).
                guard BlockList.shared.isLoaded else { return }
                let visible = self.hideAccountBlocked(self.withPinnedExtras(convs), me: uid)
                UnknownChatArchiver.sweep(visible)
                self.publish(visible)
                // 2026-09-25 delivered ticks: this phone has these chats' newest messages now. Only
                // from the server (a cached snapshot proves nothing arrived), and never for a chat
                // I blocked, so a blocked sender keeps seeing one tick.
                if !snap.metadata.isFromCache { Task { @MainActor in DeliveryReceipts.mark(visible, me: uid) } }

                // Warm recipient public keys so last-message previews can decrypt — CONCURRENTLY
                // (was N sequential round-trips → slow cold start). preloadKey is cached, so the
                // re-run on later snapshots is mostly hits.
                Task {
                    // ⛔ AND TELL THE LIST WHEN A KEY ARRIVES — owner, 2026-09-11: "when I send a
                    // message for someone for request message, in the chat list I can't see the
                    // message I sent ... 2 people I sent request message but the message I sent I
                    // can't see."
                    //
                    // ⚠️ THE PREVIEW WAS NOT EMPTY, IT WAS THE "KEYS NOT READY" MARKER. `decrypt`
                    // returns "…" when the other person's public key is not in the cache yet, and
                    // that ellipsis is exactly what he photographed. The order here is what put it
                    // there: `publish` hands the rows to SwiftUI, the rows decrypt immediately, and
                    // only THEN does this task fetch the keys they needed.
                    //
                    // ⚠️ WHY IT ONLY BIT REQUEST CHATS, which is the part worth keeping. The sentinel
                    // is deliberately not memoised (see `decryptCached`), so any later render heals
                    // it — and a busy chat gets one within seconds, because every typing flag and
                    // read receipt is another snapshot. A request nobody has answered produces NO
                    // further snapshots at all: the one message is the last thing that will ever
                    // happen in it until they reply. So the first render was the only render, and
                    // the ellipsis was permanent in precisely the chats that never change.
                    //
                    // Republishing once, and only when something was actually fetched, is the whole
                    // fix: the rows re-decrypt with the keys now in hand. `wasCached` costs a
                    // dictionary read, so a snapshot whose keys are all warm — which is nearly all
                    // of them — does nothing at all.
                    var fetchedAny = false
                    await withTaskGroup(of: Bool.self) { group in
                        for c in convs {
                            let key = c.isGroup ? c.lastSender : c.otherUid(uid)
                            guard !key.isEmpty else { continue }
                            group.addTask {
                                let alreadyWarm = Crypto.shared.hasCachedKey(key)
                                _ = await Crypto.shared.preloadKey(key)
                                return !alreadyWarm && Crypto.shared.hasCachedKey(key)
                            }
                        }
                        for await didFetch in group where didFetch { fetchedAny = true }
                    }
                    guard fetchedAny else { return }
                    await MainActor.run { self.republishForKeys() }
                }
            }
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

    /// ⛔ NUDGE THE LIST AFTER A KEY LANDS — see the warm task in the listener for the report and the
    /// reasoning. This is NOT a re-run of `publish`: that would re-add the demo chats, re-run the
    /// voice prefetch and re-warm the history preloader, none of which has anything to do with a
    /// public key arriving. All that is needed is for SwiftUI to ask the rows for their text again.
    ///
    /// ⚠️ REASSIGNING THE SAME VALUES IS THE POINT, not a mistake. `Conversation` is `Equatable` and
    /// nothing about it has changed — what changed is a cache OUTSIDE it, which `@Observable` cannot
    /// see. Writing the array is the one thing that makes the rows re-decrypt. It happens at most
    /// once per genuinely new key, so it is not a loop and not a per-snapshot cost.
    @MainActor
    private func republishForKeys() {
        guard !conversations.isEmpty else { return }
        let current = conversations
        conversations = []
        conversations = current
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
        // 2026-09-24 feature-audit: only the chats near the top. The window arrives newest first, so
        // its first page is the top of the list; a chat that was only PAGED IN (a search, a filter,
        // the archive) is not about to be opened and no longer queues a warm-up. It rejoins the
        // first page the moment anything happens in it. A pinned chat counts as near the top.
        let warmMe = Auth.auth().currentUser?.uid ?? ""
        let warmList = Array(convs.prefix(Self.pageSize))
            + convs.dropFirst(Self.pageSize).filter { $0.isPinned(warmMe) }
        Task { @MainActor in ChatHistoryPreloader.shared.refresh(warmList, me: warmMe) }
        guard convs != conversations else { hasLoaded = true; return }   // no-op snapshot → no re-render
        if Date().timeIntervalSince(lastPublish) >= minPublishInterval {
            lastPublish = Date()
            conversations = convs
            hasLoaded = true
            // 2026-09-24 fix-all #166: the app badge follows the list, so a read on another device lowers it.
            Task { @MainActor in NotificationCleaner.syncBadgeFromList() }
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
                    Task { @MainActor in NotificationCleaner.syncBadgeFromList() }   // 2026-09-24 fix-all #166
                }
            }
        }
    }

    // MARK: - Account block list (2026-09-24 decision D8, rebuilt 2026-09-26)
    //
    // Blocking is SILENT: the rules let a blocked person's new chat and messages land, so they look
    // sent to them. The blocker must never see them.
    //   · A chat that was ours before the block stays on my list, frozen at the block
    //     (`Conversation.displayUpdatedAt`, `leaksBlocked`): its history is mine, and the thread
    //     shows it with an Unblock bar, the way the reference apps do.
    //   · A REQUEST from somebody I blocked (theirs, never accepted) is dropped here, before every
    //     screen (chat list, requests, search, forward) reads it: blocking a request removes it, and
    //     a new one they send while blocked never appears.
    @ObservationIgnored private var lastRaw: [Conversation] = []

    private func hideAccountBlocked(_ convs: [Conversation], me: String) -> [Conversation] {
        guard !me.isEmpty else { return convs }
        let list = BlockList.snapshot
        guard !list.entries.isEmpty || convs.contains(where: { $0.blockedBy[me] == true }) else { return convs }
        return convs.filter { c in
            guard !c.isGroup, c.isBlockedByMe(me) else { return true }
            let theirRequest = !c.accepted && !c.startedBy.isEmpty && c.startedBy != me
            return !theirRequest
        }
    }

    /// Called by `BlockList` when my list changes (or first loads), so a block or unblock applies to
    /// the list at once, and a list held back for it is published.
    func blockListChanged() {
        guard listener != nil, !lastRaw.isEmpty, let me = Auth.auth().currentUser?.uid,
              BlockList.shared.isLoaded else { return }
        let visible = hideAccountBlocked(withPinnedExtras(lastRaw), me: me)
        publish(visible)
        BlockList.shared.migrate(lastRaw)
    }

    // MARK: - Pinned chats older than the window (2026-09-24 fix-all #6)
    //
    // The window is the newest `pageSize` chats, and a pin does not bump `updatedAt`, so on a big
    // account a chat pinned long ago can sit below the window and would drop off the top of the
    // list. The pinned ids are remembered per account; any that a FULL window does not contain get
    // a listener of their own on that one document (pins are few, so this is a handful at most).
    // A window that is not full holds every chat there is, so a remembered id missing from it was
    // unpinned, left or deleted and is forgotten.
    @ObservationIgnored private var pinnedExtraListeners: [String: ListenerRegistration] = [:]
    @ObservationIgnored private var pinnedExtraDocs: [String: Conversation] = [:]

    private func pinnedIdsKey(_ uid: String) -> String { "pinnedChatIds-\(uid)" }

    private func syncPinnedExtras(_ window: [Conversation], uid: String, fromServer: Bool) {
        let inWindow = Set(window.map(\.id))
        let pinnedInWindow = Set(window.filter { $0.isPinned(uid) }.map(\.id))
        let remembered = Set(UserDefaults.standard.stringArray(forKey: pinnedIdsKey(uid)) ?? [])
        let outside = hasOlder ? remembered.subtracting(inWindow) : []
        // Only a server answer may forget an id: a cold cache can hold fewer chats than exist.
        let keep = fromServer ? pinnedInWindow.union(outside) : pinnedInWindow.union(remembered)
        UserDefaults.standard.set(Array(keep), forKey: pinnedIdsKey(uid))
        // 2026-09-24 feature-audit: and only a server answer may tear a listener down. A cache
        // snapshot can only ADD pinned chats; it used to remove every one kept below the window.
        for id in Array(pinnedExtraListeners.keys) where fromServer && !outside.contains(id) {
            pinnedExtraListeners.removeValue(forKey: id)?.remove()
            pinnedExtraDocs[id] = nil
        }
        for id in outside where pinnedExtraListeners[id] == nil {
            pinnedExtraListeners[id] = db.collection("conversations").document(id)
                .addSnapshotListener { [weak self] snap, _ in
                    guard let self else { return }
                    // Offline and not cached yet says nothing about the chat; wait for the server.
                    if let snap, snap.metadata.isFromCache, !snap.exists { return }
                    guard let snap, snap.exists, let data = snap.data(with: .estimate),
                          (data["users"] as? [String] ?? []).contains(uid) else {
                        self.forgetPinnedExtra(id, uid: uid); return
                    }
                    let c = Conversation(id: snap.documentID, data: data)
                    // 2026-09-24 feature-audit: a cleared chat (delete for me) is off every list, so
                    // its listener is released like an unpinned one. A new message un-clears it and
                    // brings it back to the top of the window, where its pin is remembered again.
                    guard c.isPinned(uid), !c.isCleared(uid) else { self.forgetPinnedExtra(id, uid: uid); return }
                    self.pinnedExtraDocs[id] = c
                    self.blockListChanged()   // re-publish the window with this chat merged in
                }
        }
    }

    private func forgetPinnedExtra(_ id: String, uid: String) {
        pinnedExtraListeners.removeValue(forKey: id)?.remove()
        let had = pinnedExtraDocs.removeValue(forKey: id) != nil
        let kept = (UserDefaults.standard.stringArray(forKey: pinnedIdsKey(uid)) ?? []).filter { $0 != id }
        UserDefaults.standard.set(kept, forKey: pinnedIdsKey(uid))
        if had { blockListChanged() }
    }

    /// The window plus any pinned chat that sits below it (never twice: the window wins).
    private func withPinnedExtras(_ window: [Conversation]) -> [Conversation] {
        guard !pinnedExtraDocs.isEmpty else { return window }
        let inWindow = Set(window.map(\.id))
        return window + pinnedExtraDocs.values.filter { !inWindow.contains($0.id) }
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
        // 2026-09-24 fix-all #6: the per-document pin listeners and the window belong to the old account.
        pinnedExtraListeners.values.forEach { $0.remove() }
        pinnedExtraListeners = [:]
        pinnedExtraDocs = [:]
        listenerUid = nil
        windowLimit = Self.pageSize
        hasOlder = false
        loadingOlder = false
        loadingWholeList = false   // 2026-09-24 feature-audit
        pendingConvs = nil
        lastRaw = []   // 2026-09-24 decision D8
        conversations = []
        hasLoaded = false
        loadFailed = false   // 2026-09-24 audit: belongs to the account that just went away
        // The warm-up listeners belong to an account that just went away.
        Task { @MainActor in ChatHistoryPreloader.shared.stopAll() }

    }
}
