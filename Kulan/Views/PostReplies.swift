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
    var send: Send = .sent
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
    private(set) var answers: [String: [PostReply]] = [:]  // thread id -> answers, oldest first
    private(set) var answerNext: [String: String] = [:]
    var openThreads: Set<String> = []
    private(set) var olderCursor = ""
    private(set) var loaded = false
    private(set) var failed = false
    private(set) var loadingOlder = false
    private(set) var off = false
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
    /// Is the end of the list on screen? New replies then scroll in instead of counting in the pill.
    var atEnd = true

    /// The last first page per post, for an instant paint when the sheet opens again (this launch).
    private static var cache: [String: [PostReply]] = [:]

    init(cid: String, mid: String) {
        self.cid = cid
        self.mid = mid
        if let c = Self.cache[mid] { threads = c; loaded = true }
    }

    static func reset() { cache.removeAll() }

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
        return r
    }

    func loadFirst() async {
        do {
            let res = try await fn.httpsCallable("getReplies").call(args())
            let d = res.data as? [String: Any] ?? [:]
            applyFlags(d)
            let page = Array(rows(d).reversed())
            let ids = Set(page.map(\.id))
            if threads.isEmpty || olderCursor.isEmpty { olderCursor = d["next"] as? String ?? "" }
            // Pages loaded further up stay (a Try Again or a switch flip used to drop them).
            let firstAt = page.first?.at
            let kept = threads.filter { r in !ids.contains(r.id) && (r.send != .sent || (firstAt.map { r.at < $0 } ?? true)) }
            threads = (kept + page).sorted { $0.at < $1.at }
            if lastRev < 0 { lastRev = (d["rev"] as? NSNumber)?.intValue ?? 0 }
            loaded = true
            failed = false
            Self.cache[mid] = page
        } catch {
            failed = true
            loaded = true
        }
    }

    /// The newest page again, merged by id: new ones added at the end, changed ones updated, ones gone
    /// from inside the page's time range removed. Only the newest refresh lands; my own replies saved
    /// in the last seconds are kept; a page that does not reach back to what is shown replaces the
    /// list (and the "earlier" cursor), so no gap is left between them (2026-11-06 audits).
    func refreshNewest() async {
        refreshGen &+= 1
        let gen = refreshGen
        guard let res = try? await fn.httpsCallable("getReplies").call(args()) else { return }
        guard gen == refreshGen else { return }
        let d = res.data as? [String: Any] ?? [:]
        applyFlags(d)
        let page = Array(rows(d).reversed())
        let next = d["next"] as? String ?? ""
        let now = Date()
        recentMine = recentMine.filter { now.timeIntervalSince($0.value) < 8 }
        let keepMine: (PostReply) -> Bool = { $0.send != .sent || self.recentMine[$0.id] != nil }
        guard let oldestShown = page.first?.at else {
            // Nothing visible on the newest page: only rows newer than what that page covered can go.
            if next.isEmpty { threads.removeAll { !keepMine($0) } }
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
        if added > 0 {
            if atEnd { scrollTarget = list.last?.id } else { unseenNew += added }
        }
        Self.cache[mid] = page
        // Open threads whose answer count moved, together.
        let changed = openThreads.filter { t in
            guard let r = page.first(where: { $0.id == t }) else { return false }
            return r.answers != (answers[t]?.filter { $0.send == .sent }.count ?? -1)
        }
        await withTaskGroup(of: Void.self) { g in
            for t in changed.prefix(5) { g.addTask { await self.loadAnswers(t, more: false) } }
        }
    }

    func loadOlder() async {
        guard !olderCursor.isEmpty, !loadingOlder else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        guard let res = try? await fn.httpsCallable("getReplies").call(args(["cursor": olderCursor])) else { return }
        let d = res.data as? [String: Any] ?? [:]
        let page = Array(rows(d).reversed()).filter { r in !threads.contains { $0.id == r.id } }
        olderCursor = d["next"] as? String ?? ""
        threads.insert(contentsOf: page, at: 0)
    }

    func loadAnswers(_ rid: String, more: Bool) async {
        let cursor = more ? (answerNext[rid] ?? "") : ""
        guard let res = try? await fn.httpsCallable("getReplyAnswers").call(args(["rid": rid, "cursor": cursor])) else { return }
        let d = res.data as? [String: Any] ?? [:]
        let page = rows(d)
        let local = (answers[rid] ?? []).filter { $0.send != .sent }
        var list = more ? (answers[rid] ?? []).filter { $0.send == .sent } : []
        for r in page where !list.contains(where: { $0.id == r.id }) { list.append(r) }
        for l in local where !list.contains(where: { $0.id == l.id }) { list.append(l) }
        answers[rid] = list
        answerNext[rid] = d["next"] as? String ?? ""
        answersLoaded.insert(rid)
    }

    /// Threads whose answers came from the server at least once. A thread can hold my own answer
    /// (just sent) without the others; "View N replies" then showed only the newest (owner
    /// 2026-11-07: "show me the first ones"). Opened, it loads from the first answer down.
    private var answersLoaded: Set<String> = []

    func toggleThread(_ rid: String) {
        if openThreads.contains(rid) { openThreads.remove(rid); return }
        openThreads.insert(rid)
        if !answersLoaded.contains(rid) { Task { await loadAnswers(rid, more: false) } }
    }

    // MARK: Actions

    /// Sends a reply (`thread` nil) or an answer. Shown at once; on failure it stays with Retry.
    func send(_ text: String, thread: String?, me: (name: String, photo: String), clientId: String? = nil) {
        let id = clientId ?? UUID().uuidString
        let row = PostReply(pendingId: id, text: text, name: me.name, photoUrl: me.photo)
        if let t = thread {
            // A thread never opened: its other answers load too, or only this one would show and the
            // thread would look fully loaded (2026-11-06 verify pass). loadAnswers keeps this row.
            if answers[t] == nil { Task { await loadAnswers(t, more: false) } }
            var list = answers[t] ?? []
            if let i = list.firstIndex(where: { $0.id == id }) { list[i].send = .sending } else { list.append(row) }
            answers[t] = list
            openThreads.insert(t)
        } else {
            if let i = threads.firstIndex(where: { $0.id == id }) { threads[i].send = .sending } else { threads.append(row) }
        }
        scrollTarget = id
        Task {
            var a: [String: Any] = ["text": text, "clientId": id]
            if let t = thread { a["rid"] = t }
            do {
                let res = try await fn.httpsCallable("addReply").call(args(a))
                guard let d = (res.data as? [String: Any])?["reply"] as? [String: Any], let saved = PostReply(d) else { return }
                let firstTime = clientId == nil
                replace(id, with: saved, thread: thread)
                recentMine[id] = Date()
                if firstTime {
                    if let t = thread, let i = threads.firstIndex(where: { $0.id == t }) { threads[i].answers += 1 }
                    count += 1
                }
            } catch {
                mark(id, thread: thread, .failed)
            }
        }
    }

    func retry(_ r: PostReply, thread: String?) {
        send(r.text, thread: thread, me: (r.name, r.photoUrl), clientId: r.id)
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
        if let t = thread {
            answers[t]?.removeAll { $0.id == r.id }
            if let i = threads.firstIndex(where: { $0.id == t }) { threads[i].answers = max(0, threads[i].answers - 1) }
        } else {
            threads.removeAll { $0.id == r.id }
            answers[r.id] = nil
        }
        var a: [String: Any] = [:]
        if let t = thread { a["rid"] = t; a["aid"] = r.id } else { a["rid"] = r.id }
        do {
            let res = try await fn.httpsCallable("deleteReply").call(args(a))
            let removed = ((res.data as? [String: Any])?["removed"] as? NSNumber)?.intValue ?? 0
            count = max(0, count - removed)
        } catch {
            deletedIds.remove(r.id)
            if let t = thread, let i = threads.firstIndex(where: { $0.id == t }) { threads[i].answers += 1 }
            // Only the one row comes back, never a whole saved list over newer arrivals.
            if let t = thread, let before = answersBefore, let row = before.first(where: { $0.id == r.id }) {
                answers[t, default: []].append(row)
                answers[t]?.sort { $0.at < $1.at }
            } else if thread == nil, let row = threadsBefore.first(where: { $0.id == r.id }) {
                threads.append(row)
                threads.sort { $0.at < $1.at }
            }
        }
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
    /// This post's replies switch changed here: the chat updates the post at once (owner 2026-11-07).
    var onPostRepliesChanged: (Bool) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .replies
    @State private var model: RepliesModel
    @State private var answering: (id: String, name: String)?
    @State private var reporting: (PostReply, String?)?
    @State private var banning: (PostReply, String?)?
    @State private var toast: String?
    @State private var quotesShown = false

    init(cid: String, mid: String, post: Message?, repliesOff: Bool = false, sourceTitle: String, sourcePhoto: String?,
         sourceVerified: Bool, picture: @escaping () async -> UIImage?, onOpen: @escaping (QuotedInItem) -> Void,
         startTab: Tab = .replies) {
        self.cid = cid
        self.mid = mid
        self.post = post
        self.repliesOff = repliesOff
        let first: Tab = repliesOff ? .quotes : startTab
        self.sourceTitle = sourceTitle
        self.sourcePhoto = sourcePhoto
        self.sourceVerified = sourceVerified
        self.picture = picture
        self.onOpen = onOpen
        self.startTab = first
        _tab = State(initialValue: first)
        _quotesShown = State(initialValue: first == .quotes)
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
        .onChange(of: model.off) { _, off in if off { tab = .quotes } }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        // `presenting:` hands each button the item itself (2026-11-06 audit: reading the state in the
        // action could find it already cleared by the dialog closing).
        .confirmationDialog("Report this reply?", isPresented: reportingShown, titleVisibility: .visible, presenting: reporting) { item in
            ForEach(Self.reasons, id: \.0) { key, label in
                Button(label) { Task { show(await model.report(item.0, thread: item.1, reason: key) ? "Thanks. We'll take a look." : "Couldn't send the report.") } }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Remove this person?", isPresented: banningShown, titleVisibility: .visible, presenting: banning) { item in
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
            if !(repliesOff || model.off) { tabButton("Replies", .replies) }
            tabButton("Quotes", .quotes)
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
        case thread(PostReply)
        case answer(PostReply, String)
        case toggle(String, Int, Bool)
        case moreAnswers(String)
        var id: String {
            switch self {
            case .older: return "older"
            case .thread(let r): return "t-\(r.id)"
            case .answer(let r, _): return "a-\(r.id)"
            case .toggle(let t, _, _): return "g-\(t)"
            case .moreAnswers(let t): return "m-\(t)"
            }
        }
    }

    /// The list as one flat run of rows (lazy all the way down, a long thread included).
    private var items: [Item] {
        var out: [Item] = []
        if !model.olderCursor.isEmpty { out.append(.older) }
        for r in model.threads {
            out.append(.thread(r))
            let loaded = model.answers[r.id] ?? []
            let total = max(r.answers, loaded.count)
            guard total > 0 else { continue }
            let open = model.openThreads.contains(r.id)
            if open {
                for a in loaded { out.append(.answer(a, r.id)) }
                if !(model.answerNext[r.id] ?? "").isEmpty { out.append(.moreAnswers(r.id)) }
            }
            out.append(.toggle(r.id, total, open))
        }
        return out
    }

    private var repliesTab: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { item in itemView(item).id(item.id) }
                        Color.clear.frame(height: 6).id("end")
                            .onAppear { model.atEnd = true; model.unseenNew = 0 }
                            .onDisappear { model.atEnd = false }
                    }
                    .padding(.top, 4)
                }
                // A few replies start at the top, under the tabs (owner 2026-11-07); a long thread still
                // opens at its newest reply and stays there as new ones land.
                .defaultScrollAnchor(.top, for: .alignment)
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .scrollDismissesKeyboard(.interactively)
                .overlay { repliesOverlay }
                .overlay(alignment: .bottom) { newPill(proxy) }
                .onChange(of: model.scrollTarget) { _, id in
                    guard let id else { return }
                    let key = model.threads.contains(where: { $0.id == id }) ? "t-\(id)" : "a-\(id)"
                    model.scrollTarget = nil
                    // After the new row is laid out, not in the same pass that added it.
                    Task { @MainActor in
                        await Task.yield()
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(key, anchor: .bottom) }
                    }
                }
            }
            // Off as the post already says, from the first frame (owner 2026-11-07: the field showed for
            // a second, then turned into the off line when the server answered).
            ReplyComposer(off: model.off || repliesOff, loaded: model.loaded, answering: $answering) { text, thread in
                let me = ProfileStore.shared.me
                model.send(text, thread: thread, me: (me?.name ?? "You", me?.photoUrl ?? ""))
            }
        }
    }

    @ViewBuilder private func newPill(_ proxy: ScrollViewProxy) -> some View {
        if model.unseenNew > 0 {
            Button {
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("end", anchor: .bottom) }
                model.unseenNew = 0
            } label: {
                Label("\(model.unseenNew) new \(model.unseenNew == 1 ? "reply" : "replies")", systemImage: "arrow.down")
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
                Text(model.loadingOlder ? "Loading…" : "Show earlier replies")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .buttonStyle(.plain)
        case .thread(let r):
            ReplyRow(reply: r, small: false, actions: actions(r, thread: nil))
        case .answer(let r, let t):
            ReplyRow(reply: r, small: true, actions: actions(r, thread: t)).padding(.leading, 46)
        case .toggle(let t, let n, let open):
            Button { withAnimation(.easeInOut(duration: 0.2)) { model.toggleThread(t) } } label: {
                HStack(spacing: 8) {
                    Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 20, height: 1)
                    Text(open ? "Hide replies" : "View \(n) \(n == 1 ? "reply" : "replies")")
                        .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
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
        }
    }

    private func actions(_ r: PostReply, thread: String?) -> ReplyRow.Actions {
        ReplyRow.Actions(
            like: { model.toggleLike(r, thread: thread) },
            react: { e in model.react(r, emoji: e, thread: thread) },
            reply: model.off ? nil : { answering = (thread ?? r.id, r.name) },
            delete: r.canDelete ? { Task { await model.delete(r, thread: thread) } } : nil,
            report: r.mine ? nil : { reporting = (r, thread) },
            ban: (model.may.ban && !r.mine) ? { banning = (r, thread) } : nil,
            retry: r.send == .failed ? { model.retry(r, thread: thread) } : nil,
            discard: r.send == .failed ? { model.discard(r, thread: thread) } : nil)
    }

    @ViewBuilder private var repliesOverlay: some View {
        if model.failed && model.threads.isEmpty {
            ContentUnavailableView {
                Label("Couldn't load replies", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Try Again") { Task { await model.loadFirst() } }
            }
        } else if !model.loaded {
            RepliesSkeleton()
        } else if model.threads.isEmpty {
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
        var delete: (() -> Void)?
        var report: (() -> Void)?
        var ban: (() -> Void)?
        var retry: (() -> Void)?
        var discard: (() -> Void)?
    }

    let reply: PostReply
    let small: Bool
    let actions: Actions

    var body: some View {
        // His reference picture (owner 2026-11-07): name and age over the bubble, the photo beside
        // the bubble's middle, the heart and Reply under it.
        let side: CGFloat = small ? 28 : 40
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(reply.name).font(.footnote.weight(.semibold)).lineLimit(1)
                if reply.verified {
                    Image(systemName: "checkmark.seal.fill").font(.caption2).foregroundStyle(.blue)
                }
                Text(Self.age(reply.at)).font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.leading, side + 10 + 14)
            HStack(alignment: .center, spacing: 10) {
                AvatarView(name: reply.name, photoUrl: reply.photoUrl.isEmpty ? nil : reply.photoUrl, size: side)
                    .accessibilityHidden(true)
                Text(reply.text)
                    .font(small ? .subheadline : .body)
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(reply.name), \(reply.text), \(Self.spokenAge(reply.at))\(reply.likes > 0 ? ", \(reply.likes) likes" : "")")
        .accessibilityActions {
            if reply.send == .sent { Button(reply.liked ? "Unlike" : "Like") { actions.like() } }
            if let r = actions.reply { Button("Reply", action: r) }
            if let r = actions.retry { Button("Retry", action: r) }
            if let d = actions.delete { Button("Delete", action: d) }
            if let r = actions.report { Button("Report", action: r) }
        }
    }

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
            HStack(spacing: 6) {
                // ⛔ THE CHAT'S REACTION PILL, NOT A HEART BUTTON (owner 2026-11-07: "make it like how
                // bubble react works in my app"). No empty outline: a double tap on the bubble reacts,
                // and once there is a reaction a pill shows the emoji and count; mine is the dark,
                // filled one, as in the chat; a tap on it takes mine back or adds it.
                ForEach(reply.rx, id: \.emoji) { r in
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
                if let r = actions.reply {
                    Button(action: r) { Text("Reply").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                        .padding(.leading, reply.rx.isEmpty ? 0 : 8)
                }
                if reply.held {
                    Text("Hidden after reports").font(.caption2).foregroundStyle(.secondary)
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
        Button { UIPasteboard.general.string = reply.text } label: { Label("Copy", systemImage: "doc.on.doc") }
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
    @Binding var answering: (id: String, name: String)?
    let onSend: (String, String?) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        if off {
            Text("Replies are turned off for this post.")
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(14)
        } else {
            VStack(spacing: 6) {
                if let a = answering {
                    HStack {
                        Text("Replying to \(a.name)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { answering = nil } label: { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Cancel reply")
                    }
                    .padding(.horizontal, 20)
                }
                HStack(spacing: 8) {
                    TextField("Add a reply…", text: $draft, axis: .vertical)
                        .lineLimit(1...5)
                        .focused($focused)
                    Button("Send") {
                        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        onSend(text, answering?.id)
                        draft = ""
                        answering = nil
                    }
                    .font(.body.weight(.semibold))
                    .disabled(!loaded || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(.horizontal, 24)   // clear of the sheet's round corners (owner 2026-11-07)
            }
            .padding(.vertical, 8)
            .onChange(of: answering?.id) { _, id in if id != nil { focused = true } }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(dim ? 0.5 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
        .onAppear { dim = true }
        .accessibilityLabel("Loading replies")
    }
    private var fill: Color { Color.primary.opacity(0.08) }
}
