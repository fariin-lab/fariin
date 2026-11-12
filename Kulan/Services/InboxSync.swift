import Foundation
import UIKit
import FirebaseAuth
import FirebaseFirestore

/// ⛔ INBOX SYNC (owner 2026-11-12, Documents/fariin-plans/2026-11-12-device-storage-plan.md, phase 2,
/// D1). A chat's messages reached the phone's database only while its ThreadRepository ran, so a
/// chat nobody opened was never stored and its delivery cursor never moved. This pulls the new
/// messages of every PRIVATE chat (1:1 and private groups) without opening it, files them in
/// `LocalMessageDB`, moves `chats.synced_up_to`, and writes the delivery cursor the same way an open
/// chat does. Channels and public groups are left out: their history stays on the server (D11).
///
/// - Runs on a list change and when the app comes back to the front, 2 s after the first kick, one
///   run at a time, at most 3 chats at once.
/// - A chat the app is already listening to (`ThreadRepository.isListening`) files itself.
/// - Filing twice is harmless: the database upserts by (cid, id).
/// - A chat never pulled before gets only its newest 60 messages; older history is phase 4.
@MainActor
final class InboxSync {
    static let shared = InboxSync()
    /// The one switch: false and nothing here runs.
    static let enabled = true

    private static let pageSize = 100
    private static let firstPull = 60
    private static let maxConcurrent = 3
    private static let delay: UInt64 = 2_000_000_000

    private var pendingKick: Task<Void, Never>?
    private var running = false
    private var kickedWhileRunning = false
    /// Chats still to pull this run, with the mark each is pulled from.
    private var queue: [(conv: Conversation, from: Int64?)] = []
    /// The `updatedAt` each chat had when it was last pulled to its end, so a chat-list write with no
    /// new message in it (a reaction, a read, a typing flag) does not cost a query every kick.
    private var pulledAt: [String: Double] = [:]
    private var pulledFor = ""
    /// A chat whose read failed, or stopped on a message whose keys are missing, rests a minute
    /// rather than costing a query on every kick.
    private var restUntil: [String: Date] = [:]
    private static let rest: TimeInterval = 60

    private init() {
        // `queue: nil`, as ThreadMessageCache explains: the block runs on the posting thread, which
        // for this notification is main, with no operation to wait on.
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                               object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { InboxSync.shared.kick() }
        }
    }

    /// Ask for a run. Kicks within the 2 s wait share one run; a kick during a run brings one more.
    func kick() {
        guard Self.enabled, pendingKick == nil else { return }
        pendingKick = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.delay)
            guard let self else { return }
            self.pendingKick = nil
            if self.running { self.kickedWhileRunning = true; return }
            await self.run()
        }
    }

    private func run() async {
        guard Self.enabled, UIApplication.shared.applicationState == .active,
              let me = Auth.auth().currentUser?.uid else { return }
        running = true
        defer {
            running = false
            if kickedWhileRunning { kickedWhileRunning = false; kick() }
        }
        if pulledFor != me { pulledAt = [:]; restUntil = [:]; pulledFor = me }
        let marks = await withCheckedContinuation { (c: CheckedContinuation<[String: Int64], Never>) in
            LocalMessageDB.shared.syncedUpTo(uid: me) { c.resume(returning: $0) }
        }
        guard Auth.auth().currentUser?.uid == me else { return }
        queue = ConversationsRepository.shared.conversations.compactMap { c -> (conv: Conversation, from: Int64?)? in
            guard !c.isChannel, !Conversation.Right.isChannel(c.id), !c.isPublic,
                  !DemoMode.isDemoConversation(c.id), c.updatedAtMillis > 0,
                  c.updatedAtMillis > (pulledAt[c.id] ?? 0),
                  (restUntil[c.id].map { Date() >= $0 } ?? true),
                  !ThreadRepository.isListening(c.id) else { return nil }
            let mark = marks[c.id]
            if let mark, c.updatedAtMillis <= Double(mark) { return nil }
            return (conv: c, from: mark)
        }
        guard !queue.isEmpty else { return }
        let workers = (0..<Self.maxConcurrent).map { _ in
            Task { @MainActor in
                while !self.queue.isEmpty {
                    let next = self.queue.removeFirst()
                    await self.pull(next.conv, from: next.from, me: me)
                }
            }
        }
        for w in workers { await w.value }
    }

    /// One page of one chat: read, decrypt off the main thread, file, mark, cursor.
    private func pull(_ conv: Conversation, from: Int64?, me: String) async {
        let cid = conv.id
        let stamp = conv.updatedAtMillis
        // Keys first, the way ThreadRepository.start warms them: a message read before its author's
        // key is here decrypts as "…", and that is never filed (below).
        try? await Crypto.shared.ensureReady()
        _ = await Crypto.shared.preloadKeys(conv.users.filter { $0 != me })
        let base = FirestoreHub.db.collection("conversations").document(cid).collection("messages")
        let query: Query
        if let from {
            query = base.whereField("createdAt", isGreaterThan: Self.timestamp(from))
                .order(by: "createdAt").limit(to: Self.pageSize)
        } else {
            query = base.order(by: "createdAt", descending: true).limit(to: Self.firstPull)
        }
        // The server only: a page from the local cache may have holes, and the mark must not pass them.
        guard let snap = try? await query.getDocuments(source: .server) else {
            restUntil[cid] = Date().addingTimeInterval(Self.rest)
            return
        }
        let docs = from == nil ? Array(snap.documents.reversed()) : snap.documents
        guard Auth.auth().currentUser?.uid == me else { return }
        guard !docs.isEmpty else { pulledAt[cid] = stamp; return }
        // Built OFF the main thread exactly as ThreadRepository.loadOlder does.
        let built: [(ms: Int64, m: Message)] = await Task.detached(priority: .utility) {
            docs.compactMap { doc -> (ms: Int64, m: Message)? in
                guard let ts = doc.data()["createdAt"] as? Timestamp else { return nil }
                return (ms: Self.ms(ts), m: Message(id: doc.documentID, data: doc.data(), cid: cid, crypto: Crypto.shared))
            }
        }.value
        guard Auth.auth().currentUser?.uid == me, !ThreadRepository.isListening(cid) else { return }
        // Oldest first. A message whose keys are still missing ("…") stops the page there: what
        // came before it is filed and marked, it and the rest are read again on a later run.
        var kept = built
        var stoppedOnKeys = false
        if let i = built.firstIndex(where: { !$0.m.deleted && $0.m.text == "…" }) {
            kept = Array(built[..<i])
            stoppedOnKeys = true
            restUntil[cid] = Date().addingTimeInterval(Self.rest)
        }
        guard let upTo = kept.map({ $0.ms }).max() else { return }
        // The rules the chat applies before filing: my Clear Chat cut (`isClearedForMe`, rebuilt
        // here from the conversation, server-stamped messages only) and the account block list
        // (static). The chat's per-1:1 block window (`hiddenByBlock`'s myBlockedAtMillis part) is
        // an instance value and is not repeated here. Also left out: messages I hid for myself, and
        // ones sealed without me (`notForMe`, never readable on this phone).
        let clearedAt = conv.clearedAt[me] ?? 0
        let file = kept.map { $0.m }.filter { m in
            let t = m.createdAt.timeIntervalSince1970 * 1000
            if clearedAt > 0, m.hasServerTime, t <= clearedAt { return false }
            if BlockList.snapshot.hides(author: m.authorId, atMillis: t) { return false }
            return !HiddenMessages.isHidden(m.id) && !m.notForMe
        }
        // One serial database queue: the rows land before the mark that says they are here.
        LocalMessageDB.shared.upsert(cid: cid, uid: me, file)
        LocalMessageDB.shared.setSyncedUpTo(cid: cid, uid: me, ms: upTo)
        DeliveryCursor.write(cid: cid, me: me, ms: upTo)
        if stoppedOnKeys { return }
        if from != nil, docs.count == Self.pageSize {
            queue.append((conv: conv, from: upTo))   // more behind this page
        } else {
            pulledAt[cid] = stamp
        }
    }

    /// Server time in ms, rounded down (as the delivery cursor), so a later read from it can only
    /// read a message twice, never skip one.
    nonisolated private static func ms(_ ts: Timestamp) -> Int64 {
        Int64(ts.seconds) * 1000 + Int64(ts.nanoseconds / 1_000_000)
    }

    nonisolated private static func timestamp(_ ms: Int64) -> Timestamp {
        Timestamp(seconds: ms / 1000, nanoseconds: Int32((ms % 1000) * 1_000_000))
    }
}

/// ⛔ PHASE 2 DELIVERY CURSOR WRITE (owner 2026-11-12, shared plan D1), shared by an open chat
/// (ThreadRepository.writeDeliveryCursor) and InboxSync. conversations/{cid}/cursors/{me} =
/// { deliveredUpTo: ms, at: server time }; the rules only let it move forward. One memory per
/// account and chat: only forward, at most one write every 20 s. A newer mark inside the 20 s is
/// kept and written once the 20 s are up, so a chat that goes quiet still gets its last mark.
/// Channels have no cursor (their history stays on the server for good).
enum DeliveryCursor {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sent: [String: Int64] = [:]
    nonisolated(unsafe) private static var sentAt: [String: Date] = [:]
    nonisolated(unsafe) private static var waiting: [String: Int64] = [:]
    private static let gap: TimeInterval = 20

    static func write(cid: String, me: String, ms: Int64) {
        guard !cid.isEmpty, !me.isEmpty, ms > 0, !Conversation.Right.isChannel(cid) else { return }
        let key = me + "|" + cid
        lock.lock()
        guard ms > (sent[key] ?? 0) else { lock.unlock(); return }
        let since = Date().timeIntervalSince(sentAt[key] ?? .distantPast)
        if since <= gap {
            let first = waiting[key] == nil
            waiting[key] = max(waiting[key] ?? 0, ms)
            lock.unlock()
            if first {
                DispatchQueue.main.asyncAfter(deadline: .now() + (gap - since) + 0.1) {
                    Self.lock.lock()
                    let held = Self.waiting.removeValue(forKey: key)
                    Self.lock.unlock()
                    if let held { Self.write(cid: cid, me: me, ms: held) }
                }
            }
            return
        }
        sent[key] = ms
        sentAt[key] = Date()
        lock.unlock()
        FirestoreHub.db.collection("conversations").document(cid).collection("cursors").document(me)
            .setData(["deliveredUpTo": ms, "at": FieldValue.serverTimestamp()]) { err in
                if let err { debugLog("[cursor] write refused:", err.localizedDescription) }
            }
    }
}
