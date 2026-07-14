import Foundation
import Observation
import FirebaseAuth
import FirebaseFirestore

// Locally-hidden message ids ("delete for me"): the message doc stays in Firestore for the other
// person, but we never show it here. Persisted in UserDefaults, cached in memory for cheap reads.
enum HiddenMessages {
    private static var cache = Set<String>((UserDefaults.standard.string(forKey: "hiddenMessages") ?? "")
        .split(separator: " ").map(String.init))
    static func isHidden(_ id: String) -> Bool { cache.contains(id) }
    static func hide(_ id: String) {
        guard !id.isEmpty, !cache.contains(id) else { return }
        cache.insert(id)
        UserDefaults.standard.set(cache.joined(separator: " "), forKey: "hiddenMessages")
    }
}

/// Live messages for one conversation. Loads a bounded WINDOW (most-recent page)
/// with a live listener, pages OLDER messages in on scroll-to-top, and reuses
/// already-decrypted messages so each snapshot only decrypts new/changed docs.
@Observable
final class ThreadRepository {
    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?
    private var convListener: ListenerRegistration?
    private var userListener: ListenerRegistration?
    let cid: String

    private let pageSize = 40
    // The standard approach caps the in-memory window (~500) and LRU-drops the oldest — an unbounded
    // window is a memory + main-thread cost that feeds watchdog kills on huge chats. We trim on live
    // commits above a high-water mark (paging older may exceed the cap briefly; the next live commit
    // trims back, and canLoadOlder flips true so the dropped history re-pages on scroll).
    private let windowCap = 500
    private let windowHighWater = 800
    private var windowTrimmed = false   // oldestDoc cursor no longer matches the kept window → cursor by value

    var messages: [Message] = []           // confirmed server messages (ascending)
    var pending: [Message] = []            // optimistic, not yet echoed back
    var canLoadOlder = true
    var loadingOlder = false

    // Decrypt cache: id -> built message, plus the raw (encrypted) reactions we last
    // saw, so we only rebuild a message when its one mutable field actually changes.
    private var byId: [String: Message] = [:]
    private var rawReactions: [String: String] = [:]   // id -> change signature (reactions + text cipher + edited)
    private var oldestDoc: DocumentSnapshot?   // cursor for paging older
    private var lastDocs: [QueryDocumentSnapshot] = []   // last window, to re-decrypt once the key loads
    private(set) var didInitialLoad = false

    var otherTyping = false
    var typingNames: [String] = []   // group: who is currently typing
    private var typingExpiry: Timer? // incoming typing self-clears after 15s — a crashed sender's flag can't stick
    var otherOnline = false
    var otherLastActive: Date?
    var otherLastReadMillis: Double = 0
    var memberLastRead: [String: Double] = [:]   // group: uid -> last-read time (millis); for "read by"
    var iBlocked = false
    var disappearSeconds = 0
    private var expiryTimer: Timer?
    private var otherUid = ""
    private var myBlockedAtMillis: Double = 0       // when I blocked
    private var myBlockClearedAtMillis: Double = 0  // when I unblocked (end of the hide window)
    var pinnedMessageIds: [String] = []   // up to 5 pinned messages (standard)

    init(cid: String) {
        self.cid = cid
        // Seed the last-decrypted messages SYNCHRONOUSLY so the conversation is fully rendered and
        // frozen on the first frame — before the push transition — as standard messengers do, instead of
        // fading in a beat late while the E2EE decrypt runs off the main thread. The live listener
        // in start() then reconciles silently (same ids → no visible change). First-ever open this
        // session has no cache → normal async load + reveal.
        if let cached = ThreadMessageCache.shared.messages(for: cid), !cached.isEmpty {
            messages = cached
            for m in cached { byId[m.id] = m }   // reuse them so start()'s snapshot only decrypts new/changed docs
            didInitialLoad = true
            refreshItems()
        }
    }

    /// Display list = confirmed server messages + any optimistic ones not yet echoed.
    /// Stored (not computed) so every read in one render is the same snapshot and we
    /// don't re-filter per row.
    private(set) var items: [Message] = []
    // One-producer discipline (Signal model): the repo publishes derived lookups ONCE per data change,
    // instead of every consumer re-deriving them per render/per cell. indexById kills the O(n) scans the
    // row builder / swipe gate / date pill did per call; itemsVersion lets the view cache per-emission
    // work (row signatures) instead of recomputing it on every SwiftUI body run.
    private(set) var indexById: [String: Int] = [:]
    private(set) var itemsVersion = 0
    private func refreshItems() {
        let echoed = Set(messages.compactMap { $0.clientId })
        items = (messages + pending.filter { p in !(p.clientId.map(echoed.contains) ?? false) })
            .filter { !HiddenMessages.isHidden($0.id) }   // drop messages the user deleted "for me"
        indexById = Dictionary(items.enumerated().map { ($0.element.rowId, $0.offset) },
                               uniquingKeysWith: { a, _ in a })
        itemsVersion += 1
    }

    func addPending(_ m: Message) { pending.append(m); refreshItems() }
    // "Delete for me" — hide a single message locally (the doc stays for the other person). Deleting
    // "for everyone" removes the Firestore doc instead (ChatService.deleteMessage).
    func hideForMe(_ id: String) { HiddenMessages.hide(id); refreshItems() }
    #if DEBUG
    func addDemoMessage(_ text: String, from authorId: String) {
        messages.append(Message(demoId: UUID().uuidString, from: authorId, text, Date()))
        refreshItems()
    }
    #endif
    func markFailed(clientId: String) {
        if let i = pending.firstIndex(where: { $0.clientId == clientId }) { pending[i].sendState = .failed }
        refreshItems()
    }
    func removePending(clientId: String) { pending.removeAll { $0.clientId == clientId }; refreshItems() }

    func start() {
        #if DEBUG
        if DemoMode.active {
            // Preview: serve the local demo conversation directly — no Firestore, no decryption.
            messages = DemoMode.messages(for: cid)
            didInitialLoad = true
            canLoadOlder = false
            otherOnline = true
            refreshItems()
            return
        }
        #endif
        guard let uid = Auth.auth().currentUser?.uid else { return }
        // 1:1 cid is "uidA_uidB"; a group cid is a random doc id (no underscore).
        let isOneToOne = cid.contains("_")
        let other = isOneToOne ? (cid.split(separator: "_").map(String.init).first { $0 != uid } ?? "") : ""
        otherUid = other
        stop()
        // Conversation doc: the other person's typing flag + their read timestamp.
        convListener = db.collection("conversations").document(cid)
            .addSnapshotListener { [weak self] snap, _ in
                guard let self else { return }
                let d = snap?.data()
                // Typing + lastRead are hot fields (fire on every keystroke / incoming
                // message) but never change which messages are visible — update directly,
                // skip the O(N log N) rebuild.
                if isOneToOne {
                    self.otherTyping = (d?["typing"] as? [String: Any])?[other] as? Bool ?? false
                    self.armTypingExpiry()
                    if let ts = (d?["lastRead"] as? [String: Any])?[other] as? Timestamp {
                        self.otherLastReadMillis = ts.dateValue().timeIntervalSince1970 * 1000
                    }
                } else {
                    // Group: typing = ANY other member typing; "read" = the SLOWEST other reader
                    // (a message shows read only once everyone has read it, matching the list).
                    let others = (d?["users"] as? [String] ?? []).filter { $0 != uid }
                    let typingMap = d?["typing"] as? [String: Any] ?? [:]
                    let names = d?["names"] as? [String: String] ?? [:]
                    let typers = others.filter { (typingMap[$0] as? Bool) == true }
                    self.otherTyping = !typers.isEmpty
                    self.typingNames = typers.map { names[$0] ?? "Someone" }
                    self.armTypingExpiry()
                    if !others.isEmpty {
                        let readMap = d?["lastRead"] as? [String: Any] ?? [:]
                        let times = others.map { (readMap[$0] as? Timestamp)?.dateValue().timeIntervalSince1970 ?? 0 }
                        self.otherLastReadMillis = (times.min() ?? 0) * 1000
                        // Keep the FULL per-member map too (not just the min) so a message-info screen
                        // can show exactly who has read a given message ("read by" list).
                        self.memberLastRead = Dictionary(uniqueKeysWithValues: others.map {
                            ($0, ((readMap[$0] as? Timestamp)?.dateValue().timeIntervalSince1970 ?? 0) * 1000)
                        })
                    }
                }
                // Only rebuild when a field that actually FILTERS the list changes.
                let newBlocked   = (d?["blockedBy"]      as? [String: Any])?[uid] as? Bool ?? false
                let newBlockedAt = ((d?["blockedAt"]      as? [String: Any])?[uid] as? NSNumber)?.doubleValue ?? 0
                let newClearedAt = ((d?["blockClearedAt"] as? [String: Any])?[uid] as? NSNumber)?.doubleValue ?? 0
                // Up to 5 pins (array). Fall back to the legacy single `pinnedMessageId`.
                let newPinned: [String] = (d?["pinnedMessageIds"] as? [String])
                    ?? ((d?["pinnedMessageId"] as? String).flatMap { $0.isEmpty ? nil : [$0] } ?? [])
                let newDisappear = (d?["disappearSeconds"] as? NSNumber)?.intValue ?? 0
                let needsRebuild = newBlocked   != self.iBlocked               ||
                                   newBlockedAt != self.myBlockedAtMillis      ||
                                   newClearedAt != self.myBlockClearedAtMillis ||
                                   newPinned    != self.pinnedMessageIds       ||
                                   newDisappear != self.disappearSeconds
                self.iBlocked               = newBlocked
                self.myBlockedAtMillis      = newBlockedAt
                self.myBlockClearedAtMillis = newClearedAt
                self.pinnedMessageIds       = newPinned
                self.disappearSeconds       = newDisappear
                if needsRebuild { self.rebuild() }
            }
        // The other user's presence (online / last active) — 1:1 only (no single "other" in a group).
        if isOneToOne, !other.isEmpty {
            userListener = db.collection("users").document(other)
                .addSnapshotListener { [weak self] snap, _ in
                    let d = snap?.data()
                    self?.otherOnline = d?["online"] as? Bool ?? false
                    if let ts = d?["lastActive"] as? Timestamp { self?.otherLastActive = ts.dateValue() }
                }
        }
        expiryTimer?.invalidate()
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.sweepExpired()
            self?.sweepStuckSends()
        }
        // Attach the message listener IMMEDIATELY — the thread must paint without waiting
        // on key fetches. (Bug fixed: previously this listener was created only AFTER
        // awaiting ensureReady() + preloadKey(), so a slow key fetch — common when opening
        // a NEW chat — left the screen stuck on a loading spinner for many seconds.)
        // Live listener over the most-recent page only (bounds first paint, memory, and
        // Firestore reads regardless of how long the history is).
        listener = db.collection("conversations").document(cid).collection("messages")
            .order(by: "createdAt", descending: true)
            .limit(to: pageSize)
            .addSnapshotListener { [weak self] snap, _ in
                guard let self, let snap else { return }
                // Don't blank an open thread on an empty offline snapshot.
                if snap.metadata.isFromCache && snap.documents.isEmpty && !self.messages.isEmpty { return }
                // Pass whether this is a cache/local snapshot — deletes are only trusted from the SERVER
                // (a from-cache/resync snapshot can transiently drop docs that still exist → the "message
                // gone for a few seconds then comes back" bug).
                self.applyLiveSnapshot(snap.documents, fromCache: snap.metadata.isFromCache)
            }
        // Load keys in the BACKGROUND (in parallel). Warming the recipient's key here also
        // means the first send is instant instead of blocking on the fetch. Once the key
        // arrives, re-decrypt the current window (existing chats may briefly show "…").
        Task {
            try? await Crypto.shared.ensureReady()
            // Preload EVERY member's public key (groups), not just a cid-derived "other" —
            // group messages can only be decrypted with their author's key, so all members'
            // keys must be cached or their messages render as "…".
            let members = await Self.memberUids(cid: cid, fallbackOther: other)
            await withTaskGroup(of: Void.self) { g in
                for m in members where m != uid { g.addTask { _ = await Crypto.shared.preloadKey(m) } }
            }
            await MainActor.run {
                guard !self.lastDocs.isEmpty else { return }   // new chat: nothing to re-decrypt
                // Force a re-decrypt of the window (keys just arrived) WITHOUT clearing byId: emptying it
                // blanked the whole list until the off-main decrypt finished AND dropped any paged-older
                // history. Clearing only the sig cache makes applyLiveSnapshot re-decrypt the window while
                // byId stays populated, so nothing ever goes blank and older messages are preserved.
                self.rawReactions.removeAll()
                self.applyLiveSnapshot(self.lastDocs, fromCache: false)
            }
        }
    }

    // All member uids for a cid: prefer the loaded conversation; fall back to fetching the
    // doc (a just-created group may not be in the repo yet); else the 1:1 "other".
    private static func memberUids(cid: String, fallbackOther: String) async -> [String] {
        if let conv = ConversationsRepository.shared.conversations.first(where: { $0.id == cid }) {
            return conv.users
        }
        if let snap = try? await Firestore.firestore().collection("conversations").document(cid).getDocument(),
           let users = snap.data()?["users"] as? [String] {
            return users
        }
        return fallbackOther.isEmpty ? [] : [fallbackOther]
    }

    // Stable change signature for the MUTABLE fields of a message doc: reactions, the text cipher
    // (EDITS — the old reactions-only gate meant an edited message never re-rendered), and the edited
    // flag. Reaction keys are sorted so the signature is deterministic.
    private func changeSig(_ data: [String: Any]) -> String {
        let raw = (data["reactions"] as? [String: String]) ?? [:]
        let reactions = raw.keys.sorted().map { "\($0)=\(raw[$0] ?? "")" }.joined(separator: ",")
        return (data["text"] as? String ?? "") + "|" + String(data["edited"] as? Bool ?? false) + "|" + reactions
    }

    // Build a message, reusing the cached copy unless a mutable field (reactions / edit) changed.
    @discardableResult
    private func buildCached(_ doc: QueryDocumentSnapshot) -> Message {
        let id = doc.documentID, data = doc.data()
        let sig = changeSig(data)
        if let cached = byId[id], rawReactions[id] == sig { return cached }
        let m = Message(id: id, data: data, cid: cid, crypto: Crypto.shared)
        byId[id] = m
        rawReactions[id] = sig
        return m
    }

    // Monotonic snapshot sequencing: detached decrypt batches can finish out of order; the
    // committed sequence guards against an OLDER batch overwriting a newer one (which would
    // resurrect deleted messages / revert reactions).
    private var snapshotSeq = 0
    private var committedSeq = 0

    // Apply the live (recent-window) snapshot: refresh/insert the window's messages,
    // reconcile deletes within the window's time range, keep paged-older messages.
    private func applyLiveSnapshot(_ docs: [QueryDocumentSnapshot], fromCache: Bool) {
        lastDocs = docs   // remember the window so we can re-decrypt once the key arrives
        snapshotSeq += 1
        let seq = snapshotSeq
        // Decrypt OFF the main thread. Opening a chat that already has cached history fires
        // this listener INSTANTLY with up to a full page; decrypting it all on the main
        // thread froze the UI during the navigation transition (the tester's "tap → gray →
        // hang"). Only NEW or reaction-changed docs are decrypted; the rest are reused.
        // (box.open is a thread-safe pure op, and my keys are set before any chat can open.)
        let sigs = Dictionary(uniqueKeysWithValues: docs.map { ($0.documentID, changeSig($0.data())) })
        let needBuild = docs.filter { doc in
            byId[doc.documentID] == nil || rawReactions[doc.documentID] != sigs[doc.documentID]
        }
        guard !needBuild.isEmpty else { commitSnapshot(docs, seq: seq, fromCache: fromCache); return }
        let cidLocal = cid
        Task.detached(priority: .userInitiated) { [weak self] in
            let built: [(String, Message)] = needBuild.map { doc in
                (doc.documentID, Message(id: doc.documentID, data: doc.data(), cid: cidLocal, crypto: Crypto.shared))
            }
            await MainActor.run {
                guard let self else { return }
                // Drop this batch if a NEWER snapshot already committed (out-of-order completion).
                guard seq >= self.committedSeq else { return }
                for (id, m) in built { self.byId[id] = m; self.rawReactions[id] = sigs[id] ?? "" }
                self.commitSnapshot(docs, seq: seq, fromCache: fromCache)
            }
        }
    }

    // Reconcile the window (deletes, paging cursor, first-load flag) and republish — runs
    // on the main thread AFTER the (off-main) decryption merges its results into the cache.
    private func commitSnapshot(_ docs: [QueryDocumentSnapshot], seq: Int, fromCache: Bool) {
        guard seq >= committedSeq else { return }   // never let an older snapshot overwrite a newer one
        committedSeq = seq
        let windowIds = Set(docs.map { $0.documentID })
        // A doc missing from the window but newer than its oldest edge was deleted — but ONLY trust the
        // SERVER for this. A from-cache/resync snapshot can transiently omit a doc that still exists;
        // deleting on it made the message vanish for a few seconds until the next full snapshot re-added
        // it ("gone then comes back"). Cache snapshots may still ADD/UPDATE (below), just never DELETE.
        if !fromCache, let oldest = docs.last, let cutoff = (oldest.data()["createdAt"] as? Timestamp)?.dateValue() {
            for (id, m) in byId where m.createdAt >= cutoff && !windowIds.contains(id) {
                byId.removeValue(forKey: id); rawReactions.removeValue(forKey: id)
            }
        }
        if oldestDoc == nil { oldestDoc = docs.last }
        if !didInitialLoad {
            didInitialLoad = true
            if docs.count < pageSize { canLoadOlder = false }   // short first page => no history
        }
        trimWindowIfNeeded()
        rebuild()
        let echoed = Set(byId.values.compactMap { $0.clientId })
        pending.removeAll { p in p.clientId.map(echoed.contains) ?? false }
    }

    // Incoming typing self-clears after 15s without a refresh: if the
    // sender's app crashed/lost network before writing typing=false, the bubble would otherwise stick
    // until some other doc change. Re-armed on every snapshot where typing is (still) true.
    private func armTypingExpiry() {
        typingExpiry?.invalidate(); typingExpiry = nil
        guard otherTyping else { return }
        typingExpiry = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            self?.otherTyping = false
            self?.typingNames = []
        }
    }

    // Failed-message sweep, adapted: a bubble must never spin "sending" forever. Any
    // optimistic message still .sending after 2 minutes flips to .failed ("Tap to retry"). If its
    // upload later succeeds anyway, the server echo removes the pending — the state self-corrects.
    private func sweepStuckSends() {
        let cutoff = Date().addingTimeInterval(-120)
        var changed = false
        for i in pending.indices where pending[i].sendState == .sending && pending[i].createdAt < cutoff {
            pending[i].sendState = .failed
            changed = true
        }
        if changed { refreshItems() }
    }

    // True while the reader is AWAY from the bottom (reading history) — fed by the view. The trim must
    // never run then: it LRU-drops the OLDEST rows, which are exactly the rows under the reader — the
    // deletion yanked the viewport ("the conversation scrolls back while I read old messages"). Trimming
    // resumes as soon as they return to the bottom, so the memory cap still holds over time.
    var readerAwayFromBottom = false

    // LRU-drop the OLDEST messages once the window blows past the high-water mark (the standard 500-cap).
    // Runs only on live commits — never right after loadOlder, so paging isn't undone under the reader.
    private func trimWindowIfNeeded() {
        guard !readerAwayFromBottom else { return }
        guard byId.count > windowHighWater else { return }
        let sorted = byId.values.sorted { $0.createdAt < $1.createdAt }
        for m in sorted.prefix(sorted.count - windowCap) {
            byId.removeValue(forKey: m.id); rawReactions.removeValue(forKey: m.id)
        }
        windowTrimmed = true
        canLoadOlder = true   // the dropped history can page back in on scroll
    }

    // Periodic sweep so messages disappear over time even while the chat is open;
    // also deletes my own expired messages from Firestore.
    private func sweepExpired() {
        guard disappearSeconds > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(disappearSeconds))
        let me = Auth.auth().currentUser?.uid
        for m in byId.values where m.authorId == me && m.createdAt < cutoff {
            Task { await ChatService.deleteMessage(cid: cid, messageId: m.id) }
        }
        rebuild()
    }

    private func rebuild() {
        var msgs = byId.values.filter { !hiddenByBlock($0) }
        if disappearSeconds > 0 {   // hide messages past the disappearing timer
            let cutoff = Date().addingTimeInterval(-Double(disappearSeconds))
            msgs = msgs.filter { $0.createdAt >= cutoff }
        }
        if iBlocked {
            // Also silence the blocked person's reactions on my messages (their activity is hidden).
            msgs = msgs.map { m in
                guard m.reactions[otherUid] != nil else { return m }
                var c = m; c.reactions.removeValue(forKey: otherUid); return c
            }
        }
        var sorted = msgs.sorted { $0.createdAt < $1.createdAt }
        // Double-echo dedupe: a retry racing a slow-but-successful original can produce TWO server docs
        // with the same clientId. Show only the FIRST (earlier) one — the duplicate is invisible to the
        // user even before any server-side cleanup.
        var seenClientIds = Set<String>()
        sorted.removeAll { m in
            guard let c = m.clientId else { return false }
            return !seenClientIds.insert(c).inserted
        }
        messages = sorted
        ThreadMessageCache.shared.store(cid, messages)   // keep the warm cache fresh for the next open (instant render)
        refreshItems()
    }

    // Silent block: hide the other person's messages that landed during the block.
    // While blocked → hide everything after I blocked. After unblock → keep hiding
    // just the block window (blockedAt … blockClearedAt) so the backlog never arrives.
    private func hiddenByBlock(_ m: Message) -> Bool {
        guard m.authorId == otherUid, myBlockedAtMillis > 0 else { return false }
        let t = m.createdAt.timeIntervalSince1970 * 1000
        if iBlocked { return t > myBlockedAtMillis }
        return t > myBlockedAtMillis && t <= myBlockClearedAtMillis
    }

    /// Page in the next older window (called on scroll-to-top). `completion` runs after
    /// the list updates so the view can restore the scroll anchor (no jump).
    func loadOlder(completion: @escaping () -> Void = {}) {
        guard canLoadOlder, !loadingOlder else { completion(); return }
        let base = db.collection("conversations").document(cid).collection("messages")
            .order(by: "createdAt", descending: true)
        // After a window trim the doc-snapshot cursor points BELOW the dropped range, so cursor by the
        // oldest KEPT message's value instead — dropped history pages back in seamlessly.
        let query: Query
        if windowTrimmed, let oldest = messages.first {
            query = base.start(after: [Timestamp(date: oldest.createdAt)])
        } else if let cursor = oldestDoc {
            query = base.start(afterDocument: cursor)
        } else { completion(); return }
        loadingOlder = true
        query
            .limit(to: pageSize)
            .getDocuments { [weak self] snap, _ in
                guard let self else { return }
                let docs = snap?.documents ?? []
                for doc in docs { self.buildCached(doc) }
                if let last = docs.last { self.oldestDoc = last }
                if docs.count < self.pageSize { self.canLoadOlder = false }
                self.loadingOlder = false
                self.rebuild()
                completion()
            }
    }

    // Page older history until `messageId` is loaded (so in-chat search can scroll to a match that's
    // far above the current window), or we run out of history. Bounded so a bad id can't loop forever.
    @MainActor
    func ensureLoaded(_ messageId: String, maxPages: Int = 12) async {   // 12×40 ≈ the window cap — never page unbounded history into memory
        var pages = 0
        while !items.contains(where: { $0.id == messageId }) && canLoadOlder && pages < maxPages {
            await withCheckedContinuation { cont in loadOlder { cont.resume() } }
            pages += 1
        }
    }

    func stop() {
        listener?.remove(); listener = nil
        convListener?.remove(); convListener = nil
        userListener?.remove(); userListener = nil
        expiryTimer?.invalidate(); expiryTimer = nil
        typingExpiry?.invalidate(); typingExpiry = nil
    }

    deinit { listener?.remove(); convListener?.remove(); userListener?.remove(); expiryTimer?.invalidate(); typingExpiry?.invalidate() }
}
