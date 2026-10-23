//  GroupKeyRelease.swift
//  Kulan
//
//  ⛔ GROUPS ARE NOT END-TO-END ENCRYPTED — owner 2026-10-23: every member reads the group's whole
//  history, the ones who joined later included, unless the admins hid it. 1:1 chats stay end-to-end
//  and are never touched here.
//
//  Old group content was sealed for the members of the day ("encg1:" text, files whose `EncMeta`
//  carries one wrapped key per member). A later member holds no wrap, so it stayed locked. This
//  worker runs on the phones that DO hold wraps: for a group that switched (`e2ee == false`) and
//  does not hide its history, it opens its own wraps of old items (cheap, no file download) and
//  sends the per-item keys to the server function `releaseGroupKeys`. The server checks each key
//  against the real ciphertext and files it on the message under `rk`, keyed by the item's nonce;
//  every member's phone then opens the item with it (Crypto, "Released group keys").
//
//  Runs when the group is opened, and once in a while quietly for groups in the chat list. One
//  group at a time, small batches with a pause between them, a daily ceiling below the server's,
//  and a cursor per group on disk so a pass that stops resumes where it left off. Keys are never
//  logged; only counts are. Server contract: Documents/Kulan groups no-E2EE 2026-10-23/CONTRACT.md.

import Foundation
import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions

actor GroupKeyRelease {
    static let shared = GroupKeyRelease()

    // MARK: - Entry points (any thread)

    /// Groups already heard of this launch (Conversation parse runs on every list snapshot).
    private final class Noted: @unchecked Sendable {
        private let lock = NSLock()
        private var set = Set<String>()
        func insert(_ cid: String) -> Bool { lock.withLock { set.insert(cid).inserted } }
    }
    private static let noted = Noted()

    /// A switched group is in my chat list (Conversation parse). Once per launch per group, a quiet
    /// pass is considered a little later.
    nonisolated static func noteGroup(_ cid: String) {
        guard Crypto.isGroupCid(cid), noted.insert(cid) else { return }
        Task.detached(priority: .background) {
            try? await Task.sleep(nanoseconds: 20_000_000_000)   // after launch has settled
            await shared.run(cid, opened: false)
        }
    }

    /// I opened this chat (ThreadRepository.open). 1:1 ids are ignored.
    nonisolated static func chatOpened(_ cid: String) {
        guard Crypto.isGroupCid(cid) else { return }
        Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 2_000_000_000)    // the chat draws first
            await shared.run(cid, opened: true)
        }
    }

    // MARK: - Limits

    private static let pageSize = 100
    private static let pagesPerPass = 10
    private static let textPerCall = 200
    private static let filesPerCall = 10
    private static let pauseBetweenCalls: UInt64 = 1_500_000_000
    /// Items ASKED per day on this phone; the server allows 5,000 per uid per UTC day.
    private static let dailyCeiling = 4_000

    // MARK: - Per-group progress, on disk

    private struct Progress: Codable {
        /// Newest `createdAt` (ms) already looked at; the next pass starts with anything newer.
        var top: Double = 0
        /// Oldest `createdAt` (ms) already looked at; the next pass continues below it.
        var bottom: Double = 0
        /// The beginning of the chat was reached.
        var done = false
        /// Last pass started (s since 1970).
        var lastRun: Double = 0
        /// No pass before this (s): the server said the group does not release (hidden history,
        /// not switched, closed, not a member) or the day's ceiling was hit.
        var notBefore: Double = 0
    }

    private static let progressKey = "groupKeyRelease.v1"
    private static let dailyKey = "groupKeyRelease.daily.v1"

    private func load(_ cid: String) -> Progress {
        let all = UserDefaults.standard.dictionary(forKey: Self.progressKey) as? [String: Data] ?? [:]
        return all[cid].flatMap { try? JSONDecoder().decode(Progress.self, from: $0) } ?? Progress()
    }

    private func save(_ cid: String, _ p: Progress) {
        var all = UserDefaults.standard.dictionary(forKey: Self.progressKey) as? [String: Data] ?? [:]
        all[cid] = try? JSONEncoder().encode(p)
        UserDefaults.standard.set(all, forKey: Self.progressKey)
    }

    /// Items asked today (UTC day, like the server's count).
    private func askedToday() -> Int {
        let d = UserDefaults.standard.dictionary(forKey: Self.dailyKey) ?? [:]
        return d["day"] as? String == Self.utcDay() ? (d["n"] as? Int ?? 0) : 0
    }

    private func addAsked(_ n: Int) {
        UserDefaults.standard.set(["day": Self.utcDay(), "n": askedToday() + n], forKey: Self.dailyKey)
    }

    private static func utcDay() -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    // MARK: - The pass

    /// One group at a time; the others wait their turn (an opened chat goes first).
    private var running = false
    private var waiting: [(cid: String, opened: Bool)] = []

    private func run(_ cid: String, opened: Bool) async {
        guard Crypto.isGroupCid(cid) else { return }
        if running {
            waiting.removeAll { $0.cid == cid }
            if opened { waiting.insert((cid, true), at: 0) } else { waiting.append((cid, false)) }
            return
        }
        running = true
        defer { running = false }
        var next: (cid: String, opened: Bool)? = (cid, opened)
        while let job = next {
            await pass(job.cid, opened: job.opened)
            next = waiting.isEmpty ? nil : waiting.removeFirst()
        }
    }

    private struct Item {
        let mid: String
        let f: String
        let n: String
        let k: String
        var isFile: Bool { Self.fileFields.contains(f) || f.hasPrefix("album.") }
        static let fileFields: Set<String> = ["enc", "thumbEnc", "linkPreview.imageEnc"]
        var payload: [String: Any] { ["mid": mid, "f": f, "n": n, "k": k] }
    }

    private enum Stop: Error { case later, blocked(TimeInterval) }

    private func pass(_ cid: String, opened: Bool) async {
        var p = load(cid)
        let now = Date().timeIntervalSince1970
        if now < p.notBefore { return }
        // An opened chat re-checks after 10 minutes; the quiet pass after 30 minutes while there is
        // history left, and once a day after that (old builds may still send sealed messages).
        let gap: TimeInterval = opened ? 600 : (p.done ? 86_400 : 1_800)
        if now - p.lastRun < gap { return }
        guard let me = Auth.auth().currentUser?.uid else { return }
        p.lastRun = now
        save(cid, p)

        let db = FirestoreHub.db
        // The group as the server sees it now: switched, history visible, open, and I am in it.
        guard let snap = try? await db.collection("conversations").document(cid).getDocument(source: .server),
              let g = snap.data() else { return }
        let users = g["users"] as? [String] ?? []
        let banned = g["bannedUids"] as? [String] ?? []
        let hidden = ((g["hideHistoryAt"] as? NSNumber)?.doubleValue ?? 0) > 0 || g["hideHistoryAt"] is Timestamp
        guard g["type"] as? String == "group", g["e2ee"] as? Bool == false, !hidden,
              g["endedAt"] == nil, users.contains(me), !banned.contains(me) else {
            p.notBefore = now + 3_600   // one cheap read an hour at most while it stays so
            save(cid, p)
            return
        }
        do { try await Crypto.shared.ensureReady() } catch { return }

        var sentTotal = 0
        do {
            // 1) Anything newer than what was looked at (sealed by an old build after the last pass).
            if p.top > 0 {
                let from = p.top
                var after: DocumentSnapshot?
                for _ in 0..<Self.pagesPerPass {
                    var q = db.collection("conversations").document(cid).collection("messages")
                        .whereField("createdAt", isGreaterThan: Timestamp(date: Date(timeIntervalSince1970: from / 1000)))
                        .order(by: "createdAt", descending: false)
                        .limit(to: Self.pageSize)
                    if let after { q = q.start(afterDocument: after) }
                    let page = try await q.getDocuments(source: .server)
                    guard !page.documents.isEmpty else { break }
                    sentTotal += try await release(cid, page.documents)
                    for d in page.documents { if let ms = Self.ms(d) { p.top = max(p.top, ms) } }
                    save(cid, p)
                    after = page.documents.last
                    if page.documents.count < Self.pageSize { break }
                }
            }
            // 2) Back through history from where the last pass stopped (or from the newest).
            if !p.done {
                let below = p.bottom
                var after: DocumentSnapshot?
                for _ in 0..<Self.pagesPerPass {
                    var q: Query = db.collection("conversations").document(cid).collection("messages")
                    if below > 0 {
                        q = q.whereField("createdAt", isLessThan: Timestamp(date: Date(timeIntervalSince1970: below / 1000)))
                    }
                    q = q.order(by: "createdAt", descending: true).limit(to: Self.pageSize)
                    if let after { q = q.start(afterDocument: after) }
                    let page = try await q.getDocuments(source: .server)
                    if page.documents.isEmpty { p.done = true; save(cid, p); break }
                    sentTotal += try await release(cid, page.documents)
                    for d in page.documents {
                        guard let ms = Self.ms(d) else { continue }
                        p.top = max(p.top, ms)
                        p.bottom = p.bottom > 0 ? min(p.bottom, ms) : ms
                    }
                    if page.documents.count < Self.pageSize { p.done = true }
                    save(cid, p)
                    if p.done { break }
                    after = page.documents.last
                }
            }
        } catch Stop.blocked(let wait) {
            p.notBefore = Date().timeIntervalSince1970 + wait
            save(cid, p)
        } catch {
            // Offline, a fault, or the ceiling for today: the cursor stays where the last full page
            // ended, and the next pass picks up from there.
        }
        if sentTotal > 0 { DiagLog.add("[keyRelease] \(cid.prefix(6)) sent \(sentTotal)") }
    }

    private static func ms(_ d: DocumentSnapshot) -> Double? {
        (d.get("createdAt") as? Timestamp).map { $0.dateValue().timeIntervalSince1970 * 1000 }
    }

    /// The keys of one page that this phone holds and the server does not have yet, sent in batches.
    /// Returns how many items were sent. Throws to stop the pass.
    private func release(_ cid: String, _ docs: [QueryDocumentSnapshot]) async throws -> Int {
        // Author keys for the wraps, fetched together before the synchronous unwraps.
        var authors = Set<String>()
        for d in docs {
            if let a = d.get("authorId") as? String { authors.insert(a) }
            if let r = d.get("reactions") as? [String: Any] { authors.formUnion(r.keys) }
            if let e = d.get("enc") as? [String: Any], let a = e["a"] as? String { authors.insert(a) }
        }
        _ = await Crypto.shared.preloadKeys(Array(authors))

        var items: [Item] = []
        for d in docs { items += collect(d) }
        guard !items.isEmpty else { return 0 }

        var queue = items
        var sent = 0
        var retries = 0
        while !queue.isEmpty {
            if askedToday() >= Self.dailyCeiling { throw Stop.blocked(6 * 3600) }
            // One call: up to 200 items, of which up to 10 files.
            var batch: [Item] = []
            var files = 0
            var rest: [Item] = []
            for it in queue {
                if batch.count < Self.textPerCall, !it.isFile || files < Self.filesPerCall {
                    batch.append(it)
                    if it.isFile { files += 1 }
                } else {
                    rest.append(it)
                }
            }
            addAsked(batch.count)
            sent += batch.count
            let again = try await call(cid, batch)
            // Skipped for a reason that can pass (the call's file budget, a busy document): once more.
            // Bounded, so a server that keeps skipping cannot hold the pass forever.
            if !again.isEmpty, retries < 20 { retries += 1; rest += again }
            queue = rest
            if !queue.isEmpty { try? await Task.sleep(nanoseconds: Self.pauseBetweenCalls) }
        }
        try? await Task.sleep(nanoseconds: Self.pauseBetweenCalls)
        return sent
    }

    /// Posts one batch. Returns the items to try again; throws to stop the pass.
    private func call(_ cid: String, _ batch: [Item]) async throws -> [Item] {
        let fn = Functions.functions(region: "me-central1").httpsCallable("releaseGroupKeys")
        fn.timeoutInterval = 300
        do {
            let res = try await fn.call(["cid": cid, "items": batch.map(\.payload)] as [String: Any])
            let results = (res.data as? [String: Any])?["results"] as? [[String: Any]] ?? []
            var retry: [Item] = []
            for r in results where r["status"] as? String == "skipped" {
                let reason = r["reason"] as? String ?? ""
                guard reason == "budget" || reason == "busy" else { continue }
                if let it = batch.first(where: { $0.mid == r["mid"] as? String && $0.n == r["n"] as? String }) {
                    retry.append(it)
                }
            }
            return retry
        } catch {
            let ns = error as NSError
            guard ns.domain == FunctionsErrorDomain else { throw Stop.later }
            switch FunctionsErrorCode(rawValue: ns.code) {
            case .failedPrecondition?, .permissionDenied?: throw Stop.blocked(6 * 3600)
            case .resourceExhausted?: throw Stop.blocked(6 * 3600)
            case .invalidArgument?: return []   // a batch the server would not take; move on
            default: throw Stop.later
            }
        }
    }

    // MARK: - What one message holds

    /// Every sealed group item in `d` whose key my own wrap opens and that has no released key yet.
    private func collect(_ d: QueryDocumentSnapshot) -> [Item] {
        let x = d.data()
        // Never released (the server refuses them too): deleted, view-once, held, disappearing.
        if x["deleted"] as? Bool == true || x["viewOnce"] as? Bool == true
            || x["held"] as? Bool == true || x["expiresAt"] != nil { return [] }
        let mid = d.documentID
        let author = x["authorId"] as? String ?? ""
        let have = Set(((x["rk"] as? [String: Any]) ?? [:]).keys.compactMap { Crypto.looseBase64($0) })
        let crypto = Crypto.shared
        var out: [Item] = []

        func text(_ f: String, _ raw: Any?, by: String) {
            guard let raw = raw as? String, raw.hasPrefix("encg1:"),
                  let key = crypto.ownGroupTextKey(raw, authorId: by),
                  let n = Crypto.looseBase64(key.n), !have.contains(n) else { return }
            out.append(Item(mid: mid, f: f, n: key.n, k: key.k))
        }
        func file(_ f: String, _ map: Any?, url: Any?) {
            guard let u = url as? String, !u.isEmpty,
                  let m = (map as? [String: Any]).flatMap(EncMeta.init(map:)),
                  let key = crypto.ownGroupFileKey(m),
                  let n = Crypto.looseBase64(key.n), !have.contains(n) else { return }
            out.append(Item(mid: mid, f: f, n: key.n, k: key.k))
        }

        text("text", x["text"], by: author)
        text("blurhash", x["blurhash"], by: author)
        text("thumb", x["thumb"], by: author)
        if let r = x["replyTo"] as? [String: Any] { text("replyTo.text", r["text"], by: author) }
        let lp = x["linkPreview"] as? [String: Any]
        if let lp {
            for k in ["url", "title", "desc"] { text("linkPreview.\(k)", lp[k], by: author) }
        }
        for (uid, raw) in (x["reactions"] as? [String: Any]) ?? [:] {
            text("reactions.\(uid)", raw, by: uid)
        }
        for (i, e) in ((x["edits"] as? [[String: Any]]) ?? []).enumerated() {
            text("edits.\(i)", e["t"], by: author)
        }
        let mainUrl = [x["videoUrl"], x["audioUrl"], x["fileUrl"], x["imageUrl"]]
            .compactMap { $0 as? String }.first { !$0.isEmpty }
        file("enc", x["enc"], url: mainUrl)
        file("thumbEnc", x["thumbEnc"], url: x["thumbUrl"])
        if let lp { file("linkPreview.imageEnc", lp["imageEnc"], url: lp["imageUrl"]) }
        for (i, a) in ((x["album"] as? [[String: Any]]) ?? []).enumerated() {
            file("album.\(i).enc", a["enc"], url: a["imageUrl"])
            file("album.\(i).videoEnc", a["videoEnc"], url: a["videoUrl"])
        }
        return out
    }
}
