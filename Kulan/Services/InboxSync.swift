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
/// - A chat never pulled before gets only its newest 60 messages; its whole history and first mark
///   come from `HistoryPull` (phase 4).
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
        HistoryPull.shared.start()   // owner 2026-11-12: phase 4 full pull sets each chat's FIRST mark
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
            // safety review 2026-11-12, the same-millisecond boundary on the read side: from the
            // mark's own millisecond (`>=`), not past it. A message committed later in that same
            // millisecond, or cut off by a full page that ended inside it, is read again rather than
            // skipped for good (filing twice is harmless).
            query = base.whereField("createdAt", isGreaterThanOrEqualTo: Self.timestamp(from))
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
        // Oldest first. A message whose keys are still missing ("…", or "🔒" in a group: safety
        // review 2026-11-12, `DeliveryCursor.holdsMark`) stops the page there: what came before it is
        // filed and marked, it and the rest are read again on a later run.
        var kept = built
        var stoppedOnKeys = false
        var cap = Int64.max
        if let i = built.firstIndex(where: { DeliveryCursor.holdsMark($0.m, cid: cid) }) {
            kept = Array(built[..<i])
            stoppedOnKeys = true
            restUntil[cid] = Date().addingTimeInterval(Self.rest)
            cap = built[i].ms - 1   // a kept message may share its millisecond: the mark stays below it
        }
        guard var upTo = kept.map({ $0.ms }).max() else { return }
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
        // ⛔ MEDIA FIRST (safety review 2026-11-12, `DeliveryCursor.mediaMissing`): every row is filed,
        // but the mark stops below the oldest filed message whose file is not on this phone yet, and
        // that file is asked for. The chat rests and is read again from the mark later.
        let filedIds = Set(file.map(\.id))
        var heldOnMedia = false
        if let h = kept.first(where: { filedIds.contains($0.m.id) && DeliveryCursor.mediaMissing($0.m, cid: cid) }) {
            cap = min(cap, h.ms - 1)
            heldOnMedia = true
            restUntil[cid] = Date().addingTimeInterval(Self.rest)
            DeliveryCursor.fetchMissing(h.m, cid: cid)
        }
        upTo = min(upTo, cap)
        // ⛔ The mark and the cursor only after the rows are really committed (safety review
        // 2026-11-12): a failed write rests the chat and vouches for nothing.
        let filed = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            LocalMessageDB.shared.upsert(cid: cid, uid: me, file) { c.resume(returning: $0) }
        }
        guard filed else {
            restUntil[cid] = Date().addingTimeInterval(Self.rest)
            return
        }
        // ⛔ NO GAP (2026-11-12): only a pull that continues from an existing mark is contiguous. A
        // chat with no mark got only its newest 60, so it vouches for nothing: no mark, no cursor
        // (phase 4's full pull sets the first mark). The cursor goes out after the mark is stored.
        if let from, upTo > from {
            let marked = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                LocalMessageDB.shared.setSyncedUpTo(cid: cid, uid: me, ms: upTo) { c.resume(returning: $0) }
            }
            guard marked else {
                restUntil[cid] = Date().addingTimeInterval(Self.rest)
                return
            }
            DeliveryCursor.write(cid: cid, me: me, ms: upTo)
        }
        if stoppedOnKeys || heldOnMedia { return }
        if let from, docs.count == Self.pageSize, upTo > from {
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

    /// ⛔ THE SAME-MILLISECOND LINE (safety review 2026-11-12). The server deletes every message with
    /// `createdAt < deliveredUpTo + 1 ms`, i.e. up to and including that millisecond. Two messages
    /// can share our newest millisecond and only one of them be on this phone, so the cursor always
    /// goes out one millisecond BELOW the mark: whatever shares the mark's millisecond stays on the
    /// server. The stored mark (`chats.synced_up_to`) stays at the newest millisecond filed. Every
    /// cursor write goes through `write`, which applies this one helper.
    static func line(forMark mark: Int64) -> Int64 { mark - 1 }

    /// ⛔ A MESSAGE THIS PHONE CANNOT KEEP YET (safety review 2026-11-12). No mark may pass it: a
    /// mark one millisecond below it at most, and InboxSync / HistoryPull stop filing there and read
    /// it again later. Not deleted, and either
    /// - its words still "…" (the keys are not warm yet; it decrypts later), or
    /// - a GROUP message sealed for keys this phone does not hold ("🔒", no wrap for me `notForMe`,
    ///   or a caption-less file whose key will not open, `sealUnreadable`). In a group that is not final: a member can release the
    ///   key (`rk`) later and it opens then. In a 1:1 chat "🔒" is final and is filed as it is.
    static func holdsMark(_ m: Message, cid: String) -> Bool {
        guard !m.deleted else { return false }
        if m.text == "…" { return true }
        let group = !cid.contains("_")   // the server's own test (ChatService.summaryOfNewest)
        return group && (m.text == "🔒" || m.notForMe || m.sealUnreadable == true)
    }

    /// ⛔ MEDIA FIRST (safety review 2026-11-12). A message that carries a file (photo, video, voice
    /// note, document, album, a sticker I made) is not vouched for until its file is on this phone:
    /// the server deletes the message and its media on the cursor, and the database row alone only
    /// holds the link. The simplest safe rule for now: InboxSync, HistoryPull and the open chat stop
    /// the mark one millisecond below the OLDEST such message whose file is not yet in the app's own
    /// media store, and ask for that file (`fetchMissing`, under the person's auto-download settings).
    /// The mark moves on once it has landed.
    ///
    /// "On this phone" is what the app's stores already answer: photos and album photos
    /// `DiskImageCache.isCached(url)`, videos and album clips `VideoCache.url(for: id / "id-i")`,
    /// voice notes `AudioCache.url(for: id or clientId)`, documents `DocumentPrefetch.cached`.
    /// Not waited for: a deleted message, an opened view-once, media the server already reported
    /// gone for good (`DeadMedia`), a GIF (a public link, not our file), and a 1:1 file that can
    /// never open here (`sealUnreadable`). An UNOPENED view-once is waited for and never fetched
    /// ahead of the tap: it holds the mark until it is opened.
    ///
    /// ⚠️ Known limits, for the next pass: photos live in the image CACHE (evictable by Keep Media,
    /// Clear Cache, the size budget and iOS), documents in the temporary directory; a file on the
    /// phone today can be gone later. And a file the auto-download settings never fetch holds the
    /// mark until the person opens it, so the server keeps that chat's messages (the safe side).
    static func mediaMissing(_ m: Message, cid: String) -> Bool {
        guard !m.deleted, !(m.viewOnce && m.consumed), !DeadMedia.contains(m.id) else { return false }
        if cid.contains("_"), m.sealUnreadable == true { return false }   // 1:1: can never open here
        if !m.album.isEmpty {
            for (i, it) in m.album.enumerated() {
                if it.isVideo, let v = it.videoUrl, !v.isEmpty {
                    if VideoCache.url(for: "\(m.id)-\(i)") == nil { return true }
                } else if !it.imageUrl.isEmpty, !DiskImageCache.shared.isCached(it.imageUrl) {
                    return true
                }
            }
            return false
        }
        let hasFile = [m.videoUrl, m.audioUrl, m.fileUrl, m.type == "gif" ? nil : m.imageUrl]
            .contains { !($0 ?? "").isEmpty }
        if m.viewOnce { return hasFile }   // unopened view-once: waits for the tap
        if let v = m.videoUrl, !v.isEmpty { return VideoCache.url(for: m.id) == nil }
        if let a = m.audioUrl, !a.isEmpty {
            return AudioCache.url(for: m.id) == nil && (m.clientId.map { AudioCache.url(for: $0) == nil } ?? true)
        }
        if let f = m.fileUrl, !f.isEmpty { return DocumentPrefetch.cached(id: m.id, fileName: m.fileName) == nil }
        if m.type != "gif", let u = m.imageUrl, !u.isEmpty { return !DiskImageCache.shared.isCached(u) }
        return false
    }

    /// Asks for the files `mediaMissing` is waiting on, through the same shared downloader and the
    /// same auto-download rules as the chat's own media (safety review 2026-11-12). A view-once is
    /// never fetched ahead of the tap.
    @MainActor static func fetchMissing(_ m: Message, cid: String) {
        guard !m.viewOnce, !m.deleted else { return }
        if !m.album.isEmpty {
            for (i, it) in m.album.enumerated() {
                if it.isVideo, let v = it.videoUrl, !v.isEmpty {
                    if VideoCache.url(for: "\(m.id)-\(i)") == nil {
                        MediaFetch.requestVideo(url: v, enc: it.videoEnc, cid: cid, messageId: "\(m.id)-\(i)",
                                                authorId: m.authorId, priority: .auto)
                    }
                } else if !it.imageUrl.isEmpty, !DiskImageCache.shared.isCached(it.imageUrl) {
                    MediaFetch.requestPhoto(url: it.imageUrl, enc: it.enc, cid: cid, gated: true)
                }
            }
            return
        }
        if let v = m.videoUrl, !v.isEmpty {
            MediaFetch.requestVideo(url: v, enc: m.enc, cid: cid, messageId: m.id, authorId: m.authorId, priority: .auto)
        } else if m.audioUrl?.isEmpty == false {
            MediaFetch.requestVoice(m, cid: cid, priority: .auto)
        } else if let f = m.fileUrl, !f.isEmpty {
            // As MediaAutoDownloader.sweep fetches a document, to the path ThreadView.openFile opens.
            guard m.enc != nil, AutoDownloadPrefs.allowedNow(.documents),
                  Int64(m.fileSize ?? 0) <= MediaAutoDownloader.maxAutoBytes else { return }
            let dest = DocumentPrefetch.localURL(id: m.id, fileName: m.fileName)
            MediaDownloads.shared.request(f, priority: .auto,
                                          finish: MediaFetch.dataFinisher(enc: m.enc, cid: cid) {
                                              DocumentPrefetch.write($0, to: dest); return true
                                          })
        } else if m.type != "gif", let u = m.imageUrl, !u.isEmpty {
            MediaFetch.requestPhoto(url: u, enc: m.enc, cid: cid, gated: true)
        }
    }

    /// `ms` is the MARK (newest millisecond filed); what is sent is `line(forMark:)`.
    static func write(cid: String, me: String, ms: Int64) {
        guard !cid.isEmpty, !me.isEmpty, line(forMark: ms) > 0, !Conversation.Right.isChannel(cid) else { return }
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
            .setData(["deliveredUpTo": line(forMark: ms), "at": FieldValue.serverTimestamp()]) { err in
                if let err { debugLog("[cursor] write refused:", err.localizedDescription) }
            }
    }
}
