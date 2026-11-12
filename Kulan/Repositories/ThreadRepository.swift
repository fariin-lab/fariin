import Foundation
import Observation
import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions
import UIKit

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

    /// 2026-10-23: the message itself is on the server and only its file is still going up (a
    /// sticker I made, StickerSend.write). The bubble already holds the file, so it is drawn sent.
    static let didLand = Notification.Name("PendingOutbox.didLand")
    static func markLanded(clientId: String) {
        lock.lock()
        for (cid, list) in byCid {
            byCid[cid] = list.map { m in
                guard m.clientId == clientId, m.sendState == .sending else { return m }
                var c = m; c.sendState = nil; return c
            }
        }
        lock.unlock()
        DispatchQueue.main.async { NotificationCenter.default.post(name: didLand, object: clientId) }
    }

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

extension Notification.Name {
    /// Posted after a message or album tile is hidden "for me". The set is process-wide and has no
    /// observation of its own; a chat that is open needs to know so the row can re-measure.
    static let hiddenMessagesChanged = Notification.Name("hiddenMessagesChanged")
}

enum HiddenMessages {
    private static var cache = Set<String>((UserDefaults.standard.string(forKey: "hiddenMessages") ?? "")
        .split(separator: " ").map(String.init))
    static func isHidden(_ id: String) -> Bool { cache.contains(id) }
    static func hide(_ id: String) {
        guard !id.isEmpty, !cache.contains(id) else { return }
        cache.insert(id)
        UserDefaults.standard.set(cache.joined(separator: " "), forKey: "hiddenMessages")
        NotificationCenter.default.post(name: .hiddenMessagesChanged, object: id)
    }
    /// Sign-out: the stored key is cleared by SessionWipe, but this in-memory copy would keep
    /// hiding the previous account's ids until relaunch.
    static func clear() {
        cache.removeAll()
        UserDefaults.standard.removeObject(forKey: "hiddenMessages")
    }
}

/// Why a publish of `ThreadRepository.items` happened (owner 2026-10-21, the open jump). The message
/// list holds the reader still for every reason except `.live`, the way the reference app's reload
/// keeps every visible row stationary. `.live` is a real arrival, edit, delete or send.
enum MessageListUpdateReason: Equatable {
    case initial        // the first rows: cache seed, a cache window before the server answered
    case serverSettle   // the server's first window replacing what the cache showed
    case live           // something actually happened in the chat
    case olderPage      // a page of history paged in above the reader
    case redecrypt      // the same window decrypted again once the keys arrived
}

/// Live messages for one conversation. Loads a bounded WINDOW (most-recent page)
/// with a live listener, pages OLDER messages in on scroll-to-top, and reuses
/// already-decrypted messages so each snapshot only decrypts new/changed docs.
@Observable
final class ThreadRepository {
    private var db: Firestore { FirestoreHub.db }
    private var listener: ListenerRegistration?
    private var outboxObserver: NSObjectProtocol?
    private var outboxAddObserver: NSObjectProtocol?
    private var outboxLandObserver: NSObjectProtocol?   // 2026-10-23, PendingOutbox.didLand
    private var hiddenObserver: NSObjectProtocol?
    /// A peer's fresh key arrived after this window was decrypted (audit 04 F2).
    private var keyObserver: NSObjectProtocol?
    private var blockObserver: NSObjectProtocol?
    /// 2026-10-07: back to the front → burn what fell due while the app was asleep, at once.
    private var foregroundObserver: NSObjectProtocol?
    private var convListener: ListenerRegistration?
    private var userListener: ListenerRegistration?
    /// Separate from `userListener` because presence lives in its own subcollection now, so the
    /// server can enforce the Last Seen audience rather than the reading client. See PresenceService.
    private var presenceListener: ListenerRegistration?
    /// The key-preload Task `start()` kicks off. Stored and cancelled by `stop()` (audit C6):
    /// leaving and quickly reopening the same chat used to leave the old run alive with a strong
    /// `self`, and it could land after the new screen's cache was fresh and overwrite it.
    private var keyPreloadTask: Task<Void, Never>?
    let cid: String
    /// Where each group's chat starts for me (Conversation.historyStart), kept by the chat screen.
    /// Read and written through `cutLock` (a chat can be rebuilt off the main thread).
    nonisolated(unsafe) private static var historyStartStore: [String: Date] = [:]
    /// When I came into each group (Conversation.memberSince), for messages sealed before that.
    nonisolated(unsafe) private static var joinedAtStore: [String: Date] = [:]
    private static let cutLock = NSLock()
    static func setCuts(cid: String, historyStart: Date?, joinedAt: Date?) -> Bool {
        cutLock.lock(); defer { cutLock.unlock() }
        let changed = historyStartStore[cid] != historyStart || joinedAtStore[cid] != joinedAt
        historyStartStore[cid] = historyStart
        joinedAtStore[cid] = joinedAt
        return changed
    }
    private static func cuts(_ cid: String) -> (start: Date?, joined: Date?) {
        cutLock.lock(); defer { cutLock.unlock() }
        return (historyStartStore[cid], joinedAtStore[cid])
    }
    /// Sign-out: the next account must not inherit these.
    static func clearCuts() {
        cutLock.lock(); historyStartStore = [:]; joinedAtStore = [:]; cutLock.unlock()
    }
    /// The cut-off changed while the chat is open: draw the list again with it.
    func reapplyCuts() { refreshItems() }

    /// 60, which is the reference messenger's own page size for exactly this job. 40 was a smaller
    /// bite than anybody else takes: on a fast flick the reader clears a page before the next one
    /// lands, and the wall you hit is the gap between pages rather than the network being slow.
    /// Bigger bites, fewer gaps, and the round trips per screen actually go DOWN.
    private let pageSize: Int
    /// A background warm-up for `ChatHistoryPreloader` (owner 2026-11-07), not a chat on screen: the
    /// newest 30 only, merged by id into the rows the cache already holds, and none of the header's
    /// listeners (the other person's profile and presence).
    let warmOnly: Bool
    // The standard approach caps the in-memory window (~500) and LRU-drops the oldest — an unbounded
    // window is a memory + main-thread cost that feeds watchdog kills on huge chats. We trim on live
    // commits above a high-water mark (paging older may exceed the cap briefly; the next live commit
    // trims back, and canLoadOlder flips true so the dropped history re-pages on scroll).
    private let windowCap = 500
    private let windowHighWater = 800
    private var windowTrimmed = false   // oldestDoc cursor no longer matches the kept window → cursor by value

    var messages: [Message] = []           // confirmed server messages (ascending)
    /// The channel's "created" line is among the oldest loaded rows, so nothing older exists. A
    /// surer sign of the start than a short page: a channel whose deleted posts fill a whole page
    /// kept `canLoadOlder` on and lost its card (owner 2026-11-07, "sometimes not appearing").
    var holdsChannelStart: Bool {
        messages.prefix(4).contains { $0.isSystem && Self.channelNoticeText($0.text) == "Channel created" }
    }
    // Optimistic, not yet echoed back. Mirrored into ThreadMessageCache on every change so leaving the
    // conversation cannot throw away a send that is still owed — this repository is per-cid and dies when
    // you navigate away, which is why an offline message vanished on reopen.
    var pending: [Message] = [] {
        didSet { ThreadMessageCache.shared.storePending(cid, pending) }
    }
    var canLoadOlder = true {
        // Only the flag here. The oldest message for the next open's seed is taken in `rebuild`,
        // once the page that ended the history is in `messages` (this flips before that page is).
        didSet { if canLoadOlder != oldValue { refreshHistoryStart(record: false) } }
    }
    /// ⛔ THE START OF THE HISTORY IS ON THE PHONE (owner 2026-11-08, channel VE3: 125 of its 126
    /// docs are deleted posts or notices, its one live post sits ~95 back, and the card at the top
    /// came and went). True when nothing older can exist:
    /// - the server sent a short page (`canLoadOlder` off);
    /// - the oldest doc held was written within 5 s of the conversation itself (`createdAt` on the
    ///   conversation doc), which holds even when the "Channel created" line was deleted;
    /// - the "Channel created" line is among the oldest rows (`holdsChannelStart`);
    /// - the window holds the oldest message a past visit saw at the start (`cacheLooksWhole`).
    /// Read by ThreadView's `groupHistoryCard`; also ends the thin-history top-up below.
    private(set) var historyStartReached = false
    /// The conversation doc's own `createdAt`, from the chat's listener on it.
    @ObservationIgnored private var convBornFromDoc: Date?
    private var convBorn: Date? {
        if let d = convBornFromDoc { return d }
        let conv = ConversationsRepository.shared.conversations.first { $0.id == cid }
            ?? ChannelFollows.shared.conversations.first { $0.id == cid }
        return conv?.createdAt
    }
    /// ⛔ HISTORY HIDDEN FROM NEW MEMBERS (verify pass 2, 2026-11-08): the rows start at my join
    /// (`cuts.start`), so once a doc older than that is held there is nothing more to page for, and
    /// the top-up stopped short instead of reading 10 empty pages on every open.
    private var holdsJoinCut: Bool {
        guard let start = Self.cuts(cid).start,
              let oldest = byId.values.lazy.map(\.createdAt).min() else { return false }
        return oldest < start.addingTimeInterval(-2)
    }
    /// The oldest doc held was written with the conversation (groups and channels only).
    private var holdsConversationBirth: Bool {
        guard !cid.contains("_"), !windowTrimmed, let born = convBorn,
              let oldest = byId.values.lazy.map(\.createdAt).min() else { return false }
        return abs(oldest.timeIntervalSince(born)) <= 5
    }
    /// `record`: also save the oldest message for the next open. Only from `rebuild`, where
    /// `messages` holds every page loaded so far, and never on the saved copy's word alone.
    private func refreshHistoryStart(record: Bool) {
        let proven = !canLoadOlder || holdsChannelStart || holdsConversationBirth || holdsJoinCut
            || holdsClearCut || (cacheLooksWhole && sawServerWindow)
        let reached = proven || cacheLooksWhole
        if historyStartReached != reached { historyStartReached = reached }
        if record, proven, let first = messages.first?.id { Self.saveWholeFrom(cid, first) }
    }
    /// The thin-history top-up is paging (`topUpIfThin`). The chat shows its loading state while
    /// this is on and nothing is visible yet, instead of an empty chat.
    private(set) var historyTopUpRunning = false
    /// Pages the top-up asked for in this open (cap `topUpCap`).
    @ObservationIgnored private var topUpPages = 0
    @ObservationIgnored private var windowLogs = 0
    private let topUpCap = 10
    /// With NOTHING visible yet the top-up may go further, so a follower never ends on a blank
    /// screen at the cap (verify pass 1, 2026-11-08). Still bounded: 30 x 60 docs per open.
    private let topUpCapWhenEmpty = 30
    /// Fewer visible rows than this after a page, and the top-up asks for the next one.
    private let topUpMinRows = 20
    /// ⛔ A REOPEN REMEMBERS THE HISTORY WAS WHOLE (owner 2026-10-30, his recording: scrolled to a
    /// channel's first post, back, open again, and the chat jumped). The repository is made fresh on
    /// every open and starts at `canLoadOlder = true`, so the card at the start of the history
    /// (`groupHistoryCard`) waited for the server and then pushed the whole page down under a reader
    /// sitting at the top. Per chat: the oldest message id when nothing older was left. A seed that
    /// still starts at that message holds the whole history.
    nonisolated(unsafe) private static var wholeFrom: [String: String] = [:]   // main thread only, as the repository
    /// Sign-out (SessionWipe): the memory copy goes with the account (the disk keys are wiped there).
    static func forgetWholeFrom() { wholeFrom.removeAll() }
    /// Kept across launches too (owner 2026-11-08), per account and chat: a cold start's first open
    /// then knows the start is here as well.
    private static func wholeFromKey(_ cid: String) -> String? {
        guard let uid = Auth.auth().currentUser?.uid else { return nil }
        return "thread.wholeFrom.\(uid).\(cid)"
    }
    private static func savedWholeFrom(_ cid: String) -> String? {
        if let id = wholeFrom[cid] { return id }
        guard let key = wholeFromKey(cid), let id = UserDefaults.standard.string(forKey: key) else { return nil }
        wholeFrom[cid] = id
        return id
    }
    private static func saveWholeFrom(_ cid: String, _ id: String) {
        guard wholeFrom[cid] != id else { return }
        wholeFrom[cid] = id
        if let key = wholeFromKey(cid) { UserDefaults.standard.set(id, forKey: key) }
    }
    /// This window holds the oldest message a past visit saw when the history was whole.
    private func holdsSavedStart(_ docs: [QueryDocumentSnapshot]) -> Bool {
        guard let id = Self.savedWholeFrom(cid) else { return false }
        // Also when the rows already held (a reopen from the 200-row memory copy) begin at the saved
        // start: the 60-doc window alone never reaches it, and the card blinked off until the last
        // page came back (verify pass 1, 2026-11-08).
        return docs.contains { $0.documentID == id } || messages.first?.id == id
    }
    /// The phone's saved copy opened with less than a page and the server has not answered yet: the
    /// whole history is almost certainly here already. The group's welcome card (ThreadView
    /// `groupHistoryCard`) shows on that instead of waiting for the server (owner 2026-10-28: "the
    /// card appears late"). The server's first window decides from then on (`canLoadOlder`), except
    /// that a window holding the saved start (`wholeFrom`) keeps it on: nothing older exists.
    var cacheLooksWhole = false {
        didSet { if cacheLooksWhole != oldValue { refreshHistoryStart(record: false) } }
    }
    var loadingOlder = false
    /// Owner audit 2026-10-06 chat #1: completions of `loadOlder` calls made while a page was in
    /// flight. They run when that page lands, never before.
    @ObservationIgnored private var olderWaiters: [() -> Void] = []
    /// Owner audit 2026-10-06 chat #69: the query of the first older page the LOCAL CACHE answered
    /// (offline). Re-run once online, so a hole in the cache cannot become a hole in the history.
    @ObservationIgnored private var resumeOlderQuery: Query?
    /// The resume read was answered from the cache (database not reconnected); wait for the network.
    @ObservationIgnored private var resumeHeld = false
    /// Owner audit 2026-10-06 chat #68: the last older page failed or came from the cache only.
    @ObservationIgnored private var olderNeedsRetry = false
    @ObservationIgnored private var networkObserver: NSObjectProtocol?

    // ⛔ CHANNEL SYNC (owner 2026-11-09, CHANNEL-SYNC-SPEC.md 5-9). A channel keeps its history in
    // `ChannelHistoryStore` and follows the change counter instead of a 60-doc window. Groups and
    // 1:1 chats never set any of this (see the extension at the end of this file).
    enum ChannelSyncMode { case off, probing, synced }
    /// `.probing`: today's window listener runs until the server's first window shows whether the
    /// channel's docs carry `chg`; `.synced`: the store and the `chg` listener own the rows.
    @ObservationIgnored private var chMode: ChannelSyncMode = .off
    @ObservationIgnored private var chBox: ChannelHistoryBox<Message>?
    @ObservationIgnored private var chGoneListener: ListenerRegistration?
    @ObservationIgnored private var chHeadListener: ListenerRegistration?
    /// The `chg` query was refused (rules or index not there yet): today's path for this repository.
    @ObservationIgnored private var chRefused = false
    /// Set on a refused `chg` query: the store's rows not in the next server window are dropped.
    @ObservationIgnored private var chDropUnheld = false
    @ObservationIgnored private var chStartGen = 0
    @ObservationIgnored private var chChgToken = 0
    @ObservationIgnored private var chGoneToken = 0
    @ObservationIgnored private var chHeadToken = 0
    /// The next server answer of the `chg` listener is its first since a fresh attach.
    @ObservationIgnored private var chFirstServer = true
    @ObservationIgnored private var chTooLongRunning = false
    /// Failed "too long" catch-ups in a row, for the retry's backoff (audit C2).
    @ObservationIgnored private var chTooLongFails = 0
    /// A post's Replies switch set here after the server said yes, until the store's copy carries
    /// it (audit C3): the store is mirrored into `byId` on every change, and its older copy would
    /// otherwise put the old switch back until the stamped echo lands.
    @ObservationIgnored private var chRepliesOverlay: [String: (off: Bool, at: Date)] = [:]
    /// A post's reply count as the Replies sheet last knew it (R-02), drawn over the post until a
    /// listener brings the same number or 90 s pass. Any channel mode: applied in `rebuild`.
    @ObservationIgnored private var replyCountOverlay: [String: (n: Int, at: Date)] = [:]
    /// I unfollowed or left this channel while its screen was open: its store goes when the screen
    /// closes (audit C5).
    @ObservationIgnored private var chForgetOnClose = false
    @ObservationIgnored private var chAttachedAt = Date.distantPast
    @ObservationIgnored private var chSyncLogs = 0
    /// The newest snapshot of each post's doc, so a key that lands late can decrypt it again.
    @ObservationIgnored private var chDocs: [String: QueryDocumentSnapshot] = [:]

    // Decrypt cache: id -> built message, plus the raw (encrypted) reactions we last
    // saw, so we only rebuild a message when its one mutable field actually changes.
    private var byId: [String: Message] = [:]
    private var rawReactions: [String: String] = [:]   // id -> change signature (reactions + text cipher + edited)
    /// What this chat last wrote to the phone's database (`LocalMessageDB`, owner 2026-11-12 phase 1),
    /// so each update files only the messages that are new or changed.
    @ObservationIgnored private var filedToDB: [String: Message] = [:]
    /// safety review 2026-11-12: a write to the phone's database failed and the full re-file that
    /// follows has not committed yet. Nothing is vouched for (no mark, no cursor) while true.
    @ObservationIgnored private var localDBBehind = false
    // Ids the user has just deleted for everyone, whose server write has not come back yet. Applied as
    // an overlay in rebuild() so the bubble reads as deleted immediately; cleared the moment the real
    // tombstone (or the message's removal) arrives. See markDeletedLocally.
    private var locallyDeleted: Set<String> = []
    // clientId -> my link card while its attach write is on the way (see showLocalCard).
    private var localCards: [String: Message.LinkPreviewData] = [:]
    private var droppedCards: Set<String> = []   // attach settled without a card: never shown again
    private var oldestDoc: DocumentSnapshot?   // cursor for paging older
    private var lastDocs: [QueryDocumentSnapshot] = []   // last window, to re-decrypt once the key loads
    private var lastDocsFromCache = false   // owner audit 2026-10-06 chat #19: `lastDocs` came from the local cache
    // Owner audit 2026-10-06 chat #17: the first SERVER window has been seen (it alone may end
    // history), and `oldestDoc` still comes from a cache window (the server's replaces it).
    @ObservationIgnored private var sawServerWindow = false
    /// The same moment, observed: the list holds a just-landed reader until the server's window has
    /// been applied (`NativeMessageList.liveWindowSettled`). On a cold open it comes well after the
    /// warm reopen's few hundred milliseconds.
    private(set) var serverWindowSettled = false
    @ObservationIgnored private var oldestDocFromCacheWindow = false
    private(set) var didInitialLoad = false

    /// Same rule as the chat list's: the skeleton is for a genuinely cold chat, not for the moment
    /// the cache takes to hand back messages it already holds. Shown immediately it flashed grey
    /// bubbles during the push into EVERY chat, including ones fully cached (owner screenshot).
    /// Armed only if the first page has still not arrived after a beat.
    var skeletonArmed = false

    private(set) var convLoaded = false   // first conversation-doc snapshot landed (block state is real)
    /// ⛔ READ-ONLY, FOR A PUBLIC GROUP SEEN FROM OUTSIDE (owner 2026-10-21, ThreadView `guest`). Only
    /// the messages are listened to: the rules let a non-member read those of a public group sent
    /// in the clear, never the group document. Set before `start()`.
    @ObservationIgnored var previewOnly = false
    /// ⛔ SUSPENDED OR DISABLED BY FARIIN (owner 2026-10-26): the rules refuse this group's messages
    /// while the hold lasts, so a refusal here is expected. It is neither reported nor retried; the
    /// chat re-attaches when the hold ends (ThreadView `groupModHidesChat`).
    @ObservationIgnored var moderationLocked = false
    /// A public group whose messages I may not read from outside (owner 2026-10-23): the chat opens
    /// with its header and Join, and no listener is started (it could only be refused).
    @ObservationIgnored var lockedGuest = false
    var otherTyping = false
    var otherRecording = false       // someone is recording a voice note (string "audio…" in the typing map)
    var recordingNames: [String] = []   // group only: who is recording, for the header's "X is recording…"
    var typingNames: [String] = []   // group: who is currently typing
    private var typingExpiry: Timer? // incoming typing self-clears after 15s — a crashed sender's flag can't stick
    var otherOnline = false
    var otherLastActive: Date?
    var otherPrivacy: [String: String] = [:]   // their per-field audience map (users doc)
    /// 2026-09-24 decision D15: the other person's account is deleted — their users doc is gone
    /// (purged) or carries `isHidden` (ProfileStore.scheduleDeletion sets it for the grace period).
    /// Only set from a snapshot that actually arrived; a failed read leaves it false.
    var otherAccountDeleted = false
    var otherLastReadMillis: Double = 0
    /// 1:1 only: the newest time the other person's phone confirmed it had my messages. Written by
    /// their app (`ConversationsRepository.markDelivered`) or, while it is closed, by the server when
    /// the notification lands (`ackDelivered`). Drives the two grey ticks.
    var otherDeliveredMillis: Double = 0
    var memberLastRead: [String: Double] = [:]   // group: uid -> last-read time (millis); for "read by"
    var iBlocked = false
    var disappearSeconds = 0
    /// Disable Sharing, from this chat's own listener, so the chat screen reads them without
    /// observing every chat in the list. See `ChatRestrictions`.
    var noScreenshots = false
    var noForwarding = false
    var noSaving = false
    /// Bumped by every expiry sweep while this chat holds anything on a timer, so the footer's
    /// countdown rings re-render. Read into the row-model cache key; see `sweepExpired`.
    private(set) var expiryTick = 0
    private var expiryTimer: Timer?
    /// Fires ONCE, at the exact second the next message is due. See `scheduleNextBurn`.
    private var burnTimer: Timer?
    private var otherUid = ""
    // ⚠️ The OLD, shared copy of a block (see `Conversation.blockedBy`); `BlockList` is the real one.
    private var legacyBlocked = false
    private var myBlockedAtMillis: Double = 0       // when I blocked
    private var myBlockClearedAtMillis: Double = 0  // when I unblocked (end of the hide window)
    /// Clear Chat / Delete Chat for me (`Conversation.clearedAt[me]`, server ms): every message
    /// written at or before it is gone for me, in a 1:1 and in a group. Only moves forward.
    private(set) var myChatClearedAtMillis: Double = 0
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
        defer { persistPins() }
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

    // ⛔ A REPLY MUST NOT KEEP A DELETED MESSAGE READABLE (audit H5). A reply carries a copy of the
    // words it quotes, and the row only hid that copy when it could see the original as a tombstone in
    // `items`. A group drops its tombstones from `items` (see `refreshItems`), and an original older
    // than the loaded window is not there at all, so every member kept reading the deleted words
    // inside each reply to them. The answer now comes from the whole window (`byId`, tombstones
    // included) and, for an original outside it, from one read by id, like the pins above.
    /// Quoted originals a read by id found deleted, or not there at all.
    @ObservationIgnored private var quotesGone: Set<String> = []
    /// Quoted originals already asked about by id, so each is read at most once per repository.
    @ObservationIgnored private var quotesChecked: Set<String> = []
    /// At most this many reads by id per repository, so a chat full of old replies stays cheap.
    private static let maxQuoteChecks = 40
    /// The originals quoted by `items` that are known to be deleted for everyone. Published once per
    /// `refreshItems`, like `indexById`, so the screen reads one set instead of observing `byId`.
    private(set) var quotedDeletedIds: Set<String> = []

    /// Is the message a reply quotes known to be deleted for everyone?
    func quoteOriginalDeleted(_ id: String) -> Bool { quotedDeletedIds.contains(id) }

    /// The set `quoteOriginalDeleted` reads, from the whole window (tombstones a group drops from
    /// `items` included), a delete still on its way, and the reads by id below.
    private func refreshQuotedDeleted() {
        var gone = Set<String>()
        for m in items {
            guard let r = m.replyTo, !r.isStatus else { continue }
            if locallyDeleted.contains(r.id) || quotesGone.contains(r.id) || byId[r.id]?.deleted == true {
                gone.insert(r.id)
            }
        }
        if gone != quotedDeletedIds { quotedDeletedIds = gone }
    }

    /// Ask by id about each quoted original that is not in the window. A failed read is no signal,
    /// so it is never taken as "deleted"; the reply keeps its copy until a read says otherwise.
    private func checkQuotedOriginals() {
        // Only once the server's window is in: before that, most originals are about to arrive in
        // it for free. A warm-only repository draws nothing, so it asks nothing.
        guard !warmOnly, sawServerWindow else { return }
        for m in items {
            guard let r = m.replyTo, !r.isStatus, !m.deleted, !r.id.isEmpty else { continue }
            let id = r.id
            guard byId[id] == nil, !quotesChecked.contains(id) else { continue }
            // A reply to something of mine still sending: its document may not be written yet, and
            // "not there" must not read as "deleted".
            guard !pending.contains(where: { $0.id == id || $0.clientId == id }) else { continue }
            guard quotesChecked.count < Self.maxQuoteChecks else { return }
            quotesChecked.insert(id)
            db.collection("conversations").document(cid).collection("messages").document(id)
                .getDocument { [weak self] snap, _ in
                    guard let self, let snap else { return }
                    let gone = !snap.exists || (snap.data()?["deleted"] as? Bool ?? false)
                    guard gone, !self.quotesGone.contains(id) else { return }
                    self.quotesGone.insert(id)
                    self.refreshItems()
                }
        }
    }

    /// A TOMBSTONE counts as gone. Delete-for-everyone already unpins, so this only catches the case
    /// where that write was refused and the pin outlived the message — but the pin bar must never be
    /// the one place in the app still showing something you deleted.
    private func keepPinned(_ m: Message) {
        if m.deleted { pinnedGone.insert(m.id) } else { pinnedPreviews[m.id] = m }
        persistPins()
    }

    // ⛔ THE PINS ARE KEPT ON THE PHONE BETWEEN VISITS — owner 2026-10-13: "every time I open the chat
    // the bar says Pinned Message / Tap to view, and the real pin comes seconds later". `pinnedPreviews`
    // lived only as long as this repository, so every open started empty and fetched each pin again
    // over the network before the bar had anything to draw. The reference apps read the pinned
    // message out of their own local database, so their bar is drawn on the first frame. Ours now
    // keeps the pinned messages (decrypted, like the rest of the chat's cached window) beside that
    // window in `ThreadMessageCache`, in pin order, and seeds both the list and the previews from it
    // at init. The conversation listener still decides: its first snapshot replaces the seeded list.
    private var pinCacheKey: String { "pins-" + cid }
    private func persistPins() {
        let ordered = pinnedMessageIds.compactMap { pinnedPreviews[$0] }
        ThreadMessageCache.shared.store(pinCacheKey, ordered)
    }
    private func seedPinsFromCache() {
        guard let cached = ThreadMessageCache.shared.messages(for: pinCacheKey), !cached.isEmpty else { return }
        pinnedMessageIds = cached.map(\.id)
        for m in cached where !m.deleted { pinnedPreviews[m.id] = m }
    }

    /// Unpin on screen NOW (owner 2026-10-13: "unpin is not working"). The shared write follows;
    /// if the server refuses it, the next snapshot puts the pin back and the caller says why.
    func unpinLocally(_ id: String) {
        guard pinnedMessageIds.contains(id) else { return }
        pinnedMessageIds.removeAll { $0 == id }
        syncPinnedPreviews()
    }

    init(cid: String, warmOnly: Bool = false) {
        self.cid = cid
        self.warmOnly = warmOnly
        self.pageSize = warmOnly ? 30 : 60
        // ⛔ WHO THE OTHER PERSON IS, BEFORE THE FIRST SEED — owner, 2026-09-29: "You blocked / You
        // unblocked this person" vanished on coming back to a chat and returned when he reacted.
        // A warm reopen seeds from memory right here, and `blockNotices` answers nothing without
        // `otherUid`, which `start()` used to be the first to set; the listener's rebuild then saw
        // no MESSAGE change and never republished, so the notices waited for the next message. A
        // 1:1 id is the two uids, so it is known now. `start()` still sets it as before.
        if cid.contains("_"), let me = Auth.auth().currentUser?.uid {
            otherUid = cid.split(separator: "_").map(String.init).first { $0 != me } ?? ""
        }
        // A cleared chat must not draw its old messages on the first frame, before the chat's own
        // listener brings `clearedAt`: the copy in the chat list already holds it.
        if let me = Auth.auth().currentUser?.uid,
           let conv = ConversationsRepository.shared.conversations.first(where: { $0.id == cid }) {
            myChatClearedAtMillis = conv.clearedAt[me] ?? 0
        }
        // Restore anything still unsent from a previous visit to this chat, BEFORE the cached window is
        // seeded, so a pending message is on screen from the very first frame with its sending/failed
        // state intact and its retry affordance available.
        pending = ThreadMessageCache.shared.pending(for: cid)
        // The pinned bar's content from the last visit, so the bar is drawn on the first frame.
        seedPinsFromCache()
        // Seed the last-decrypted messages SYNCHRONOUSLY so the conversation is fully rendered and
        // frozen on the first frame — before the push transition — as standard messengers do, instead of
        // fading in a beat late while the E2EE decrypt runs off the main thread. The live listener
        // in start() then reconciles silently (same ids → no visible change). First-ever open this
        // session has no cache → normal async load + reveal.
        //
        // ⛔ MEMORY ONLY HERE; THE DISK IS READ OFF THE MAIN THREAD — owner, 2026-09-27: "the first
        // chat I open after launching the app opens late". This init runs inside the tap, and on a
        // miss `messages(for:)` read and decoded the chat's file right here, on the main thread,
        // before the push could start — the grey row he photographed. The reference app never loads
        // messages before the push: it pushes, loads on a background queue, and shows the list when
        // the load lands. A miss now does the same; the reveal veil already holds the list hidden
        // until it has something to show, and the live listener still reconciles after.
        // ⛔ A CHANNEL OPENS FROM ITS OWN STORE (CHANNEL-SYNC-SPEC.md 5 and 9): memory at once, or
        // its file read off the main thread. ThreadMessageCache's 60-row tail is not used for it.
        let chUid = (!warmOnly && !cid.contains("_")) ? Auth.auth().currentUser?.uid : nil
        if let chUid, let box = ChannelHistoryStore.shared.memory(uid: chUid, cid: cid), box.history.isSynced {
            NSLog("[REOPEN] repo seed from CHANNEL STORE rows=%ld", box.history.posts.count)
            seedFromChannel(box)
        } else if let chUid, ChannelHistoryStore.shared.hasFile(uid: chUid, cid: cid) {
            ChannelHistoryStore.shared.open(uid: chUid, cid: cid) { [weak self] box in
                guard let self, box.history.isSynced, !self.didInitialLoad || self.messages.isEmpty,
                      self.chMode != .synced else { return }
                NSLog("[REOPEN] repo seed from CHANNEL STORE (disk) rows=%ld", box.history.posts.count)
                self.seedFromChannel(box)
            }
        } else if let cached = ThreadMessageCache.shared.memoryMessages(for: cid), !cached.isEmpty {
            // ⚠️ TEMPORARY, with the list's [REOPEN] lines: 60 rows here means the cache was cut on backgrounding.
            // Debug builds only (release audit 2026-11-10), as are the other [REOPEN] lines here.
            #if DEBUG
            NSLog("[REOPEN] repo seed from MEMORY rows=%ld", cached.count)
            #endif
            seed(cached)
        } else {
            #if DEBUG
            NSLog("[REOPEN] repo seed MISS, reading the disk file")
            #endif
            ThreadMessageCache.shared.loadAsync(cid) { [weak self] cold in
                guard let self else { return }
                // ⛔ No warm copy: the phone's own database (owner 2026-11-12, phase 1: a chat opens
                // from the phone first). Same seed, same rule: the live listener stays the truth.
                // Never for a channel, which opens from its own store above.
                guard let cold else { self.seedFromLocalDB(); return }
                // The live snapshot got here first: it is the truth, the file is only a head start.
                guard !self.didInitialLoad, self.messages.isEmpty else { return }
                #if DEBUG
                NSLog("[REOPEN] repo seed from DISK rows=%ld", cold.count)
                #endif
                self.seed(cold)
            }
        }
    }

    /// The newest page from `LocalMessageDB` when neither memory nor the cache file had this chat.
    private func seedFromLocalDB() {
        guard !Conversation.Right.isChannel(cid), !didInitialLoad, messages.isEmpty,
              let me = Auth.auth().currentUser?.uid else { return }
        LocalMessageDB.shared.newest(cid: cid, uid: me, limit: pageSize) { [weak self] rows in
            guard let self, !rows.isEmpty, !self.didInitialLoad, self.messages.isEmpty else { return }
            #if DEBUG
            NSLog("[REOPEN] repo seed from LOCAL DB rows=%ld", rows.count)
            #endif
            self.seed(rows)
        }
    }

    private func seed(_ cached: [Message]) {
        for m in cached { byId[m.id] = m }   // reuse them so start()'s snapshot only decrypts new/changed docs
        // Owner audit 2026-10-06 chat #21: the cache can hold disappearing messages that ran out
        // while the chat was closed. This path skipped `rebuild`'s expiry filter, so they drew on the
        // first frame and vanished when the first snapshot landed. Same filter, and the burn timer
        // armed for whatever is still counting down.
        let now = Date()
        messages = cached.filter { m in (m.expiresAt.map { now < $0 } ?? true) && !isClearedForMe(m) }
        if let first = messages.first?.id, Self.savedWholeFrom(cid) == first { cacheLooksWhole = true }
        didInitialLoad = true
        refreshItems(reason: .initial)
        scheduleNextBurn()
    }

    // MARK: - One timeline for everybody

    /// authorId → how far that person's clock is from the server's, in seconds.
    ///
    /// Rebuilt from the window on every snapshot. Median rather than average, so one message sent
    /// across a clock correction cannot drag the whole conversation sideways.
    private var clockOffset: [String: TimeInterval] = [:]

    private func recomputeClockOffsets<C: Collection>(_ msgs: C) where C.Element == Message {
        var samples: [String: [TimeInterval]] = [:]
        for m in msgs {
            // Both halves have to be real. `hasServerTime` is what stops a still-in-flight row, whose
            // "server time" is actually this phone's clock, from measuring an offset of roughly zero
            // and flattening the correction it exists to make.
            guard m.hasServerTime, let tap = m.clientTs else { continue }
            samples[m.authorId, default: []].append(m.createdAt.timeIntervalSince(tap))
        }
        clockOffset = samples.compactMapValues { list in
            let s = list.sorted()
            return s.isEmpty ? nil : s[s.count / 2]
        }
    }

    /// WHERE A MESSAGE SITS — one key per message, assigned ONCE and kept for the repo's lifetime.
    ///
    /// ⚠️ THIS REPLACES THE CLOCK-OFFSET PROJECTION (his build-542 screenshots: an incoming message
    /// landing in the MIDDLE of a pair he had already sent). The projection corrected each person's
    /// tap time by an ESTIMATE of their clock error, and that estimate is off by the network jitter
    /// of the very messages it is measured from — a second or two. Two phones chatting fast live
    /// inside that jitter, so an incoming message could still sort between two messages the server
    /// had stamped in order. The server's stamp is the one clock both phones share; between two
    /// people it decides, with no arithmetic on top. (The big messengers order by server sequence, full stop.)
    ///
    /// The rules, in order:
    /// 1. A message that HAS a server stamp when first seen takes the stamp as its key.
    /// 2. Within one author the keys are forced monotonic in TAP order (the `runningMax` clamp): a
    ///    photo that uploads slowly keeps its place above a text typed after it, even though the
    ///    text's stamp is earlier. ⚠️ Do not "simplify" the clamp away — it IS the photo rule.
    /// 3. A message still in flight gets its tap time projected by its author's measured offset —
    ///    the only place the estimate survives, because an unstamped row has nothing better.
    /// 4. A key is STICKY: once a rowId has one it never changes while this repo lives, so a bubble
    ///    never moves on screen when its ack lands (`rowId` is `clientId ?? id`, so the server echo
    ///    inherits the pending row's key). A fresh open recomputes from stamps — true server order.
    private var stickyOrderKey: [String: Date] = [:]

    private func assignOrderKeys<C: Collection>(_ msgs: C) where C.Element == Message {
        for (author, list) in Dictionary(grouping: msgs, by: { $0.authorId }) {
            let offset = clockOffset[author] ?? 0
            let tapOrdered = list.sorted { a, b in
                let ta = a.clientTs ?? a.createdAt, tb = b.clientTs ?? b.createdAt
                return ta == tb ? a.rowId < b.rowId : ta < tb
            }
            var runningMax = Date.distantPast
            // Same account, two phones, two clocks (audit C15): `clientTs` is the tap time each
            // device stamped locally, so `tapOrdered` above can disagree with the server's real
            // order between them. The clamp below exists for a message with NO server stamp yet
            // (rule 3); once both this message and the one before it in tap order have a real
            // server stamp, that stamp alone is the truth and must not be pushed later just to
            // stay monotonic with a skewed clock's tap order.
            var runningMaxHasServerTime = false
            for m in tapOrdered {
                if let k = stickyOrderKey[m.rowId] {
                    runningMax = max(runningMax, k)
                    runningMaxHasServerTime = m.hasServerTime
                    continue
                }
                let raw = m.hasServerTime
                    ? m.createdAt
                    : (m.clientTs ?? m.createdAt).addingTimeInterval(offset)
                let k = (m.hasServerTime && runningMaxHasServerTime)
                    ? raw
                    : max(raw, runningMax.addingTimeInterval(0.001))
                stickyOrderKey[m.rowId] = k
                runningMax = k
                runningMaxHasServerTime = m.hasServerTime
            }
        }
    }

    /// The one sort everybody uses. A single precomputed key per message keeps the comparator a
    /// strict weak ordering — a per-pair "compare server times only when both are stamped" branch
    /// looks equivalent and is not (it can go intransitive, and `sort` is allowed to do anything
    /// with an inconsistent comparator, including trap).
    private func sortedOneTimeline(_ msgs: [Message]) -> [Message] {
        assignOrderKeys(msgs)
        return msgs.sorted { a, b in
            let ka = stickyOrderKey[a.rowId] ?? a.createdAt
            let kb = stickyOrderKey[b.rowId] ?? b.createdAt
            return ka == kb ? a.rowId < b.rowId : ka < kb
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
    /// ⛔ WHY THIS PUBLISH HAPPENED (owner 2026-10-21, the open jump). The list could not tell the
    /// server's window replacing the cache from a message arriving, so it treated both as an arrival
    /// (glided, let neighbours move). Every publish now says which it is; the list holds the reader
    /// still for anything that is not `.live`. Read together with `itemsVersion`.
    private(set) var itemsUpdateReason: MessageListUpdateReason = .initial
    /// Set by the chat screen when it opens: this conversation is a channel. Used when the channel is
    /// in none of my lists (a visitor), where its kind cannot be looked up.
    var channelHint = false {
        didSet { if channelHint != oldValue { refreshItems() } }
    }

    /// A channel I neither own nor run: its notices are not shown to me.
    private var hidesChannelNotices: Bool {
        let me = AuthService.shared.uid ?? ""
        let conv = ConversationsRepository.shared.conversations.first { $0.id == cid }
            ?? ChannelFollows.shared.conversations.first { $0.id == cid }
        guard let c = conv else { return channelHint }
        guard c.isChannel else { return false }
        return !(c.isOwner(me) || c.isAdmin(me))
    }

    private func refreshItems(reason: MessageListUpdateReason = .live) {
        itemsUpdateReason = reason
        // ⚠️ MY OWN PHOTO MUST NOT TURN INTO A BLUR WHILE IT UPLOADS.
        //
        // A photo message is written to the server the instant Send is tapped now, carrying its
        // blurhash but no media yet — which is what lets the RECIPIENT see a bubble immediately.
        // The echo of that write comes straight back to the sender too, and it carries the same
        // clientId as the optimistic bubble, so the plain rule below would have dropped the local
        // copy and rendered the placeholder in its place: the sender would watch their own picture
        // dissolve into a blur for the length of the upload.
        //
        // While a server message is still `uploading` AND I am holding the real bytes for it, MY
        // copy is the better one and the echo is hidden. When the media is attached the flag clears,
        // this stops matching, and the server message takes over — by which point the plaintext is
        // already in DiskImageCache under its URL, so the swap draws nothing new.
        let myPendingIds = Set(pending.compactMap { $0.clientId })
        let visible = messages.filter { m in
            !(m.uploading && (m.clientId.map(myPendingIds.contains) ?? false))
        }
        let echoed = Set(visible.compactMap { $0.clientId })
        // Pending sends are MERGED by key, not appended: an uploading photo stays exactly where
        // it was sent even when later texts confirm first (order never shuffles on upload finish).
        var merged = sortedOneTimeline(visible + pending.filter { p in !(p.clientId.map(echoed.contains) ?? false) }
                                       + blockNotices(after: visible.first?.createdAt))
        // Deleted "for me"; or sealed without me and sent BEFORE I came in (audit 2026-10-20: one
        // sealed by a phone that had not seen me join yet is shown as the lock, not dropped).
        let cuts = Self.cuts(cid)
        // ⛔ A GROUP SHOWS NO "deleted" LINE (owner 2026-10-26): a message deleted for everyone just
        // goes, for its author and for every member. The 1:1 keeps its line. A group id has no "_".
        let group = !cid.contains("_")
        merged.removeAll { m in
            HiddenMessages.isHidden(m.id)
                || (m.notForMe && (cuts.joined.map { m.createdAt < $0.addingTimeInterval(5) } ?? true))
                || (group && m.deleted && !m.isCall)
        }
        // ⛔ SEALED BEFORE THIS PHONE HAD ITS KEYS (owner 2026-11-10: signed in on another phone, the
        // old messages were a wall of locks). They can never open here (`Message.predatesThisDevice`),
        // so they are left out and one notice stands where the newest of them was.
        var newestOldSeal: Date?
        merged.removeAll { m in
            guard m.predatesThisDevice else { return false }
            if newestOldSeal.map({ m.createdAt > $0 }) ?? true { newestOldSeal = m.createdAt }
            return true
        }
        // ⛔ A CHANNEL'S NOTICES ARE FOR ITS OWNER AND ADMINS (owner 2026-11-06): wallpaper changed,
        // verified, pinned, "X joined" and the other activity lines are not shown to followers or
        // visitors as messages. (Deleted posts already go, above.)
        if group, hidesChannelNotices {
            merged.removeAll { $0.isSystem || $0.pinNotice != nil }
        }
        // Chat history hidden from new members, and I came in after that: the chat starts at my
        // join (2 s early, so the "joined" line written with it stays).
        if let start = cuts.start {
            let cut = start.addingTimeInterval(-2)
            merged.removeAll { $0.createdAt < cut }
            if let at = newestOldSeal, at < cut { newestOldSeal = nil }   // the chat starts later anyway
        }
        if let at = newestOldSeal {
            // One id for the chat, so the list keeps the same row as older pages load.
            let notice = Message(localNotice: Self.oldDeviceHistoryNotice, symbol: "lock",
                                 id: "local-device-history", at: at)
            merged.insert(notice, at: merged.firstIndex { $0.createdAt > at } ?? merged.count)
        }

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
        refreshQuotedDeleted()
        itemsVersion += 1
        checkQuotedOriginals()
    }

    func addPending(_ m: Message) { pending.append(m); refreshItems() }

    /// A quoted channel post going with media whose bubble the attach sheet already posted
    /// (owner 2026-11-07): the pending copy shows the card at once.
    func setPendingQuote(clientId: String, qid: String) {
        guard let i = pending.firstIndex(where: { $0.clientId == clientId }) else { return }
        pending[i].quoteId = qid
        refreshItems()
    }

    /// 2026-10-23 (owner, build 1014): THE CARD FOLLOWS THE TEXT. A text with a link is written at
    /// once and its card is attached by a second write a moment later. Between the two, my own
    /// bubble shows the card from the local draft: on the pending copy, and as an overlay on the
    /// server copy (the echo drops the pending one), until the server copy has its own card.
    func showLocalCard(clientId: String, card: Message.LinkPreviewData) {
        guard !droppedCards.contains(clientId) else { return }
        if localCards.count > 50 { localCards.removeAll() }
        localCards[clientId] = card
        if let i = pending.firstIndex(where: { $0.clientId == clientId }), pending[i].linkPreview == nil {
            pending[i].linkPreview = card
            refreshItems()
        }
        if byId[clientId] != nil { rebuild() }
    }
    /// The attach write failed or was not allowed: my bubble shows what the other side sees.
    func dropLocalCard(clientId: String) {
        if droppedCards.count > 50 { droppedCards.removeAll() }
        droppedCards.insert(clientId)
        guard localCards.removeValue(forKey: clientId) != nil else { return }
        rebuild()
    }

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

    /// ⛔ MY OWN REACTION SHOWS AT ONCE, ON ANY MESSAGE — owner, 2026-10-06, with a screenshot: "old
    /// messages I can't react, and I can't remove a reaction". The write reached the server; the
    /// screen never heard. Only the newest window is live (the listener); a message paged in from
    /// further back was read once, so nothing ever told the row it changed and a tap looked dead
    /// (chat audit #16 is the general version). The row now takes my reaction the moment I make it,
    /// and `revertMyReaction` puts the old one back if the server refuses. Inside the live window the
    /// listener's echo writes the same value over it.
    @discardableResult
    func setMyReactionLocally(_ messageId: String, uid: String, emoji: String?) -> String? {
        guard var m = byId[messageId] else { return nil }
        let previous = m.reactions[uid]
        if let emoji { m.reactions[uid] = emoji } else { m.reactions.removeValue(forKey: uid) }
        byId[messageId] = m
        rebuild()
        return previous
    }

    /// ⛔ A POST'S REPLIES SWITCH, SHOWN AT ONCE (owner 2026-11-07: "not realtime, always needs a
    /// refresh"). Only the newest stretch of posts is listened to; an older post loaded by scrolling
    /// up never hears the server's change. Set here once the server has said yes; inside the live
    /// window the listener's echo writes the same value over it.
    /// A synced channel (audit C3): `byId` follows the channel store on every change, so the switch
    /// is kept as an overlay that `chMirrorAll` lays over the store's copy until that copy carries it.
    func setRepliesOffLocally(_ messageId: String, off: Bool) {
        guard var m = byId[messageId] else { return }
        if chMode == .synced, chBox != nil { chRepliesOverlay[messageId] = (off, Date()) }
        m.setPostRepliesSwitch(off)
        byId[messageId] = m
        rebuild()
    }

    /// ⛔ THE REPLIES SHEET'S COUNT, SHOWN AT ONCE (R-02): the sheet closing reports how many replies
    /// it saw, and the post's bar shows that number now instead of snapping back to an older one
    /// until the server's count lands. Held until a listener carries the same number, or 90 s.
    func setReplyCountLocally(_ id: String, _ n: Int) {
        guard byId[id] != nil, n >= 0 else { return }
        if byId[id]?.replyCount == n { replyCountOverlay[id] = nil; return }
        replyCountOverlay[id] = (n, Date())
        rebuild()
    }

    private func applyReplyCountOverlay(_ msgs: [Message]) -> [Message] {
        let now = Date()
        replyCountOverlay = replyCountOverlay.filter { id, o in
            guard let m = byId[id] else { return false }
            return m.replyCount != o.n && now.timeIntervalSince(o.at) < 90
        }
        guard !replyCountOverlay.isEmpty else { return msgs }
        return msgs.map { m in
            guard let o = replyCountOverlay[m.id] else { return m }
            var c = m
            c.replyCount = o.n
            return c
        }
    }

    /// The server refused my reaction: the row goes back to what it showed before the tap.
    func revertMyReaction(_ messageId: String, uid: String, to previous: String?) {
        setMyReactionLocally(messageId, uid: uid, emoji: previous)
    }

    /// The server refused the delete: drop the overlay and the real message is back, untouched.
    func restoreAfterFailedDelete(_ id: String) {
        guard locallyDeleted.remove(id) != nil else { return }
        rebuild()
    }
    // Un-guarded from `#if DEBUG`: ThreadView's demo send calls this, and that path is live in
    // TestFlight now. Nothing reaches it unless DemoMode.active is true.
    func addDemoMessage(_ text: String, from authorId: String) {
        messages.append(Message(demoId: UUID().uuidString, from: authorId, text, Date()))
        refreshItems()
    }
    func markFailed(clientId: String) {
        if let i = pending.firstIndex(where: { $0.clientId == clientId }) {
            pending[i].sendState = .failed
        } else if var back = echoedPending.removeValue(forKey: clientId) {
            // Its local echo had replaced it, and the server's refusal took the echo away (see
            // `echoedPending`): back as a failed bubble with its red !, never silently gone.
            back.sendState = .failed
            pending.append(back)
            DiagLog.add("SEND# refused after echo cid=\(cid) client=\(clientId)")
        }
        refreshItems()
    }
    func removePending(clientId: String) { pending.removeAll { $0.clientId == clientId }; refreshItems() }

    /// A RESEND gets a new server time, so its sticky order key (the old send's place) is dropped and
    /// the row sorts by the new send. Kept, the bubble stayed at the old place for this visit and then
    /// jumped to the new one on reopen (owner audit 2026-10-06 chat #76). Resend only: an ordinary
    /// ack keeps its key, which is the whole point of the key.
    func forgetOrder(rowId: String) { stickyOrderKey[rowId] = nil }

    func start() {
        // Demo: serve the local conversation directly — no Firestore, no decryption. Keyed on the
        // conversation, not on a global flag, because a demo chat now opens from a list that also
        // holds real ones and only this one may skip the real path.
        if DemoMode.isDemoConversation(cid) {
            messages = DemoMode.messages(for: cid)
            didInitialLoad = true
            canLoadOlder = false
            otherOnline = true
            // Everything I sent is read: blue ticks on the demo chats (App Store pictures).
            otherLastReadMillis = Date().timeIntervalSince1970 * 1000
            otherDeliveredMillis = otherLastReadMillis
            refreshItems(reason: .initial)
            return
        }
        if lockedGuest {
            convLoaded = true
            didInitialLoad = true
            canLoadOlder = false
            refreshItems(reason: .initial)
            return
        }
        skeletonArmed = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !self.didInitialLoad else { return }   // cache already answered
            self.skeletonArmed = true
        }
        // Tear down the previous run FIRST (2026-09-24 audit). `stop()` sat below the two outbox
        // observers and removes them, so they were unregistered the instant they were added: a
        // forward that failed or arrived while this chat was open never reached it.
        stop()
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
        // A disappearing message that ran out while the app was in the background (owner,
        // 2026-10-07): timers do not fire there, and the 15s sweep would show it for up to 15s
        // more after the return. The sweep runs the moment the app comes back instead.
        if foregroundObserver == nil {
            foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                    self?.sweepExpired()
                    // Owner, 2026-10-08: back in the foreground, bring back any listener that died.
                    self?.reattachIfDead(includePresence: false)
                    // A channel picks its changes up again from the last one applied (spec 7).
                    self?.chReattachFromLastChg(why: "foreground")
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
        // A sticker I made is on the server while its file still uploads: my bubble (which holds
        // the PNG) stops showing a send in progress (2026-10-23, see StickerSend.write).
        if outboxLandObserver == nil {
            outboxLandObserver = NotificationCenter.default.addObserver(
                forName: PendingOutbox.didLand, object: nil, queue: .main) { [weak self] n in
                    guard let self, let id = n.object as? String,
                          let i = self.pending.firstIndex(where: { $0.clientId == id }),
                          self.pending[i].sendState == .sending else { return }
                    self.pending[i].sendState = nil
                    self.refreshItems()
                }
        }
        // A message hidden "for me" somewhere else (the chat's Storage page, owner 2026-10-19)
        // leaves this open chat at once, not at the next snapshot.
        if hiddenObserver == nil {
            hiddenObserver = NotificationCenter.default.addObserver(
                forName: .hiddenMessagesChanged, object: nil, queue: .main) { [weak self] n in
                    guard let self, let id = n.object as? String, self.byId[id] != nil else { return }
                    self.refreshItems()
                }
        }
        // ⛔ A KEY THAT LANDS AFTER THE WINDOW WAS DECRYPTED HEALS IT (audit 04 F2, 2026-10-23). A
        // decrypt against a stale key gave a lock bubble and fetched the new key, but nothing here
        // re-decrypted, so the lock stayed for the rest of the visit. The same replay the key preload
        // does, for the other person of a 1:1 or any author in this window.
        if keyObserver == nil {
            keyObserver = NotificationCenter.default.addObserver(
                forName: .peerKeyChanged, object: nil, queue: .main) { [weak self] n in
                    // A synced channel keeps no window: its posts' own docs are decrypted again.
                    if let self, self.chMode == .synced, let who = n.object as? String,
                       self.byId.values.contains(where: { $0.authorId == who }) {
                        self.chRedecrypt()
                        return
                    }
                    guard let self, let who = n.object as? String, !self.lastDocs.isEmpty,
                          who == self.otherUid || self.byId.values.contains(where: { $0.authorId == who })
                    else { return }
                    self.rawReactions.removeAll()
                    self.applyLiveSnapshot(self.lastDocs, fromCache: self.lastDocsFromCache, redecrypt: true)
                }
        }
        guard let uid = Auth.auth().currentUser?.uid else { return }
        // 1:1 cid is "uidA_uidB"; a group cid is a random doc id (no underscore).
        let isOneToOne = cid.contains("_")
        let other = isOneToOne ? (cid.split(separator: "_").map(String.init).first { $0 != uid } ?? "") : ""
        otherUid = other
        // 2026-09-26 block rebuild: the block comes from MY list, so it is known before the chat
        // document answers, and a block or unblock made anywhere (another screen, another of my
        // devices) re-filters this chat at once.
        iBlocked = isOneToOne && BlockList.snapshot.contains(other)
        if blockObserver == nil {
            blockObserver = NotificationCenter.default.addObserver(
                forName: BlockList.didChange, object: nil, queue: .main) { [weak self] _ in
                    self?.blockStateChanged()
                }
        }
        // 2026-09-28: the server let this phone back in after refusing it (see `SessionRecovery`).
        // Only a chat whose message listener actually died re-attaches; a healthy one is left alone.
        // `start()` re-attaches all four listeners together, so the header and presence come back too.
        if recoveredObserver == nil {
            recoveredObserver = NotificationCenter.default.addObserver(
                forName: SessionRecovery.recovered, object: nil, queue: .main) { [weak self] _ in
                    // Owner, 2026-10-08: every listener of this chat that is dead comes back, not only
                    // the message one. A refused header or user listener used to stay dead for good.
                    self?.reattachIfDead(includePresence: true)
                }
        }
        // 2026-10-20 (owner): the old Firestore client froze and `FirestoreHub` swapped in a fresh
        // one. Every listener of this chat belongs to the stuck client, dead or not, so all of them
        // come back on the new one, and a page or cursor tied to the old client is let go.
        if swappedObserver == nil {
            swappedObserver = NotificationCenter.default.addObserver(
                forName: FirestoreHub.swapped, object: nil, queue: .main) { [weak self] _ in
                    self?.reattachAfterSwap()
                }
        }
        // Owner audit 2026-10-06 chat #68: an older page that failed, or came only from the local
        // cache, was not asked again until the reader scrolled; a reader resting at the top saw
        // nothing arrive after the signal came back. Ask once more when it does, if they are still
        // reading history. A beat late, so the database has reconnected and answers from the server.
        if networkObserver == nil {
            networkObserver = NotificationCenter.default.addObserver(
                forName: .networkCameBack, object: nil, queue: .main) { [weak self] _ in
                    self?.resumeHeld = false   // #69: the resume read may try the server again
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        self?.chReattachFromLastChg(why: "network")
                        // A thin history (the top-up stopped on the failed page) asks again too.
                        guard let self, self.olderNeedsRetry,
                              self.readerAwayFromBottom || (!self.cid.contains("_") && self.items.count < self.topUpMinRows),
                              self.listener != nil, !self.loadingOlder else { return }
                        self.loadOlder()
                    }
                }
        }
        // (`stop()` moved to the top of this function; see the note there.)
        // Conversation doc: the other person's typing flag + their read timestamp.
        convListener?.remove()   // same re-entry rule as the message listener above
        convListener = nil
        // ⛔ A PUBLIC GROUP SEEN FROM OUTSIDE (`previewOnly`, owner 2026-10-21) MAY NOT READ THE GROUP
        // DOCUMENT: no listener, so no refusal reaches SessionRecovery. Nothing on it is the guest's.
        // (The block below is not re-indented, to keep the change readable.)
        if previewOnly { convLoaded = true } else {
        convListener = db.collection("conversations").document(cid)
            .addSnapshotListener { [weak self] snap, error in
                guard let self else { return }
                if snap == nil, error != nil {
                    // Owner, 2026-10-08: this error used to be ignored, leaving the header, typing and
                    // read ticks dead for the rest of the visit. Drop the handle so `recovered` or the
                    // foreground re-attaches it, and let SessionRecovery know the server refused.
                    debugLog("[Recovery] chat conv listener ended: \(error!.localizedDescription)")
                    self.convListener = nil
                    Task { @MainActor in SessionRecovery.noteRefusal(error, "chat-conv") }
                    return
                }
                self.convLoaded = true
                let d = snap?.data()
                // The conversation's birth, for `historyStartReached` (read once; it never changes).
                if self.convBornFromDoc == nil, let born = (d?["createdAt"] as? Timestamp)?.dateValue() {
                    self.convBornFromDoc = born
                    self.refreshHistoryStart(record: true)
                }
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
                    // 2026-09-25: when my messages reached their phone (two grey ticks).
                    // Milliseconds: the conversation's `updatedAt` their phone confirmed it had.
                    if let n = (d?["delivered"] as? [String: Any])?[other] as? NSNumber {
                        self.otherDeliveredMillis = n.doubleValue
                    }
                } else {
                    // Group: typing = ANY other member typing; "read" = the SLOWEST other reader
                    // (a message shows read only once everyone has read it, matching the list).
                    let others = (d?["users"] as? [String] ?? []).filter { $0 != uid }
                    let typingMap = d?["typing"] as? [String: Any] ?? [:]
                    let names = d?["names"] as? [String: String] ?? [:]
                    // 2026-10-19: a member I blocked never shows as typing or recording; their
                    // messages are hidden, so a header that says they type was a leak.
                    let blocks = BlockList.snapshot
                    let typers = others.filter {
                        !blocks.contains($0) &&
                        ((typingMap[$0] as? Bool) == true || (typingMap[$0] as? String)?.hasPrefix("text") == true)
                    }
                    self.otherTyping = !typers.isEmpty
                    let recorders = others.filter {
                        !blocks.contains($0) && (typingMap[$0] as? String)?.hasPrefix("audio") == true
                    }
                    self.otherRecording = !recorders.isEmpty
                    self.recordingNames = recorders.map { names[$0] ?? "Someone" }
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
                // 2026-09-26: these three are the OLD, shared copy of a block, honoured until
                // `BlockList.migrate` moves it to my private list; `iBlocked` also reads that list.
                let legacyBlocked = (d?["blockedBy"]      as? [String: Any])?[uid] as? Bool ?? false
                let newBlocked   = legacyBlocked || (isOneToOne && BlockList.snapshot.contains(other))
                let newBlockedAt = ((d?["blockedAt"]      as? [String: Any])?[uid] as? NSNumber)?.doubleValue ?? 0
                let newClearedAt = ((d?["blockClearedAt"] as? [String: Any])?[uid] as? NSNumber)?.doubleValue ?? 0
                // Up to 5 pins (array). Fall back to the legacy single `pinnedMessageId`.
                let newPinned: [String] = (d?["pinnedMessageIds"] as? [String])
                    ?? ((d?["pinnedMessageId"] as? String).flatMap { $0.isEmpty ? nil : [$0] } ?? [])
                let newDisappear = (d?["disappearSeconds"] as? NSNumber)?.intValue ?? 0
                // Clear Chat, from this phone or another of mine (a watermark: never moves back).
                let newChatCleared = max(self.myChatClearedAtMillis,
                                         ((d?["clearedAt"] as? [String: Any])?[uid] as? NSNumber)?.doubleValue ?? 0)
                let pinsChanged = newPinned != self.pinnedMessageIds
                let needsRebuild = newBlocked   != self.iBlocked               ||
                                   newBlockedAt != self.myBlockedAtMillis      ||
                                   newClearedAt != self.myBlockClearedAtMillis ||
                                   newPinned    != self.pinnedMessageIds       ||
                                   newDisappear != self.disappearSeconds       ||
                                   newChatCleared != self.myChatClearedAtMillis
                self.iBlocked               = newBlocked
                self.legacyBlocked          = legacyBlocked
                self.myBlockedAtMillis      = newBlockedAt
                self.myBlockClearedAtMillis = newClearedAt
                self.pinnedMessageIds       = newPinned
                self.disappearSeconds       = newDisappear
                if newChatCleared != self.myChatClearedAtMillis {
                    self.myChatClearedAtMillis = newChatCleared
                    self.refreshHistoryStart(record: false)
                }
                // Restricted while ANYONE'S own switch is on (`restrictedBy`), or an older build's
                // shared fields still say so — the same rule `Conversation` reads.
                let anyone = ((d?["restrictedBy"] as? [String: Any]) ?? [:]).values.contains { ($0 as? Bool) == true }
                let newNoShots = anyone || (d?["noScreenshots"] as? Bool ?? false)
                if newNoShots != self.noScreenshots { self.noScreenshots = newNoShots }
                let newNoForward = anyone || (d?["noForwarding"] as? Bool ?? false)
                if newNoForward != self.noForwarding { self.noForwarding = newNoForward }
                let newNoSave = anyone || (d?["noSaving"] as? Bool ?? false)
                if newNoSave != self.noSaving { self.noSaving = newNoSave }
                // Only when the list actually changed: this snapshot also fires for every typing
                // flicker and every read receipt.
                if pinsChanged { self.syncPinnedPreviews() }
                if needsRebuild { self.rebuild() }
            }
        }   // !previewOnly
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
        if isOneToOne, !other.isEmpty, !warmOnly {
            userListener?.remove()   // same re-entry rule as the message listener above
        userListener = db.collection("users").document(other)
                .addSnapshotListener { [weak self] snap, error in
                    // Owner, 2026-10-08: an error is not "no privacy settings". It used to reset the
                    // map and record an empty one for calls. Keep what is known, drop the handle so
                    // it re-attaches, and report the refusal.
                    guard let snap else {
                        debugLog("[Recovery] chat user listener ended: \(error?.localizedDescription ?? "?")")
                        self?.userListener = nil
                        Task { @MainActor in SessionRecovery.noteRefusal(error, "chat-user") }
                        return
                    }
                    let privacy = (snap.data()?["privacy"] as? [String: String]) ?? [:]
                    self?.otherPrivacy = privacy
                    // owner 2026-10-18: their admin-panel override (Message Requests / Chat Key) rides
                    // the same snapshot, so a flip reaches this open chat at once.
                    MsgPolicy.shared.record(uid: other, data: snap.data())
                    // 2026-09-24 decision D15: a deleted account is one whose profile is GONE.
                    // ⛔ 2026-10-18, owner: "after 30 days" — inside the deletion grace period
                    // (isHidden + deletionScheduledFor) they can still come back, so the chat stays
                    // open; the bar comes when the purge removes the profile, whoever asked for it.
                    // A missing doc counts only when the server said so: a cold cache also reports
                    // "does not exist" on its first snapshot, which is not a deletion.
                    if snap.exists || !snap.metadata.isFromCache {
                        let deleted = !snap.exists
                        if self?.otherAccountDeleted != deleted { self?.otherAccountDeleted = deleted }
                    }
                    // AND THE CALL BUTTON LEARNS IT ON THE SAME SNAPSHOT. This listener is already
                    // live on their user document, so the moment they set calls to No One we know —
                    // but `CallPrivacyIndex` was only ever filled by one-off profile FETCHES, and it
                    // refreshed itself AFTER a call was placed. So the first press on somebody who
                    // had just changed the setting rang anyway, and only the second press said
                    // anything. That is the "appears a little late" in his report: not a slow dialog,
                    // a stale answer.
                    CallPrivacyIndex.record(uid: other, privacy: privacy)
                }
            attachPresence(other)
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
        // ⛔ ONE LISTENER. `onAppear` is not once-per-identity — it fires again on every return from
        // a pushed screen (the profile, the gallery, a full-screen cover tearing down), and this
        // assignment had no guard and no prior removal, so each return attached a SECOND live
        // snapshot stream with its own off-main decrypt fan. `stop()` removes only the last handle,
        // so the earlier ones kept streaming, and billing reads, after the chat was left.
        //
        // The two notification observers a few lines above ARE guarded, which is the tell that
        // re-entry was considered for one half of this method and not the other.
        listener?.remove()
        listener = nil
        // ⛔ A CHANNEL FOLLOWS ITS CHANGE COUNTER (CHANNEL-SYNC-SPEC.md 7); everything else, and a
        // channel whose docs carry no `chg` yet, keeps the window listener exactly as before.
        if channelSyncEligible {
            startChannelSync(uid: uid)
        } else {
            chUse(nil)
            chMode = .off
            attachWindowListener()
        }
        // Load keys in the BACKGROUND (in parallel). Warming the recipient's key here also
        // means the first send is instant instead of blocking on the fetch. Once the key
        // arrives, re-decrypt the current window (existing chats may briefly show "…").
        // [weak self] + stored + cancelled by `stop()` (audit C6): this used to hold `self` strongly
        // and outlive the screen that started it, so leaving and quickly reopening the same chat let
        // the OLD run's re-decrypt land after the new screen had already rebuilt from a fresh cache.
        keyPreloadTask?.cancel()
        keyPreloadTask = Task { [weak self] in
            try? await Crypto.shared.ensureReady()
            guard !Task.isCancelled else { return }
            // Preload EVERY member's public key (groups), not just a cid-derived "other" —
            // group messages can only be decrypted with their author's key, so all members'
            // keys must be cached or their messages render as "…".
            let members = await Self.memberUids(cid: cid, fallbackOther: other)
            await withTaskGroup(of: Void.self) { g in
                for m in members where m != uid { g.addTask { _ = await Crypto.shared.preloadKey(m) } }
            }
            await MainActor.run {
                // A synced channel keeps no window: its posts' own docs are decrypted again.
                if let self, !Task.isCancelled, self.chMode == .synced { self.chRedecrypt(); return }
                // Bail if this run was cancelled (chat left) or already gone before landing its write.
                guard let self, !Task.isCancelled, !self.lastDocs.isEmpty else { return }
                // Force a re-decrypt of the window (keys just arrived) WITHOUT clearing byId: emptying it
                // blanked the whole list until the off-main decrypt finished AND dropped any paged-older
                // history. Clearing only the sig cache makes applyLiveSnapshot re-decrypt the window while
                // byId stays populated, so nothing ever goes blank and older messages are preserved.
                self.rawReactions.removeAll()
                // Owner audit 2026-10-06 chat #19: replay the window AS WHAT IT WAS. This said
                // `fromCache: false` always, so a window that came from the local cache was treated as
                // the server's answer and its delete pass removed newer messages until the real
                // server snapshot put them back.
                self.applyLiveSnapshot(self.lastDocs, fromCache: self.lastDocsFromCache, redecrypt: true)
            }
        }
    }

    /// The live listener over the newest window (moved out of `start()` unchanged, 2026-11-09, so a
    /// channel still probing for `chg` can attach it after its store has loaded).
    private func attachWindowListener() {
        listener?.remove()
        listener = db.collection("conversations").document(cid).collection("messages")
            .order(by: "createdAt", descending: true)
            .limit(to: pageSize)
            .addSnapshotListener { [weak self] snap, error in
                guard let self else { return }
                guard let snap else {
                    // Listener ERROR (seen in the wild: a brand-new chat opened from search sat on
                    // the skeleton FOREVER). A dead listener must never freeze the screen — reveal
                    // the (empty) chat and re-attach after a beat.
                    self.didInitialLoad = true
                    self.listenerFailed = true
                    if self.moderationLocked { return }
                    // Owner, 2026-10-08: never blank a chat because the server is refusing. Rows already
                    // in memory stay; if there are none, take the warm cache.
                    if self.messages.isEmpty, let c = ThreadMessageCache.shared.memoryMessages(for: self.cid), !c.isEmpty {
                        self.seed(c)
                    }
                    // 2026-09-28: and if it was the SERVER refusing, the backoff retries below
                    // will be refused too. `SessionRecovery` gets back in and posts `recovered`,
                    // which re-attaches this chat at once instead of waiting out the backoff.
                    // A guest refused (the group went private, or banned them) is not a session
                    // problem (owner 2026-10-21): it is never reported, only retried.
                    if !self.previewOnly {
                        Task { @MainActor in SessionRecovery.noteRefusal(error, "chat") }
                    }
                    self.retryStartSoon()
                    return
                }
                self.listenerRetries = 0   // a live snapshot landed: the next error starts backoff over
                self.listenerFailed = false
                // Don't blank an open thread on an empty offline snapshot.
                if snap.metadata.isFromCache && snap.documents.isEmpty && !self.messages.isEmpty { return }
                // Pass whether this is a cache/local snapshot — deletes are only trusted from the SERVER
                // (a from-cache/resync snapshot can transiently drop docs that still exist → the "message
                // gone for a few seconds then comes back" bug).
                self.applyLiveSnapshot(snap.documents, fromCache: snap.metadata.isFromCache)
            }
    }

    // All member uids for a cid: prefer the loaded conversation; fall back to fetching the
    // doc (a just-created group may not be in the repo yet); else the 1:1 "other".
    private static func memberUids(cid: String, fallbackOther: String) async -> [String] {
        if let conv = ConversationsRepository.shared.conversations.first(where: { $0.id == cid }) {
            return conv.users
        }
        if let snap = try? await FirestoreHub.db.collection("conversations").document(cid).getDocument(),
           let users = snap.data()?["users"] as? [String] {
            return users
        }
        return fallbackOther.isEmpty ? [] : [fallbackOther]
    }

    // Stable change signature for the MUTABLE fields of a message doc: reactions, the text cipher
    // (EDITS — the old reactions-only gate meant an edited message never re-rendered), the edited
    // flag, the album array, and the deleted flag + type (tombstones, see below).
    // Reaction keys are sorted so the signature is deterministic.
    // Static: it reads only the doc, so the live snapshot can compute it off the main thread.
    private static func changeSig(_ data: [String: Any]) -> String {
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
        // CALL ROWS ARE MUTABLE NOW (the live ring row, 2026-08-12): outcome merges
        // ringing → ongoing → missed/answered onto the SAME doc, the duration lands with the final
        // write, and a voice call that opened a camera upgrades callVideo. Without these the cached
        // Message is reused and the bubble freezes at "Ringing" until relaunch — the same class of
        // bug as `deleted` below, third instance.
        let call = (data["callOutcome"] as? String ?? "") + ":"
            + String((data["callDuration"] as? NSNumber)?.intValue ?? -1) + ":"
            + String(data["callVideo"] as? Bool ?? false)
        // ⛔ THE TWO-PHASE MEDIA WRITE, AND THE THIRD INSTANCE OF THE MISTAKE ABOVE.
        //
        // A photo, video, voice note or file is written in TWO writes: the message first, carrying
        // `uploading: true` and no url so the recipient gets a real bubble immediately, and then a
        // second write that attaches the url and deletes the flag when the bytes land.
        //
        // Not one field of that second write was in this signature. For a single photo with no
        // caption the string it produced was byte-identical before and after — same empty text, same
        // type "image", no album, not deleted, no reactions, not a call — so `buildCached` handed
        // back the Message it had built from the FIRST write, the one that still says
        // `uploading == true` and has no url. `refreshItems` hides a server copy that is still
        // uploading in favour of my own pending row, so the bubble kept its clock and its ring for
        // as long as the chat stayed open. Leaving and coming back rebuilt the cache from the doc as
        // it now stands, which is why it healed itself the moment he did that.
        //
        // ⚠️ An ALBUM was immune, and that is the tell: `albumSig` above already reads the item
        // urls, so the attach write moved its signature. Every path that attaches a SINGLE url had
        // nothing watching it.
        let uploading = String(data["uploading"] as? Bool ?? false)
        let media = ["imageUrl", "videoUrl", "audioUrl", "fileUrl", "thumbUrl"]
            .map { data[$0] as? String ?? "" }.joined(separator: ",")
        // Owner audit 2026-10-06 chat #18: THE SERVER STAMP, a fourth field that changes after the
        // first sight. My own message is first seen from the local write, where `createdAt` is still
        // pending, so `Message` falls back to this phone's clock with `hasServerTime == false`. The
        // ack fills the stamp and nothing else, so the signature did not move and the row kept the
        // phone's time (and its disappearing timer counted from it) until the chat was reopened.
        // Display order is unaffected: the order key is sticky per row.
        let stamp = (data["createdAt"] as? Timestamp).map { "\($0.seconds).\($0.nanoseconds)" } ?? "-"
        // 2026-10-23 (owner, build 1014): THE LINK CARD ARRIVES AFTER THE TEXT. A message with a link
        // is written at once and its author adds `linkPreview` a moment later (ChatService
        // .attachLinkPreview). Without it here the cached card-less Message was reused forever.
        let lp = data["linkPreview"] as? [String: Any]
        let link = lp.map { "L" + ($0["imageUrl"] as? String ?? "") } ?? "-"
        // ⛔ A CHANNEL POST'S COUNTS, THE FIFTH INSTANCE (owner 2026-10-30: a new post kept "👁 0"
        // while the server already held views 1; proved with a read of the post). The server writes
        // `views`, `reactionCounts` and the poll tallies onto the post AFTER it is first seen (the
        // author's view at once, everyone else's once a minute), and none of them was here, so the
        // cached Message with the old numbers was handed back until the channel was reopened.
        let views = String((data["views"] as? NSNumber)?.intValue ?? 0)
        let rc = (data["reactionCounts"] as? [String: Any]) ?? [:]
        let counts = rc.keys.sorted().map { "\($0)=\((rc[$0] as? NSNumber)?.intValue ?? 0)" }.joined(separator: ",")
        let pc = (data["pollCounts"] as? [String: Any]) ?? [:]
        let polls = pc.keys.sorted().map { "\($0)=\((pc[$0] as? NSNumber)?.intValue ?? 0)" }.joined(separator: ",")
            + ":" + String((data["pollVoters"] as? NSNumber)?.intValue ?? 0)
        let base: String = (data["text"] as? String ?? "") + "|" + String(data["edited"] as? Bool ?? false)
            + "|" + reactions + "|" + albumSig + "|" + deleted + "|" + type + "|" + call
            + "|" + uploading + "|" + media + "|" + stamp + "|" + link
            + "|" + views + "|" + counts + "|" + polls
            + "|" + String(data["pollClosed"] as? Bool ?? false)   // Stop Poll changes nothing else
            // The sixth: the server stamps the timer in a second write after the message lands.
            + "|" + String((data["expiresAt"] as? Timestamp)?.seconds ?? 0)
        return base + "|" + Self.postExtrasSig(data)
    }

    /// ⛔ THE SEVENTH (owner 2026-11-07: replies turned off, the post still said "Reply" and its sheet
    /// still opened on Replies until the channel was reopened). Replies and quotes land on the post
    /// later too: the off switch, both counts and both face lists. Its own function: one more `+` in
    /// `changeSig` was past what the compiler can type-check (TF 42356820367).
    private static func postExtrasSig(_ data: [String: Any]) -> String {
        let off: String = (data["repliesOff"] as? Bool).map { String($0) } ?? "-"   // unset differs from false
        let replies: Int = (data["replyCount"] as? NSNumber)?.intValue ?? 0
        let quotes: Int = (data["quoteCount"] as? NSNumber)?.intValue ?? 0
        let rf: [String] = (data["replyFaces"] as? [String]) ?? []
        let qf: [String] = (data["quoteFaces"] as? [String]) ?? []
        // The eighth: a view-once burn (consumeOnceImage / consumeOnceVoice) sets `consumed`,
        // which flips the sender's bubble to "Opened". The url delete moves `media` too, but a
        // sender whose doc never had a url (still uploading) must not miss it.
        let once: Bool = data["consumed"] as? Bool ?? false
        // Bold spans (`fmt`): an edit may change only them.
        let fmt: String = data["fmt"] as? String ?? ""
        let parts: [String] = [off, String(replies), String(quotes),
                               rf.joined(separator: ","), qf.joined(separator: ","), String(once), fmt]
        return parts.joined(separator: "|")
    }

    // Build a message, reusing the cached copy unless a mutable field (reactions / edit) changed.
    @discardableResult
    private func buildCached(_ doc: QueryDocumentSnapshot) -> Message {
        let id = doc.documentID, data = doc.data()
        let sig = Self.changeSig(data)
        if let cached = byId[id], rawReactions[id] == sig { return cached }
        let m = Message(id: id, data: data, cid: cid, crypto: Crypto.shared)
        forgetLocalCopiesIfDeleted(old: byId[id], new: m)
        byId[id] = m
        rawReactions[id] = sig
        return m
    }

    /// Someone deleted this for everyone: the tombstone carries no urls, so the files this phone
    /// decrypted are named from the copy it replaces, and any banner of it goes too.
    private func forgetLocalCopiesIfDeleted(old: Message?, new: Message) {
        guard new.deleted, let old, !old.deleted else { return }
        let id = new.id, cid = cid
        Task { @MainActor in
            ChatService.forgetLocalCopies(of: old, cid: cid)
            NotificationCleaner.remove(messageId: id)
        }
    }

    // Re-attach the whole listener set after a listener error. Audit C14: this used to give up
    // after 3 tries and leave the chat silently frozen (no new messages, reactions or receipts)
    // until it was left and reopened. Retrying forever with backoff instead — 2s, 4s, 8s… capped
    // at 60s — means a listener that keeps failing settles into a slow, harmless poll rather than
    // stopping, and `listenerRetries` resets to 0 the moment a live snapshot actually lands.
    private var listenerRetries = 0
    /// The message listener ended in an error and no snapshot has arrived since.
    private(set) var listenerFailed = false
    /// The load failed and there is nothing to show. The chat says so with a Try Again button
    /// instead of looking like an empty new chat. Rows from the cache, if any, win.
    var loadFailed: Bool { listenerFailed && messages.isEmpty && !moderationLocked && !previewOnly && !lockedGuest }
    /// Try Again on the failed-load panel: skip the backoff wait and attach now.
    func retryLoad() {
        retryWork?.cancel()
        listenerRetries = 0
        start()
    }
    private var recoveredObserver: NSObjectProtocol?
    /// 2026-10-20 (owner): `FirestoreHub.swapped`, the Firestore client was replaced by a fresh one.
    private var swappedObserver: NSObjectProtocol?
    /// Owner audit 2026-10-06 chat #72: the pending retry, so `stop()` can cancel it. It used to be a
    /// bare `asyncAfter` that nothing could take back: an error, then leaving the chat within the
    /// backoff (up to a minute), and the retry re-attached all four listeners to a closed chat with
    /// nothing left to stop them while anything still held the repository.
    @ObservationIgnored private var retryWork: DispatchWorkItem?
    /// Owner, 2026-10-08: re-attach when any of this chat's listeners is dead. `start()` re-attaches all
    /// of them together. Presence is left out of the foreground check because a denied presence read
    /// is normal and would otherwise restart the chat every time the app comes forward.
    /// Owner, 2026-10-08: set when the presence read was refused (code 7, a privacy outcome). A refused
    /// presence is not a dead chat: it never restarts the whole chat, only retries presence alone.
    private var presenceRefused = false
    private var presenceRetriedThisRecovery = false

    private func attachPresence(_ other: String) {
        presenceListener?.remove()   // same re-entry rule as the message listener
        presenceListener = db.collection("users").document(other)
            .collection("presence").document("state")
            .addSnapshotListener { [weak self] snap, error in
                // Owner, 2026-10-08: a denied presence read is a normal privacy outcome, so it is
                // not reported and not retried in a loop. Keep the last known value; the handle is
                // dropped so a recovery or a reopen can try again.
                guard let snap else {
                    debugLog("[Recovery] chat presence listener ended (privacy or network): \(error?.localizedDescription ?? "?")")
                    let ns = error as NSError?
                    if ns?.domain == FirestoreErrorDomain, ns?.code == 7 { self?.presenceRefused = true }
                    self?.presenceListener = nil
                    return
                }
                self?.presenceRefused = false
                let d = snap.data()
                self?.otherOnline = d?["online"] as? Bool ?? false
                if let ts = d?["lastActive"] as? Timestamp { self?.otherLastActive = ts.dateValue() }
            }
    }

    private func reattachIfDead(includePresence: Bool) {
        guard !cid.isEmpty, !DemoMode.isDemoConversation(cid), listener != nil || listenerFailed else { return }
        let oneToOne = !otherUid.isEmpty
        if includePresence { presenceRetriedThisRecovery = false }
        let dead = listenerFailed || listener == nil || (convListener == nil && !previewOnly)
            || (oneToOne && (userListener == nil || (includePresence && presenceListener == nil && !presenceRefused)))
        guard dead else {
            // Presence alone, once per recovery, never the whole chat.
            if includePresence, oneToOne, presenceListener == nil, !presenceRetriedThisRecovery {
                presenceRetriedThisRecovery = true
                attachPresence(otherUid)
            }
            return
        }
        listenerRetries = 0
        start()
    }

    /// 2026-10-20 (owner): after `FirestoreHub.swapped`. The old handles are let go off the main
    /// thread (`FirestoreHub.drop`), set nil first so `start()`'s own `stop()` never calls `remove()`
    /// on them here, then `start()` attaches the same four listeners to the fresh client.
    private func reattachAfterSwap() {
        guard !cid.isEmpty, !DemoMode.isDemoConversation(cid), listener != nil || listenerFailed else { return }
        FirestoreHub.drop([listener, convListener, userListener, presenceListener, chGoneListener, chHeadListener])
        listener = nil; convListener = nil; userListener = nil; presenceListener = nil
        chGoneListener = nil; chHeadListener = nil
        // The older-page cursor is a snapshot of the stuck client, and the held resume query was built
        // on it: page on by value from the oldest message held instead (the same path as after a trim).
        if oldestDoc != nil { windowTrimmed = true }
        resumeOlderQuery = nil
        resumeHeld = false
        // A page asked of the stuck client never answers, and `loadingOlder` would hold every later
        // page behind it. Ask again on the fresh client and hand its waiters that answer.
        let waiters = olderWaiters
        olderWaiters = []
        let wasLoading = loadingOlder
        loadingOlder = false
        listenerRetries = 0
        start()
        if wasLoading || !waiters.isEmpty {
            loadOlder { waiters.forEach { $0() } }
        }
    }

    private func retryStartSoon() {
        listenerRetries += 1
        let delay = min(pow(2.0, Double(listenerRetries)), 60)
        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.start()
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // Monotonic snapshot sequencing: detached decrypt batches can finish out of order; the
    // committed sequence guards against an OLDER batch overwriting a newer one (which would
    // resurrect deleted messages / revert reactions).
    private var snapshotSeq = 0
    private var committedSeq = 0

    // Apply the live (recent-window) snapshot: refresh/insert the window's messages,
    // reconcile deletes within the window's time range, keep paged-older messages.
    private func applyLiveSnapshot(_ docs: [QueryDocumentSnapshot], fromCache: Bool, redecrypt: Bool = false) {
        // A channel that moved to its change counter: a late answer of the old window is not applied.
        guard chMode != .synced else { return }
        lastDocs = docs   // remember the window so we can re-decrypt once the key arrives
        lastDocsFromCache = fromCache   // #19: and where it came from
        snapshotSeq += 1
        let seq = snapshotSeq
        // Decrypt OFF the main thread. Opening a chat that already has cached history fires
        // this listener INSTANTLY with up to a full page; decrypting it all on the main
        // thread froze the UI during the navigation transition (the tester's "tap → gray →
        // hang"). Only NEW or reaction-changed docs are decrypted; the rest are reused.
        // (box.open is a thread-safe pure op, and my keys are set before any chat can open.)
        //
        // ⛔ AND THE FINGERPRINTS TOO — owner, 2026-09-28, the timing box: the app froze for 73ms
        // three milliseconds after the first snapshot landed, in the middle of the open's slide. The
        // decrypt was already off the main thread; working out WHICH docs needed it was not: a
        // `data()` conversion and a signature string for every doc in the window, on main. Both are
        // pure reads of an immutable snapshot, so they go with the decrypt, against a copy of what
        // is known now. The out-of-order guard below covers the extra hop exactly as it did before.
        let knownSigs = rawReactions
        let knownIds = Set(byId.keys)
        let cidLocal = cid
        Task.detached(priority: .userInitiated) { [weak self] in
            let sigs = Dictionary(docs.map { ($0.documentID, Self.changeSig($0.data())) },
                                  uniquingKeysWith: { a, _ in a })
            let needBuild = docs.filter { doc in
                !knownIds.contains(doc.documentID) || knownSigs[doc.documentID] != sigs[doc.documentID]
            }
            let built: [(String, Message)] = needBuild.map { doc in
                (doc.documentID, Message(id: doc.documentID, data: doc.data(), cid: cidLocal, crypto: Crypto.shared))
            }
            await MainActor.run {
                guard let self else { return }
                // Drop this batch if a NEWER snapshot already committed (out-of-order completion).
                guard seq >= self.committedSeq else { return }
                for (id, m) in built { self.byId[id] = m; self.rawReactions[id] = sigs[id] ?? "" }
                self.commitSnapshot(docs, seq: seq, fromCache: fromCache, redecrypt: redecrypt)
            }
        }
    }

    // Reconcile the window (deletes, paging cursor, first-load flag) and republish — runs
    // on the main thread AFTER the (off-main) decryption merges its results into the cache.
    private func commitSnapshot(_ docs: [QueryDocumentSnapshot], seq: Int, fromCache: Bool, redecrypt: Bool = false) {
        guard seq >= committedSeq else { return }   // never let an older snapshot overwrite a newer one
        guard chMode != .synced else { return }     // the window was let go for the change counter
        committedSeq = seq
        // owner 2026-10-21 (the open jump): what this window IS, for the list. A cache window before the
        // server has answered is still the open; the server's first window is the settle; a replay
        // after the keys arrived is a re-decrypt. Only what comes after those is a live arrival.
        var reason: MessageListUpdateReason = redecrypt ? .redecrypt
            : (!fromCache && !sawServerWindow) ? .serverSettle
            : (fromCache && !sawServerWindow) ? .initial
            : .live
        // ⛔ A MESSAGE THAT ARRIVES INSIDE THE SETTLE IS STILL AN ARRIVAL (owner 2026-10-23: "after the
        // app restarts, the first message they send me pops in; the next ones come in smooth"). After
        // a cold start the cache paints the chat and the server's first window comes late; a message
        // sent in between rides in on that window, which the list holds still (no animation). A doc
        // the list has not shown, newer than everything it has shown, makes this window a live one.
        if reason == .serverSettle, let newestShown = items.map(\.createdAt).max() {
            let arrived = docs.contains { d in
                indexById[d.documentID] == nil
                    && ((d.data()["createdAt"] as? Timestamp)?.dateValue() ?? .distantPast) > newestShown
            }
            if arrived { reason = .live }
        }
        let windowIds = Set(docs.map { $0.documentID })
        // Rows from a channel store whose `chg` query was refused: only what the window holds stays.
        if chDropUnheld, !fromCache {
            chDropUnheld = false
            for id in Array(byId.keys) where !windowIds.contains(id) {
                byId.removeValue(forKey: id); rawReactions.removeValue(forKey: id)
            }
        }
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
            // `>`, not `>=` — owner audit 2026-10-06 chat #71: a held message with EXACTLY the edge's
            // stamp (a batch write, a bulk forward) can be one the `limit` cut off, not one that was
            // deleted. Deleting it lost a real message; a hard delete at that exact stamp is the
            // only thing `>` can miss, and a delete for everyone is a tombstone update anyway.
            for (id, m) in byId where m.createdAt > cutoff && !windowIds.contains(id) {
                byId.removeValue(forKey: id); rawReactions.removeValue(forKey: id)
                // Purged on the server before this phone's own timer got to it.
                let cid = cid
                if m.expiresAt != nil { Task { @MainActor in ChatService.forgetLocalCopies(of: m, cid: cid) } }
            }
        }
        // The optimistic delete overlay has done its job once the real thing is in hand: the doc now
        // carries `deleted`, or the message is not here at all (hard-delete fallback, or paged out of
        // the window, where the overlay is inert anyway). Firestore applies our own write locally
        // before it reaches the server, so this usually clears on the very next snapshot.
        if !locallyDeleted.isEmpty {
            locallyDeleted = locallyDeleted.filter { byId[$0]?.deleted == false }
        }
        // Owner audit 2026-10-06 chat #17: ONLY THE SERVER CAN SAY HISTORY HAS ENDED, the rule
        // `loadOlder` already follows. The first window used to decide it whatever its source, so a
        // short answer from the local cache (a cold open on a slow line) switched paging off for the
        // whole visit, and the server's full page that followed never got a say. The cursor follows
        // the same rule: one taken from a cache window is replaced by the server's window, as long
        // as no older page has moved it since.
        if oldestDoc == nil || (oldestDocFromCacheWindow && !fromCache) {
            oldestDoc = docs.last
            oldestDocFromCacheWindow = fromCache
        }
        if !didInitialLoad { didInitialLoad = true }
        // ⛔ A FULL CACHE WINDOW THAT STILL HOLDS THE SAVED START STAYS WHOLE (owner 2026-11-08): a
        // channel whose 60 newest docs are mostly deleted posts reaches its start inside one full
        // window, and this used to clear the seed's `cacheLooksWhole` on the first cache snapshot.
        if fromCache && !sawServerWindow { cacheLooksWhole = docs.count < pageSize || holdsSavedStart(docs) }
        if !fromCache && !sawServerWindow {
            // The server's window decides from here (`canLoadOlder`); one that holds the oldest
            // message of a past whole visit is whole too.
            cacheLooksWhole = holdsSavedStart(docs)
            sawServerWindow = true
            serverWindowSettled = true   // published with the rebuild below, in the same update
            #if DEBUG
            NSLog("[REOPEN] repo first SERVER window docs=%ld", docs.count)
            #endif
            if docs.count < pageSize { canLoadOlder = false }   // short first SERVER page => no history
        }
        trimWindowIfNeeded()
        noteSentSound()
        let rowsBefore = items.count
        rebuild(reason: reason)
        // ⚠️ DIAGNOSTIC (owner 2026-11-09, VE3: after a return from the background the server's
        // window landed 10 s late and the one post on screen went, content 568 -> 179 pt). What the
        // window held and what it left on screen, for groups and channels, a few per open.
        if !cid.contains("_"), windowLogs < 8, rowsBefore != items.count || !fromCache {
            windowLogs += 1
            let deleted = docs.filter { ($0.get("deleted") as? Bool) == true }.count
            let kinds = Dictionary(grouping: docs.prefix(60).map { ($0.get("type") as? String) ?? "text" }, by: { $0 }).map { "\($0.key)\($0.value.count)" }.sorted().joined(separator: ",")
            DiagLog.add("WINDOW# cid=\(cid.suffix(5)) cache=\(fromCache) docs=\(docs.count) deleted=\(deleted) rows \(rowsBefore)->\(items.count) msgs=\(messages.count) canOlder=\(canLoadOlder) start=\(historyStartReached) kinds=\(kinds)")
        }
        // ⚠️ `!$0.uploading` — THE SECOND PLACE THAT DROPS A PENDING, and it has to agree with the
        // one in `refreshItems`.
        //
        // A media message is written to the server the instant Send is tapped now, carrying no bytes
        // yet. Its echo comes straight back with the same clientId, and this line deleted the
        // sender's optimistic bubble on sight — the copy that actually HAS the picture. `refreshItems`
        // then correctly hid the still-uploading server message, found no local copy left to show in
        // its place, and drew the recipient's placeholder instead. The owner saw exactly that on a
        // video (2026-08-16): the upload ring finished, then a spinner started, and his own video
        // was unplayable until a relaunch — by which time the upload had long finished.
        //
        // A message that is still uploading is not an echo yet. It is a promise.
        dropEchoedPending()
        // A channel's first SERVER window decides whether it moves to the change counter (spec 7).
        if chMode == .probing, !fromCache, !redecrypt { chProbe(docs) }
        topUpIfThin(lastPageAddedRows: true)
    }

    /// Pending sends the server now holds (see the note above, in `commitSnapshot`).
    private func dropEchoedPending() {
        let echoed = Set(byId.values.filter { !$0.uploading }.compactMap { $0.clientId })
        // ⛔ KEPT ASIDE, NOT FORGOTTEN (owner 2026-10-21: "the message disappears in seconds"). The
        // echo above is Firestore's LOCAL copy, delivered before the server has answered. When the
        // server then refuses the batch, the SDK takes that copy back out and `markFailed` found no
        // pending bubble to mark: the message simply vanished, with no red !. The dropped copy waits
        // here so a refusal can put it back as failed.
        for p in pending where p.clientId.map(echoed.contains) ?? false {
            if let cid = p.clientId { echoedPending[cid] = p }
        }
        if echoedPending.count > 50 { echoedPending.removeAll() }
        pending.removeAll { p in p.clientId.map(echoed.contains) ?? false }
    }
    private var echoedPending: [String: Message] = [:]

    /// My messages seen before the server had them (no server time yet, or the file still going up).
    private var unconfirmedMine: Set<String> = []
    /// The sent sound (owner 2026-10-29): one of mine that was waiting is now on the server, its file
    /// included. Never for a message that arrived already confirmed (opening a chat is silent).
    private func noteSentSound() {
        guard let me = Auth.auth().currentUser?.uid else { return }
        var landed = false
        for (id, m) in byId where m.authorId == me && !m.isSystem && !m.isCall {
            if !m.hasServerTime || m.uploading {
                unconfirmedMine.insert(id)
            } else if unconfirmedMine.remove(id) != nil, !m.deleted {
                landed = true
            }
        }
        if landed { ChatSounds.sent() }
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
        // ⛔ OFFLINE, A SEND IS NOT "IN FLIGHT" AND DOES NOT GET TWO MINUTES — his screenshot,
        // 2026-08-27: the retry badges never appear while he is sending, then arrive one at a time
        // once he leaves and comes back into the chat.
        //
        // Both halves of that are this cutoff. Nothing marks these failed promptly: the explicit
        // `markFailed` sites only fire when a send THROWS, and an offline write does not throw —
        // Firestore queues it and returns happily — so the only thing that ever flips them is this
        // sweep, at 120 seconds. And because each message is measured against its OWN `createdAt`,
        // they cross that line in the order they were sent: badges appearing one by one, which is
        // exactly what he described. By the time he had left the chat and come back, two minutes had
        // passed and they all showed at once, which is why it looked like re-entering was what
        // summoned them.
        //
        // The two minutes are there for a real case — a slow but genuine send should not be called
        // failed — and that case requires a network. With no path at all there is nothing to be slow
        // about, so five seconds is generous. The timer runs every 15s, so a badge now appears within
        // about that, against a floor of two minutes before.
        //
        // ⚠️ A FALSE POSITIVE IS ALREADY HARMLESS HERE, which is what makes the shorter grace safe:
        // as the note above says, if the upload lands anyway the server echo removes the pending and
        // the state corrects itself.
        let grace: TimeInterval = NetworkState.shared.isOnline ? 120 : 5
        let cutoff = Date().addingTimeInterval(-grace)
        var changed = false
        // A media send this process is still uploading is not stuck (audit 04 F4): it was shown as
        // failed while its bytes kept going, and Retry did nothing. Its own throw marks a real failure.
        let uploading: (String?) -> Bool = { id in
            guard let id, Thread.isMainThread else { return false }
            return MainActor.assumeIsolated { MediaSend.shared.isInFlight(id) }
        }
        for i in pending.indices where pending[i].sendState == .sending && pending[i].createdAt < cutoff
            && !uploading(pending[i].clientId) {
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
    /// ⛔ READ BY THE VIEW, so the top spinner can tell the two kinds of paging apart — his report,
    /// 2026-08-28: tap a reply's quote and the chat "goes loading".
    ///
    /// The spinner at the top of the list means one thing: you scrolled to the oldest message you
    /// have and more is on its way. A quote jump also pages older history, but it is not that — the
    /// person tapped a quote, they are not looking at the top of the list, and a spinner up there
    /// reads as the conversation itself failing to load. Theirs never shows one for this because a
    /// quoted reply resolves out of a local database; ours has to walk back a page at a time, so the
    /// least it can do is not narrate it in the wrong place.
    var jumpPagingInFlight: Bool { jumpPagingDepth > 0 }
    /// Owner audit 2026-10-06 chat #1: a COUNT, not a flag. Two jumps can page at once (a quote tap
    /// and a search step), and the first to finish cleared the flag while the second was still
    /// paging, so a live commit could trim away the pages the second had just loaded.
    private var jumpPagingDepth = 0

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
        // #69: the oldest rows are gone, cache-only pages first among them; paging restarts from
        // the oldest row kept, so an older resume point would jump over what was just dropped.
        resumeOlderQuery = nil
        cacheLooksWhole = false   // the start is no longer in the window
        canLoadOlder = true   // the dropped history can page back in on scroll
    }

    // ⛔ THE SWEEP DOES NOT DELETE ANY MORE. THE SERVER DOES.
    //
    // What was here deleted only messages THIS phone had written, only while this chat was open on
    // it, and left everything else to a display filter — so the feature hid content instead of
    // removing it, and the other person's copy never went anywhere. It could not have been fixed
    // here: `allow delete` on a message is author-only, so a recipient's phone is not permitted to
    // delete the sender's message and never will be. `cleanupExpiringMessages` on the server owns it
    // now and hard-deletes for both people, along with the media, the pin and the chat-list preview.
    //
    // Nor does this call `deleteMessage`, which would be the obvious shortcut for making my own copy
    // go sooner: that leaves a TOMBSTONE, and a chat filling with "this message was deleted" every
    // time a timer runs out is worse than the bug. A timer expiring is not an event worth marking.

    // ⛔ REALTIME, THE WAY THE APP THAT DELETES ON THE DEVICE DOES IT (his order, 2026-08-21:
    // "Every message Disappearing realtime").
    //
    // A five-minute sweep is fine for a chat set to a day. For a chat set to thirty seconds it is
    // the whole feature failing: the message sits there for minutes after it was supposed to be
    // gone, which is exactly what "the custom time is not working" was. So whichever phone has the
    // chat open now fires at the exact second, takes the message off the screen, and asks the server
    // to burn it for both people.
    //
    // ⚠️ THE SERVER STILL DOES THE DELETING and that is not a detour. A recipient's phone is not
    // allowed to delete the sender's message (`allow delete` is author-only), and NO phone is
    // allowed to delete anything from Storage (`storage.rules` permits a write only when
    // `resource == null`, which is create-only). `burnExpiredMessages` re-reads every id and refuses
    // anything whose expiry has not really passed, so this can never remove something the five
    // minute sweep would not have removed on its own.
    //
    // One timer, not a poll, and it is rescheduled from `rebuild()` every time the message set
    // changes. `sweepExpired` below stays as the coarse safety net for a missed fire or a clock that
    // moved.
    private func scheduleNextBurn() {
        burnTimer?.invalidate(); burnTimer = nil
        let now = Date()
        guard let next = byId.values.compactMap({ $0.expiresAt }).filter({ $0 > now }).min() else { return }
        // A fifth of a second past the mark, so the message is genuinely due when it is looked at
        // rather than a millisecond short of it.
        let delay = max(0.2, next.timeIntervalSince(now) + 0.2)
        burnTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.burnDue()
        }
    }

    /// ⛔ PHASE 1, THE PHONE KEEPS THE HISTORY (owner 2026-11-12, both apps): every message this chat
    /// shows is filed in the phone's own database. Only new or changed ones are written.
    private func fileToLocalDB(_ list: [Message]) {
        guard let me = Auth.auth().currentUser?.uid else { return }
        // On the chat's first update: what ran out while it was closed leaves the database first.
        if filedToDB.isEmpty { LocalMessageDB.shared.purgeExpired(uid: me) }
        // ⛔ safety review 2026-11-12: the cursor is written only from inside the write's success.
        // A failed write forgets what was filed (so the next update files everything again) and
        // vouches for nothing until such a full re-file has committed (`localDBBehind`). Completions
        // arrive in call order, so a failure is always seen before any later write's success.
        let full = filedToDB.isEmpty
        let changed = list.filter { filedToDB[$0.id] != $0 }
        guard !changed.isEmpty else { return }
        for m in changed { filedToDB[m.id] = m }
        LocalMessageDB.shared.upsert(cid: cid, uid: me, changed) { [weak self] ok in
            guard let self else { return }
            guard ok else {
                self.filedToDB = [:]
                self.localDBBehind = true
                return
            }
            if full { self.localDBBehind = false }
            guard !self.localDBBehind, Auth.auth().currentUser?.uid == me else { return }
            self.writeDeliveryCursor(me: me, filed: list)
        }
    }

    /// ⛔ PHASE 2 DELIVERY CURSOR (owner 2026-11-12, shared plan D1): "this phone has every message of
    /// this chat up to here". conversations/{cid}/cursors/{me} = { deliveredUpTo: ms, at: server time };
    /// the rules only let it move forward. The server deletes what every member has (behind its own
    /// switch, OFF until both apps ship). At most one write per chat every 20 s, and only forward.
    /// Channels have no cursor (their history stays on the server for good). The write itself is
    /// `DeliveryCursor.write` (owner 2026-11-12), shared with InboxSync so both keep one memory.
    private func writeDeliveryCursor(me: String, filed: [Message]) {
        let stamped = filed.filter { $0.hasServerTime }.map(\.createdAt)
        guard let newest = stamped.max(), let oldest = stamped.min() else { return }
        let ms = Int64((newest.timeIntervalSince1970 * 1000).rounded(.down))
        let low = Int64((oldest.timeIntervalSince1970 * 1000).rounded(.down)), chat = cid
        // ⛔ NO GAP, EVER. The cursor tells the server "every message up to here is on this phone",
        // and the server may delete on it. An open chat holds only its newest window, so it moves the
        // mark (and the cursor) only when that window reaches back to the mark already held. No mark
        // yet = this chat's history was never fully pulled (phase 4 does that): nothing is vouched for.
        LocalMessageDB.shared.syncedUpTo(cid: chat, uid: me) { mark in
            guard let mark, low <= mark, ms > mark else { return }
            LocalMessageDB.shared.setSyncedUpTo(cid: chat, uid: me, ms: ms) { stored in
                guard stored else { return }
                DeliveryCursor.write(cid: chat, me: me, ms: ms)
            }
        }
    }

    /// Everything due right now: off the screen first, then gone for both people.
    private func burnDue() {
        let now = Date()
        // A disappearing message leaves the phone's database at the same moment (agreed with Android).
        if let me = Auth.auth().currentUser?.uid { LocalMessageDB.shared.purgeExpired(uid: me) }
        let due = byId.values.filter { m in m.expiresAt.map { now >= $0 } ?? false }.map(\.id)
        // The redraw happens whether or not the call lands. Hiding is ours and cannot fail; the
        // deleting is the server's and might have to wait for a network.
        rebuild()
        guard !due.isEmpty else { return }
        // The files this phone decrypted go with it. The server cannot reach them.
        let dueMessages = due.compactMap { byId[$0] }, chat = cid
        Task { @MainActor in
            for m in dueMessages { ChatService.forgetLocalCopies(of: m, cid: chat) }
        }
        // Fire and forget. The other phone is very likely making the same call a second either side
        // of this one, and the second one to arrive finds nothing left and says so — deleting twice
        // is not an error, it is the end state already being true.
        Functions.functions(region: "me-central1").httpsCallable("burnExpiredMessages")
            .call(["cid": cid, "ids": Array(due.prefix(200))]) { _, _ in }
    }

    // The COARSE net behind `scheduleNextBurn`, still on its fifteen-second tick. It catches a timer
    // that never fired: a phone that was asleep, a clock that moved, or a message paged in from
    // history that was already due before this chat was opened.
    private func sweepExpired() {
        let now = Date()
        // ⛔ ADVANCE THE COUNTDOWNS EVERY SWEEP, not only when something is due. The footer's
        // disappearing-message ring shows how much of a message's life is left, and a ring is only
        // honest if it moves — but a row is rebuilt from a cache key made of content, and a message
        // on a timer has identical content from one second to the next. Without a clock in that key
        // the ring would freeze at whatever fraction it had when the row was last touched.
        //
        // The tick rides this sweep rather than a timer of its own: the sweep already exists, already
        // runs on the right cadence for this, and one counter for the whole chat is the alternative
        // to a live timer per expiring row.
        if byId.values.contains(where: { $0.expiresAt != nil }) { expiryTick &+= 1 }
        guard byId.values.contains(where: { ($0.expiresAt.map { now >= $0 }) == true }) else { return }
        burnDue()
    }

    /// ⛔ A CHANNEL SHOWS ITS OWN NEWS, NOT ITS ADMINS' WORK (owner 2026-10-30, as a visitor: "it
    /// shows the admin changed the wallpaper; that is for groups"). In a channel only the channel's
    /// own events stay, worded without the admin's name: created, renamed, photo removed. Pins and
    /// timer lines stay as they are. Everything else an admin did (wallpaper, who may post, adds and
    /// removals, restrictions) is hidden here for everyone; admins have Recent Actions for that.
    static func channelNotice(_ m: Message) -> Message? {
        guard m.isSystem, m.pinNotice == nil, m.disappearSeconds == nil, m.localNoticeSymbol == nil else { return m }
        guard let said = channelNoticeText(m.text) else { return nil }
        var out = m
        out.text = said
        return out
    }

    /// The words a channel shows for one admin notice, or nil when the notice is hidden there.
    /// Shared with the chat list preview (owner 2026-11-07: followers saw "changed the group
    /// wallpaper" as the channel's last line).
    static func channelNoticeText(_ t: String) -> String? {
        if t == "Channel created" || t.hasSuffix(" created the group") || t.hasSuffix(" created the channel") {
            return "Channel created"
        } else if let r = t.range(of: " renamed the group to ") {
            return "Channel name changed to " + t[r.upperBound...]
        } else if t.hasSuffix(" removed the group photo") {
            return "Channel photo removed"
        }
        return nil
    }

    /// An admin's wallpaper line, which a channel never shows (owner 2026-11-07).
    static func isWallpaperNotice(_ t: String) -> Bool {
        t.hasSuffix(" changed the group wallpaper") || t.hasSuffix(" removed the group wallpaper")
    }

    private func rebuild(reason: MessageListUpdateReason = .live) {
        // BEFORE anything is sorted: measure each person's clock against the server's, from the whole
        // window rather than the filtered view, so a blocked or expired message still contributes a
        // sample. `refreshItems` reuses whatever this leaves behind.
        recomputeClockOffsets(byId.values)
        var msgs = byId.values.filter { !hiddenByBlock($0) && !isClearedForMe($0) }
        if Conversation.Right.isChannel(cid) { msgs = msgs.compactMap(Self.channelNotice) }
        if !replyCountOverlay.isEmpty { msgs = applyReplyCountOverlay(msgs) }
        // Deletes the user has made but the server has not confirmed yet (see markDeletedLocally).
        // Ids for messages that are no longer here at all cost nothing and are pruned on the next
        // confirmed snapshot.
        if !locallyDeleted.isEmpty {
            msgs = msgs.map { locallyDeleted.contains($0.id) && !$0.deleted ? $0.tombstoned() : $0 }
        }
        // My own link card while its attach write is on the way (see `showLocalCard`). Dropped the
        // moment the server copy carries one.
        if !localCards.isEmpty {
            localCards = localCards.filter { k, _ in byId[k].map { $0.linkPreview == nil && !$0.deleted } ?? true }
            msgs = msgs.map { m in
                guard m.linkPreview == nil, !m.deleted, let k = m.clientId, let card = localCards[k] else { return m }
                var c = m; c.linkPreview = card; return c
            }
        }
        // ⛔ HIDE WHAT THE SERVER IS ABOUT TO DELETE, AND NOTHING ELSE.
        //
        // This used to read `createdAt >= now - disappearSeconds`, which had two faults. It hid
        // messages that were never going to be deleted by anybody, so the timer LOOKED like it was
        // working while every word was still in Firestore and still on the other person's phone.
        // And it was retroactive: setting a chat to 30 seconds blanked its entire history on sight,
        // then handed it all back if the timer was turned off again.
        //
        // A message's own `expiresAt` is the only thing consulted now. The server stamps it at send
        // time and deletes on it, so what is hidden here is exactly what is going, within the five
        // minutes to the next sweep. A message without one is not expiring — it was sent before the
        // timer was turned on, or before any of this existed — and it stays visible, which is the
        // honest answer even though it shows more than the old code did.
        let now = Date()
        msgs = msgs.filter { m in m.expiresAt.map { now < $0 } ?? true }
        // Also silence reactions from anybody I block (their activity is hidden), in a group too.
        let blocks = BlockList.snapshot
        if iBlocked || !blocks.entries.isEmpty {
            msgs = msgs.map { m in
                let drop = m.reactions.keys.filter { ($0 == otherUid && iBlocked) || blocks.contains($0) }
                guard !drop.isEmpty else { return m }
                var c = m; drop.forEach { c.reactions.removeValue(forKey: $0) }; return c
            }
        }
        // Sort on ONE timeline — see the long note above `assignOrderKeys`. Server stamps decide
        // between people; tap order holds within a person; keys are sticky so nothing moves on ack.
        var sorted = sortedOneTimeline(msgs)
        // Keys for rows that left the window (trim, delete-for-everyone) are dropped so a long session
        // cannot grow the map without bound. A re-paged row simply takes its server stamp again.
        if stickyOrderKey.count > byId.count + pending.count + 64 {
            var keep = Set(byId.values.map(\.rowId))
            pending.forEach { keep.insert($0.rowId) }
            stickyOrderKey = stickyOrderKey.filter { keep.contains($0.key) }
        }
        // Double-echo dedupe: a retry racing a slow-but-successful original can produce TWO server docs
        // with the same clientId. Show only the FIRST (earlier) one — the duplicate is invisible to the
        // user even before any server-side cleanup.
        var seenClientIds = Set<String>()
        sorted.removeAll { m in
            guard let c = m.clientId else { return false }
            return !seenClientIds.insert(c).inserted
        }
        // ⛔ NOTHING CHANGED, NOTHING PUBLISHED — owner, 2026-09-28, the timing box: a freeze in the
        // middle of the open's slide when the first snapshot landed. A chat opens on the messages it
        // already had, and the first snapshot is usually those same messages; publishing them anyway
        // bumped `itemsVersion`, which re-ran the whole chat screen's body and a list update for a
        // result identical to what was on screen. The reference app lands a load only when its
        // render state actually differs. Every other input to `items` (pending sends, hidden
        // messages) publishes through its own call to `refreshItems`, so skipping here loses nothing.
        guard sorted != messages else { refreshHistoryStart(record: true); scheduleNextBurn(); return }
        messages = sorted
        refreshHistoryStart(record: true)   // before the publish, so the card comes with the rows
        // A synced channel saves its own store (CHANNEL-SYNC-SPEC.md 5), and the warm cache still
        // gets its newest rows: channel info's media seed, the Storage page and the chat-list peek
        // read that cache, and showed deleted or stale posts while it froze (audit C9).
        if chMode == .synced, let box = chBox { box.scheduleSave() }
        ThreadMessageCache.shared.store(cid, messages)   // keep the warm cache fresh for the next open (instant render)
        fileToLocalDB(messages)
        refreshItems(reason: reason)
        // The message set just changed, so the next expiry may have too. Cheap: one timer.
        scheduleNextBurn()
    }

    /// ⛔ "YOU BLOCKED / UNBLOCKED THIS PERSON", FOR MY EYES ONLY — owner, 2026-09-28, with the
    /// reference app's two pills: "show this when I block and unblock, show only me, don't show the
    /// user I blocked". Built from my own owner-only block list (`BlockList`: the block running now
    /// and every one that ended), never written to the shared chat, so the person blocked has
    /// nothing to read — the block stays silent (2026-09-26 rebuild).
    ///
    /// Only inside the history that is loaded (`oldest`, unless there is nothing older to page in),
    /// or an old block would sit on top of the loaded page instead of where it happened. 1:1 only.
    private func blockNotices(after oldest: Date?) -> [Message] {
        guard cid.contains("_"), !otherUid.isEmpty else { return [] }
        let snap = BlockList.snapshot
        var events: [(ms: Double, blocked: Bool)] = []
        for span in snap.spans[otherUid] ?? [] {
            events.append((span.lowerBound, true))
            events.append((span.upperBound, false))
        }
        if let since = snap.entries[otherUid] { events.append((since, true)) }
        let floor = canLoadOlder ? (oldest?.timeIntervalSince1970 ?? .infinity) * 1000 : -.infinity
        return events.filter { $0.ms > 0 && $0.ms >= floor }.map { e in
            Message(localNotice: e.blocked ? "You blocked this person." : "You unblocked this person.",
                    symbol: e.blocked ? "nosign" : "bubble.left.and.bubble.right",
                    id: "local-block-\(e.blocked ? "on" : "off")-\(Int64(e.ms))",
                    at: Date(timeIntervalSince1970: e.ms / 1000))
        }
    }

    // Silent block: hide what anybody I block sent while I had them blocked. While blocked → hide
    // everything after I blocked. After unblock → keep hiding the block window so the backlog never
    // arrives. 2026-09-26 block rebuild: `BlockList` answers (my private list and its history), for
    // the 1:1 partner AND for a blocked member of a group I share with them (the reference app that
    // hides them there too). The chat's old copy of the window still counts until it is moved.
    private func hiddenByBlock(_ m: Message) -> Bool {
        let t = m.createdAt.timeIntervalSince1970 * 1000
        if !m.authorId.isEmpty, BlockList.snapshot.hides(author: m.authorId, atMillis: t) { return true }
        guard m.authorId == otherUid, myBlockedAtMillis > 0 else { return false }
        if legacyBlocked { return t > myBlockedAtMillis }
        return t > myBlockedAtMillis && t <= myBlockClearedAtMillis
    }

    /// Written at or before my Clear Chat (`myChatClearedAtMillis`). Server-stamped messages only:
    /// a send still pending, or one whose time is still this phone's guess, is newer than the clear.
    func isClearedForMe(_ m: Message) -> Bool {
        myChatClearedAtMillis > 0 && m.sendState == nil && m.hasServerTime
            && m.createdAt.timeIntervalSince1970 * 1000 <= myChatClearedAtMillis
    }

    /// The window already holds a message from before my Clear Chat, so nothing older can show.
    private var holdsClearCut: Bool {
        guard myChatClearedAtMillis > 0,
              let oldest = byId.values.lazy.map(\.createdAt).min() else { return false }
        return oldest.timeIntervalSince1970 * 1000 <= myChatClearedAtMillis
    }

    /// Clear Chat from this phone: hide at once, before the chat document's echo comes back.
    @MainActor
    static func clearedForMe(_ cid: String, atMillis ms: Double) {
        guard let r = live[cid]?.value else { return }
        // The phone's database just lost this chat: what stays on screen is filed again.
        r.filedToDB = [:]
        r.applyChatCleared(ms)
        for m in r.byId.values where r.isClearedForMe(m) { ChatService.forgetLocalCopies(of: m, cid: cid) }
    }

    private func applyChatCleared(_ ms: Double) {
        guard ms > myChatClearedAtMillis else { return }
        myChatClearedAtMillis = ms
        refreshHistoryStart(record: false)
        rebuild()
    }

    /// The notice that stands in for messages sealed before this phone's keys existed.
    static let oldDeviceHistoryNotice =
        "Messages from before you signed in on this device aren't available here. They're end-to-end encrypted."

    /// Is `id` a loaded message sealed before this phone's keys existed (owner 2026-11-10)? A reply
    /// quoting one says "Original message not available", and a pin to one leaves the bar.
    func isFromBeforeThisDevice(id: String) -> Bool {
        byId[id]?.predatesThisDevice ?? false
    }

    /// Is `id` a message the block window hides? A reply quoting one shows "Not available" and its
    /// tap does not try to reach it (owner, 2026-10-04). Answers for messages fetched so far.
    func isHiddenByBlock(id: String) -> Bool {
        byId[id].map(hiddenByBlock) ?? false
    }

    /// My block list changed (here, on another screen, or on another of my devices).
    private func blockStateChanged() {
        iBlocked = legacyBlocked || (cid.contains("_") && BlockList.snapshot.contains(otherUid))
        rebuild()
        // `rebuild` skips publishing when the MESSAGES did not change, and a block changes none:
        // the "You blocked / unblocked this person" notices (`blockNotices`) would wait for the
        // next message to appear.
        refreshItems()
    }

    /// Page in the next older window (called on scroll-to-top). `completion` runs after
    /// the list updates so the view can restore the scroll anchor (no jump).
    func loadOlder(completion: @escaping () -> Void = {}) {
        // A synced channel reads the hole under its newest block instead (CHANNEL-SYNC-SPEC.md 6).
        if chMode == .synced { chLoadOlder(completion); return }
        guard canLoadOlder else { completion(); return }
        // Everything older than what is held was cleared for me: paging it in shows nothing.
        if holdsClearCut, !loadingOlder { canLoadOlder = false; completion(); return }
        // Owner audit 2026-10-06 chat #1: BUSY IS NOT DONE. A call while a page is already in flight
        // used to run its completion at once, as if a page had landed. `ensureLoaded` counted that as
        // a page and spent its whole budget in microseconds, so a quote, search or pin jump tapped
        // during a scroll-load said "isn't loaded" for a message one page away; a second scroll
        // caller also restored its anchor before the list had changed. It now waits for the page in
        // flight and runs when that page lands. Still only one fetch at a time.
        if loadingOlder { olderWaiters.append(completion); return }
        let base = db.collection("conversations").document(cid).collection("messages")
            .order(by: "createdAt", descending: true)
        // After a window trim the doc-snapshot cursor points BELOW the dropped range, so cursor by the
        // oldest KEPT message's value instead — dropped history pages back in seamlessly.
        // `messages` is sorted for DISPLAY (`sortedOneTimeline`'s sticky keys), which the C15 clamp
        // above can put in a different order than the server's real `createdAt` (audit C30) — take
        // the smallest raw `createdAt` actually held, not `messages.first`, so the cursor can't sit
        // above history that display order happens to show later.
        //
        // Owner audit 2026-10-06 chat #71: `start(at:)`, not `start(after:)`, by value. Every message
        // sharing the oldest kept stamp (a batch write, a bulk forward) was skipped, including ones
        // the trim had dropped. `at` re-reads the tied ones already held (the build filter below
        // skips them), and the page's own last document becomes the cursor from then on, so a run
        // of identical stamps cannot hold the cursor in place.
        let query: Query
        let resumeQuery = (!resumeHeld && NetworkState.shared.isOnline) ? resumeOlderQuery : nil
        let usedResume = resumeQuery != nil
        if let resume = resumeQuery {
            // Owner audit 2026-10-06 chat #69: pages answered from the LOCAL CACHE while offline may
            // have holes (the cache only has what this phone happened to read). Paging on from their
            // cursor once online skipped the hole for good, so the first online page re-reads from
            // where the cache took over. Pages already held cost nothing to rebuild.
            query = resume
        } else if windowTrimmed, let oldest = messages.map(\.createdAt).min() {
            query = base.start(at: [Timestamp(date: oldest)])
        } else if let cursor = oldestDoc, cursor.get("createdAt") is Timestamp {
            query = base.start(afterDocument: cursor)
        } else if oldestDoc != nil, let oldest = messages.map(\.createdAt).min() {
            // ⛔ BUILD 973 CRASH (owner's .ips, 2026-10-18): `start(afterDocument:)` RAISES an ObjC
            // exception, uncatchable, when the cursor document has no `createdAt` value (a message whose
            // server time had not landed yet, or one written without it): "FIRQuery
            // boundFromSnapshot … ThrowInvalidArgument", from the scroll-up auto load. Such a cursor is
            // never handed over; the page starts at the oldest time held instead, as after a trim.
            query = base.start(at: [Timestamp(date: oldest)])
        } else { completion(); return }
        loadingOlder = true
        query
            .limit(to: pageSize)
            .getDocuments { [weak self] snap, _ in
                guard let self else { return }
                let docs = snap?.documents ?? []
                let fromServer = snap.map { !$0.metadata.isFromCache } ?? false
                if usedResume && !fromServer {
                    // #69: the phone has a path but the database has not reconnected, so the resume
                    // read came back from the cache again. Keep the deeper cursor (offline reading
                    // goes on) and try the resume again when the network next comes back, rather
                    // than re-reading this same cached page on every scroll.
                    self.resumeHeld = true
                } else if let last = docs.last {
                    self.oldestDoc = last
                    self.oldestDocFromCacheWindow = false   // #17: an older page owns the cursor now
                    self.windowTrimmed = false              // #71: this page's last doc is the cursor
                }
                // #69: remember where an unverified (cache) run began; a server answer clears it.
                if fromServer {
                    self.resumeOlderQuery = nil
                    self.resumeHeld = false
                } else if snap != nil, !docs.isEmpty, self.resumeOlderQuery == nil {
                    self.resumeOlderQuery = query
                }
                // Owner audit 2026-10-06 chat #68: a failed or cache-only answer is asked again when
                // the network comes back, instead of waiting for the reader to scroll.
                self.olderNeedsRetry = !fromServer
                // Only the SERVER can say history has ended (2026-09-24 audit). A failed fetch
                // (snap nil) or an offline answer from the local cache (a partial page) used to
                // switch paging off for the rest of the visit, so older messages never loaded
                // again even after the signal came back.
                if let snap, !snap.metadata.isFromCache, docs.count < self.pageSize { self.canLoadOlder = false }
                // 2026-09-24 fix-all #222: decrypt the page OFF the main thread, the same way
                // `applyLiveSnapshot` does. A 40-message page (group unwraps included) was opened on
                // main in the scroll-to-top callback and hitched the scroll. Only docs the cache does
                // not already hold (or whose signature moved) are built; the merge is on main.
                let sigs = Dictionary(docs.map { ($0.documentID, Self.changeSig($0.data())) },
                                      uniquingKeysWith: { a, _ in a })
                let needBuild = docs.filter { doc in
                    self.byId[doc.documentID] == nil || self.rawReactions[doc.documentID] != sigs[doc.documentID]
                }
                let finish = {
                    // A page asked for before a channel moved to its store: kept, not yet proven.
                    if self.chMode == .synced, let box = self.chBox {
                        box.history.adoptUnverified(Array(self.byId.values))
                    }
                    self.loadingOlder = false
                    let rowsBefore = self.items.count
                    self.rebuild(reason: .olderPage)
                    let addedRows = self.items.count > rowsBefore
                    completion()
                    // #1: everyone who asked while this page was in flight. Swapped out first, so a
                    // waiter that starts the next page queues on a fresh list.
                    let waiters = self.olderWaiters
                    self.olderWaiters = []
                    waiters.forEach { $0() }
                    // Not tied to the list landing anything: a page of deleted posts lands nothing.
                    self.topUpIfThin(lastPageAddedRows: addedRows)
                }
                // ⛔ PHASE 1 (owner 2026-11-12): when the server could not answer (offline, failed),
                // the phone's own database fills the older page. Online, the server's copy stays the
                // authority, so a message deleted there can never come back from an old local copy.
                // Channels keep reading the server (their history lives there for good).
                let finishLocal = {
                    guard !fromServer, !Conversation.Right.isChannel(self.cid),
                          let me = Auth.auth().currentUser?.uid,
                          let oldest = self.byId.values.map(\.createdAt).min() else { finish(); return }
                    LocalMessageDB.shared.older(cid: self.cid, uid: me, before: oldest, limit: self.pageSize) { page in
                        for m in page where self.byId[m.id] == nil { self.byId[m.id] = m; self.filedToDB[m.id] = m }
                        finish()
                    }
                }
                guard !needBuild.isEmpty else { finishLocal(); return }
                // Owner audit 2026-10-06 chat #70: what each entry looked like when this page was
                // read. The decrypt below is off the main thread, and a live snapshot can land in
                // between; writing the page's older copy over it reverted a reaction or a delete.
                let sigsBefore = self.rawReactions
                let cidLocal = self.cid
                Task.detached(priority: .userInitiated) { [weak self] in
                    let built: [(String, Message)] = needBuild.map { doc in
                        (doc.documentID, Message(id: doc.documentID, data: doc.data(), cid: cidLocal, crypto: Crypto.shared))
                    }
                    await MainActor.run {
                        guard let self else { completion(); return }
                        // #70: the live window is the authority for what it covers, and an entry
                        // that changed (or was removed) while this page decrypted keeps the newer
                        // state. Only untouched entries outside the live window take the page's copy.
                        let liveIds = Set(self.lastDocs.map(\.documentID))
                        for (id, m) in built where !liveIds.contains(id) && self.rawReactions[id] == sigsBefore[id] {
                            self.byId[id] = m; self.rawReactions[id] = sigs[id] ?? ""
                        }
                        finishLocal()
                    }
                }
            }
    }

    /// ⛔ A THIN HISTORY PAGES ITSELF IN (owner 2026-11-08, channel VE3). A page is 60 raw docs and
    /// the filters run after it (deleted posts always go in a group; a follower does not see a
    /// channel's notices), so a page can come back with nothing to show. Older pages were asked for
    /// only by the list, on a scroll or after a page landed rows, so a chat whose newest pages were
    /// all deleted posts stopped there: no posts and no card. Here the repository asks by itself,
    /// after the server's window and after every older page, while fewer than `topUpMinRows` rows are
    /// visible, or the page just read showed nothing new. Never during a jump or a focus hunt (they
    /// page on their own), never twice at once, at most `topUpCap` pages per open. Groups and
    /// channels only. The scroll-driven paging is unchanged.
    private func thinHistoryNet(_ delay: Double) {
        if chMode == .synced { channelFill(); return }
        guard listener != nil, holders > 0, canLoadOlder, !historyStartReached,
              items.count < topUpMinRows, !loadingOlder, !jumpPagingInFlight else { return }
        DiagLog.add("TOPUP# net t=\(delay)s cid=\(cid.suffix(5)) rows=\(items.count) sawServer=\(sawServerWindow) cursor=\(oldestDoc != nil || windowTrimmed) retry=\(olderNeedsRetry) pages=\(topUpPages) running=\(historyTopUpRunning) cacheWhole=\(cacheLooksWhole)")
        historyTopUpRunning = true
        loadOlder()
        if !loadingOlder { historyTopUpRunning = false }
    }

    private func topUpIfThin(lastPageAddedRows: Bool) {
        if chMode == .synced { channelFill(); return }
        // `listener != nil`: never on a chat that was closed (or an account switched away) while a
        // page was out (verify pass 3, 2026-11-08).
        guard listener != nil, !warmOnly, !cid.contains("_"), sawServerWindow, canLoadOlder, !historyStartReached,
              !loadingOlder, !jumpPagingInFlight, !olderNeedsRetry,
              topUpPages < (items.isEmpty ? topUpCapWhenEmpty : topUpCap),
              items.count < topUpMinRows || !lastPageAddedRows,
              oldestDoc != nil || windowTrimmed else {
            if historyTopUpRunning, !loadingOlder { historyTopUpRunning = false }
            return
        }
        topUpPages += 1
        historyTopUpRunning = true
        loadOlder()
        // No cursor to page from: `loadOlder` answered at once and no page is coming.
        if !loadingOlder { historyTopUpRunning = false }
    }

    // Page older history until `messageId` is loaded (so in-chat search can scroll to a match that's
    // far above the current window), or we run out of history. Bounded so a bad id can't loop forever.
    @MainActor
    func ensureLoaded(_ messageId: String, maxPages: Int = 12) async {   // 12×40 ≈ the window cap — never page unbounded history into memory
        jumpPagingDepth += 1
        defer { jumpPagingDepth -= 1 }
        var pages = 0
        while !items.contains(where: { $0.id == messageId }) && canLoadOlder && pages < maxPages {
            // Audit C29: leaving the quote jump cancels the caller's Task, but this loop kept paging
            // an old screen's copy regardless. Stop as soon as that happens instead of paging on.
            guard !Task.isCancelled else { break }
            await withCheckedContinuation { cont in loadOlder { cont.resume() } }
            pages += 1
        }
    }

    /// The same walk, keyed by `Message.rowId` (`clientId ?? id`), which is what a saved reading
    /// position names: a row this reader sent is stored under its client id, so matching on `id`
    /// alone would page past it and never know.
    ///
    /// Two things `ensureLoaded` does not need, because its callers run in a chat that is already
    /// open and settled:
    /// - A fresh repository seeded from `ThreadMessageCache` has rows but NO paging cursor until the
    ///   first live snapshot lands, and `loadOlder` answers at once with nothing in that state. The
    ///   wait is paid here, in small sleeps, rather than spending the whole page budget on empty
    ///   answers in a few microseconds.
    /// - A `deadline`, because the caller is holding the chat's first reveal on this. A page already
    ///   in flight still lands; no new one starts past it.
    @MainActor
    func ensureLoaded(rowId: String, maxPages: Int = 12, deadline: Date) async {
        jumpPagingDepth += 1
        defer { jumpPagingDepth -= 1 }
        var pages = 0
        while !items.contains(where: { $0.rowId == rowId }) && canLoadOlder && pages < maxPages {
            guard !Task.isCancelled, Date() < deadline else { break }
            guard oldestDoc != nil || windowTrimmed || chMode == .synced else {
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            await withCheckedContinuation { cont in loadOlder { cont.resume() } }
            pages += 1
        }
    }

    // MARK: - One repository per open chat

    /// ⛔ SWIFTUI RUNS `ThreadView.init` MANY TIMES; ONLY THE FIRST REPOSITORY IS EVER KEPT — owner,
    /// 2026-10-03: "the chat takes too long to open and the row stays grey". `State(initialValue:)`
    /// keeps the first value and drops the rest, but the init that builds each one still runs: every
    /// redraw of the shell during the push (and every conversation update while the chat is open)
    /// built a new repository, seeded it from the cache and rebuilt every row, on the main thread, to
    /// throw it away. This hands every init the one already alive for the chat.
    private struct WeakRef { weak var value: ThreadRepository? }
    private static var live: [String: WeakRef] = [:]

    /// The live repository for `cid`, or a new one. Previews do not come here: they own their own.
    static func forChat(_ cid: String) -> ThreadRepository {
        if let r = live[cid]?.value { return r }
        let r = ThreadRepository(cid: cid)
        live[cid] = WeakRef(value: r)
        return r
    }

    /// A visitor's repository goes on as the member's after Follow or Join (owner 2026-11-07), so
    /// the rows on screen stay. Taken only when no other screen already holds a live one.
    static func adoptAsLive(_ r: ThreadRepository) {
        if live[r.cid]?.value == nil { live[r.cid] = WeakRef(value: r) }
    }

    /// A chat whose live repository is listening right now files its own messages (owner 2026-11-12:
    /// InboxSync leaves it alone). Main thread, as `live` is.
    static func isListening(_ cid: String) -> Bool { live[cid]?.value?.listener != nil }

    /// Clear Messages (owner 2026-11-08): the server deleted every message of `cid`. The open chat
    /// shows it empty at once (the listener only covers the newest window, and a page loaded by
    /// scrolling up would stay), and this phone's cached and decrypted copies go too.
    @MainActor
    static func clearedOnServer(_ cid: String) {
        // ⛔ The phone's own database too (owner 2026-11-12, phase 1).
        if let me = Auth.auth().currentUser?.uid { LocalMessageDB.shared.removeChat(cid: cid, uid: me) }
        if let r = live[cid]?.value { r.clearAllLocally() }
        else if let uid = Auth.auth().currentUser?.uid { ChannelHistoryStore.shared.forget(uid: uid, cid: cid) }
        for m in ThreadMessageCache.shared.memoryMessages(for: cid) ?? [] {
            ChatService.forgetLocalCopies(of: m, cid: cid)
        }
        ThreadMessageCache.shared.store(cid, [])
        ThreadMessageCache.shared.store("pins-" + cid, [])
    }

    @MainActor
    private func clearAllLocally() {
        for m in byId.values { ChatService.forgetLocalCopies(of: m, cid: cid) }
        byId.removeAll()
        filedToDB.removeAll()
        rawReactions.removeAll()
        locallyDeleted.removeAll()
        lastDocs = []   // or a key arriving later re-decrypts the old window back onto the screen
        chDocs = [:]
        // A channel's store knows the history is now empty (and keeps its change counter).
        if let box = chBox { box.history.clearAll(); box.scheduleSave() }
        pinnedMessageIds = []
        pinnedPreviews = [:]
        rebuild()
    }

    /// Screens showing this chat. Two at once only when the same chat is reopened while its old
    /// screen is still leaving; the leaving one must not stop the listeners the new one runs on.
    @ObservationIgnored private var holders = 0

    /// A screen starts showing this chat.
    func open() {
        holders += 1
        // The thin-history top-up's budget is per OPEN, not per re-attach: `start()` also runs on
        // every retry and network recovery, which gave a flapping network a fresh 10 pages each time.
        if holders == 1 { topUpPages = 0; windowLogs = 0; chSyncLogs = 0 }
        start()
        // ⛔ THE NET UNDER THE TOP-UP (owner 2026-11-09, VE3 again: one open showed only the newest
        // post for 5 s and more, LISTGEO# rows=1 throughout, while the next open paged "Hello Guys"
        // in at 0.35 s). `topUpIfThin` runs only from a server window or a landed page, behind nine
        // conditions, and one open never got there. Twice after the open, a group or channel still
        // showing fewer than `topUpMinRows` rows with history left asks for the next page itself;
        // TOPUP# names the condition that held the top-up back, so the next log proves which.
        if holders == 1, !cid.contains("_"), !warmOnly {
            for delay in [1.5, 4.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.thinHistoryNet(delay) }
            }
        }
        // A group's old sealed items: release the keys this phone holds (2026-10-23; groups only).
        GroupKeyRelease.chatOpened(cid)
    }

    /// A screen stops showing this chat. The last one out stops it and frees the slot, so the next
    /// visit starts from a fresh repository, as before.
    func close() {
        holders = max(0, holders - 1)
        guard holders == 0 else { return }
        stop()
        // The channel store is no longer shown from here: it may leave memory, trimmed (audit C4).
        chBox?.release(self)
        if chForgetOnClose {
            chForgetOnClose = false
            Self.forgetChannelStore(cid)
        }
        if Self.live[cid]?.value === self { Self.live[cid] = nil }
    }

    /// ⛔ A CHANNEL I NO LONGER READ TAKES ITS DECRYPTED POSTS WITH IT (audit C5). Unfollowed (by any
    /// road: my tap, removed, the channel deleted), left, or deleted by me: the channel store and
    /// the cached rows go now, or when its open screen closes. Following again syncs afresh.
    @MainActor
    static func channelLeft(_ cid: String) {
        guard !cid.contains("_") else { return }
        if let r = live[cid]?.value, r.holders > 0 {
            r.chForgetOnClose = true
            return
        }
        forgetChannelStore(cid)
    }

    private static func forgetChannelStore(_ cid: String) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        ChannelHistoryStore.shared.forget(uid: uid, cid: cid)
        ThreadMessageCache.shared.store(cid, [])
    }

    func stop() {
        listener?.remove(); listener = nil
        // Channel sync: its two other listeners, and any answer still on its way is let go.
        chGoneListener?.remove(); chGoneListener = nil
        chHeadListener?.remove(); chHeadListener = nil
        chStartGen += 1; chChgToken += 1; chGoneToken += 1; chHeadToken += 1
        chTooLongRunning = false
        chTooLongFails = 0
        if chMode == .synced { chBox?.scheduleSave() }
        if let outboxObserver { NotificationCenter.default.removeObserver(outboxObserver) }
        outboxObserver = nil
        if let outboxAddObserver { NotificationCenter.default.removeObserver(outboxAddObserver) }
        outboxAddObserver = nil
        if let outboxLandObserver { NotificationCenter.default.removeObserver(outboxLandObserver) }
        outboxLandObserver = nil
        if let hiddenObserver { NotificationCenter.default.removeObserver(hiddenObserver) }
        hiddenObserver = nil
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        foregroundObserver = nil
        if let blockObserver { NotificationCenter.default.removeObserver(blockObserver) }
        blockObserver = nil
        if let recoveredObserver { NotificationCenter.default.removeObserver(recoveredObserver) }
        recoveredObserver = nil
        if let swappedObserver { NotificationCenter.default.removeObserver(swappedObserver) }
        swappedObserver = nil
        if let networkObserver { NotificationCenter.default.removeObserver(networkObserver) }
        networkObserver = nil
        // #72: a backoff retry still waiting must not re-attach a chat that has been stopped.
        retryWork?.cancel(); retryWork = nil
        convListener?.remove(); convListener = nil
        userListener?.remove(); userListener = nil
        presenceListener?.remove(); presenceListener = nil
        keyPreloadTask?.cancel(); keyPreloadTask = nil
        expiryTimer?.invalidate(); expiryTimer = nil
        burnTimer?.invalidate(); burnTimer = nil
        typingExpiry?.invalidate(); typingExpiry = nil
    }

    // ⛔ NEVER `remove()` HERE DIRECTLY (crash builds 1010 + 1011, 2026-10-23, SIGABRT on the
    // com.google.firebase.firestore thread): the last reference can die inside a Firestore callback
    // block being released ON FIRESTORE'S OWN QUEUE, and remove() from there trips its assertion.
    // `FirestoreHub.drop` removes on a utility queue instead.
    deinit {
        FirestoreHub.drop([listener, convListener, userListener, presenceListener, chGoneListener, chHeadListener])
        keyPreloadTask?.cancel()
        // Timers belong to the main run loop; invalidated there when this dies elsewhere.
        let timers = [expiryTimer, burnTimer, typingExpiry]
        if Thread.isMainThread { timers.forEach { $0?.invalidate() } }
        else { DispatchQueue.main.async { timers.forEach { $0?.invalidate() } } }
    }
}

// MARK: - Channel sync (CHANNEL-SYNC-SPEC.md 5-9, owner 2026-11-09)
//
// The thin adapter between Firestore and `ChannelHistoryStore`, used ONLY for a channel that a
// member or follower opens. Groups, 1:1 chats, visitors (`previewOnly`), warm-ups and a channel
// whose docs carry no `chg` yet all keep the window path above, untouched.
//
// - Open: the store's rows at once (init, `seedFromChannel`), then the listeners.
// - Sync: `messages where chg > lastChg order by chg limit 200`, each doc applied as add / edit /
//   delete; hard deletes from `changes`; the newest 10 posts listened to as well, so my own send
//   and anything not yet stamped show at once. Nothing here ever drops a row for being absent.
// - Fill: while fewer than 40 visible posts sit above the first hole, read the hole (pages of 60,
//   createdAt-descending), whole span marked read, deleted posts included.
// - Too long: 200 changes waiting at attach. The newest page goes on top, a hole under it, and the
//   old rows stay on screen until a page proves them current.
extension ThreadRepository {
    private static let chLimit = 200
    private static let chRebaseAt = 150
    private static let chWantVisible = 40

    /// A channel this account follows or runs, opened as a chat (not a visitor's preview).
    private var channelSyncEligible: Bool {
        guard !cid.contains("_"), !warmOnly, !previewOnly, !lockedGuest, !moderationLocked, !chRefused,
              !DemoMode.isDemoConversation(cid) else { return false }
        return channelHint || Conversation.Right.isChannel(cid)
            || ChannelFollows.shared.conversations.contains { $0.id == cid }
    }

    private static func chgOf(_ d: DocumentSnapshot) -> Int? {
        (d.get("chg") as? NSNumber)?.intValue
    }

    private func chLog(_ line: String) {
        guard chSyncLogs < 40 else { return }
        chSyncLogs += 1
        DiagLog.add(line)
    }

    // MARK: Open

    /// The store this screen shows (nil: none). Held while shown, so the registry never lets it go
    /// from memory under this screen (audit C4); `close()` releases it.
    private func chUse(_ box: ChannelHistoryBox<Message>?) {
        if let old = chBox, old !== box { old.release(self) }
        chBox = box
        box?.hold(self)
    }

    /// The store's rows, before any listener (init, or the file landing just after it).
    private func seedFromChannel(_ box: ChannelHistoryBox<Message>) {
        chUse(box)
        byId = box.history.posts
        didInitialLoad = true
        canLoadOlder = !box.history.reachedStart
        rebuild(reason: .initial)
        scheduleNextBurn()
    }

    private func startChannelSync(uid: String) {
        let gen = chStartGen
        ChannelHistoryStore.shared.open(uid: uid, cid: cid) { [weak self] box in
            guard let self, self.chStartGen == gen else { return }
            self.chUse(box)
            if box.history.isSynced {
                self.chMode = .synced
                // The store is the truth: rows seeded from anywhere else give way to it.
                self.chMirrorAll()
                self.chLog("SYNC# open cid=\(self.cid.suffix(5)) rows=\(box.history.posts.count) lastChg=\(box.history.lastChg ?? -1) hole=\(box.history.topHole != nil)")
                self.attachChannelListeners()
                self.finishChannelCommit(reason: self.sawServerWindow ? .live : .initial)
            } else {
                // Not synced yet: today's window, whose first server answer decides (`chProbe`).
                self.chMode = .probing
                self.attachWindowListener()
            }
        }
    }

    /// The window's first SERVER answer. Docs carrying `chg`: the store starts from this window
    /// (top range = the window, `lastChg` = its newest change) and the change listeners take over.
    /// None: today's path for the rest of this visit.
    private func chProbe(_ docs: [QueryDocumentSnapshot]) {
        guard let box = chBox, let top = docs.compactMap({ Self.chgOf($0) }).max() else {
            chMode = .off
            chUse(nil)
            chLog("SYNC# legacy cid=\(cid.suffix(5)) docs=\(docs.count) (no chg yet)")
            return
        }
        let now = Date()
        let windowIds = Set(docs.map(\.documentID))
        let page = docs.map { d in
            ChannelDoc(post: byId[d.documentID] ?? Message(id: d.documentID, data: d.data(), cid: cid, crypto: Crypto.shared),
                       chg: Self.chgOf(d))
        }
        // Rows held outside the window (older pages, a cached copy): kept, not yet proven. Adopted
        // BEFORE the page, so a short window (the whole channel) drops the ones the server no
        // longer has.
        box.history.adoptUnverified(byId.values.filter { !windowIds.contains($0.id) })
        let r = box.history.applyPage(page, upper: .distantFuture, full: docs.count >= pageSize, fromServer: true, now: now)
        box.history.lastChg = max(box.history.lastChg ?? top, top)
        box.history.lastGoneChg = max(box.history.lastGoneChg ?? top, top)
        box.history.syncedAt = now
        for d in docs where box.history.posts[d.documentID] != nil { chDocs[d.documentID] = d }
        chMode = .synced
        FirestoreHub.drop([listener])
        listener = nil
        lastDocs = []
        chLog("SYNC# start cid=\(cid.suffix(5)) docs=\(docs.count) add=\(r.added) del=\(r.removed) lastChg=\(top) start=\(box.history.reachedStart)")
        attachChannelListeners()
        chMirrorAll()
        box.scheduleSave()
        finishChannelCommit(reason: .live)
    }

    // MARK: Listeners

    private func attachChannelListeners() {
        chFirstServer = true
        chAttachedAt = Date()
        attachChgListener(fresh: true)
        attachGoneListener()
        attachHeadListener()
    }

    /// `fresh`: a new attach (open, foreground, network back), whose first full answer means "too
    /// long". Otherwise a re-base from `lastChg` after a run of changes while open.
    private func attachChgListener(fresh: Bool = false) {
        guard let from = chBox?.history.lastChg else { return }
        chChgToken += 1
        let token = chChgToken
        if !fresh { chFirstServer = false }
        FirestoreHub.drop([listener])
        listener = db.collection("conversations").document(cid).collection("messages")
            .whereField("chg", isGreaterThan: from)
            .order(by: "chg")
            .limit(to: Self.chLimit)
            .addSnapshotListener { [weak self] snap, error in
                self?.onChgSnapshot(snap, error, token: token)
            }
    }

    private func onChgSnapshot(_ snap: QuerySnapshot?, _ error: Error?, token: Int) {
        guard token == chChgToken else { return }
        guard let snap else {
            let ns = error as NSError?
            let code = ns?.code ?? -1
            chLog("SYNC# chg listener error cid=\(cid.suffix(5)) code=\(code)")
            if ns?.domain == FirestoreErrorDomain, code == 7 || code == 9 {
                // Refused, or the index is missing: today's window path for this repository. A
                // refusal of the whole session is reported by that path in its turn.
                chRefused = true
                // The store can no longer follow this channel: it must not seed a later open frozen.
                if let uid = Auth.auth().currentUser?.uid { ChannelHistoryStore.shared.forget(uid: uid, cid: cid) }
                chUse(nil)
                chDropUnheld = true   // the window's first server answer drops rows it does not hold
                DispatchQueue.main.async { [weak self] in self?.start() }
                return
            }
            didInitialLoad = true
            listenerFailed = true
            if moderationLocked { return }
            Task { @MainActor in SessionRecovery.noteRefusal(error, "chat") }
            retryStartSoon()
            return
        }
        listenerRetries = 0
        listenerFailed = false
        let fromCache = snap.metadata.isFromCache
        let docs = snap.documents
        chDecode(docs) { [weak self] built, sigs in
            guard let self, token == self.chChgToken, let box = self.chBox else { return }
            let reason = self.chReason(fromCache: fromCache, docs: docs)
            let firstServer = !fromCache && self.chFirstServer
            // Away longer than the server keeps its hard-delete records (audit C6): asked BEFORE this
            // answer moves `syncedAt`.
            let expired = firstServer && box.history.changeRecordsMayHaveExpired(now: Date())
            let n = self.chApply(docs, built: built, sigs: sigs, box: box)
            // Only the server's answer moves the counter: the local cache can miss a change.
            if !fromCache, let top = docs.compactMap({ Self.chgOf($0) }).max() {
                box.history.lastChg = max(box.history.lastChg ?? top, top)
            }
            // Not while a re-verify is owed: a kill before it lands must ask again on the next open.
            if !fromCache, !expired, !self.chTooLongRunning, self.chTooLongFails == 0 {
                box.history.syncedAt = Date()
            }
            if firstServer { self.chFirstServer = false }
            if !fromCache, !self.sawServerWindow {
                self.sawServerWindow = true
                self.serverWindowSettled = true
            }
            if docs.count > 0 || firstServer {
                self.chLog("SYNC# chg cid=\(self.cid.suffix(5)) cache=\(fromCache) docs=\(docs.count) add=\(n.added) edit=\(n.edited) del=\(n.removed) lastChg=\(box.history.lastChg ?? -1)")
            }
            self.finishChannelCommit(reason: reason)
            box.scheduleSave()
            if expired {
                self.chLog("SYNC# expired cid=\(self.cid.suffix(5)) (records may be gone)")
                self.chTooLong()
            } else if !fromCache, docs.count >= Self.chLimit {
                if firstServer { self.chTooLong() } else { self.attachChgListener() }
            } else if !fromCache, docs.count >= Self.chRebaseAt {
                self.attachChgListener()
            }
        }
    }

    /// Every change record, in `chg` order: hard deletes `{mid, gone: true}` and Clear Messages
    /// `{clear: true, before: <ms>}` (the server writes no per-post record for what a clear covers).
    private func attachGoneListener() {
        guard let box = chBox, let from = box.history.lastGoneChg ?? box.history.lastChg else { return }
        chGoneToken += 1
        let token = chGoneToken
        FirestoreHub.drop([chGoneListener])
        chGoneListener = db.collection("conversations").document(cid).collection("changes")
            .whereField("chg", isGreaterThan: from)
            .order(by: "chg")
            .limit(to: Self.chLimit)
            .addSnapshotListener { [weak self] snap, error in
                guard let self, token == self.chGoneToken, let box = self.chBox else { return }
                guard let snap else {
                    // Not readable yet (server or rules still to deploy): deletes for everyone still
                    // arrive as edits carrying `deleted`; only hard deletes wait.
                    self.chLog("SYNC# gone listener error cid=\(self.cid.suffix(5)) code=\((error as NSError?)?.code ?? -1)")
                    return
                }
                var removed = 0
                let now = Date()
                for d in snap.documents {
                    if (d.get("clear") as? Bool) == true {
                        guard let ms = (d.get("before") as? NSNumber)?.doubleValue else { continue }
                        let gone = box.history.clearBefore(Date(timeIntervalSince1970: ms / 1000), now: now)
                        removed += gone.count
                        gone.forEach { self.chForgetLocalCopies($0) }
                        continue
                    }
                    guard (d.get("gone") as? Bool) == true, let mid = d.get("mid") as? String else { continue }
                    let old = box.history.posts[mid]
                    if box.history.remove(mid, chg: Self.chgOf(d) ?? Int(d.documentID), now: now) == .removed {
                        removed += 1
                        if let old { self.chForgetLocalCopies(old) }
                    }
                }
                if !snap.metadata.isFromCache,
                   let top = snap.documents.compactMap({ Self.chgOf($0) ?? Int($0.documentID) }).max() {
                    box.history.lastGoneChg = max(box.history.lastGoneChg ?? top, top)
                }
                if removed > 0 {
                    self.chMirrorAll()
                    self.chLog("SYNC# gone cid=\(self.cid.suffix(5)) removed=\(removed)")
                    self.finishChannelCommit(reason: .live)
                }
                box.scheduleSave()
                if !snap.metadata.isFromCache, snap.documents.count >= Self.chRebaseAt { self.attachGoneListener() }
            }
    }

    /// The newest 10 posts, applied as changes only (never a delete pass): my own send, edit or
    /// delete shows at once from the local write, before the server has stamped its `chg`.
    private func attachHeadListener() {
        chHeadToken += 1
        let token = chHeadToken
        FirestoreHub.drop([chHeadListener])
        chHeadListener = db.collection("conversations").document(cid).collection("messages")
            .order(by: "createdAt", descending: true)
            .limit(to: 10)
            .addSnapshotListener { [weak self] snap, _ in
                guard let self, token == self.chHeadToken, let snap else { return }
                // Not my unconfirmed writes: the pending row shows the send, and a write the server
                // refuses must not stay in the store.
                let docs = snap.documents.filter { !$0.metadata.hasPendingWrites }
                self.chDecode(docs) { [weak self] built, sigs in
                    guard let self, token == self.chHeadToken, let box = self.chBox else { return }
                    let n = self.chApply(docs, built: built, sigs: sigs, box: box)
                    guard n.added + n.edited + n.removed > 0 else { return }
                    self.finishChannelCommit(reason: self.sawServerWindow ? .live : .initial)
                }
            }
    }

    /// Back in the foreground, or the network came back: pick up from the last change applied.
    private func chReattachFromLastChg(why: String) {
        guard chMode == .synced, listener != nil, !listenerFailed,
              Date().timeIntervalSince(chAttachedAt) > 2 else { return }
        chLog("SYNC# reattach cid=\(cid.suffix(5)) why=\(why) lastChg=\(chBox?.history.lastChg ?? -1)")
        attachChannelListeners()
    }

    /// More than 200 changes waited. The conversation's `chSeq` first (so a change made during the
    /// read comes again), then the newest page on top; the rows already held stay, below a hole.
    private func chTooLong() {
        guard !chTooLongRunning, chBox != nil else { return }
        chTooLongRunning = true
        let gen = chStartGen
        let conv = db.collection("conversations").document(cid)
        chLog("SYNC# toolong cid=\(cid.suffix(5)) lastChg=\(chBox?.history.lastChg ?? -1) rows=\(items.count)")
        conv.getDocument(source: .server) { [weak self] cs, _ in
            guard let self, gen == self.chStartGen else { return }
            let seq = (cs?.get("chSeq") as? NSNumber)?.intValue
            conv.collection("messages")
                .order(by: "createdAt", descending: true)
                .limit(to: self.pageSize)
                .getDocuments(source: .server) { [weak self] snap, _ in
                    guard let self, gen == self.chStartGen else { return }
                    guard let snap else {
                        // ⛔ NOT LEFT HANGING (audit C2): the `chg` listener is still pinned to the
                        // oldest 200 changes, so nothing new would arrive for the rest of the visit.
                        self.chTooLongRunning = false
                        self.chTooLongRetryLater(gen: gen)
                        return
                    }
                    let docs = snap.documents
                    self.chDecode(docs) { [weak self] built, sigs in
                        guard let self, gen == self.chStartGen, let box = self.chBox else { return }
                        self.chTooLongRunning = false
                        self.chTooLongFails = 0
                        box.history.resetForTooLong()
                        box.history.syncedAt = Date()
                        let page = docs.map { d in
                            ChannelDoc(post: built[d.documentID] ?? self.byId[d.documentID]
                                        ?? Message(id: d.documentID, data: d.data(), cid: self.cid, crypto: Crypto.shared),
                                       chg: Self.chgOf(d))
                        }
                        let r = box.history.applyPage(page, upper: .distantFuture, full: docs.count >= self.pageSize,
                                                      fromServer: true, now: Date())
                        for d in docs where box.history.posts[d.documentID] != nil {
                            self.chDocs[d.documentID] = d
                            self.rawReactions[d.documentID] = sigs[d.documentID] ?? ""
                        }
                        let newLast = seq ?? docs.compactMap({ Self.chgOf($0) }).max() ?? (box.history.lastChg ?? 0)
                        box.history.lastChg = max(box.history.lastChg ?? newLast, newLast)
                        if let seq { box.history.lastGoneChg = max(box.history.lastGoneChg ?? seq, seq) }
                        self.chMirrorAll()
                        self.chLog("SYNC# toolong done cid=\(self.cid.suffix(5)) seq=\(seq ?? -1) add=\(r.added) dropped=\(r.dropped) hole=\(box.history.topHole != nil) rows=\(box.history.posts.count)")
                        self.finishChannelCommit(reason: .live)
                        box.scheduleSave()
                        self.attachChgListener()
                        if seq != nil { self.attachGoneListener() }
                    }
                }
        }
    }

    /// The catch-up read failed: asked again after 2, 4, 8 ... 60 s while this channel stays open.
    /// The foreground and the network coming back also re-attach, whose first full answer asks at
    /// once; `chTooLongRunning` keeps the two from running together.
    private func chTooLongRetryLater(gen: Int) {
        chTooLongFails += 1
        let delay = min(60, pow(2, Double(min(chTooLongFails, 6))))
        chLog("SYNC# toolong failed cid=\(cid.suffix(5)) try=\(chTooLongFails) again in \(Int(delay))s")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, gen == self.chStartGen, self.chMode == .synced, self.chBox != nil else { return }
            self.chTooLong()
        }
    }

    // MARK: History

    /// The hole under the newest block, one page (CHANNEL-SYNC-SPEC.md 6).
    private func chLoadOlder(_ completion: @escaping () -> Void) {
        guard let box = chBox, let hole = box.history.topHole else {
            if canLoadOlder { canLoadOlder = false }
            completion()
            return
        }
        if loadingOlder { olderWaiters.append(completion); return }
        loadingOlder = true
        var query: Query = db.collection("conversations").document(cid).collection("messages")
            .order(by: "createdAt", descending: true)
        // One microsecond ABOVE the edge (audit C8): the edge went through Date's Double (and the
        // disk's seconds) and can come back a hair below the server's own stamp, which would skip
        // every post sharing the edge post's stamp. The few rows read twice are applied harmlessly.
        if hole.upper < .distantFuture {
            query = query.start(at: [Timestamp(date: hole.upper.addingTimeInterval(0.000_001))])
        }
        let gen = chStartGen
        query.limit(to: pageSize).getDocuments { [weak self] snap, _ in
            guard let self else { return }
            let docs = snap?.documents ?? []
            let fromServer = snap.map { !$0.metadata.isFromCache } ?? false
            self.chDecode(docs) { [weak self] built, sigs in
                guard let self else { completion(); return }
                let rowsBefore = self.items.count
                if gen == self.chStartGen, let box = self.chBox, self.chMode == .synced {
                    let page = docs.map { d in
                        ChannelDoc(post: built[d.documentID] ?? self.byId[d.documentID]
                                    ?? Message(id: d.documentID, data: d.data(), cid: self.cid, crypto: Crypto.shared),
                                   chg: Self.chgOf(d))
                    }
                    let r = box.history.applyPage(page, upper: hole.upper, full: docs.count >= self.pageSize,
                                                  fromServer: fromServer, now: Date())
                    for d in docs where box.history.posts[d.documentID] != nil {
                        self.chDocs[d.documentID] = d
                        self.rawReactions[d.documentID] = sigs[d.documentID] ?? ""
                    }
                    self.chMirrorAll()
                    box.scheduleSave()
                    let more = box.history.topHole != nil
                    if self.canLoadOlder != more { self.canLoadOlder = more }
                    self.chLog("SYNC# hole cid=\(self.cid.suffix(5)) server=\(fromServer) docs=\(docs.count) add=\(r.added) del=\(r.removed) dropped=\(r.dropped) visible=\(box.history.visibleCount(self.chVisiblePredicate())) more=\(more)")
                }
                // A failed or cache-only page is asked again when the network comes back.
                self.olderNeedsRetry = !fromServer
                self.loadingOlder = false
                self.rebuild(reason: .olderPage)
                completion()
                let waiters = self.olderWaiters
                self.olderWaiters = []
                waiters.forEach { $0() }
                if self.items.count != rowsBefore { self.chLog("SYNC# rows \(rowsBefore)->\(self.items.count) cid=\(self.cid.suffix(5))") }
                self.channelFill()
            }
        }
    }

    /// Fewer than 40 visible posts above the first hole: read the hole (spec 6). Bounded per open
    /// (`topUpCapWhenEmpty` pages), never during a jump, never twice at once.
    private func channelFill() {
        guard chMode == .synced, let box = chBox, listener != nil, !warmOnly, !loadingOlder,
              !jumpPagingInFlight, !olderNeedsRetry, topUpPages < topUpCapWhenEmpty,
              box.history.needsFill(want: Self.chWantVisible, chVisiblePredicate()) else {
            if historyTopUpRunning, !loadingOlder { historyTopUpRunning = false }
            return
        }
        topUpPages += 1
        historyTopUpRunning = true
        loadOlder()
        if !loadingOlder { historyTopUpRunning = false }
    }

    /// What the reader would see of a post (the same filters `rebuild` and `refreshItems` apply).
    private func chVisiblePredicate() -> (Message) -> Bool {
        let hides = hidesChannelNotices
        let cut = Self.cuts(cid).start?.addingTimeInterval(-2)
        return { m in
            guard !m.deleted, !HiddenMessages.isHidden(m.id), let shown = Self.channelNotice(m) else { return false }
            if hides, shown.isSystem || shown.pinNotice != nil { return false }
            if let cut, m.createdAt < cut { return false }
            return true
        }
    }

    // MARK: Applying

    /// Docs from a listener, in order, as changes to the store; then `byId` follows the store.
    private func chApply(_ docs: [QueryDocumentSnapshot], built: [String: Message], sigs: [String: String],
                         box: ChannelHistoryBox<Message>) -> ChannelHistory<Message>.PageResult {
        var n = ChannelHistory<Message>.PageResult()
        let now = Date()
        for doc in docs {
            let id = doc.documentID
            let m = built[id] ?? byId[id] ?? Message(id: id, data: doc.data(), cid: cid, crypto: Crypto.shared)
            let old = box.history.posts[id]
            switch box.history.applyChange(ChannelDoc(post: m, chg: Self.chgOf(doc)), now: now) {
            case .added:
                n.added += 1
                chDocs[id] = doc; rawReactions[id] = sigs[id] ?? ""
            case .edited:
                n.edited += 1
                chDocs[id] = doc; rawReactions[id] = sigs[id] ?? ""
            case .unchanged:
                if box.history.posts[id] != nil { chDocs[id] = doc; rawReactions[id] = sigs[id] ?? "" }
            case .removed:
                n.removed += 1
                if let old { chForgetLocalCopies(old) }
            case .ignored:
                break
            }
        }
        chMirrorAll()
        return n
    }

    /// `byId` holds exactly the store's posts (pending sends and overlays live elsewhere).
    private func chMirrorAll() {
        guard let posts = chBox?.history.posts else { return }
        let gone = byId.keys.filter { posts[$0] == nil }
        for id in gone {
            byId[id] = nil
            rawReactions[id] = nil
            chDocs[id] = nil
        }
        guard !chRepliesOverlay.isEmpty else {
            for (id, p) in posts where byId[id] != p { byId[id] = p }
            return
        }
        // A Replies switch set here (audit C3) stays over the store's copy until that copy carries
        // the same switch (the server's stamped echo), or a minute has passed.
        let now = Date()
        for (id, p) in posts {
            var shown = p
            if let o = chRepliesOverlay[id] {
                // `channelDefault: !o.off` makes "no switch on the post" read as different.
                if p.repliesOff(channelDefault: !o.off) == o.off || now.timeIntervalSince(o.at) > 60 {
                    chRepliesOverlay[id] = nil
                } else {
                    shown.setPostRepliesSwitch(o.off)
                }
            }
            if byId[id] != shown { byId[id] = shown }
        }
        chRepliesOverlay = chRepliesOverlay.filter { posts[$0.key] != nil }
    }

    private func chReason(fromCache: Bool, docs: [QueryDocumentSnapshot]) -> MessageListUpdateReason {
        if sawServerWindow { return .live }
        if fromCache { return .initial }
        // A post the list has not shown, newer than all it shows, is an arrival (see commitSnapshot).
        if let newestShown = items.map(\.createdAt).max(), docs.contains(where: { d in
            indexById[d.documentID] == nil
                && ((d.get("createdAt") as? Timestamp)?.dateValue() ?? .distantPast) > newestShown
        }) { return .live }
        return .serverSettle
    }

    /// Everything a listener or page round needs after the store changed.
    private func finishChannelCommit(reason: MessageListUpdateReason) {
        if !locallyDeleted.isEmpty {
            locallyDeleted = locallyDeleted.filter { byId[$0]?.deleted == false }
        }
        if !didInitialLoad { didInitialLoad = true }
        if let box = chBox {
            let more = box.history.topHole != nil
            if canLoadOlder != more { canLoadOlder = more }
        }
        chTrimIfNeeded()
        noteSentSound()
        rebuild(reason: reason)
        dropEchoedPending()
        channelFill()
    }

    /// The in-memory bound (as `trimWindowIfNeeded`): the oldest rows go, and become a hole again.
    private func chTrimIfNeeded() {
        guard !readerAwayFromBottom, !jumpPagingInFlight, let box = chBox,
              box.history.posts.count > windowHighWater else { return }
        let n = box.history.bound(keepVisible: windowCap) { _ in true }
        chMirrorAll()
        chLog("SYNC# trim cid=\(cid.suffix(5)) removed=\(n)")
    }

    private func chForgetLocalCopies(_ old: Message) {
        let id = old.id, cid = cid
        Task { @MainActor in
            ChatService.forgetLocalCopies(of: old, cid: cid)
            NotificationCleaner.remove(messageId: id)
        }
    }

    /// Decode (decrypt) the docs that are new or changed, off the main thread; back on main.
    private func chDecode(_ docs: [QueryDocumentSnapshot],
                          _ done: @escaping (_ built: [String: Message], _ sigs: [String: String]) -> Void) {
        let knownSigs = rawReactions
        let knownIds = Set(byId.keys)
        let cidLocal = cid
        Task.detached(priority: .userInitiated) {
            let sigs = Dictionary(docs.map { ($0.documentID, Self.changeSig($0.data())) },
                                  uniquingKeysWith: { a, _ in a })
            let need = docs.filter { doc in
                !knownIds.contains(doc.documentID) || knownSigs[doc.documentID] != sigs[doc.documentID]
            }
            let built = Dictionary(need.map { doc in
                (doc.documentID, Message(id: doc.documentID, data: doc.data(), cid: cidLocal, crypto: Crypto.shared))
            }, uniquingKeysWith: { a, _ in a })
            await MainActor.run { done(built, sigs) }
        }
    }

    /// A key landed after these posts were decrypted: decrypt their docs again.
    private func chRedecrypt() {
        let docs = Array(chDocs.values)
        guard !docs.isEmpty else { return }
        for d in docs { rawReactions[d.documentID] = nil }
        let gen = chStartGen
        chDecode(docs) { [weak self] built, sigs in
            guard let self, gen == self.chStartGen, let box = self.chBox else { return }
            let now = Date()
            for d in docs {
                let id = d.documentID
                guard let m = built[id], box.history.posts[id] != nil else { continue }
                let r = box.history.applyChange(ChannelDoc(post: m, chg: Self.chgOf(d)), now: now)
                if r == .edited || r == .unchanged { self.rawReactions[id] = sigs[id] ?? "" }
            }
            self.chMirrorAll()
            self.rebuild(reason: .redecrypt)
        }
    }
}
