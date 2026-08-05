import Foundation
import Observation
import FirebaseAuth
import FirebaseFirestore

// Locally-hidden message ids ("delete for me"): the message doc stays in Firestore for the other
// person, but we never show it here. Persisted in UserDefaults, cached in memory for cheap reads.
// Optimistic bubbles for a chat that is NOT OPEN YET.
//
// `addPending` only ever reaches the repository of the chat you are standing in. A normal send never
// notices, because it is already in the chat it is sending to. A FORWARD is the one case that is
// not: you land in the target chat and the bubble cannot exist yet, so you sit looking at nothing
// through a download, a decrypt, a re-encrypt and an upload before the photo appears (owner report).
//
// A forward parks its bubble here first, and the repository picks it up the moment that chat opens.
// Reconciliation is entirely unchanged: the bubble carries a clientId, and refreshItems already
// drops any pending whose clientId comes back in a real message.
//
// In memory only, deliberately. A forward that does not outlive the app being killed is a forward
// that never left, and SendQueue already owns durable retry for text.
enum PendingOutbox {
    private static var byCid: [String: [Message]] = [:]
    private static let lock = NSLock()

    /// Posted so a chat that is ALREADY OPEN can claim this straight away.
    ///
    /// `take` is a drain and the repository only calls it as it starts, so anything parked for a
    /// chat the user is currently standing in would have sat here untouched until the next open.
    /// That is why ForwardPicker used to skip the source chat entirely: a bubble it could not
    /// deliver was worse than none. With this the open chat hears about it and the forward draws
    /// as fast as a normal send does.
    static let didAdd = Notification.Name("PendingOutbox.didAdd")

    static func add(_ m: Message, to cid: String) {
        lock.lock(); byCid[cid, default: []].append(m); lock.unlock()
        // AFTER the unlock. An observer on this thread can call straight back into `take`.
        NotificationCenter.default.post(name: didAdd, object: cid)
    }

    /// Drained, not copied. The repository owns them from here, so a second open cannot resurrect a
    /// bubble whose real message has already landed.
    static func take(_ cid: String) -> [Message] {
        lock.lock(); defer { lock.unlock() }
        return byCid.removeValue(forKey: cid) ?? []
    }

    /// A forward that failed before its chat was ever opened must not leave a bubble waiting there
    /// to greet the user later.
    static func remove(clientId: String) {
        lock.lock(); defer { lock.unlock() }
        for (cid, list) in byCid {
            let kept = list.filter { $0.clientId != clientId }
            if kept.isEmpty { byCid.removeValue(forKey: cid) } else { byCid[cid] = kept }
        }
    }

    /// Sign-out: these are decrypted previews of the previous account's messages.
    static func removeAll() { lock.lock(); byCid.removeAll(); lock.unlock() }

    static let didFail = Notification.Name("PendingOutbox.didFail")

    /// The forward failed, so nothing is coming to replace its bubble.
    ///
    /// Two places can be holding it and ForwardPicker can reach neither: the outbox if that chat was
    /// never opened, and the chat's own repository if the user is standing in it right now. Clearing
    /// one and not the other leaves a bubble stuck on "sending" for the rest of the session, which
    /// reads as the app losing the message rather than failing to send it.
    static func markFailed(clientId: String) {
        remove(clientId: clientId)
        NotificationCenter.default.post(name: didFail, object: clientId)
    }
}

enum HiddenMessages {
    private static var cache = Set<String>((UserDefaults.standard.string(forKey: "hiddenMessages") ?? "")
        .split(separator: " ").map(String.init))
    static func isHidden(_ id: String) -> Bool { cache.contains(id) }
    static func hide(_ id: String) {
        guard !id.isEmpty, !cache.contains(id) else { return }
        cache.insert(id)
        UserDefaults.standard.set(cache.joined(separator: " "), forKey: "hiddenMessages")
    }
    /// Sign-out: the stored key is cleared by SessionWipe, but this in-memory copy would keep
    /// hiding the previous account's ids until relaunch.
    static func clear() {
        cache.removeAll()
        UserDefaults.standard.removeObject(forKey: "hiddenMessages")
    }
}

/// Live messages for one conversation. Loads a bounded WINDOW (most-recent page)
/// with a live listener, pages OLDER messages in on scroll-to-top, and reuses
/// already-decrypted messages so each snapshot only decrypts new/changed docs.
@Observable
final class ThreadRepository {
    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?
    private var outboxObserver: NSObjectProtocol?
    private var outboxAddObserver: NSObjectProtocol?
    private var convListener: ListenerRegistration?
    private var userListener: ListenerRegistration?
    /// Separate from `userListener` because presence lives in its own subcollection now, so the
    /// server can enforce the Last Seen audience rather than the reading client. See PresenceService.
    private var presenceListener: ListenerRegistration?
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
    // Optimistic, not yet echoed back. Mirrored into ThreadMessageCache on every change so leaving the
    // conversation cannot throw away a send that is still owed — this repository is per-cid and dies when
    // you navigate away, which is why an offline message vanished on reopen.
    var pending: [Message] = [] {
        didSet { ThreadMessageCache.shared.storePending(cid, pending) }
    }
    var canLoadOlder = true
    var loadingOlder = false

    // Decrypt cache: id -> built message, plus the raw (encrypted) reactions we last
    // saw, so we only rebuild a message when its one mutable field actually changes.
    private var byId: [String: Message] = [:]
    private var rawReactions: [String: String] = [:]   // id -> change signature (reactions + text cipher + edited)
    // Ids the user has just deleted for everyone, whose server write has not come back yet. Applied as
    // an overlay in rebuild() so the bubble reads as deleted immediately; cleared the moment the real
    // tombstone (or the message's removal) arrives. See markDeletedLocally.
    private var locallyDeleted: Set<String> = []
    private var oldestDoc: DocumentSnapshot?   // cursor for paging older
    private var lastDocs: [QueryDocumentSnapshot] = []   // last window, to re-decrypt once the key loads
    private(set) var didInitialLoad = false

    /// Same rule as the chat list's: the skeleton is for a genuinely cold chat, not for the moment
    /// the cache takes to hand back messages it already holds. Shown immediately it flashed grey
    /// bubbles during the push into EVERY chat, including ones fully cached (owner screenshot).
    /// Armed only if the first page has still not arrived after a beat.
    var skeletonArmed = false

    private(set) var convLoaded = false   // first conversation-doc snapshot landed (block state is real)
    var otherTyping = false
    var otherRecording = false       // someone is recording a voice note (string "audio…" in the typing map)
    var typingNames: [String] = []   // group: who is currently typing
    private var typingExpiry: Timer? // incoming typing self-clears after 15s — a crashed sender's flag can't stick
    var otherOnline = false
    var otherLastActive: Date?
    var otherPrivacy: [String: String] = [:]   // their per-field audience map (users doc)
    var otherLastReadMillis: Double = 0
    var memberLastRead: [String: Double] = [:]   // group: uid -> last-read time (millis); for "read by"
    var iBlocked = false
    var disappearSeconds = 0
    private var expiryTimer: Timer?
    private var otherUid = ""
    private var myBlockedAtMillis: Double = 0       // when I blocked
    private var myBlockClearedAtMillis: Double = 0  // when I unblocked (end of the hide window)
    var pinnedMessageIds: [String] = []   // up to 5 pinned messages (standard)

    // THE PINNED MESSAGES THEMSELVES, fetched by id and independent of how far back the chat is
    // loaded. This is the reference app's model, read from their source: `pinnedMessageData(for:)` reads the
    // message out of their own database, and their banner shows nothing at all rather than a
    // placeholder (ConversationViewController+PinnedMessages.swift:93, +Banners.swift:1204).
    //
    // Ours used to resolve a pin against the loaded window, which is the screen, not the chat. A pin
    // is usually old and old messages are not loaded until you scroll back, so the bar had nothing to
    // draw and said "Pinned Message / Tap to view" — the owner's report, twice.
    //
    // At most five documents, one read each, only when the pin list changes.
    private(set) var pinnedPreviews: [String: Message] = [:]
    /// Pins whose document is REALLY gone. Only ever set from a snapshot that came back and said the
    /// document does not exist — never from an error, because a failed read means "no signal" as
    /// often as it means "deleted", and treating those the same is what put the word "deleted" in
    /// front of him for a message that was merely old.
    private(set) var pinnedGone: Set<String> = []
    private var pinnedFetching: Set<String> = []

    /// Keep `pinnedPreviews` in step with the pin list: forget what is no longer pinned, take
    /// anything already in the window for free, and fetch the rest by id.
    private func syncPinnedPreviews() {
        let ids = Set(pinnedMessageIds)
        pinnedPreviews = pinnedPreviews.filter { ids.contains($0.key) }
        pinnedGone = pinnedGone.filter { ids.contains($0) }
        for id in ids where pinnedPreviews[id] == nil && !pinnedFetching.contains(id) {
            if let inWindow = byId[id] { keepPinned(inWindow); continue }
            pinnedFetching.insert(id)
            db.collection("conversations").document(cid).collection("messages").document(id)
                .getDocument { [weak self] snap, _ in
                    guard let self else { return }
                    self.pinnedFetching.remove(id)
                    guard let snap else { return }        // error: leave it unknown, try again next time
                    guard snap.exists, let data = snap.data() else {
                        self.pinnedGone.insert(id)        // the document really is not there
                        return
                    }
                    self.keepPinned(Message(id: id, data: data, cid: self.cid, crypto: Crypto.shared))
                }
        }
    }

    /// A TOMBSTONE counts as gone. Delete-for-everyone already unpins, so this only catches the case
    /// where that write was refused and the pin outlived the message — but the pin bar must never be
    /// the one place in the app still showing something you deleted.
    private func keepPinned(_ m: Message) {
        if m.deleted { pinnedGone.insert(m.id) } else { pinnedPreviews[m.id] = m }
    }

    init(cid: String) {
        self.cid = cid
        // Restore anything still unsent from a previous visit to this chat, BEFORE the cached window is
        // seeded, so a pending message is on screen from the very first frame with its sending/failed
        // state intact and its retry affordance available.
        pending = ThreadMessageCache.shared.pending(for: cid)
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
    // One-producer discipline (the reference app model): the repo publishes derived lookups ONCE per data change,
    // instead of every consumer re-deriving them per render/per cell. indexById kills the O(n) scans the
    // row builder / swipe gate / date pill did per call; itemsVersion lets the view cache per-emission
    // work (row signatures) instead of recomputing it on every SwiftUI body run.
    private(set) var indexById: [String: Int] = [:]
    private(set) var itemsVersion = 0
    private func refreshItems() {
        let echoed = Set(messages.compactMap { $0.clientId })
        // Pending sends are MERGED by send time, not appended: an uploading photo stays exactly where
        // it was sent even when later texts confirm first (order never shuffles on upload finish).
        var merged = (messages + pending.filter { p in !(p.clientId.map(echoed.contains) ?? false) })
            .sorted { $0.sortAt == $1.sortAt ? $0.rowId < $1.rowId : $0.sortAt < $1.sortAt }
            .filter { !HiddenMessages.isHidden($0.id) }   // drop messages the user deleted "for me"

        // ROW IDS MUST BE UNIQUE. `rowId` is `clientId ?? id`, and the list feeds it straight into a
        // diffable snapshot — `appendItemsWithIdentifiers:` throws an NSInternalInconsistencyException on
        // a repeat, which is an instant abort, not a glitch. Three crash reports from the user's phone
        // (builds 380, 381 and 384, 2026-07-27) are exactly that stack.
        //
        // Every individual path that can produce a collision is already defended: the listener drops a
        // double echo sharing a clientId, retry removes the old pending before adding the new one, and
        // `indexById` two lines down has always used `uniquingKeysWith` — which is the tell. Someone knew
        // duplicates could reach here and protected the dictionary while leaving `items` itself, the thing
        // that actually crashes, unprotected. Rather than hunt for one more path, this makes the invariant
        // true at the funnel where `items` is produced. First occurrence wins, matching the double-echo
        // rule that the EARLIER message is the real one.
        var seenRowIds = Set<String>()
        seenRowIds.reserveCapacity(merged.count)
        merged.removeAll { !seenRowIds.insert($0.rowId).inserted }
        items = merged

        indexById = Dictionary(items.enumerated().map { ($0.element.rowId, $0.offset) },
                               uniquingKeysWith: { a, _ in a })
        itemsVersion += 1
    }

    func addPending(_ m: Message) { pending.append(m); refreshItems() }

    /// Give an already-visible pending message the file a retry would re-send.
    ///
    /// Needed because the video path now draws its bubble BEFORE the transcode runs, so at
    /// `addPending` time the transcoded mp4 does not exist yet and there is no path to attach. Every
    /// other send path has its bytes in hand first and sets `localMediaURL` up front.
    ///
    /// Without this the bubble would sit there with no payload, and a failed video would retry as
    /// its own thumbnail — a photo instead of the video, which is the exact data loss the retry file
    /// was introduced to stop.
    func attachRetryPayload(clientId: String, path: String) {
        guard let i = pending.firstIndex(where: { $0.clientId == clientId }) else { return }
        pending[i].localMediaURL = path
        refreshItems()
    }
    // "Delete for me" — hide a single message locally (the doc stays for the other person). Deleting
    // "for everyone" removes the Firestore doc instead (ChatService.deleteMessage).
    func hideForMe(_ id: String) { HiddenMessages.hide(id); refreshItems() }

    /// Optimistic "Delete for Everyone": the bubble becomes a tombstone HERE, the moment the user
    /// taps, instead of after a doc read, a write and the listener echo — a full network round trip
    /// with nothing moving on screen, which read as the delete not working.
    ///
    /// This is an OVERLAY, not an edit: `byId` keeps the real message and `rebuild` tombstones it on
    /// the way out. That matters because the delete is not instant on the wire. Editing `byId`
    /// directly meant any unrelated snapshot arriving in that one-second gap (the other person sends
    /// something) would rebuild this message from a doc the server has not stripped yet and flash the
    /// photo back before the write landed. An overlay cannot be undone by a snapshot.
    ///
    /// Returns false when there is nothing to do, so the caller knows there is nothing to undo.
    @discardableResult
    func markDeletedLocally(_ id: String) -> Bool {
        guard let m = byId[id], !m.deleted, !locallyDeleted.contains(id) else { return false }
        locallyDeleted.insert(id)
        rebuild()
        return true
    }

    /// The server refused the delete: drop the overlay and the real message is back, untouched.
    func restoreAfterFailedDelete(_ id: String) {
        guard locallyDeleted.remove(id) != nil else { return }
        rebuild()
    }
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
        skeletonArmed = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !self.didInitialLoad else { return }   // cache already answered
            self.skeletonArmed = true
        }
        // Anything a forward parked for this chat before we existed. Claimed BEFORE the listener
        // attaches, so the bubble is on screen on the first frame rather than appearing a beat later.
        pending.append(contentsOf: PendingOutbox.take(cid))
        // A forward can fail while its chat is open, and ForwardPicker has no handle on us to say so.
        if outboxObserver == nil {
            outboxObserver = NotificationCenter.default.addObserver(
                forName: PendingOutbox.didFail, object: nil, queue: .main) { [weak self] n in
                    if let id = n.object as? String { self?.markFailed(clientId: id) }
                }
        }
        // And a forward can ARRIVE while its chat is open — forwarding back into the chat you are
        // standing in is the commonest case of all. The drain above already ran, so without this the
        // bubble would wait for the server echo while every other chat got one instantly.
        if outboxAddObserver == nil {
            outboxAddObserver = NotificationCenter.default.addObserver(
                forName: PendingOutbox.didAdd, object: nil, queue: .main) { [weak self] n in
                    guard let self, n.object as? String == self.cid else { return }
                    let claimed = PendingOutbox.take(self.cid)
                    guard !claimed.isEmpty else { return }
                    self.pending.append(contentsOf: claimed)
                    self.refreshItems()
                }
        }
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
                self.convLoaded = true
                let d = snap?.data()
                // Typing + lastRead are hot fields (fire on every keystroke / incoming
                // message) but never change which messages are visible — update directly,
                // skip the O(N log N) rebuild.
                if isOneToOne {
                    // Typing = Bool true (older builds) OR the "text-<seconds>" refresh string —
                    // the changing value is what re-arms the 15s expiry during a long composing burst.
                    let tv = (d?["typing"] as? [String: Any])?[other]
                    self.otherTyping = tv as? Bool == true || (tv as? String)?.hasPrefix("text") == true
                    self.otherRecording = (tv as? String)?.hasPrefix("audio") == true
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
                    let typers = others.filter {
                        (typingMap[$0] as? Bool) == true || (typingMap[$0] as? String)?.hasPrefix("text") == true
                    }
                    self.otherTyping = !typers.isEmpty
                    self.otherRecording = others.contains { (typingMap[$0] as? String)?.hasPrefix("audio") == true }
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
                let pinsChanged = newPinned != self.pinnedMessageIds
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
                // Only when the list actually changed: this snapshot also fires for every typing
                // flicker and every read receipt.
                if pinsChanged { self.syncPinnedPreviews() }
                if needsRebuild { self.rebuild() }
            }
        // The other user's presence (online / last active) — 1:1 only (no single "other" in a group).
        //
        // TWO listeners now, because presence moved off the user document into
        // `users/{other}/presence/state` so the server can enforce "Last Seen: My Contacts" instead of
        // trusting the reading app to (see PresenceService). The privacy MAP stays on the user
        // document — it has to be readable by anyone, since it is what tells a stranger's client what
        // it may show in the first place.
        //
        // A denied presence read is a normal outcome here, not an error: it is what somebody who has
        // hidden their last seen from non-contacts looks like. The snapshot simply never arrives and
        // the header shows nothing, which is exactly right.
        if isOneToOne, !other.isEmpty {
            userListener = db.collection("users").document(other)
                .addSnapshotListener { [weak self] snap, _ in
                    self?.otherPrivacy = (snap?.data()?["privacy"] as? [String: String]) ?? [:]
                }
            presenceListener = db.collection("users").document(other)
                .collection("presence").document("state")
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
                guard let self else { return }
                guard let snap else {
                    // Listener ERROR (seen in the wild: a brand-new chat opened from search sat on
                    // the skeleton FOREVER). A dead listener must never freeze the screen — reveal
                    // the (empty) chat and re-attach after a beat.
                    self.didInitialLoad = true
                    self.retryStartSoon()
                    return
                }
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
    // (EDITS — the old reactions-only gate meant an edited message never re-rendered), the edited
    // flag, the album array, and the deleted flag + type (tombstones, see below).
    // Reaction keys are sorted so the signature is deterministic.
    private func changeSig(_ data: [String: Any]) -> String {
        let raw = (data["reactions"] as? [String: String]) ?? [:]
        let reactions = raw.keys.sorted().map { "\($0)=\(raw[$0] ?? "")" }.joined(separator: ",")
        // The ALBUM ARRAY is mutable too: deleteAlbumItem rewrites it for everyone, but the signature
        // ignored it, so the recipient's open chat reused the cached Message with the old array and
        // the deleted photo stayed on screen until relaunch (audit). Count + urls is enough to notice.
        let album = (data["album"] as? [[String: Any]]) ?? []
        let albumSig = "\(album.count):" + album.compactMap { $0["imageUrl"] as? String }.joined(separator: ",")
        // DELETED AND TYPE, and this is what made "delete for everyone" look broken on media.
        // A tombstone is an UPDATE, not a removal: the doc survives with deleted=true, text="",
        // type="text" and every media field stripped. For a TEXT message the cipher goes from the
        // user's words to empty, so the signature moved and the bubble redrew. For a photo, gif,
        // voice note, file or sticker WITHOUT a caption, text was already empty and stayed empty,
        // reactions and album were empty on both sides, so the signature was byte-identical before
        // and after. buildCached then handed back the CACHED pre-delete Message and needBuild came
        // out empty, so the new doc was never even read. The server really had deleted it; this
        // screen simply never found out, and it survived a relaunch too because rebuild() persists
        // `messages` into ThreadMessageCache. That is the owner's stuck forwarded gif: not the
        // Firestore rules, not gifs, just any media message with no caption.
        let deleted = String(data["deleted"] as? Bool ?? false)
        let type = data["type"] as? String ?? ""
        return (data["text"] as? String ?? "") + "|" + String(data["edited"] as? Bool ?? false)
            + "|" + reactions + "|" + albumSig + "|" + deleted + "|" + type
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

    // Re-attach the whole listener set after a listener error (bounded — never an error loop).
    private var listenerRetries = 0
    private func retryStartSoon() {
        guard listenerRetries < 3 else { return }
        listenerRetries += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.start()
        }
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
        if !fromCache, docs.isEmpty {
            // The SERVER says the collection is now EMPTY (everything deleted for everyone / the
            // disappearing sweep finished on the other device). The cutoff loop below is skipped when
            // there's no oldest doc, which used to keep every cached message alive — and re-persist the
            // ghosts to the warm cache, so even reopening showed a fully-deleted conversation forever.
            byId.removeAll(); rawReactions.removeAll()
        } else if !fromCache, let oldest = docs.last, let cutoff = (oldest.data()["createdAt"] as? Timestamp)?.dateValue() {
            for (id, m) in byId where m.createdAt >= cutoff && !windowIds.contains(id) {
                byId.removeValue(forKey: id); rawReactions.removeValue(forKey: id)
            }
        }
        // The optimistic delete overlay has done its job once the real thing is in hand: the doc now
        // carries `deleted`, or the message is not here at all (hard-delete fallback, or paged out of
        // the window, where the overlay is inert anyway). Firestore applies our own write locally
        // before it reaches the server, so this usually clears on the very next snapshot.
        if !locallyDeleted.isEmpty {
            locallyDeleted = locallyDeleted.filter { byId[$0]?.deleted == false }
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
        guard otherTyping || otherRecording else { return }
        // Recording outlives 15s routinely — the sender refreshes the flag every 10s (each refresh
        // changes the value, so a snapshot re-arms this). The expiry only catches crashed senders.
        typingExpiry = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            self?.otherTyping = false
            self?.otherRecording = false
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
    // True while ensureLoaded pages toward a jump target: the jump can start FROM the bottom (the
    // scroll hasn't happened yet, so readerAwayFromBottom is still false), and a live commit mid-loop
    // used to trim away the very pages the jump just loaded — the loop re-paged, the trim re-dropped,
    // and the jump silently failed after burning its page budget (audit M7).
    private var jumpPagingInFlight = false

    // LRU-drop the OLDEST messages once the window blows past the high-water mark (the standard 500-cap).
    // Runs only on live commits — never right after loadOlder, so paging isn't undone under the reader.
    private func trimWindowIfNeeded() {
        guard !readerAwayFromBottom, !jumpPagingInFlight else { return }
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
        // Deletes the user has made but the server has not confirmed yet (see markDeletedLocally).
        // Ids for messages that are no longer here at all cost nothing and are pruned on the next
        // confirmed snapshot.
        if !locallyDeleted.isEmpty {
            msgs = msgs.map { locallyDeleted.contains($0.id) && !$0.deleted ? $0.tombstoned() : $0 }
        }
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
        // Sort by SEND time (sortAt = sender tap time when present) — a slow-uploading photo keeps its
        // place above a fast text sent after it. rowId tie-break keeps equal-time order deterministic.
        var sorted = msgs.sorted { $0.sortAt == $1.sortAt ? $0.rowId < $1.rowId : $0.sortAt < $1.sortAt }
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
        jumpPagingInFlight = true
        defer { jumpPagingInFlight = false }
        var pages = 0
        while !items.contains(where: { $0.id == messageId }) && canLoadOlder && pages < maxPages {
            await withCheckedContinuation { cont in loadOlder { cont.resume() } }
            pages += 1
        }
    }

    func stop() {
        listener?.remove(); listener = nil
        if let outboxObserver { NotificationCenter.default.removeObserver(outboxObserver) }
        outboxObserver = nil
        if let outboxAddObserver { NotificationCenter.default.removeObserver(outboxAddObserver) }
        outboxAddObserver = nil
        convListener?.remove(); convListener = nil
        userListener?.remove(); userListener = nil
        presenceListener?.remove(); presenceListener = nil
        expiryTimer?.invalidate(); expiryTimer = nil
        typingExpiry?.invalidate(); typingExpiry = nil
    }

    deinit { listener?.remove(); convListener?.remove(); userListener?.remove(); presenceListener?.remove(); expiryTimer?.invalidate(); typingExpiry?.invalidate() }
}
