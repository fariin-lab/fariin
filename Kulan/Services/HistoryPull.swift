import Foundation
import UIKit
import FirebaseAuth
import FirebaseFirestore

/// ⛔ FULL HISTORY PULL (owner 2026-11-12, Documents/fariin-plans/2026-11-12-device-storage-plan.md,
/// D7 + phase 4). The NO-GAP rule says a chat's FIRST mark (`chats.synced_up_to`) may only come from
/// a pull that has filed the chat's whole history, from its very first message up to the mark. This
/// is that pull. Once a chat has its mark, InboxSync and the open chat carry it forward.
///
/// For every PRIVATE chat (same choice as InboxSync: no channels, no public groups, no demo) with no
/// mark yet:
/// - T0 = the server time of the newest message, read as the first page (newest first).
/// - Pages of 100 go backwards from there (server only, cursor = the page's last document), built off
///   the main thread exactly like InboxSync, with the same hide rules, and filed page by page.
/// - A message whose keys are not here yet ("…") stops the chat; it is tried again later. So does a
///   GROUP message sealed without a key here ("🔒": a released key can still open it, safety review
///   2026-11-12, `DeliveryCursor.holdsMark`). In a 1:1 chat "🔒" can never be read and is filed like
///   any other.
/// - A short page means the first message is reached: mark = T0, then the delivery cursor at T0 once
///   the rows have committed. A chat with no messages at all gets mark 0 (no cursor).
/// - Progress lives in the database's `meta` ("pull.<cid>" = "<oldest filed ms>|<T0>[|<hold>]", then
///   "done"), so a pull killed half way goes on from where it stopped.
/// - MEDIA FIRST (safety review 2026-11-12, `DeliveryCursor.mediaMissing`): <hold> is the oldest
///   filed message whose file is not on this phone yet; the first mark is then one millisecond below
///   it instead of T0, and InboxSync carries it on once the file has landed.
/// - One chat at a time, newest activity first, a short pause between pages, only while the app is
///   in front and online. The first run waits 10 s after launch.
@MainActor
final class HistoryPull {
    static let shared = HistoryPull()
    /// The one switch: false and nothing here runs.
    static let enabled = true

    private static let pageSize = 100
    private static let firstDelay: UInt64 = 10_000_000_000
    private static let againDelay: UInt64 = 2_000_000_000
    private static let pagePause: UInt64 = 300_000_000
    /// A chat whose read failed, or that stopped on a message whose keys are missing, rests a minute.
    private static let rest: TimeInterval = 60

    private var task: Task<Void, Never>?
    private var launched = false
    private var restUntil: [String: Date] = [:]
    private var restFor = ""

    private init() {}

    /// Called with every InboxSync kick (list change, app back in front). One run at a time; a run
    /// with nothing left to pull costs two local reads and no server read.
    func start() {
        // One server switch starts both apps' pulls together (config/features.historyPull, agreed with
        // Android 2026-11-12); off until we decide when. Read as of the last launch.
        // safety review 2026-11-12: and never before the sign-in restore check has decided.
        guard Self.enabled, SignInRestoreGate.done, RemoteFeatures.value("historyPull", default: false),
              task == nil else { return }
        let wait = launched ? Self.againDelay : Self.firstDelay
        launched = true
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: wait)
            await self?.run()
            self?.task = nil
        }
    }

    private func canWork(_ me: String) -> Bool {
        Self.enabled && UIApplication.shared.applicationState == .active
            && NetworkState.shared.isOnline && Auth.auth().currentUser?.uid == me
    }

    private func run() async {
        guard let me = Auth.auth().currentUser?.uid else { return }
        if restFor != me { restUntil = [:]; restFor = me }
        while canWork(me) {
            let marks = await withCheckedContinuation { (c: CheckedContinuation<[String: Int64], Never>) in
                LocalMessageDB.shared.syncedUpTo(uid: me) { c.resume(returning: $0) }
            }
            let progress = await withCheckedContinuation { (c: CheckedContinuation<[String: String], Never>) in
                LocalMessageDB.shared.meta(uid: me, prefix: "pull.") { c.resume(returning: $0) }
            }
            guard canWork(me) else { return }
            let now = Date()
            // Newest activity first. A chat open on screen waits: its own listener is filing it.
            let next = ConversationsRepository.shared.conversations.filter { c in
                !c.isChannel && !Conversation.Right.isChannel(c.id) && !c.isPublic
                    && !DemoMode.isDemoConversation(c.id) && marks[c.id] == nil
                    && (restUntil[c.id].map { now >= $0 } ?? true)
                    && !ThreadRepository.isListening(c.id)
            }.max { $0.updatedAtMillis < $1.updatedAtMillis }
            guard let conv = next else { return }
            if await pull(conv, me: me, saved: progress["pull.\(conv.id)"]) {
                InboxSync.shared.kick()   // it carries the chat on from T0
            }
        }
    }

    /// One chat, page by page, to its first message. true = the chat got its mark. Every other way
    /// out either rests the chat or ends with the app no longer able to work, so `run` never spins.
    private func pull(_ first: Conversation, me: String, saved: String?) async -> Bool {
        let cid = first.id
        // Keys first, as InboxSync: a message read before its author's key is here decrypts as "…".
        try? await Crypto.shared.ensureReady()
        _ = await Crypto.shared.preloadKeys(first.users.filter { $0 != me })

        // Resume: "<oldest filed ms>|<T0>[|<hold>]". "done" (or anything else) with no mark starts over.
        var t0: Int64?
        var oldest: Int64?
        var hold: Int64?
        if let parts = saved?.split(separator: "|"), parts.count == 2 || parts.count == 3,
           let o = Int64(parts[0]), let t = Int64(parts[1]) {
            oldest = o
            t0 = t
            if parts.count == 3 {
                guard let h = Int64(parts[2]) else {   // unreadable hold: never guess, start over later
                    LocalMessageDB.shared.setMeta(uid: me, key: "pull.\(cid)", nil)
                    restUntil[cid] = Date().addingTimeInterval(Self.rest)
                    return false
                }
                hold = h
            }
        }
        let base = FirestoreHub.db.collection("conversations").document(cid).collection("messages")
        // A resume reads its oldest filed millisecond again (`< oldest + 1`): a message sharing that
        // millisecond is read twice rather than skipped. Filing twice is harmless (upsert).
        let ordered: Query = oldest.map {
            base.whereField("createdAt", isLessThan: Self.timestamp($0 + 1)).order(by: "createdAt", descending: true)
        } ?? base.order(by: "createdAt", descending: true)
        var after: DocumentSnapshot?

        while true {
            guard canWork(me) else { return false }
            // The chat as it is now: a Clear Chat during the pull counts from the next page on.
            guard let conv = ConversationsRepository.shared.conversations.first(where: { $0.id == cid }) else {
                restUntil[cid] = Date().addingTimeInterval(Self.rest)
                return false
            }
            var query = ordered
            if let after { query = query.start(afterDocument: after) }
            // The server only: a page from the local cache may have holes.
            guard let snap = try? await query.limit(to: Self.pageSize).getDocuments(source: .server) else {
                restUntil[cid] = Date().addingTimeInterval(Self.rest)
                return false
            }
            guard Auth.auth().currentUser?.uid == me else { return false }
            let docs = snap.documents   // newest first

            if docs.isEmpty {
                guard let newestMs = t0 else {
                    // No messages at all: everything up to 0 is here. No cursor (nothing to vouch for).
                    LocalMessageDB.shared.setSyncedUpTo(cid: cid, uid: me, ms: 0)
                    LocalMessageDB.shared.setMeta(uid: me, key: "pull.\(cid)", "done")
                    return true
                }
                return await finish(cid: cid, me: me, t0: newestMs, hold: hold)
            }

            // Built OFF the main thread exactly as InboxSync / ThreadRepository.loadOlder do.
            let built: [(ms: Int64, m: Message)] = await Task.detached(priority: .utility) {
                docs.compactMap { doc -> (ms: Int64, m: Message)? in
                    guard let ts = doc.data()["createdAt"] as? Timestamp else { return nil }
                    return (ms: Self.ms(ts), m: Message(id: doc.documentID, data: doc.data(), cid: cid, crypto: Crypto.shared))
                }
            }.value
            guard Auth.auth().currentUser?.uid == me else { return false }
            if t0 == nil {
                guard let newest = built.first?.ms else {
                    restUntil[cid] = Date().addingTimeInterval(Self.rest)
                    return false
                }
                t0 = newest
            }
            guard let top = t0 else { return false }

            // Newest first. A message whose keys are missing ("…", or "🔒" in a group: safety review
            // 2026-11-12, `DeliveryCursor.holdsMark`) stops the chat there: what is newer than it is
            // filed and remembered, it and everything older are read again later.
            var kept = built
            var stoppedOnKeys = false
            if let i = built.firstIndex(where: { DeliveryCursor.holdsMark($0.m, cid: cid) }) {
                kept = Array(built[..<i])
                stoppedOnKeys = true
            }
            // The same hide rules InboxSync applies before filing (see its comment): my Clear Chat cut,
            // the account block list, messages I hid for myself, ones sealed without me.
            let clearedAt = conv.clearedAt[me] ?? 0
            let file = kept.map { $0.m }.filter { m in
                let t = m.createdAt.timeIntervalSince1970 * 1000
                if clearedAt > 0, m.hasServerTime, t <= clearedAt { return false }
                if BlockList.snapshot.hides(author: m.authorId, atMillis: t) { return false }
                return !HiddenMessages.isHidden(m.id) && !m.notForMe
            }
            // ⛔ Progress (and later the mark) only after the rows are really committed (safety review
            // 2026-11-12): a failed write rests the chat, and a resume reads the page again.
            let filed = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                LocalMessageDB.shared.upsert(cid: cid, uid: me, file) { c.resume(returning: $0) }
            }
            guard filed else {
                restUntil[cid] = Date().addingTimeInterval(Self.rest)
                return false
            }
            // MEDIA FIRST: newest first, so the last missing file of this page is the oldest so far.
            let filedIds = Set(file.map(\.id))
            if let h = kept.last(where: { filedIds.contains($0.m.id) && DeliveryCursor.mediaMissing($0.m, cid: cid) }) {
                hold = min(hold ?? .max, h.ms)
                DeliveryCursor.fetchMissing(h.m, cid: cid)
            }
            // Progress after the rows (one serial queue), so a resume never skips a page.
            if let low = kept.last?.ms {
                let held = hold.map { "|\($0)" } ?? ""
                LocalMessageDB.shared.setMeta(uid: me, key: "pull.\(cid)", "\(low)|\(top)\(held)")
            }
            if stoppedOnKeys {
                restUntil[cid] = Date().addingTimeInterval(Self.rest)
                return false
            }
            // The first message is reached: a short page, or a page that reaches under my Clear Chat
            // cut (everything older is hidden from me anyway, no need to read it).
            let underCut: Bool = {
                guard clearedAt > 0, let last = built.last?.m, last.hasServerTime else { return false }
                return last.createdAt.timeIntervalSince1970 * 1000 <= clearedAt
            }()
            if docs.count < Self.pageSize || underCut {
                return await finish(cid: cid, me: me, t0: top, hold: hold)
            }
            after = docs.last
            try? await Task.sleep(nanoseconds: Self.pagePause)
        }
    }

    /// The chat's whole history up to T0 is on this phone (every page's upsert came back true): its
    /// first mark, then its cursor once the mark is stored (safety review 2026-11-12: from inside the
    /// write's success, never on a queue promise). A failed mark write rests the chat.
    /// `hold`: the oldest filed message whose file is not here yet; the mark stops one ms below it.
    private func finish(cid: String, me: String, t0: Int64, hold: Int64?) async -> Bool {
        let mark = hold.map { max(0, min(t0, $0 - 1)) } ?? t0
        let marked = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            LocalMessageDB.shared.setSyncedUpTo(cid: cid, uid: me, ms: mark) { c.resume(returning: $0) }
        }
        guard marked else {
            restUntil[cid] = Date().addingTimeInterval(Self.rest)
            return false
        }
        LocalMessageDB.shared.setMeta(uid: me, key: "pull.\(cid)", "done")
        DeliveryCursor.write(cid: cid, me: me, ms: mark)
        debugLog("[historyPull] done", cid, t0, mark)
        return true
    }

    /// Server time in ms, rounded down (as InboxSync and the delivery cursor).
    nonisolated private static func ms(_ ts: Timestamp) -> Int64 {
        Int64(ts.seconds) * 1000 + Int64(ts.nanoseconds / 1_000_000)
    }

    nonisolated private static func timestamp(_ ms: Int64) -> Timestamp {
        Timestamp(seconds: ms / 1000, nanoseconds: Int32((ms % 1000) * 1_000_000))
    }
}
