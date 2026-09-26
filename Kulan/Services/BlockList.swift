import Foundation
import Observation
import FirebaseAuth
import FirebaseFirestore

/// 2026-09-26 block rebuild: MY BLOCKS, AND THE ONLY PLACE THE APP ASKS "IS THIS PERSON BLOCKED".
///
/// Two owner-only collections, both invisible to the person blocked:
///   · `users/{me}/blocked/{uid}`       — who is blocked now, and since when (`at`, server time).
///   · `users/{me}/blockHistory/{uid_ms}` — every block that has ended (`from` … `to`).
/// Whatever somebody sent while they were blocked stays hidden for good, the way the reference apps
/// never deliver what a block held back, so `hides(author:atMillis:)` answers for BOTH: the block
/// running now and every past one.
///
/// ⛔ The block used to be copied onto the SHARED chat (`blockedBy`, `blockedAt`, `blockClearedAt`),
/// which the person blocked is a member of and can read: the block was never silent. Nothing
/// writes there any more, and `migrate(_:)` moves an old copy here and deletes it from the chat.
/// The old copy is still honoured wherever it has not been moved yet (`Conversation.isBlockedByMe`).
///
/// The server enforces the same list (firestore.rules `isBlockedByUser`: calls, last seen, public
/// stories, story views; storage.rules: the profile photo; functions: every push, chat key, group
/// adds). The app's job is the rest: never SHOW anything from a blocked person.
@Observable
final class BlockList {
    static let shared = BlockList()
    private init() {}

    /// uid → when I blocked them, in ms. A block still on its way to the server carries the local
    /// estimate, so hiding starts the moment Block is tapped, online or not.
    private(set) var entries: [String: Double] = [:]
    /// uid → the blocks that have ended, each `from...to` in ms.
    private(set) var spans: [String: [ClosedRange<Double>]] = [:]
    /// Bumped on every change, for views and caches that key on the block state.
    private(set) var version = 0

    /// Whose list is loaded: set once BOTH collections have answered for that account, nil
    /// otherwise. Until then nothing may be treated as "not blocked" by a screen that would show a
    /// blocked person's messages (`ConversationsRepository` holds its list back on this).
    private(set) var loadedFor: String?

    @ObservationIgnored private var listListener: ListenerRegistration?
    @ObservationIgnored private var historyListener: ListenerRegistration?
    @ObservationIgnored private var listenerUid: String?
    @ObservationIgnored private var listLoaded = false
    @ObservationIgnored private var historyLoaded = false
    /// One block/unblock per person at a time, in tap order (a fast Block, Unblock, Block must land
    /// in that order, or the list ends on the wrong answer).
    @ObservationIgnored private var inFlight: [String: Task<Bool, Never>] = [:]
    @ObservationIgnored private var migrated: Set<String> = []

    static let didChange = Notification.Name("BlockListDidChange")

    // MARK: - Reading

    func contains(_ uid: String) -> Bool { entries[uid] != nil }

    /// True once the signed-in account's own list has loaded.
    var isLoaded: Bool { loadedFor != nil && loadedFor == Auth.auth().currentUser?.uid }

    /// Was a message from `author`, sent at `atMillis` (server time), sent while I had them blocked?
    /// Now or in any past block. Such a message is never shown, before or after an unblock.
    func hides(author: String, atMillis: Double) -> Bool {
        Self.snapshot.hides(author: author, atMillis: atMillis)
    }

    // MARK: - Any thread

    /// The same answers for code that is not on the main thread (models, push handling). Replaced
    /// whole on the main thread whenever the list changes.
    struct Snapshot {
        fileprivate var allEntries: [String: Double] = [:]
        fileprivate var allSpans: [String: [ClosedRange<Double>]] = [:]
        /// ⛔ Whose list this is. Every answer is empty unless it is the SIGNED-IN account's (owner,
        /// 2026-09-25: "sometimes my chat blocks itself" when switching accounts on one phone).
        fileprivate var owner: String?
        private var current: Bool { owner != nil && owner == Auth.auth().currentUser?.uid }
        var entries: [String: Double] { current ? allEntries : [:] }
        var spans: [String: [ClosedRange<Double>]] { current ? allSpans : [:] }
        func contains(_ uid: String) -> Bool { entries[uid] != nil }
        func hides(author: String, atMillis: Double) -> Bool {
            guard !author.isEmpty, current else { return false }
            if let since = allEntries[author] {
                // `since` is 0 only for a block the server has not timed yet: everything from now on.
                if since <= 0 || atMillis <= 0 || atMillis >= since { return true }
            }
            return allSpans[author]?.contains { $0.contains(atMillis) } ?? false
        }
    }
    private static let lock = NSLock()
    private static var _snapshot = Snapshot()
    static var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return _snapshot
    }

    // MARK: - Listening

    /// Idempotent: a second call for the same account keeps the running listeners.
    func start() {
        guard let uid = Auth.auth().currentUser?.uid, !uid.isEmpty else { return }
        if listListener != nil, listenerUid == uid { return }
        stopListeners()
        // A different account: the previous one's list goes NOW, not when the new snapshot lands.
        if listenerUid != uid { publish(entries: [:], spans: [:], loadedFor: nil) }
        listenerUid = uid
        listLoaded = false
        historyLoaded = false
        // THIS ACCOUNT'S LIST AS IT WAS LAST TIME, before any listener answers, so the chat list's
        // first frame (read straight off disk) is already filtered. The listeners replace it.
        restored = false
        if let saved = Self.loadSaved(uid) {
            restored = true
            publish(entries: saved.entries, spans: saved.spans, loadedFor: uid)
        }
        let me = Firestore.firestore().collection("users").document(uid)
        listListener = me.collection("blocked").addSnapshotListener { [weak self] snap, error in
            // A late snapshot must not hand one account's list to the next one on this phone.
            guard Auth.auth().currentUser?.uid == uid else { return }
            guard let snap else {
                // ⚠️ A LIST THAT CANNOT LOAD MUST NOT HOLD THE CHAT LIST BACK FOR EVER (it waits on
                // `isLoaded`). Count it as answered with what we have (the saved copy, or none).
                if error != nil { self?.answeredWithoutData(uid, list: true) }
                return
            }
            var m: [String: Double] = [:]
            for d in snap.documents {
                let at = (d.data(with: .estimate)["at"] as? Timestamp)?.dateValue().timeIntervalSince1970 ?? 0
                m[d.documentID] = at * 1000
            }
            DispatchQueue.main.async {
                guard let self, Auth.auth().currentUser?.uid == uid, self.listenerUid == uid else { return }
                self.listLoaded = true
                self.publish(entries: m, spans: self.spans,
                             loadedFor: self.historyLoaded || self.restored ? uid : nil)
            }
        }
        historyListener = me.collection("blockHistory").addSnapshotListener { [weak self] snap, error in
            guard Auth.auth().currentUser?.uid == uid else { return }
            guard let snap else {
                if error != nil { self?.answeredWithoutData(uid, list: false) }
                return
            }
            var s: [String: [ClosedRange<Double>]] = [:]
            for d in snap.documents {
                let data = d.data(with: .estimate)
                guard let other = data["other"] as? String,
                      let from = (data["from"] as? Timestamp)?.dateValue().timeIntervalSince1970,
                      let to = (data["to"] as? Timestamp)?.dateValue().timeIntervalSince1970,
                      from <= to else { continue }
                s[other, default: []].append((from * 1000)...(to * 1000))
            }
            DispatchQueue.main.async {
                guard let self, Auth.auth().currentUser?.uid == uid, self.listenerUid == uid else { return }
                self.historyLoaded = true
                self.publish(entries: self.entries, spans: s,
                             loadedFor: self.listLoaded || self.restored ? uid : nil)
            }
        }
    }

    /// Sign-out (SessionWipe): the next account must not inherit this one's list.
    func stop() {
        stopListeners()
        if let uid = listenerUid { UserDefaults.standard.removeObject(forKey: Self.savedKey(uid)) }
        listenerUid = nil
        restored = false
        migrated = []
        publish(entries: [:], spans: [:], loadedFor: nil)
    }

    // MARK: - The saved copy

    @ObservationIgnored private var restored = false
    private static func savedKey(_ uid: String) -> String { "blockList.v1.\(uid)" }

    private static func loadSaved(_ uid: String) -> (entries: [String: Double], spans: [String: [ClosedRange<Double>]])? {
        guard let d = UserDefaults.standard.dictionary(forKey: savedKey(uid)),
              let e = d["entries"] as? [String: Double] else { return nil }
        var s: [String: [ClosedRange<Double>]] = [:]
        for (uid, pairs) in (d["spans"] as? [String: [[Double]]]) ?? [:] {
            s[uid] = pairs.compactMap { $0.count == 2 && $0[0] <= $0[1] ? $0[0]...$0[1] : nil }
        }
        return (e, s)
    }

    private static func save(_ uid: String, entries: [String: Double], spans: [String: [ClosedRange<Double>]]) {
        UserDefaults.standard.set([
            "entries": entries,
            "spans": spans.mapValues { $0.map { [$0.lowerBound, $0.upperBound] } },
        ], forKey: savedKey(uid))
    }

    private func answeredWithoutData(_ uid: String, list: Bool) {
        DispatchQueue.main.async {
            guard Auth.auth().currentUser?.uid == uid, self.listenerUid == uid else { return }
            if list { self.listLoaded = true } else { self.historyLoaded = true }
            let both = (self.listLoaded && self.historyLoaded) || self.restored
            self.publish(entries: self.entries, spans: self.spans, loadedFor: both ? uid : nil)
        }
    }

    private func stopListeners() {
        listListener?.remove(); listListener = nil
        historyListener?.remove(); historyListener = nil
    }

    private func publish(entries e: [String: Double], spans s: [String: [ClosedRange<Double>]], loadedFor l: String?) {
        Self.lock.lock()
        Self._snapshot = Snapshot(allEntries: e, allSpans: s, owner: listenerUid)
        Self.lock.unlock()
        let changed = e != entries || s != spans || l != loadedFor
        entries = e
        spans = s
        loadedFor = l
        guard changed else { return }
        if let l, listLoaded || historyLoaded { Self.save(l, entries: e, spans: s) }
        version &+= 1
        ConversationsRepository.shared.blockListChanged()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    // MARK: - Blocking

    /// Block or unblock `other`. Returns false when the server refused, so a caller can say so.
    /// Calls for the same person run one after another, in the order they were made.
    @discardableResult
    func setBlocked(_ other: String, _ value: Bool) async -> Bool {
        // The queue is only touched on the main thread, so two taps cannot both find it empty.
        let task: Task<Bool, Never> = await MainActor.run {
            let prior = self.inFlight[other]
            let t = Task { () -> Bool in
                _ = await prior?.value
                return await self.write(other, value)
            }
            self.inFlight[other] = t
            return t
        }
        let ok = await task.value
        await MainActor.run { if self.inFlight[other] == task { self.inFlight[other] = nil } }
        return ok
    }

    private func write(_ other: String, _ value: Bool) async -> Bool {
        guard let me = Auth.auth().currentUser?.uid, !me.isEmpty,
              !other.isEmpty, other != me, !other.contains("/") else { return false }
        let current = Self.snapshot
        let db = Firestore.firestore()
        let meRef = db.collection("users").document(me)
        let listRef = meRef.collection("blocked").document(other)
        let cid = ChatService.convId(me, other)
        do {
            if value {
                if !current.contains(other) {
                    try await listRef.setData(["at": FieldValue.serverTimestamp()])
                }
                // REVOKE MY ACTIVE STORIES FROM THEM (audit). The audience is frozen into
                // recipientUids at post time, so blocking has to reach back into live stories.
                await StoriesRepository.shared.revokeAudience(for: other)
            } else {
                // The block that is ending goes to my history in the SAME write that lifts it, so
                // there is never a moment where what they sent meanwhile is neither blocked nor
                // remembered. `from` is the list entry's own time (the estimate while it is pending).
                let batch = db.batch()
                // A block made on ANOTHER of my devices may not have reached this one's listener
                // yet: ask the server directly, or its window would never be recorded and what they
                // sent during it would appear the moment it is lifted.
                var known = current.entries[other]
                if known == nil,
                   let snap = try? await listRef.getDocument(source: .server), snap.exists {
                    known = ((snap.data(with: .estimate)?["at"] as? Timestamp)?.dateValue()
                        .timeIntervalSince1970 ?? 0) * 1000
                }
                if let since = known {
                    let fromMs = since > 0 ? since : Date().timeIntervalSince1970 * 1000
                    let span = meRef.collection("blockHistory").document("\(other)_\(Int64(fromMs))")
                    batch.setData([
                        "other": other,
                        "from": Timestamp(date: Date(timeIntervalSince1970: fromMs / 1000)),
                        "to": FieldValue.serverTimestamp(),
                    ], forDocument: span)
                }
                batch.deleteDocument(listRef)
                try await batch.commit()
            }
        } catch {
            print("block (\(other), \(value)) refused:", error)
            return false
        }
        // The chat's old copy of the block (and my unread count, which their silent messages ran
        // up while I could not see them). Best effort: a chat that does not exist is fine.
        var chat: [String: Any] = [
            "blockedBy.\(me)": FieldValue.delete(),
            "blockedAt.\(me)": FieldValue.delete(),
            "blockClearedAt.\(me)": FieldValue.delete(),
        ]
        if !value { chat["unreadCount.\(me)"] = 0 }
        try? await db.collection("conversations").document(cid).updateData(chat)
        return true
    }

    // MARK: - Moving old blocks off the shared chat

    /// Blocks recorded the old way, on the chat itself, move to my private list and history, and are
    /// then deleted from the chat (where the person blocked could read them). Runs once per chat per
    /// session, only for the signed-in account's own loaded list, the private copy strictly BEFORE
    /// the chat's copy is removed, so hiding never has a gap.
    /// Main thread only (called from `ConversationsRepository.blockListChanged`).
    func migrate(_ conversations: [Conversation]) {
        guard let me = Auth.auth().currentUser?.uid, isLoaded, loadedFor == me else { return }
        for c in conversations where !c.isGroup && !migrated.contains(c.id) {
            let blocked = c.blockedBy[me]
            let at = c.blockedAt[me] ?? 0
            let cleared = c.blockClearedAt[me] ?? 0
            guard blocked != nil || at > 0 || cleared > 0 else { continue }
            let other = c.otherUid(me)
            guard !other.isEmpty, other != me else { continue }
            migrated.insert(c.id)
            Task { await self.moveOldBlock(me: me, other: other, cid: c.id,
                                           blocked: blocked == true, at: at, cleared: cleared) }
        }
    }

    private func moveOldBlock(me: String, other: String, cid: String, blocked: Bool, at: Double, cleared: Double) async {
        let current = Self.snapshot
        let db = Firestore.firestore()
        let meRef = db.collection("users").document(me)
        let now = Date().timeIntervalSince1970 * 1000
        let stamp = { (ms: Double) in Timestamp(date: Date(timeIntervalSince1970: min(ms, now) / 1000)) }
        do {
            if blocked {
                if !current.contains(other) {
                    try await meRef.collection("blocked").document(other)
                        .setData(["at": stamp(at > 0 ? at : now)])
                }
            } else if at > 0, cleared >= at,
                      !(current.spans[other]?.contains { abs($0.lowerBound - at) < 1 } ?? false) {
                // (History is write-once: a span already moved by an earlier launch is not rewritten.)
                try await meRef.collection("blockHistory").document("\(other)_\(Int64(at))")
                    .setData(["other": other, "from": stamp(at), "to": stamp(cleared)])
            }
            try await db.collection("conversations").document(cid).updateData([
                "blockedBy.\(me)": FieldValue.delete(),
                "blockedAt.\(me)": FieldValue.delete(),
                "blockClearedAt.\(me)": FieldValue.delete(),
            ])
        } catch {
            // Left as it was; the old copy is still honoured, and the next launch tries again.
            print("block move (\(cid)) failed:", error)
        }
    }
}
