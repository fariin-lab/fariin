import SwiftUI
import Observation
import FirebaseFunctions
import FirebaseFirestore

/// One reply or answer under a channel post, as the server sends it (short keys, lib/replies.js).
struct PostReply: Identifiable, Equatable {
    enum Send: Equatable { case sent, sending, failed }
    var id: String
    var text: String
    var at: Date
    var name: String
    var photoUrl: String
    var verified: Bool
    var likes: Int
    var answers: Int
    var mine: Bool
    var canDelete: Bool
    var liked: Bool
    var held: Bool
    /// The author's uid: only for moderators (the server leaves it out for everyone else).
    var uid: String?
    /// Written by the channel's owner: it shows as the channel, with a "Creator" label (owner 2026-11-07).
    var creator = false
    var send: Send = .sent
    /// Changed after it was sent (shows "· edited").
    var edited = false
    /// The answer this one answers, inside the same thread (shown as "@name " before the text).
    var toId: String?
    var toName: String?
    /// Reactions as the chat has them (owner 2026-11-07): my emoji ("" = none) and each emoji's
    /// count, biggest first. `likes` stays the number of people who reacted.
    var my: String = ""
    var rx: [Reaction] = []
    struct Reaction: Equatable, Hashable { var emoji: String; var count: Int }

    static let heart = "❤️"

    /// Mine becomes `emoji` ("" takes mine back): the counts move with it.
    mutating func setMine(_ emoji: String) {
        guard emoji != my else { return }
        if !my.isEmpty, let i = rx.firstIndex(where: { $0.emoji == my }) {
            rx[i].count -= 1
            if rx[i].count <= 0 { rx.remove(at: i) }
        }
        if !emoji.isEmpty {
            if let i = rx.firstIndex(where: { $0.emoji == emoji }) { rx[i].count += 1 }
            else { rx.append(Reaction(emoji: emoji, count: 1)) }
        }
        likes = max(0, likes + (my.isEmpty ? 1 : 0) - (emoji.isEmpty ? 1 : 0))
        my = emoji
        liked = !emoji.isEmpty
    }

    init?(_ d: [String: Any]) {
        guard let id = d["id"] as? String else { return nil }
        self.id = id
        text = d["t"] as? String ?? ""
        at = Date(timeIntervalSince1970: ((d["at"] as? NSNumber)?.doubleValue ?? 0) / 1000)
        name = d["n"] as? String ?? "Someone"
        photoUrl = d["ph"] as? String ?? ""
        verified = d["v"] as? Bool ?? false
        likes = (d["lc"] as? NSNumber)?.intValue ?? 0
        answers = (d["ac"] as? NSNumber)?.intValue ?? 0
        mine = d["mine"] as? Bool ?? false
        canDelete = d["del"] as? Bool ?? false
        liked = d["liked"] as? Bool ?? false
        held = d["held"] as? Bool ?? false
        uid = d["u"] as? String
        creator = d["cr"] as? Bool ?? false
        edited = (d["edited"] as? Bool) ?? (d["ed"] as? Bool) ?? false
        if let to = d["to"] as? [String: Any], let tid = to["id"] as? String, !tid.isEmpty {
            toId = tid
            toName = to["name"] as? String ?? "Someone"
        }
        // A server from before emoji reactions sends only `liked` and `lc`: hearts.
        my = d["my"] as? String ?? (liked ? Self.heart : "")
        if let m = d["rx"] as? [String: Any] {
            rx = m.compactMap { k, v in
                let n = (v as? NSNumber)?.intValue ?? 0
                return n > 0 ? Reaction(emoji: k, count: n) : nil
            }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.emoji < $1.emoji }
        } else if likes > 0 {
            rx = [Reaction(emoji: Self.heart, count: likes)]
        }
    }

    /// A reply of mine on its way (shown at once, "Sending…", Retry if it fails).
    init(pendingId: String, text: String, name: String, photoUrl: String) {
        id = pendingId
        self.text = text
        at = Date()
        self.name = name
        self.photoUrl = photoUrl
        verified = false
        likes = 0
        answers = 0
        mine = true
        canDelete = true
        liked = false
        held = false
        uid = nil
        send = .sending
    }
}

/// Where a send from the field goes: a thread (its answers), and the answer it answers, if any.
struct ReplyTarget: Equatable {
    var thread: String
    var name: String
    var to: String?
}

/// A reply of mine being edited in the field.
struct ReplyEdit: Equatable {
    var id: String
    var thread: String?
    var text: String
}

/// ⛔ THE REPLIES OF ONE POST, KEPT BY ONE MODEL (owner 2026-11-06, rebuilt after five audits).
/// Threads arrive newest first a page at a time (shown oldest at the top); a thread's answers are
/// fetched when it is opened. While the sheet is open it listens to ONE tiny doc
/// (`messages/{mid}/rh/head`) and asks for the newest page only when that changes: no polling.
/// Every local action (a send, a heart, a delete) is applied at once and kept over any answer that
/// left the server before it (the `pendingLikes` / `deletedIds` overlays), so a late refresh never
/// flips it back. A send carries the phone's id, which becomes the reply's id on the server: a retry
/// after a lost answer cannot post twice.
@MainActor @Observable final class RepliesModel {
    struct Rights: Equatable { var del = false, ban = false, settings = false }

    let cid: String
    let mid: String
    private(set) var threads: [PostReply] = []           // oldest first
    /// The one pinned thread (owner 2026-11-07): shown first, never again in `threads`.
    private(set) var pinned: PostReply?
    private(set) var answers: [String: [PostReply]] = [:]  // thread id -> answers, oldest first
    private(set) var answerNext: [String: String] = [:]
    var openThreads: Set<String> = []
    private(set) var olderCursor = ""
    private(set) var loaded = false
    private(set) var failed = false
    private(set) var loadingOlder = false
    private(set) var off = false
    /// The server's switches have been read at least once (`off` before that is only a default).
    private(set) var flagsLoaded = false
    private(set) var channelOff = false
    private(set) var postOff = false
    private(set) var may = Rights()
    private(set) var staff = false
    private(set) var count = 0
    /// Replies by others that landed while I was reading further up ("N new replies" pill).
    var unseenNew = 0
    /// The id the list should bring into view next (my own new reply).
    var scrollTarget: String?

    private var pendingLikes: [String: String] = [:]    // key -> wanted emoji ("" = none), while in flight
    private var likeInFlight: Set<String> = []
    private var deletedIds: Set<String> = []
    private var headListener: ListenerRegistration?
    private var lastRev = -1
    private var refreshTask: Task<Void, Never>?
    /// Only the newest refresh may land (2026-11-06 audit: an older one finishing last flickered rows).
    private var refreshGen = 0
    /// My replies confirmed lately: a refresh that left before they were saved must not drop them.
    private var recentMine: [String: Date] = [:]
    /// Sends (by client id) already counted in `count` and the thread's answers.
    private var counted: Set<String> = []
    /// Is the end of the list on screen? New replies then scroll in instead of counting in the pill.
    var atEnd = true

    /// Top (the server's best first, shown in its order) or Newest (newest at the top). Top is the
    /// default. A server from before sorting ignores it and sends newest first.
    enum Sort: String { case top, new }
    private(set) var sort: Sort = .top
    /// Open threads showing all their answers, not just the first three.
    var expandedAll: Set<String> = []
    /// ⛔ MY OWN NEW REPLIES AT THE TOP, FOR ME ONLY (owner 2026-11-08, "exactly like TikTok"):
    /// what I post this visit sits first under the pinned one, newest first, so I see it at once;
    /// everyone else sees the post's normal order. Both the sending id and the saved id are kept.
    private(set) var mineOnTop: [String] = []
    /// ⛔ FIVE AT A TIME (owner 2026-11-08: "View 5 replies" shows all five; a thread of 10, 20,
    /// 100 shows 5, then "View more" adds 5 each tap, so one big thread never buries the other
    /// replies). How many answers each open thread shows; missing = `answerStep`.
    var shownAnswers: [String: Int] = [:]
    static let answerStep = 5

    /// "View N more replies": five more, fetching the next page when the loaded ones run out.
    func revealMoreAnswers(_ rid: String) {
        let next = (shownAnswers[rid] ?? Self.answerStep) + Self.answerStep
        shownAnswers[rid] = next
        if (answers[rid]?.count ?? 0) < next, !(answerNext[rid] ?? "").isEmpty {
            Task { await loadAnswers(rid, more: true) }
        }
    }
    /// The row to bring to the middle of the screen next ("t-id" or "a-id"), and the one flashing.
    var jump: String?
    private(set) var flash: String?
    /// The first page has answered (or failed) at least once in this sheet.
    private(set) var firstDone = false
    /// Edits on their way: a refresh that left before they were saved must not put the old text back.
    private var pendingEdits: [String: String] = [:]

    /// The last first page per post and sort, for an instant paint when the sheet opens again (this launch).
    private static var cache: [String: [PostReply]] = [:]
    private static var pinCache: [String: PostReply] = [:]
    private var cacheKey: String { "\(mid)|\(sort.rawValue)" }

    init(cid: String, mid: String) {
        self.cid = cid
        self.mid = mid
        if let c = Self.cache["\(mid)|top"] { threads = c; loaded = true }
        pinned = Self.pinCache[mid]
    }

    /// Time order for Newest; Top keeps the server's order.
    private func placed(_ list: [PostReply]) -> [PostReply] {
        sort == .new ? list.sorted { $0.at < $1.at } : list
    }

    private func listArgs(_ extra: [String: Any] = [:]) -> [String: Any] {
        var a = args(extra)
        a["sort"] = sort.rawValue
        return a
    }

    /// A new sort: the list starts again from its first page (pinned stays first).
    func setSort(_ s: Sort) {
        guard s != sort else { return }
        sort = s
        refreshGen &+= 1
        let mineSending = threads.filter { $0.send != .sent }
        // ⛔ NO EMPTY LIST ON A SORT SWITCH (owner 2026-11-08: tapping Newest blanked the sheet, hid the
        // Top / Newest chips and drew the loading shapes over the pinned reply). With no saved page for
        // the new order yet, the rows already here stand in, in time order (Newest draws them
        // reversed), until the server's page replaces them.
        let saved = Self.cache[cacheKey] ?? []
        let standIn = saved.isEmpty ? threads.sorted { $0.at < $1.at } : saved + mineSending
        threads = placed(standIn)
        olderCursor = ""
        unseenNew = 0
        atEnd = true
        loaded = !threads.isEmpty
        Task { await loadFirst() }
    }

    static func reset() { cache.removeAll(); pinCache.removeAll() }

    /// The first page's `pinned` (absent on a server from before pins: left as it is).
    private func applyPinned(_ d: [String: Any]) {
        guard d.keys.contains("pinned") else { return }
        let p = (d["pinned"] as? [String: Any]).flatMap(PostReply.init).map(overlay)
        setPinned(p.flatMap { deletedIds.contains($0.id) ? nil : $0 })
    }

    /// A new pin leaves the list; the one it replaces goes back into it, in time order.
    private func setPinned(_ p: PostReply?) {
        if let old = pinned, old.id != p?.id, !threads.contains(where: { $0.id == old.id }), !deletedIds.contains(old.id) {
            threads = placed(threads + [old])
        }
        if let p { threads.removeAll { $0.id == p.id } }
        pinned = p
        Self.pinCache[mid] = p
    }

    private var fn: Functions { Functions.functions(region: "me-central1") }
    private func args(_ extra: [String: Any] = [:]) -> [String: Any] {
        var a: [String: Any] = ["cid": cid, "mid": mid]
        for (k, v) in extra { a[k] = v }
        return a
    }

    // MARK: Loading

    func start() {
        Task { await loadFirst() }
        guard headListener == nil else { return }
        headListener = FirestoreHub.db.collection("conversations").document(cid).collection("messages").document(mid)
            .collection("rh").document("head")
            .addSnapshotListener { [weak self] snap, _ in
                let rev = (snap?.data()?["rev"] as? NSNumber)?.intValue ?? 0
                Task { @MainActor in self?.headChanged(rev) }
            }
    }

    func stop() {
        headListener?.remove()
        headListener = nil
        refreshTask?.cancel()
    }

    private func headChanged(_ rev: Int) {
        defer { lastRev = rev }
        guard lastRev >= 0, rev != lastRev, loaded else { return }
        // Several changes close together become one fetch (a busy thread).
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.refreshNewest()
        }
    }

    private func applyFlags(_ d: [String: Any]) {
        flagsLoaded = true
        off = d["off"] as? Bool ?? false
        channelOff = d["channelOff"] as? Bool ?? false
        postOff = d["postOff"] as? Bool ?? false
        staff = d["staff"] as? Bool ?? false
        count = (d["count"] as? NSNumber)?.intValue ?? count
        let m = d["may"] as? [String: Any] ?? [:]
        may = Rights(del: m["del"] as? Bool ?? false, ban: m["ban"] as? Bool ?? false, settings: m["settings"] as? Bool ?? false)
    }

    private func rows(_ d: [String: Any]) -> [PostReply] {
        ((d["items"] as? [[String: Any]]) ?? []).compactMap(PostReply.init).filter { !deletedIds.contains($0.id) }.map(overlay)
    }

    /// A heart still on its way wins over what an earlier answer said.
    private func overlay(_ r: PostReply) -> PostReply {
        var r = r
        if let want = pendingLikes[r.id] { r.setMine(want) }
        if let t = pendingEdits[r.id] { r.text = t; r.edited = true }
        return r
    }

    func loadFirst() async {
        let s = sort
        do {
            let res = try await fn.httpsCallable("getReplies").call(listArgs())
            guard s == sort else { return }   // the sort changed meanwhile: that load answers
            let d = res.data as? [String: Any] ?? [:]
            applyFlags(d)
            let ids: Set<String>
            if s == .top {
                // The server's order as it is; only mine still on their way stay below it.
                let page = rows(d)
                ids = Set(page.map(\.id))
                olderCursor = d["next"] as? String ?? ""
                let now = Date()
                let kept = threads.filter { r in !ids.contains(r.id)
                    && (r.send != .sent || recentMine[r.id].map { now.timeIntervalSince($0) < 8 } == true) }
                threads = page + kept
                Self.cache[cacheKey] = page
            } else {
                let page = Array(rows(d).reversed())
                ids = Set(page.map(\.id))
                if threads.isEmpty || olderCursor.isEmpty { olderCursor = d["next"] as? String ?? "" }
                // Pages loaded further down stay (a Try Again or a switch flip used to drop them).
                let firstAt = page.first?.at
                let kept = threads.filter { r in !ids.contains(r.id) && (r.send != .sent || (firstAt.map { r.at < $0 } ?? true)) }
                threads = (kept + page).sorted { $0.at < $1.at }
                Self.cache[cacheKey] = page
            }
            applyPinned(d)
            if lastRev < 0 { lastRev = (d["rev"] as? NSNumber)?.intValue ?? 0 }
            loaded = true
            failed = false
            prefetchAnswers()
        } catch {
            guard s == sort else { return }
            failed = true
            loaded = true
        }
        firstDone = true
    }

    /// ⛔ "VIEW N REPLIES" OPENS AT ONCE (owner 2026-11-07: it opened late). Right after the first page,
    /// the answers of the newest few replies that have any are fetched quietly, so the tap shows them
    /// straight away. At most 5, so a busy post does not cost a call per reply.
    private func prefetchAnswers() {
        var todo: [String] = []
        if let p = pinned, p.answers > 0 { todo.append(p.id) }
        // The first ones on screen: the top of the list for Top, the newest for Newest.
        let order = sort == .top ? threads : Array(threads.reversed())
        for r in order where r.answers > 0 && todo.count < 5 { todo.append(r.id) }
        for rid in todo where !answersLoaded.contains(rid) && !answersLoading.contains(rid) {
            Task { await loadAnswers(rid, more: false) }
        }
    }

    /// The newest page again, merged by id: new ones added at the end, changed ones updated, ones gone
    /// from inside the page's time range removed. Only the newest refresh lands; my own replies saved
    /// in the last seconds are kept; a page that does not reach back to what is shown replaces the
    /// list (and the "earlier" cursor), so no gap is left between them (2026-11-06 audits).
    func refreshNewest() async {
        refreshGen &+= 1
        let gen = refreshGen
        guard let res = try? await fn.httpsCallable("getReplies").call(listArgs()) else { return }
        guard gen == refreshGen else { return }
        let d = res.data as? [String: Any] ?? [:]
        applyFlags(d)
        if sort == .top {
            // Merged in place by id: rows keep their spot, new ones go below (the pill counts them).
            let page = rows(d)
            var list = threads
            var added = 0
            for r in page {
                if let i = list.firstIndex(where: { $0.id == r.id }) { list[i] = r }
                else { list.append(r); if !r.mine { added += 1 } }
            }
            threads = list
            applyPinned(d)
            if added > 0 { unseenNew += added }   // never a scroll for someone else's reply (below)
            Self.cache[cacheKey] = page
            dropStaleAnswers(page)
            await reloadChangedOpen(page)
            return
        }
        let page = Array(rows(d).reversed())
        let next = d["next"] as? String ?? ""
        let now = Date()
        recentMine = recentMine.filter { now.timeIntervalSince($0.value) < 8 }
        let keepMine: (PostReply) -> Bool = { $0.send != .sent || self.recentMine[$0.id] != nil }
        guard let oldestShown = page.first?.at else {
            // Nothing visible on the newest page: only rows newer than what that page covered can go.
            if next.isEmpty { threads.removeAll { !keepMine($0) } }
            applyPinned(d)   // a pin or unpin still lands when the newest page is empty
            dropStaleAnswers(page)
            return
        }
        let ids = Set(page.map(\.id))
        let newestKnown = threads.filter { $0.send == .sent }.map(\.at).max()
        let overlaps = newestKnown.map { $0 >= oldestShown } ?? true
        var list: [PostReply]
        if overlaps {
            list = threads.filter { keepMine($0) || $0.at < oldestShown || ids.contains($0.id) }
        } else {
            // More arrived than one page: start again from this page, older ones load on scroll.
            list = threads.filter(keepMine)
            olderCursor = next
        }
        var added = 0
        for r in page {
            if let i = list.firstIndex(where: { $0.id == r.id }) { list[i] = r }
            else { list.append(r); if !r.mine { added += 1 } }
        }
        list.sort { $0.at < $1.at }
        threads = list
        applyPinned(d)
        // ⛔ SOMEONE ELSE'S NEW REPLY NEVER MOVES MY LIST (owner 2026-11-08, "exactly like TikTok"):
        // on a post with thousands of replies a scroll per arrival is jumpy and costly. It lands
        // where it belongs and the "new" pill counts it.
        if added > 0 { unseenNew += added }
        Self.cache[cacheKey] = page
        dropStaleAnswers(page)
        await reloadChangedOpen(page)
    }

    /// Open threads whose answer count moved, together.
    private func reloadChangedOpen(_ page: [PostReply]) async {
        let changed = openThreads.filter { t in
            guard let r = page.first(where: { $0.id == t }) ?? (pinned?.id == t ? pinned : nil) else { return false }
            return r.answers != loadedAnswerCount(t)
        }
        await withTaskGroup(of: Void.self) { g in
            for t in changed.prefix(5) { g.addTask { await self.loadAnswers(t, more: false) } }
        }
    }

    private func loadedAnswerCount(_ t: String) -> Int {
        answers[t]?.filter { $0.send == .sent }.count ?? -1
    }

    /// A closed thread (prefetched, or opened and shut) whose answer count moved forgets its answers,
    /// so opening it loads them again instead of showing the old ones. My unsent ones stay.
    private func dropStaleAnswers(_ page: [PostReply]) {
        let shown = page + [pinned].compactMap { $0 }
        for r in shown where answersLoaded.contains(r.id) && !openThreads.contains(r.id) {
            guard r.answers != loadedAnswerCount(r.id) else { continue }
            answersLoaded.remove(r.id)
            let local = (answers[r.id] ?? []).filter { $0.send != .sent }
            answers[r.id] = local.isEmpty ? nil : local
            answerNext[r.id] = nil
        }
    }

    func loadOlder() async {
        guard !olderCursor.isEmpty, !loadingOlder else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        let s = sort
        guard let res = try? await fn.httpsCallable("getReplies").call(listArgs(["cursor": olderCursor])) else { return }
        guard s == sort else { return }
        let d = res.data as? [String: Any] ?? [:]
        let fresh = rows(d).filter { r in !threads.contains { $0.id == r.id } && r.id != pinned?.id }
        olderCursor = d["next"] as? String ?? ""
        if s == .top {
            // Below what is shown, before mine still sending.
            let at = threads.firstIndex { $0.send != .sent } ?? threads.count
            threads.insert(contentsOf: fresh, at: at)
        } else {
            threads.insert(contentsOf: fresh.reversed(), at: 0)
        }
    }

    /// Finds a row (thread, pinned, or an answer) by id.
    func find(_ id: String, thread: String?) -> PostReply? {
        if let t = thread { return answers[t]?.first { $0.id == id } }
        if pinned?.id == id { return pinned }
        return threads.first { $0.id == id }
    }

    private func isThread(_ id: String) -> Bool {
        pinned?.id == id || threads.contains { $0.id == id }
    }

    /// Brings a row into view and flashes it for about a second. An answer's thread opens, all of it.
    func reveal(_ id: String, thread: String?) {
        if let t = thread {
            openThreads.insert(t)
            expandedAll.insert(t)
            jump = "a-\(id)"
        } else {
            jump = "t-\(id)"
        }
        flash = id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            if flash == id { flash = nil }
        }
    }

    /// A tap on "@name": the answer it answers (or the thread, when it answers the thread itself).
    func jumpTo(_ id: String, inThread t: String) async {
        if id == t || isThread(id) { reveal(id, thread: nil); return }
        if !answersLoaded.contains(t) { await loadAnswers(t, more: false) }
        var pages = 0
        while answers[t]?.contains(where: { $0.id == id }) != true, !(answerNext[t] ?? "").isEmpty, pages < 5 {
            await loadAnswers(t, more: true)
            pages += 1
        }
        if answers[t]?.contains(where: { $0.id == id }) == true { reveal(id, thread: t) } else { reveal(t, thread: nil) }
    }

    /// A reply alert tapped: that thread (paging down to it if needed), opened, then the answer.
    func focus(rid: String, aid: String?) async {
        for _ in 0..<60 where !firstDone { try? await Task.sleep(nanoseconds: 100_000_000) }
        var pages = 0
        while !isThread(rid), !olderCursor.isEmpty, pages < 5 {
            await loadOlder()
            pages += 1
        }
        guard isThread(rid) else { return }   // gone, or too far down: the sheet stays at the top
        if let aid, !aid.isEmpty, aid != rid {
            await jumpTo(aid, inThread: rid)
        } else {
            if !openThreads.contains(rid) { toggleThread(rid) }
            reveal(rid, thread: nil)
        }
    }

    func loadAnswers(_ rid: String, more: Bool) async {
        if !more {
            guard !answersLoading.contains(rid) else { return }   // a prefetch already on its way
            answersLoading.insert(rid)
        }
        defer { if !more { answersLoading.remove(rid) } }
        let cursor = more ? (answerNext[rid] ?? "") : ""
        guard let res = try? await fn.httpsCallable("getReplyAnswers").call(args(["rid": rid, "cursor": cursor])) else { return }
        let d = res.data as? [String: Any] ?? [:]
        let page = rows(d)
        let next = d["next"] as? String ?? ""
        let had = answers[rid] ?? []
        // Mine still sending, and mine saved in the last seconds (a page asked for before the save
        // landed does not hold it yet, and the answer used to vanish).
        let now = Date()
        let local = had.filter { $0.send != .sent || recentMine[$0.id].map { now.timeIntervalSince($0) < 8 } == true }
        var list: [PostReply]
        var keepCursor = false
        if more {
            list = had.filter { $0.send == .sent }
        } else if !next.isEmpty, let lastAt = page.last?.at,
                  had.contains(where: { $0.send == .sent && $0.at > lastAt }) {
            // Pages past the first were loaded with "more": the first page is merged in by id and
            // those later pages (and their cursor) stay, instead of the list shrinking to one page.
            list = had.filter { $0.send == .sent && $0.at > lastAt }
            keepCursor = true
        } else {
            list = []
        }
        for r in page {
            if let i = list.firstIndex(where: { $0.id == r.id }) { list[i] = r } else { list.append(r) }
        }
        for l in local where !list.contains(where: { $0.id == l.id }) { list.append(l) }
        if keepCursor { list.sort { $0.at < $1.at } }
        answers[rid] = list
        if !keepCursor { answerNext[rid] = next }
        answersLoaded.insert(rid)
    }

    /// Threads whose answers came from the server at least once. A thread can hold my own answer
    /// (just sent) without the others; "View N replies" then showed only the newest (owner
    /// 2026-11-07: "show me the first ones"). Opened, it loads from the first answer down.
    private var answersLoaded: Set<String> = []
    /// Threads whose first answers are being fetched now (the toggle says "Loading..." meanwhile).
    private(set) var answersLoading: Set<String> = []

    func toggleThread(_ rid: String) {
        if openThreads.contains(rid) {
            openThreads.remove(rid); expandedAll.remove(rid); shownAnswers[rid] = nil; return
        }
        openThreads.insert(rid)
        if !answersLoaded.contains(rid) { Task { await loadAnswers(rid, more: false) } }
    }

    // MARK: Actions

    /// Sends a reply (`thread` nil) or an answer. Shown at once; on failure it stays with Retry.
    func send(_ text: String, thread: String?, to: (id: String, name: String)? = nil,
              me: (name: String, photo: String), clientId: String? = nil) {
        let id = clientId ?? UUID().uuidString
        var row = PostReply(pendingId: id, text: text, name: me.name, photoUrl: me.photo)
        row.toId = to?.id
        row.toName = to?.name
        if let t = thread {
            expandedAll.insert(t)   // my new answer is at the end: the whole thread shows
            // A thread never opened: its other answers load too, or only this one would show and the
            // thread would look fully loaded (2026-11-06 verify pass). loadAnswers keeps this row.
            if answers[t] == nil { Task { await loadAnswers(t, more: false) } }
            var list = answers[t] ?? []
            if let i = list.firstIndex(where: { $0.id == id }) { list[i].send = .sending } else { list.append(row) }
            answers[t] = list
            openThreads.insert(t)
        } else {
            if let i = threads.firstIndex(where: { $0.id == id }) { threads[i].send = .sending } else { threads.append(row) }
            if !mineOnTop.contains(id) { mineOnTop.insert(id, at: 0) }
        }
        scrollTarget = id
        Task {
            var a: [String: Any] = ["text": text, "clientId": id]
            if let t = thread { a["rid"] = t }
            if let to, thread != nil { a["to"] = ["id": to.id, "name": to.name] }
            do {
                let res = try await fn.httpsCallable("addReply").call(args(a))
                guard let d = (res.data as? [String: Any])?["reply"] as? [String: Any], var saved = PostReply(d) else {
                    mark(id, thread: thread, .failed)   // an answer it cannot read: Retry, not a row stuck sending
                    return
                }
                // Counted on the first save that worked, so a retried failed send counts too.
                let firstTime = !counted.contains(id)
                counted.insert(id)
                // A server that does not echo `to` yet: keep the one this phone sent.
                if saved.toId == nil, let to, thread != nil { saved.toId = to.id; saved.toName = to.name }
                replace(id, with: saved, thread: thread)
                if thread == nil, saved.id != id, let i = mineOnTop.firstIndex(of: id) { mineOnTop.insert(saved.id, at: i) }
                recentMine[id] = Date()
                recentMine[saved.id] = Date()
                if firstTime {
                    if let t = thread { update(t, thread: nil) { $0.answers += 1 } }
                    count += 1
                }
            } catch {
                mark(id, thread: thread, .failed)
                // A held thread refuses answers: say so, the server's words.
                if let m = Self.serverMessage(error) { notice = m }
            }
        }
    }

    func retry(_ r: PostReply, thread: String?) {
        send(r.text, thread: thread, to: r.toId.map { ($0, r.toName ?? "") }, me: (r.name, r.photoUrl), clientId: r.id)
    }

    /// Changes the text of one of mine. Shown at once; the old text comes back if the server says no.
    func edit(_ id: String, thread: String?, text: String) async -> Bool {
        guard let old = find(id, thread: thread) else { return false }
        pendingEdits[id] = text
        update(id, thread: thread) { $0.text = text; $0.edited = true }
        var a: [String: Any] = ["text": text]
        if let t = thread { a["rid"] = t; a["aid"] = id } else { a["rid"] = id }
        do {
            let res = try await fn.httpsCallable("editReply").call(args(a))
            if pendingEdits[id] == text { pendingEdits[id] = nil }
            // The server's copy of the row, when it sends one (its text is the one that counts).
            if let d = (res.data as? [String: Any])?["reply"] as? [String: Any], let saved = PostReply(d) {
                update(id, thread: thread) { r in r.text = saved.text; r.edited = true }
            }
            return true
        } catch {
            if pendingEdits[id] == text { pendingEdits[id] = nil }
            update(id, thread: thread) { $0.text = old.text; $0.edited = old.edited }
            notice = Self.serverMessage(error) ?? "Couldn't edit the reply."
            return false
        }
    }

    /// A short line for the sheet's toast (the server's own words for a refusal it explains).
    var notice: String?

    /// The server's message for a refusal it explains ("Too late to edit.", "This reply can't take
    /// answers."): failed-precondition errors only, everything else gets our own words.
    static func serverMessage(_ error: Error) -> String? {
        let ns = error as NSError
        guard ns.domain == FunctionsErrorDomain, ns.code == FunctionsErrorCode.failedPrecondition.rawValue else { return nil }
        let m = ns.localizedDescription
        return m.isEmpty ? nil : m
    }

    func discard(_ r: PostReply, thread: String?) {
        if let t = thread { answers[t]?.removeAll { $0.id == r.id } } else { threads.removeAll { $0.id == r.id } }
    }

    private func replace(_ id: String, with saved: PostReply, thread: String?) {
        if let t = thread {
            if let i = answers[t]?.firstIndex(where: { $0.id == id }) { answers[t]?[i] = saved }
        } else if let i = threads.firstIndex(where: { $0.id == id }) {
            threads[i] = saved
        }
    }

    private func mark(_ id: String, thread: String?, _ s: PostReply.Send) {
        if let t = thread {
            if let i = answers[t]?.firstIndex(where: { $0.id == id }) { answers[t]?[i].send = s }
        } else if let i = threads.firstIndex(where: { $0.id == id }) {
            threads[i].send = s
        }
    }

    private func update(_ id: String, thread: String?, _ change: (inout PostReply) -> Void) {
        if let t = thread {
            if let i = answers[t]?.firstIndex(where: { $0.id == id }) { change(&answers[t]![i]) }
        } else if let i = threads.firstIndex(where: { $0.id == id }) {
            change(&threads[i])
        } else if pinned?.id == id {
            change(&pinned!)
        }
    }

    /// A double tap: a heart, or mine taken back (the chat's quick reaction).
    func toggleLike(_ r: PostReply, thread: String?) {
        react(r, emoji: r.my.isEmpty ? QuickReaction.current : r.my, thread: thread)
    }

    /// Mine becomes `emoji` ("" takes it back); the same emoji again takes it back, as in the chat.
    /// One call in flight per reply; picks meanwhile only change what is wanted, sent when it returns.
    func react(_ r: PostReply, emoji: String, thread: String?) {
        guard r.send == .sent else { return }
        let want = emoji == r.my ? "" : emoji
        if confirmedMine[r.id] == nil { confirmedMine[r.id] = r.my }
        update(r.id, thread: thread) { $0.setMine(want) }
        pendingLikes[r.id] = want
        if !want.isEmpty { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        guard !likeInFlight.contains(r.id) else { return }
        likeInFlight.insert(r.id)
        Task { await flushLike(r.id, thread: thread) }
    }

    /// What the server last agreed mine was, per reply, so a failed call puts it back.
    private var confirmedMine: [String: String] = [:]

    private func flushLike(_ id: String, thread: String?) async {
        while let want = pendingLikes[id] {
            var a: [String: Any] = ["on": !want.isEmpty]
            if !want.isEmpty { a["emoji"] = want }
            if let t = thread { a["rid"] = t; a["aid"] = id } else { a["rid"] = id }
            let ok = (try? await fn.httpsCallable("likeReply").call(args(a))) != nil
            if pendingLikes[id] == want {
                pendingLikes[id] = nil
                if ok { confirmedMine[id] = nil }
                else if let back = confirmedMine.removeValue(forKey: id) { update(id, thread: thread) { $0.setMine(back) } }
            } else if ok {
                confirmedMine[id] = want
            }
        }
        likeInFlight.remove(id)
    }

    func delete(_ r: PostReply, thread: String?) async {
        deletedIds.insert(r.id)
        let threadsBefore = threads, answersBefore = answers[thread ?? ""]
        let wasPinned = thread == nil && pinned?.id == r.id ? pinned : nil
        if let t = thread {
            answers[t]?.removeAll { $0.id == r.id }
            update(t, thread: nil) { $0.answers = max(0, $0.answers - 1) }
        } else {
            threads.removeAll { $0.id == r.id }
            answers[r.id] = nil
            if wasPinned != nil { pinned = nil; Self.pinCache[mid] = nil }   // the server unpins it too
        }
        var a: [String: Any] = [:]
        if let t = thread { a["rid"] = t; a["aid"] = r.id } else { a["rid"] = r.id }
        do {
            let res = try await fn.httpsCallable("deleteReply").call(args(a))
            let removed = ((res.data as? [String: Any])?["removed"] as? NSNumber)?.intValue ?? 0
            count = max(0, count - removed)
        } catch {
            deletedIds.remove(r.id)
            if let t = thread { update(t, thread: nil) { $0.answers += 1 } }
            if let p = wasPinned { pinned = p; Self.pinCache[mid] = p; return }
            // Only the one row comes back, never a whole saved list over newer arrivals.
            if let t = thread, let before = answersBefore, let row = before.first(where: { $0.id == r.id }) {
                answers[t, default: []].append(row)
                answers[t]?.sort { $0.at < $1.at }
            } else if thread == nil, let row = threadsBefore.first(where: { $0.id == r.id }) {
                // Back in its old place for Top, in time order for Newest.
                if sort == .top, let i = threadsBefore.firstIndex(where: { $0.id == r.id }) {
                    threads.insert(row, at: min(i, threads.count))
                } else {
                    threads = placed(threads + [row])
                }
            }
        }
    }

    /// Pins a thread at the top (owner, or admins who change channel info). At once; put back on failure.
    func pin(_ r: PostReply) async -> Bool {
        let before = pinned
        setPinned(r)
        guard (try? await fn.httpsCallable("pinReply").call(args(["rid": r.id]))) != nil else {
            setPinned(before)
            if !threads.contains(where: { $0.id == r.id }) { threads = placed(threads + [r]) }
            return false
        }
        return true
    }

    func unpin() async -> Bool {
        guard let before = pinned else { return true }
        setPinned(nil)
        guard (try? await fn.httpsCallable("pinReply").call(args(["rid": ""]))) != nil else {
            setPinned(before)
            return false
        }
        return true
    }

    /// Who wrote one reply, for a tap on its photo or name. Moderators already have it on the row.
    /// nil: not found, or a Creator reply (that one opens the channel).
    func author(_ r: PostReply, thread: String?) async -> String? {
        if let u = r.uid, !u.isEmpty { return u }
        var a: [String: Any] = [:]
        if let t = thread { a["rid"] = t; a["aid"] = r.id } else { a["rid"] = r.id }
        guard let res = try? await fn.httpsCallable("replyAuthor").call(args(a)),
              let u = (res.data as? [String: Any])?["uid"] as? String, !u.isEmpty else { return nil }
        return u
    }

    func report(_ r: PostReply, thread: String?, reason: String) async -> Bool {
        var a: [String: Any] = ["reason": reason]
        if let t = thread { a["rid"] = t; a["aid"] = r.id } else { a["rid"] = r.id }
        return (try? await fn.httpsCallable("reportReply").call(args(a))) != nil
    }

    func ban(_ r: PostReply, thread: String?, all: Bool) async -> Bool {
        var a: [String: Any] = ["all": all]
        if let t = thread { a["rid"] = t; a["aid"] = r.id } else { a["rid"] = r.id }
        guard (try? await fn.httpsCallable("banReplier").call(args(a))) != nil else { return false }
        await refreshNewest()
        return true
    }

    @discardableResult
    func setOff(post: Bool, off newValue: Bool) async -> Bool {
        var a: [String: Any] = ["cid": cid, "off": newValue]
        if post { a["mid"] = mid }
        guard (try? await fn.httpsCallable("setReplies").call(a)) != nil else { return false }
        await loadFirst()
        return true
    }

    func setAlerts(on: Bool) async {
        _ = try? await fn.httpsCallable("setReplyAlerts").call(["cid": cid, "on": on])
    }
}

/// ⛔ REPLIES AND QUOTES UNDER A CHANNEL POST (owner 2026-11-06). A sheet with two tabs, opening on
/// Replies. Replies are bubbles with the person's photo beside them, their name and age above; a
/// heart on each (tap it, or double-tap the bubble); answers gathered under a reply behind
/// "View N replies". Turning replies off makes the thread read-only; it stays readable.
struct PostThreadSheet: View {
    enum Tab: Hashable { case replies, quotes }

    let cid: String
    let mid: String
    let post: Message?
    /// Replies off for this post or the whole channel: the sheet is Quotes only (owner 2026-11-07).
    var repliesOff: Bool = false
    var sourceTitle: String
    var sourcePhoto: String?
    var sourceVerified: Bool
    var picture: () async -> UIImage?
    var onOpen: (QuotedInItem) -> Void
    var startTab: Tab = .replies
    /// The channel turned Quotes off: no Quotes tab at all (owner 2026-11-07).
    var quotesOff: Bool = false
    /// This post's replies switch changed here: the chat updates the post at once (owner 2026-11-07).
    var onPostRepliesChanged: (Bool) -> Void = { _ in }
    /// A tap on a reply's photo or name: that person's profile (uid, name), or the channel's own page
    /// for a Creator reply. The chat closes this sheet first, then opens it.
    var onOpenPerson: (String, String) -> Void = { _, _ in }
    var onOpenChannel: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .replies
    @State private var model: RepliesModel
    @State private var answering: ReplyTarget?
    @State private var editing: ReplyEdit?
    @State private var reporting: (PostReply, String?)?
    @State private var reportSheet: ReportTarget?   // the report sheet (2026-11-08)
    @State private var quickReport: ReportTarget?   // a reply's one-step report (2026-11-08)
    @State private var banning: (PostReply, String?)?
    @State private var toast: String?
    @State private var quotesShown = false
    /// Replies off right now: what the chat said at open, then whatever the server says (a switch
    /// flipped inside this sheet shows or hides the Replies tab and the field at once).
    @State private var offNow = false

    init(cid: String, mid: String, post: Message?, repliesOff: Bool = false, sourceTitle: String, sourcePhoto: String?,
         sourceVerified: Bool, picture: @escaping () async -> UIImage?, onOpen: @escaping (QuotedInItem) -> Void,
         startTab: Tab = .replies, quotesOff: Bool = false) {
        self.cid = cid
        self.quotesOff = quotesOff
        self.mid = mid
        self.post = post
        self.repliesOff = repliesOff
        let first: Tab = quotesOff ? .replies : (repliesOff ? .quotes : startTab)
        self.sourceTitle = sourceTitle
        self.sourcePhoto = sourcePhoto
        self.sourceVerified = sourceVerified
        self.picture = picture
        self.onOpen = onOpen
        self.startTab = first
        _tab = State(initialValue: first)
        _quotesShown = State(initialValue: first == .quotes)
        _offNow = State(initialValue: repliesOff)
        _model = State(initialValue: RepliesModel(cid: cid, mid: mid))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // ⛔ A COMMENTS SHEET'S TOP (owner 2026-11-07, his reference picture): no channel card, no
                // segmented control, no Done. Two underlined word tabs on the left, a round 40pt X on
                // the right; the admin's ... sits beside the X.
                topBar
                // Both tabs stay built once shown, so switching back does not load them again.
                ZStack {
                    repliesTab.opacity(tab == .replies ? 1 : 0).allowsHitTesting(tab == .replies)
                    if quotesShown {
                        QuotesPage(cid: cid, mid: mid, post: post, sourceTitle: sourceTitle, sourcePhoto: sourcePhoto,
                                   sourceVerified: sourceVerified, picture: picture, onOpen: onOpen, embedded: true)
                            .opacity(tab == .quotes ? 1 : 0).allowsHitTesting(tab == .quotes)
                    }
                }
                .clipped()   // nothing of a tab draws over the tab row (owner 2026-11-07)
            }
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .top) { toastView }
        }
        // ⛔ 65% AND ONLY 65% (owner 2026-11-07, twice: a scroll made it full, then tapping the reply
        // field made it full). With a taller size on offer the system takes it when the keyboard comes
        // up; with one size the sheet stays and the field rides above the keyboard.
        .presentationDetents([.fraction(0.70)])   // 70% (owner 2026-11-07, was 65)
        .presentationContentInteraction(.scrolls)
        .presentationDragIndicator(.visible)
        .onChange(of: tab) { _, t in
            if t == .quotes {
                quotesShown = true
                // The field is on the Replies tab: the keyboard goes with it (2026-11-06 audit).
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }
        // The server says replies are off while Replies is open: over to Quotes, the only tab left.
        .onChange(of: model.off) { _, off in offNow = off }
        .onChange(of: model.flagsLoaded) { _, l in if l { offNow = model.off } }
        // Off: Quotes is the only tab left. Turned on again: back to Replies, where the field is.
        .onChange(of: offNow) { was, off in
            if off && !quotesOff { tab = .quotes } else if was { tab = .replies }
        }
        .onAppear {
            model.start()
            // A reply alert tapped: this post's thread, then the answer it was about.
            if let t = AppRouter.shared.pendingReplyTarget, t.mid == mid {
                AppRouter.shared.pendingReplyTarget = nil
                if Date().timeIntervalSince(t.at) < 60 {
                    tab = .replies
                    Task { await model.focus(rid: t.rid, aid: t.aid) }
                }
            }
        }
        .onDisappear { model.stop() }
        .onChange(of: model.notice) { _, m in
            guard let m else { return }
            model.notice = nil
            show(m)
        }
        // `presenting:` hands each button the item itself (2026-11-06 audit: reading the state in the
        // action could find it already cleared by the dialog closing).
        // The system alert in the middle of the screen, not a popover over the row (owner 2026-11-07).
        // The report sheet (owner 2026-11-08) replaced the reason alert: `reportContent` kind "reply",
        // which runs reportReply's own code on the server (one per person, the hold at 3).
        .sheet(item: $reportSheet) { ReportSheet(target: $0) }
        .alert("Report this reply?", isPresented: Binding(get: { quickReport != nil },
                                                          set: { if !$0 { quickReport = nil } })) {
            Button("Cancel", role: .cancel) { quickReport = nil }
            Button("Report", role: .destructive) {
                if let t = quickReport { sendQuickReport(t) }
                quickReport = nil
            }
        }
        .alert("Remove this person?", isPresented: banningShown, presenting: banning) { item in
            Button("Delete and Ban", role: .destructive) { Task { show(await model.ban(item.0, thread: item.1, all: false) ? "Removed and banned." : "Couldn't do that.") } }
            Button("Ban and Delete All Their Replies", role: .destructive) { Task { show(await model.ban(item.0, thread: item.1, all: true) ? "Banned. Their replies are gone." : "Couldn't do that.") } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("They leave the channel and can't come back or reply.")
        }
    }

    private static let reasons: [(String, String)] = [
        ("spam", "Spam"), ("abuse", "Harassment or bullying"), ("hate", "Hate speech"),
        ("sexual", "Sexual content"), ("violence", "Violence"), ("other", "Something else"),
    ]

    private var reportingShown: Binding<Bool> { Binding(get: { reporting != nil }, set: { if !$0 { reporting = nil } }) }
    /// Opens the report sheet for a reply. A Creator reply is the channel's own voice, so it offers
    /// no Block.
    /// ⛔ A REPLY IS REPORTED IN ONE STEP (owner 2026-11-08: "it's a text comment, I don't need
    /// those options"): no reasons list, one "Report this reply?" and it is sent, filed as
    /// "other", the moderators read the words themselves. The full sheet stays for everything else.
    private func openReport(_ r: PostReply, _ thread: String?) {
        let person = r.creator ? "" : (r.uid ?? "")
        quickReport = ReportTarget(kind: .reply, targetId: thread ?? r.id, cid: cid, mid: mid,
                                   aid: thread == nil ? "" : r.id, personUid: person, name: r.name)
    }

    private func sendQuickReport(_ t: ReportTarget) {
        Task { @MainActor in
            do {
                try await ReportService.submit(t, category: "other", sub: nil, note: "", block: false, shareText: false)
                show("Reported. Thanks for letting us know.")
            } catch {
                show(error.localizedDescription)
            }
        }
    }
    private var banningShown: Binding<Bool> { Binding(get: { banning != nil }, set: { if !$0 { banning = nil } }) }

    private func show(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if toast == text { withAnimation { toast = nil } }
        }
    }

    @ViewBuilder private var toastView: some View {
        if let toast {
            Text(toast).font(.footnote.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// "Replies  Quotes" with a line under the open one, then the admin's ... and the X.
    private var topBar: some View {
        HStack(alignment: .center, spacing: 24) {
            // Replies off (here or found off by the server): no Replies tab, Quotes alone.
            // With Quotes off too, Replies stays (read-only): something has to be shown.
            // With the count (owner 2026-11-08: "show count comments"), as the post's own row says it.
            if !offNow || quotesOff { tabButton(repliesTitle, .replies) }
            if !quotesOff { tabButton("Quotes", .quotes) }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                if model.may.settings || model.may.del {
                    adminMenu
                }
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 40, height: 40)
                        .background(Color(.tertiarySystemFill), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
        }
        .padding(.leading, 20).padding(.trailing, 16)
        .padding(.top, 18).padding(.bottom, 6)
    }

    private var repliesTitle: String {
        let n = model.count
        if n <= 0 { return "Replies" }
        return n == 1 ? "1 Reply" : "\(n.formatted()) Replies"
    }

    private func tabButton(_ title: String, _ t: Tab) -> some View {
        let on = tab == t
        return Button { tab = t } label: {
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 17, weight: on ? .bold : .regular))
                    .foregroundStyle(on ? Color.primary : Color.secondary)
                Capsule()
                    .fill(on ? Color.primary : Color.clear)
                    .frame(height: 2.5)
            }
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    // MARK: Replies

    private enum Item: Identifiable {
        case older
        case pinnedLabel
        case thread(PostReply)
        case answer(PostReply, String)
        case toggle(String, Int, Bool)
        case moreAnswers(String)
        /// "View N more replies": the rest of an open thread past its first three.
        case revealMore(String, Int)
        var id: String {
            switch self {
            case .older: return "older"
            case .pinnedLabel: return "pinned"
            case .thread(let r): return "t-\(r.id)"
            case .answer(let r, _): return "a-\(r.id)"
            case .toggle(let t, _, _): return "g-\(t)"
            case .moreAnswers(let t): return "m-\(t)"
            case .revealMore(let t, _): return "r-\(t)"
            }
        }
    }

    /// The list as one flat run of rows (lazy all the way down, a long thread included).
    private var items: [Item] {
        var out: [Item] = []
        // The pinned thread first, under a small "Pinned" line, then the rest (owner 2026-11-07).
        if let p = model.pinned { out.append(.pinnedLabel); appendThread(p, to: &out) }
        // Top: the server's order. Newest: newest at the top. Either way more load at the bottom.
        let list = model.sort == .new ? Array(model.threads.reversed()) : model.threads
        // Mine from this visit first (newest first), then the rest in their order. ⛔ NEVER ABOVE OR
        // IN PLACE OF THE PINNED REPLY (owner 2026-11-08): the pinned one is drawn above all of this,
        // untouched, and is never repeated here even when it is one of mine.
        let top = model.mineOnTop
        var shown = Set<String>()
        if let p = model.pinned { shown.insert(p.id) }
        for id in top { if let r = list.first(where: { $0.id == id }), shown.insert(r.id).inserted { appendThread(r, to: &out) } }
        for r in list where !shown.contains(r.id) { appendThread(r, to: &out) }
        if !model.olderCursor.isEmpty { out.append(.older) }
        return out
    }

    private func appendThread(_ r: PostReply, to out: inout [Item]) {
            out.append(.thread(r))
            let loaded = model.answers[r.id] ?? []
            let total = max(r.answers, loaded.count)
            guard total > 0 else { return }
            let open = model.openThreads.contains(r.id)
            if open {
                // Five, then "View N more replies" adds five more each tap (a long thread stays short).
                let cap = model.expandedAll.contains(r.id)
                    ? Int.max : (model.shownAnswers[r.id] ?? RepliesModel.answerStep)
                if total > cap {
                    for a in loaded.prefix(cap) { out.append(.answer(a, r.id)) }
                    out.append(.revealMore(r.id, total - min(cap, loaded.count)))
                } else {
                    for a in loaded { out.append(.answer(a, r.id)) }
                    if !(model.answerNext[r.id] ?? "").isEmpty { out.append(.moreAnswers(r.id)) }
                }
            }
            out.append(.toggle(r.id, total, open))
    }

    /// Where new replies land: the bottom for Top, the top for Newest.
    private func edgeSeen(top: Bool, seen: Bool) {
        guard top == (model.sort == .new) else { return }
        model.atEnd = seen
        if seen { model.unseenNew = 0 }
    }

    /// "Top" and "Newest", small, over the list. Hidden until there is something to sort.
    @ViewBuilder private var sortBar: some View {
        if model.loaded || model.sort != .top, !model.threads.isEmpty || model.pinned != nil || model.sort != .top {
            HStack(spacing: 6) {
                sortChip("Top", .top)
                sortChip("Newest", .new)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 2)
        }
    }

    private func sortChip(_ title: String, _ s: RepliesModel.Sort) -> some View {
        let on = model.sort == s
        return Button { model.setSort(s) } label: {
            Text(title)
                .font(.system(size: 13, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Color.primary : Color.secondary)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(on ? Color(.tertiarySystemFill) : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private var repliesTab: some View {
        VStack(spacing: 0) {
            sortBar
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 1).id("start")
                            .onAppear { edgeSeen(top: true, seen: true) }
                            .onDisappear { edgeSeen(top: true, seen: false) }
                        ForEach(items) { item in itemView(item).id(item.id) }
                        Color.clear.frame(height: 6).id("end")
                            .onAppear { edgeSeen(top: false, seen: true) }
                            .onDisappear { edgeSeen(top: false, seen: false) }
                    }
                    .padding(.top, 4)
                }
                // Always opens at the top, on the first replies (owner 2026-11-07, twice); the newest are a
                // scroll away, and new ones arriving below do not pull the list down (the "new" pill does).
                .defaultScrollAnchor(.top, for: .alignment)
                .defaultScrollAnchor(.top, for: .initialOffset)
                .defaultScrollAnchor(.top, for: .sizeChanges)
                .scrollDismissesKeyboard(.interactively)
                .overlay { repliesOverlay }
                .overlay(alignment: .bottom) { newPill(proxy) }
                .onChange(of: model.scrollTarget) { _, id in
                    guard let id else { return }
                    let isThread = model.threads.contains(where: { $0.id == id }) || model.pinned?.id == id
                    let key = isThread ? "t-\(id)" : "a-\(id)"
                    // A new reply sits at the top for Newest, at the bottom for Top.
                    // My new reply sits at the top now (`mineOnTop`), so the list goes up to it.
                    let anchor: UnitPoint = isThread ? .top : .bottom
                    model.scrollTarget = nil
                    // After the new row is laid out, not in the same pass that added it.
                    Task { @MainActor in
                        await Task.yield()
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(key, anchor: anchor) }
                        // ⛔ AGAIN ONCE THE KEYBOARD IS DOWN (owner 2026-11-08: after Send my reply sat
                        // behind the field). Send closes the keyboard and the sheet settles back to its
                        // smaller size; the list keeps its top (`.sizeChanges` anchor), so the row it had
                        // just shown at the bottom went under the composer.
                        try? await Task.sleep(nanoseconds: 450_000_000)
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(key, anchor: anchor) }
                    }
                }
                // A tapped "@name" or a reply alert: that row to the middle (it flashes meanwhile).
                .onChange(of: model.jump) { _, key in
                    guard let key else { return }
                    model.jump = nil
                    Task { @MainActor in
                        await Task.yield()
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(key, anchor: .center) }
                    }
                }
                // A new sort opens at the top.
                .onChange(of: model.sort) { _, _ in proxy.scrollTo("start", anchor: .top) }
            }
            // Off as the post already says, from the first frame (owner 2026-11-07: the field showed for
            // a second, then turned into the off line when the server answered).
            ReplyComposer(off: offNow, loaded: model.loaded, answering: $answering, editing: $editing,
                          onSend: { text, target in
                              let me = ProfileStore.shared.me
                              let to = target?.to.map { (id: $0, name: target?.name ?? "") }
                              model.send(text, thread: target?.thread, to: to, me: (me?.name ?? "You", me?.photoUrl ?? ""))
                          },
                          onEdit: { e, text in
                              Task { _ = await model.edit(e.id, thread: e.thread, text: text) }   // a refusal shows via notice
                          })
        }
    }

    @ViewBuilder private func newPill(_ proxy: ScrollViewProxy) -> some View {
        if model.unseenNew > 0 {
            let up = model.sort == .new
            Button {
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(up ? "start" : "end", anchor: up ? .top : .bottom) }
                model.unseenNew = 0
            } label: {
                Label("\(model.unseenNew) new \(model.unseenNew == 1 ? "reply" : "replies")", systemImage: up ? "arrow.up" : "arrow.down")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder private func itemView(_ item: Item) -> some View {
        switch item {
        case .older:
            Button { Task { await model.loadOlder() } } label: {
                Text(model.loadingOlder ? "Loading…" : (model.sort == .new ? "Show earlier replies" : "Show more replies"))
                    .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .buttonStyle(.plain)
        case .pinnedLabel:
            Label("Pinned", systemImage: "pin.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.leading, 16 + 40 + 10 + 14).padding(.top, 8)
                .accessibilityLabel("Pinned reply")
        case .thread(let r):
            // A line runs down from the photo when the reply has answers (shown or not yet).
            let hasAnswers = r.answers > 0 || !(model.answers[r.id] ?? []).isEmpty
            ReplyRow(reply: r, small: false, actions: actions(r, thread: nil), line: hasAnswers ? .below : .none)
                .background(flashFill(r.id))
        case .answer(let r, let t):
            ReplyRow(reply: r, small: true, actions: actions(r, thread: t), line: .answer)
                .padding(.leading, ReplyThreadLine.answerIndent)
                .background(flashFill(r.id))
        case .revealMore(let t, let n):
            Button { withAnimation(.easeInOut(duration: 0.2)) { model.revealMoreAnswers(t) } } label: {
                Text("View \(n) more \(n == 1 ? "reply" : "replies")")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.leading, 108).padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .leading) {   // the thread line passes by
                Rectangle().fill(ReplyThreadLine.color).frame(width: 1.5)
                    .padding(.leading, ReplyThreadLine.parentX - 0.75)
            }
        case .toggle(let t, let n, let open):
            Button { withAnimation(.easeInOut(duration: 0.2)) { model.toggleThread(t) } } label: {
                HStack(spacing: 8) {
                    Color.clear.frame(width: 20, height: 1)
                    Text(open ? (model.answersLoading.contains(t) ? "Loading…" : "Hide replies")
                              : "View \(n) \(n == 1 ? "reply" : "replies")")
                        .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                }
                // The thread line ends here, curving in from the parent photo's line.
                .background(alignment: .leading) {
                    GeometryReader { g in
                        ReplyThreadLine.toggleElbow(height: g.size.height)
                            .stroke(ReplyThreadLine.color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    }
                    .allowsHitTesting(false)
                }
            }
            .buttonStyle(.plain)
            .padding(.leading, 62).padding(.bottom, 10)
        case .moreAnswers(let t):
            Button { Task { await model.loadAnswers(t, more: true) } } label: {
                Text("Show more replies").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.leading, 108).padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .leading) {   // the thread line passes by
                Rectangle().fill(ReplyThreadLine.color).frame(width: 1.5)
                    .padding(.leading, ReplyThreadLine.parentX - 0.75)
            }
        }
    }

    /// The short background flash on a row brought into view.
    private func flashFill(_ id: String) -> some View {
        Color.accentColor.opacity(model.flash == id ? 0.14 : 0)
            .animation(.easeInOut(duration: 0.3), value: model.flash == id)
            .allowsHitTesting(false)
    }

    /// Editing is open for 15 minutes after a reply is sent (the server holds the same limit).
    private static let editWindow: TimeInterval = 15 * 60

    private func actions(_ r: PostReply, thread: String?) -> ReplyRow.Actions {
        ReplyRow.Actions(
            like: { model.toggleLike(r, thread: thread) },
            react: { e in model.react(r, emoji: e, thread: thread) },
            // On an answer, the send also says which answer it answers ("@name" on the new one).
            reply: model.off ? nil : {
                editing = nil
                answering = ReplyTarget(thread: thread ?? r.id, name: r.name, to: thread == nil ? nil : r.id)
            },
            edit: (r.mine && r.send == .sent && !model.off && Date().timeIntervalSince(r.at) < Self.editWindow) ? {
                guard Date().timeIntervalSince(r.at) < Self.editWindow else { show("Replies can be edited for 15 minutes."); return }
                answering = nil
                editing = ReplyEdit(id: r.id, thread: thread, text: r.text)
            } : nil,
            mention: (thread != nil && r.toId != nil) ? {
                if let to = r.toId, let t = thread { Task { await model.jumpTo(to, inThread: t) } }
            } : nil,
            delete: r.canDelete ? { Task { await model.delete(r, thread: thread) } } : nil,
            report: r.mine ? nil : { openReport(r, thread) },
            ban: (model.may.ban && !r.mine) ? { banning = (r, thread) } : nil,
            retry: r.send == .failed ? { model.retry(r, thread: thread) } : nil,
            discard: r.send == .failed ? { model.discard(r, thread: thread) } : nil,
            pin: (model.may.settings && thread == nil && r.send == .sent) ? {
                let on = model.pinned?.id == r.id
                Task {
                    let ok = on ? await model.unpin() : await model.pin(r)
                    show(ok ? (on ? "Reply unpinned." : "Reply pinned.") : "Couldn't do that.")
                }
            } : nil,
            pinned: thread == nil && model.pinned?.id == r.id,
            openAuthor: r.send == .sent && (!r.mine || r.creator) ? { openAuthor(r, thread: thread) } : nil)
    }

    /// Photo or name tapped: the chat closes the sheet, then opens the person (or the channel).
    private func openAuthor(_ r: PostReply, thread: String?) {
        if r.creator { onOpenChannel(); return }
        Task {
            guard let uid = await model.author(r, thread: thread) else { show("Couldn't open this profile."); return }
            onOpenPerson(uid, r.name)
        }
    }

    @ViewBuilder private var repliesOverlay: some View {
        if model.failed && model.threads.isEmpty && model.pinned == nil {
            ContentUnavailableView {
                Label("Couldn't load replies", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Try Again") { Task { await model.loadFirst() } }
            }
        } else if !model.loaded && model.threads.isEmpty && model.pinned == nil {
            // The loading shapes only over an empty sheet, never over replies already drawn.
            RepliesSkeleton()
        } else if model.threads.isEmpty && model.pinned == nil {
            // The owner's comment icon, the one on the Reply bar, and smaller words than the system's
            // empty view (owner 2026-11-07: "this text looks big").
            VStack(spacing: 6) {
                Image("ic_reply_comment")
                    .renderingMode(.template)
                    .resizable().scaledToFit()
                    .frame(width: 40, height: 40)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
                Text(model.off ? "Replies are off" : "No replies yet")
                    .font(.system(size: 15, weight: .semibold))
                Text(model.off ? "The channel turned off replies for this post." : "Be the first to reply.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        }
    }

    private var adminMenu: some View {
        Menu {
            if model.may.settings {
                Button {
                    let want = !model.postOff
                    Task { if await model.setOff(post: true, off: want) { onPostRepliesChanged(want) } }
                } label: {
                    if model.postOff {
                        Label("Turn On Replies for This Post", image: "ic_reply_comment")   // owner's icon
                    } else {
                        Label("Turn Off Replies for This Post", systemImage: "nosign")
                    }
                }
            }
            // The summaries go to admins who can delete messages; others have nothing to switch.
            if model.may.del {
                Menu("Reply Alerts") {
                    Button("On") { Task { await model.setAlerts(on: true); show("Reply alerts on.") } }
                    Button("Off") { Task { await model.setAlerts(on: false); show("Reply alerts off.") } }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 40, height: 40)
                .background(Color(.tertiarySystemFill), in: Circle())
                .accessibilityLabel("Reply settings")
        }
    }
}

/// One reply: photo, name and age above a bubble, a heart and Reply under it.
private struct ReplyRow: View {
    struct Actions {
        var like: () -> Void
        /// Mine becomes this emoji, or comes off when it already is (the chat's react bar and pills).
        var react: (String) -> Void = { _ in }
        var reply: (() -> Void)?
        /// Mine, within 15 minutes of sending.
        var edit: (() -> Void)?
        /// A tap on the "@name" before the text: the answer it answers.
        var mention: (() -> Void)?
        var delete: (() -> Void)?
        var report: (() -> Void)?
        var ban: (() -> Void)?
        var retry: (() -> Void)?
        var discard: (() -> Void)?
        /// Pin or unpin (owner and info admins, threads only); `pinned` says which it is now.
        var pin: (() -> Void)?
        var pinned = false
        var openAuthor: (() -> Void)?
    }

    let reply: PostReply
    let small: Bool
    let actions: Actions
    /// The thread line this row draws (owner 2026-11-07, his reference picture).
    var line: ReplyThreadLine = .none

    // ⛔ THE CHAT'S REACTION PILL, NOT A HEART BUTTON (owner 2026-11-07: "make it like how bubble
    // react works in my app"). A double tap on the bubble reacts; a pill shows each emoji and count,
    // mine the dark filled one, and a tap on it takes mine back or adds it.
    @ViewBuilder private var pills: some View {
        ForEach(Self.shownPills(reply), id: \.emoji) { r in
            let mine = r.emoji == reply.my
            Button { actions.react(r.emoji) } label: {
                HStack(spacing: 4) {
                    Text(r.emoji).font(.system(size: 14))
                    Text(r.count.formatted())
                        .font(.system(size: 13, weight: .semibold))
                        .contentTransition(.numericText())
                }
                .foregroundStyle(mine ? Color(.systemBackground) : Color.primary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(mine ? Color(.label) : Color(.tertiarySystemFill), in: Capsule())
            }
            .accessibilityLabel("\(r.emoji) \(r.count)\(mine ? ", yours" : "")")
            .transition(.scale.combined(with: .opacity))
        }
    }

    @ViewBuilder private func replyButton(lead: CGFloat) -> some View {
        if let r = actions.reply {
            Button(action: r) { Text("Reply").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                .padding(.leading, lead)
        }
    }

    @ViewBuilder private var heldNote: some View {
        if reply.held {
            Text("Hidden after reports").font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// At most four pills on a reply (owner 2026-11-07), the most used first; mine always stays in
    /// view, taking the fourth place when it is not among the top four.
    static func shownPills(_ r: PostReply) -> [PostReply.Reaction] {
        var out = Array(r.rx.prefix(4))
        if !r.my.isEmpty, !out.contains(where: { $0.emoji == r.my }),
           let mine = r.rx.first(where: { $0.emoji == r.my }), !out.isEmpty {
            out[out.count - 1] = mine
        }
        return out
    }

    var body: some View {
        // His reference picture (owner 2026-11-07): name and age over the bubble, the photo beside
        // the bubble's middle, the heart and Reply under it.
        let side: CGFloat = small ? 28 : 40
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(reply.name).font(.footnote.weight(.semibold)).lineLimit(1)
                    .onTapGesture { actions.openAuthor?() }
                if reply.verified {
                    Image(systemName: "checkmark.seal.fill").font(.caption2).foregroundStyle(.blue)
                }
                if reply.creator {
                    Text("Creator")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                // ⛔ "JAYZ ▸ SALMO" (owner 2026-11-08, his reference): an answer to another answer
                // names who it answers in the name line, not as "@name" in the words. A tap goes to
                // that answer, as the "@name" did.
                if let to = reply.toName, !to.isEmpty {
                    Image(systemName: "arrowtriangle.right.fill")
                        .font(.system(size: 7)).foregroundStyle(.secondary)
                    Text(to).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                        .onTapGesture { actions.mention?() }
                }
                Text(Self.age(reply.at)).font(.footnote).foregroundStyle(.secondary)
                if reply.edited {
                    Text("· edited").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, side + 10 + 14)
            // The photo stays at the top beside the name, even when the words run long (owner 2026-11-07).
            HStack(alignment: .top, spacing: 10) {
                AvatarView(name: reply.name, photoUrl: reply.photoUrl.isEmpty ? nil : reply.photoUrl, size: side)
                    .avatarSquircle(reply.creator)   // the channel's photo, shaped as channels are
                    .accessibilityHidden(true)
                    .onTapGesture { actions.openAuthor?() }
                    .anchorPreference(key: ReplyAvatarBounds.self, value: .bounds) { $0 }
                bodyText
                    .font(small ? .subheadline : .body)
                    .environment(\.openURL, OpenURLAction { url in
                        guard url.scheme == Self.mentionScheme else { return .systemAction }
                        actions.mention?()
                        return .handled
                    })
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .opacity(reply.held || reply.send != .sent ? 0.55 : 1)
                    .onTapGesture(count: 2) { if reply.send == .sent { actions.like() } }
                    .contextMenu { menu }
                Spacer(minLength: 24)
            }
            footer
                .padding(.leading, side + 10 + 8).padding(.top, 2)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        // Drawn from where the photo really is, so a reply of several lines still lines up.
        .overlayPreferenceValue(ReplyAvatarBounds.self) { a in
            GeometryReader { g in
                if let a, line != .none {
                    ReplyThreadLine.path(line, avatar: g[a], height: g.size.height)
                        .stroke(ReplyThreadLine.color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
            .allowsHitTesting(false)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(reply.name), \(reply.toName.map { "to \($0), " } ?? "")\(reply.text), \(Self.spokenAge(reply.at))\(reply.edited ? ", edited" : "")\(reply.likes > 0 ? ", \(reply.likes) likes" : "")")
        .accessibilityActions {
            if reply.send == .sent { Button(reply.liked ? "Unlike" : "Like") { actions.like() } }
            if let r = actions.reply { Button("Reply", action: r) }
            if let m = actions.mention { Button("Go to the Reply It Answers", action: m) }
            if let e = actions.edit { Button("Edit", action: e) }
            if let o = actions.openAuthor { Button(reply.creator ? "Open Channel" : "Open Profile", action: o) }
            if let p = actions.pin { Button(actions.pinned ? "Unpin" : "Pin", action: p) }
            if let r = actions.retry { Button("Retry", action: r) }
            if let d = actions.delete { Button("Delete", action: d) }
            if let r = actions.report { Button("Report", action: r) }
        }
    }

    private static let mentionScheme = "fariin-reply-to"

    /// The words alone: who an answer answers is in the name line now ("Jayz ▸ Salmo", 2026-11-08).
    private var bodyText: Text { Text(reply.text) }

    @ViewBuilder private var footer: some View {
        switch reply.send {
        case .sending:
            Text("Sending…").font(.caption).foregroundStyle(.secondary)
        case .failed:
            HStack(spacing: 14) {
                Text("Not sent").font(.caption.weight(.semibold)).foregroundStyle(.red)
                if let retry = actions.retry { Button("Retry", action: retry).font(.caption.weight(.semibold)) }
                if let discard = actions.discard { Button("Delete", action: discard).font(.caption).foregroundStyle(.secondary) }
            }
            .buttonStyle(.plain)
        case .sent:
            // Pills and Reply on one line when they fit; with many pills, Reply starts a new line
            // under them instead of squeezing in at the right (owner 2026-11-07).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    pills
                    replyButton(lead: reply.rx.isEmpty ? 0 : 8)
                    heldNote
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) { pills }
                    HStack(spacing: 6) { replyButton(lead: 0); heldNote }
                }
            }
            .buttonStyle(.plain)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: reply.rx)
            .animation(.easeOut(duration: 0.2), value: reply.my)
        }
    }

    @ViewBuilder private var menu: some View {
        // The chat's react bar on a long press (owner 2026-11-07): the same six, in the same order, as
        // one row at the menu's top; mine is marked, a tap on it takes it back.
        if reply.send == .sent {
            ControlGroup {
                ForEach(QuickReaction.bar, id: \.self) { e in
                    Button { actions.react(e) } label: {
                        Image(uiImage: Self.emojiImage(e)).renderingMode(.original)
                    }
                    .accessibilityLabel(e == reply.my ? "\(e), yours" : e)
                }
            }
            .controlGroupStyle(.palette)
            // A pick closes the menu, as in the chat (owner 2026-11-07); a palette stays open otherwise.
            .menuActionDismissBehavior(.enabled)
        }
        if let r = actions.reply { Button { r() } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") } }
        if let e = actions.edit { Button { e() } label: { Label("Edit", systemImage: "pencil") } }
        Button { UIPasteboard.general.string = reply.text } label: { Label("Copy", systemImage: "doc.on.doc") }
        if let p = actions.pin {
            Button { p() } label: { Label(actions.pinned ? "Unpin" : "Pin", systemImage: actions.pinned ? "pin.slash" : "pin") }
        }
        if let r = actions.report { Button { r() } label: { Label("Report", systemImage: "exclamationmark.bubble") } }
        if let d = actions.delete { Button(role: .destructive) { d() } label: { Label("Delete", systemImage: "trash") } }
        if let b = actions.ban { Button(role: .destructive) { b() } label: { Label("Delete and Ban", systemImage: "nosign") } }
    }

    /// An emoji drawn as a 30pt picture, for the menu's palette row (a menu row shows images, not text).
    private static var emojiImages: [String: UIImage] = [:]
    static func emojiImage(_ e: String) -> UIImage {
        if let i = emojiImages[e] { return i }
        let size = CGSize(width: 30, height: 30)
        let img = UIGraphicsImageRenderer(size: size).image { _ in
            let s = NSAttributedString(string: e, attributes: [.font: UIFont.systemFont(ofSize: 25)])
            let b = s.size()
            s.draw(at: CGPoint(x: (size.width - b.width) / 2, y: (size.height - b.height) / 2))
        }
        emojiImages[e] = img
        return img
    }

    /// "now", "5m", "3h", "2d", "6w": the age of a reply, short.
    static func age(_ d: Date) -> String {
        let s = max(0, Date().timeIntervalSince(d))
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86_400 { return "\(Int(s / 3600))h" }
        if s < 7 * 86_400 { return "\(Int(s / 86_400))d" }
        return "\(Int(s / (7 * 86_400)))w"
    }

    private static let spoken = RelativeDateTimeFormatter()
    static func spokenAge(_ d: Date) -> String {
        spoken.localizedString(for: d, relativeTo: Date())
    }
}

/// The field at the bottom: its own view, so typing redraws only it, not the whole list.
private struct ReplyComposer: View {
    let off: Bool
    let loaded: Bool
    @Binding var answering: ReplyTarget?
    @Binding var editing: ReplyEdit?
    let onSend: (String, ReplyTarget?) -> Void
    let onEdit: (ReplyEdit, String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        if off {
            Text("Replies are turned off for this post.")
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(14)
        } else {
            VStack(spacing: 6) {
                if editing != nil {
                    HStack {
                        Text("Editing").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { editing = nil; draft = "" } label: { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Cancel editing")
                    }
                    .padding(.horizontal, 20)
                } else if let a = answering {
                    HStack {
                        Text("Replying to \(a.name)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { answering = nil } label: { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Cancel reply")
                    }
                    .padding(.horizontal, 20)
                }
                let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Add a reply…", text: $draft, axis: .vertical)
                        .lineLimit(1...5)
                        .focused($focused)
                        // At most 250 characters, the server's limit too (owner 2026-11-07).
                        .onChange(of: draft) { _, v in if v.count > 250 { draft = String(v.prefix(250)) } }
                        .padding(.vertical, 12)
                    // The chat's send: a white arrow on the blue pill (owner 2026-11-07), shown once
                    // there is something to send.
                    if hasText {
                        Button {
                            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { return }
                            if let e = editing {
                                if text != e.text { onEdit(e, text) }   // the same words: nothing to save
                                editing = nil
                            } else {
                                onSend(text, answering)
                                answering = nil
                            }
                            draft = ""
                            // The keyboard goes down once it is sent (owner 2026-11-08), so the
                            // new reply can be seen.
                            focused = false
                        } label: {
                            Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 34)
                                .background(Capsule().fill(Theme.defaultBubble(false)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(!loaded)
                        .opacity(loaded ? 1 : 0.5)
                        .padding(.bottom, 5)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityLabel("Send")
                    }
                }
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hasText)
                .padding(.leading, 18).padding(.trailing, hasText ? 5 : 18)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(.horizontal, 24)   // clear of the sheet's round corners (owner 2026-11-07)
            }
            .padding(.vertical, 8)
            .onChange(of: answering) { _, a in if a != nil { focused = true } }
            // Edit: the reply's words go in the field; leaving edit empties it again.
            .onChange(of: editing) { was, e in
                if let e { draft = String(e.text.prefix(250)); focused = true } else if was != nil { draft = "" }
            }
        }
    }
}

/// Skeleton rows in the replies' own shape while the first page loads.
private struct RepliesSkeleton: View {
    @State private var dim = false
    var body: some View {
        // Light and plain like the Quotes one (owner 2026-11-07): no solid background, faint shapes
        // in the reply row's own layout (name over a bubble, the photo beside it).
        VStack(alignment: .leading, spacing: 20) {
            ForEach(0..<4, id: \.self) { i in
                VStack(alignment: .leading, spacing: 6) {
                    Capsule().fill(fill).frame(width: 80, height: 9).padding(.leading, 54)
                    HStack(spacing: 10) {
                        Circle().fill(fill).frame(width: 40, height: 40)
                        RoundedRectangle(cornerRadius: 20, style: .continuous).fill(fill)
                            .frame(width: CGFloat([200, 150, 230, 120][i]), height: 40)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.top, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)   // against the left edge, like real rows (owner 2026-11-07)
        .opacity(dim ? 0.5 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
        .onAppear { dim = true }
        .accessibilityLabel("Loading replies")
    }
    private var fill: Color { Color.primary.opacity(0.08) }
}

/// ⛔ THREAD LINES UNDER A REPLY (owner 2026-11-07, his reference picture): a thin line down from
/// the reply's photo, curving into each answer's photo and into "View N replies" / "Hide replies".
/// Answers sit `answerIndent` in; the parent's photo is 40 wide at 16 from the edge, so its line runs
/// at x = 36 in list coordinates.
enum ReplyThreadLine: Equatable {
    case none, below, answer

    static let parentX: CGFloat = 36
    static let answerIndent: CGFloat = 46
    // Solid, not see-through: where two rows' lines meet, a see-through grey showed a darker overlap.
    static let color = Color(.systemGray3)
    /// The corner's radius: a wide, round bend into the answer or the toggle, as in the owner's
    /// reference (2026-11-07: "the line's round doesn't look good").
    /// The corner's radius, as iOS's own `.continuous` rounded rectangles use it.
    private static let radius: CGFloat = 12
    /// How far the bend reaches along each line: a continuous corner starts 1.53 radii out.
    private static let bend: CGFloat = radius * 1.52866483

    /// ⛔ APPLE'S CONTINUOUS CORNER, NOT A CIRCLE (owner 2026-11-08: "still that line is not smooth,
    /// use Apple rounded design"). A circular arc meets the straight line with a jump in curvature,
    /// which reads as a kink. These are the three curves of iOS's continuous rounded-rectangle
    /// corner, so the line eases into the bend and out of it. From the vertical line at `x`, `bend`
    /// above `y`, to `bend` right of `x` on `y`.
    private static func addContinuousBend(_ p: inout Path, x: CGFloat, y: CGFloat) {
        let r = radius
        p.addCurve(to: CGPoint(x: x + 0.07491100 * r, y: y - 0.63149399 * r),
                   control1: CGPoint(x: x, y: y - 1.08849323 * r),
                   control2: CGPoint(x: x + 0.02229519 * r, y: y - 0.86840689 * r))
        p.addCurve(to: CGPoint(x: x + 0.63149399 * r, y: y - 0.07491100 * r),
                   control1: CGPoint(x: x + 0.16905899 * r, y: y - 0.37282392 * r),
                   control2: CGPoint(x: x + 0.37282392 * r, y: y - 0.16905899 * r))
        p.addCurve(to: CGPoint(x: x + bend, y: y),
                   control1: CGPoint(x: x + 0.86840689 * r, y: y - 0.02229519 * r),
                   control2: CGPoint(x: x + 1.08849323 * r, y: y))
    }

    /// In the row's own coordinates (`avatar` is that row's photo).
    static func path(_ kind: ReplyThreadLine, avatar r: CGRect, height: CGFloat) -> Path {
        var p = Path()
        switch kind {
        case .none: break
        case .below:
            p.move(to: CGPoint(x: r.midX, y: r.maxY + 2))   // right under the photo, no visible gap
            p.addLine(to: CGPoint(x: r.midX, y: height))
        case .answer:
            let x = parentX - answerIndent   // the parent's line, left of this row's own frame
            p.move(to: CGPoint(x: x, y: 0))
            p.addLine(to: CGPoint(x: x, y: height))   // on past this answer to the next
            p.move(to: CGPoint(x: x, y: r.midY - bend))
            addContinuousBend(&p, x: x, y: r.midY)
            p.addLine(to: CGPoint(x: r.minX - 4, y: r.midY))
        }
        return p
    }

    /// The last bend, into the toggle's label (the label starts 62 in, its text 28 further).
    static func toggleElbow(height: CGFloat) -> Path {
        var p = Path()
        let x = parentX - 62, mid = height / 2
        // The row is short, so the bend may start above it, on the line coming down from the reply:
        // a full round corner instead of a cramped one.
        let start = min(0, mid - bend)
        p.move(to: CGPoint(x: x, y: start))
        p.addLine(to: CGPoint(x: x, y: mid - bend))
        addContinuousBend(&p, x: x, y: mid)
        p.addLine(to: CGPoint(x: 20, y: mid))
        return p
    }
}

private struct ReplyAvatarBounds: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}
