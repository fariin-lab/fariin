import Foundation
import Observation
import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions

/// One row of the Activity page: someone answered or reacted to one of my comments on a channel post.
/// Written only by the server (`users/{me}/activity/{id}`); see fariin-activity/SPEC.md.
struct ActivityItem: Identifiable, Equatable {
    enum Kind: String { case reply, react, quote, comment, mention }
    /// A place in a post's Replies: the thread id and the answer id ("" = the thread itself).
    struct Ref: Equatable {
        var rid = ""
        var aid = ""
    }

    let id: String
    var kind: Kind
    var at: Date
    var read: Bool
    var cid: String
    var chTitle: String
    var chPhoto: String
    var mid: String
    var post: String
    /// My comment that got the activity, and its words.
    var mine: Ref
    var mineText: String
    /// The latest person.
    var fromUid: String
    var fromName: String
    var fromPhoto: String
    /// The person shown before `from` on a reaction row (design 3, two faces stacked); "" = none.
    var from2Name: String = ""
    var from2Photo: String = ""
    var hasFrom2: Bool = false
    /// Reply: their words, and where their reply is.
    var text: String
    var newRef: Ref
    /// React: the latest emoji, how many other people reacted, and the comment's counts.
    var emoji: String
    var others: Int
    var rx: [Count]
    struct Count: Equatable {
        var emoji: String
        var count: Int
    }
    /// The post's picture ("" for a text post) and whether it is a video.
    var thumb: String
    var thumbIsVideo: Bool
    /// Quote: where it was posted, only when that is a public channel ("" otherwise).
    var whereCid = ""
    var whereMid = ""
    var whereTitle = ""

    /// True when my comment was an answer in a thread, not the thread itself.
    var mineIsAnswer: Bool { !mine.aid.isEmpty && mine.aid != mine.rid }

    /// The comment the tap should land on: their reply, or mine for a reaction.
    var target: Ref { kind == .reply || kind == .comment || kind == .mention ? newRef : mine }

    init?(id: String, data d: [String: Any]) {
        guard let k = Kind(rawValue: d["kind"] as? String ?? "") else { return nil }
        self.id = id
        kind = k
        at = (d["at"] as? Timestamp)?.dateValue() ?? Date(timeIntervalSince1970: 0)
        read = d["read"] as? Bool ?? false
        cid = d["cid"] as? String ?? ""
        chTitle = d["chTitle"] as? String ?? ""
        chPhoto = d["chPhoto"] as? String ?? ""
        mid = d["mid"] as? String ?? ""
        post = d["post"] as? String ?? ""
        let m = d["mine"] as? [String: Any] ?? [:]
        mine = Ref(rid: m["rid"] as? String ?? "", aid: m["aid"] as? String ?? "")
        mineText = m["t"] as? String ?? ""
        let f = d["from"] as? [String: Any] ?? [:]
        fromUid = f["u"] as? String ?? ""
        fromName = f["n"] as? String ?? ""
        fromPhoto = f["p"] as? String ?? ""
        if let f2 = d["from2"] as? [String: Any] {
            hasFrom2 = true
            from2Name = f2["n"] as? String ?? ""
            from2Photo = f2["p"] as? String ?? ""
        }
        text = d["text"] as? String ?? ""
        let n = d["new"] as? [String: Any] ?? [:]
        newRef = Ref(rid: n["rid"] as? String ?? "", aid: n["aid"] as? String ?? "")
        emoji = d["emoji"] as? String ?? ""
        others = max(0, (d["others"] as? NSNumber)?.intValue ?? 0)
        var counts: [Count] = []
        for (e, v) in d["rx"] as? [String: Any] ?? [:] {
            let c = (v as? NSNumber)?.intValue ?? 0
            if c > 0 { counts.append(Count(emoji: e, count: c)) }
        }
        // Most used first; equal counts in a fixed order so the pills do not swap places.
        rx = counts.sorted { $0.count != $1.count ? $0.count > $1.count : $0.emoji < $1.emoji }
        thumb = d["thumb"] as? String ?? ""
        thumbIsVideo = (d["thumbKind"] as? String ?? "") == "video"
        if let w = d["where"] as? [String: Any] {
            whereCid = w["cid"] as? String ?? ""
            whereMid = w["mid"] as? String ?? ""
            whereTitle = w["title"] as? String ?? ""
        }
    }
}

/// `users/{me}/activityMeta/summary`: what the chat list's Activity row shows.
struct ActivitySummary: Equatable {
    var unread: Int
    /// The item `last` was copied from ("" from an older server).
    var lastId: String
    var lastKind: String
    var lastName: String
    var lastText: String
    var lastEmoji: String
    /// When the latest event happened, ms, the same unit as `Conversation.listSortDate`.
    var lastAtMillis: Double

    init(data d: [String: Any]) {
        unread = max(0, (d["unread"] as? NSNumber)?.intValue ?? 0)
        let l = d["last"] as? [String: Any] ?? [:]
        lastId = l["id"] as? String ?? ""
        lastKind = l["kind"] as? String ?? ""
        lastName = l["n"] as? String ?? ""
        lastText = l["text"] as? String ?? ""
        lastEmoji = l["emoji"] as? String ?? ""
        lastAtMillis = ((l["at"] as? Timestamp)?.dateValue().timeIntervalSince1970 ?? 0) * 1000
    }

    /// "Nan replied to your comment: thanks" / "Nan reacted ❤️ to your comment".
    var preview: String {
        let name = lastName.isEmpty ? "Someone" : lastName
        if lastKind == "comment" {
            return lastText.isEmpty ? "\(name) commented on your post" : "\(name) commented: \(lastText)"
        }
        if lastKind == "mention" {
            return lastText.isEmpty ? "\(name) mentioned you" : "\(name) mentioned you: \(lastText)"
        }
        if lastKind == "quote" {
            return lastText.isEmpty ? "\(name) quoted your post" : "\(name) quoted your post: \(lastText)"
        }
        if lastKind == "react" {
            return lastEmoji.isEmpty ? "\(name) reacted to your comment"
                                     : "\(name) reacted \(lastEmoji) to your comment"
        }
        return lastText.isEmpty ? "\(name) replied to your comment"
                                : "\(name) replied to your comment: \(lastText)"
    }
}

/// Replies and reactions to my comments, live. Started beside the chat list's listener
/// (`ConversationsRepository.attach`), stopped by `SessionWipe` on sign-out.
@MainActor
@Observable
final class ActivityStore {
    static let shared = ActivityStore()
    /// The chat list's synthetic row id. Never a conversation id (those have no "~").
    nonisolated static let rowId = "~activity"

    private(set) var summary: ActivitySummary?
    private(set) var items: [ActivityItem] = []
    /// The first answer for the items has come in (or the listener failed: `failed`).
    private(set) var loaded = false
    /// The items listener ended with an error (audit A20): the page says so and offers Try Again
    /// instead of showing only its chips.
    private(set) var failed = false

    @ObservationIgnored private var summaryListener: ListenerRegistration?
    @ObservationIgnored private var listListener: ListenerRegistration?
    @ObservationIgnored private var uid: String?
    /// How many of the newest items the listener holds; grows a page at a time as the page is
    /// scrolled to its end (`loadMore`).
    @ObservationIgnored private var limit = ActivityStore.pageSize
    private nonisolated static let pageSize = 100
    /// The limit the items now in `items` were read under (a larger `limit` is on its way after `loadMore`).
    @ObservationIgnored private var itemsLimit = ActivityStore.pageSize

    private init() {}

    /// The chat list's Activity row (owner 2026-11-09): there whenever I have any activity at all,
    /// like a chat, with its badge only while something is unread. nil = no activity, no row.
    ///
    /// ⛔ THE ROW FOLLOWS THE ITEMS THIS PHONE CAN SEE (audit A2/A3/A19/X7/X10/X11). The server's
    /// summary can name an item that is gone (expired after 30 days, a quote taken back, a deleted
    /// post) and count unread that no longer exists, and it counts people I blocked after they
    /// acted. When the whole list is here (fewer items than the listener holds) the row is worked
    /// out from the items alone: newest visible item, unread visible items, no row when none. With a
    /// longer list the summary stands, minus the unread from blocked people, and a `last` naming a
    /// blocked person's item gives way to the newest visible one.
    var rowSummary: ActivitySummary? {
        let blocks = BlockList.shared
        let visible = items.filter { $0.fromUid.isEmpty || !blocks.contains($0.fromUid) }
        if loaded, !failed, items.count < itemsLimit {
            guard let first = visible.first else { return nil }
            var s = Self.summaryOf(first, base: summary)
            s.unread = visible.filter { !$0.read }.count
            return s
        }
        if var s = summary, s.lastAtMillis > 0 {
            if loaded, !failed {
                let hidden = items.filter { !$0.read && !$0.fromUid.isEmpty && blocks.contains($0.fromUid) }.count
                s.unread = max(0, s.unread - hidden)
                if !s.lastId.isEmpty, let it = items.first(where: { $0.id == s.lastId }),
                   !it.fromUid.isEmpty, blocks.contains(it.fromUid), let first = visible.first {
                    let unread = s.unread
                    s = Self.summaryOf(first, base: s)
                    s.unread = unread
                }
            }
            return s
        }
        guard let first = visible.first else { return nil }
        // No summary yet (or an old one without `last`): the newest item stands in.
        return Self.summaryOf(first, base: summary)
    }

    /// The chat-list line for one item, on top of `base` (its unread count kept).
    private static func summaryOf(_ item: ActivityItem, base: ActivitySummary?) -> ActivitySummary {
        var s = base ?? ActivitySummary(data: [:])
        s.lastId = item.id
        s.lastKind = item.kind.rawValue
        s.lastName = item.fromName
        s.lastText = item.kind == .react ? "" : item.text
        s.lastEmoji = item.kind == .react ? item.emoji : ""
        s.lastAtMillis = item.at.timeIntervalSince1970 * 1000
        return s
    }

    /// The row pinned at the top of Pinned. Kept on this phone per account (the app cannot write
    /// to the activity documents). Sign-out keeps it (audit A21): the key is per account, so it
    /// is that account's again when it signs back in, and no other account reads it.
    private(set) var pinned = false

    private static func pinKey(_ uid: String) -> String { "activityPinned.\(uid)" }

    func setPinned(_ on: Bool) {
        guard let uid else { return }
        pinned = on
        if on { UserDefaults.standard.set(true, forKey: Self.pinKey(uid)) }
        else { UserDefaults.standard.removeObject(forKey: Self.pinKey(uid)) }
    }

    /// Sign-out: the listeners and what they held. The pin stays on disk under this account's key.
    func wipe() {
        stop()
    }

    func start(uid: String) {
        if self.uid == uid, summaryListener != nil { return }
        stop()
        guard Auth.auth().currentUser?.uid == uid else { return }
        self.uid = uid
        pinned = UserDefaults.standard.bool(forKey: Self.pinKey(uid))
        let me = FirestoreHub.db.collection("users").document(uid)
        summaryListener = me.collection("activityMeta").document("summary")
            .addSnapshotListener { [weak self] snap, _ in
                Task { @MainActor in
                    guard let self, self.uid == uid else { return }
                    guard let d = snap?.data() else { self.summary = nil; return }
                    let s = ActivitySummary(data: d)
                    if self.summary != s { self.summary = s }
                }
            }
        limit = Self.pageSize
        itemsLimit = Self.pageSize
        attachList(uid)
    }

    private func attachList(_ uid: String) {
        listListener?.remove()
        let lim = limit
        listListener = FirestoreHub.db.collection("users").document(uid).collection("activity")
            .order(by: "at", descending: true)
            .limit(to: lim)
            .addSnapshotListener { [weak self] snap, error in
                let list = snap?.documents.compactMap { ActivityItem(id: $0.documentID, data: $0.data()) }
                let failedNow = snap == nil && error != nil
                let why = error?.localizedDescription ?? ""
                Task { @MainActor in
                    guard let self, self.uid == uid, self.limit == lim else { return }
                    if let list {
                        self.itemsLimit = lim
                        if self.items != list { self.items = list }
                        self.failed = false
                    } else if failedNow {
                        // A listener that errors is over (audit A20): say so rather than a blank page.
                        DiagLog.add("activity: list listener failed \(why)")
                        self.failed = true
                    } else {
                        return
                    }
                    self.loaded = true
                }
            }
    }

    /// The page reached its last row: the next page of older items (audit A20: only the newest 100
    /// were ever shown). The listener is attached again with a larger limit.
    func loadMore() {
        guard let uid, !failed, items.count >= limit else { return }
        limit += Self.pageSize
        attachList(uid)
    }

    /// Try Again after the items listener failed.
    func retry() {
        guard let uid else { return }
        failed = false
        loaded = false
        attachList(uid)
    }

    /// Sign-out: the listeners and everything they held go with the account.
    func stop() {
        summaryListener?.remove(); summaryListener = nil
        listListener?.remove(); listListener = nil
        uid = nil
        pinned = false
        summary = nil
        items = []
        loaded = false
        failed = false
        limit = Self.pageSize
        itemsLimit = Self.pageSize
    }

    /// Opening the Activity page reads everything. The row's badge goes at once; the
    /// server's answer then comes back through the listeners.
    func markAllRead() async {
        guard uid != nil else { return }
        if var s = summary, s.unread > 0 { s.unread = 0; summary = s }
        // The row is worked out from the items when they are all here (`rowSummary`), so they are
        // read on this phone at once too.
        if items.contains(where: { !$0.read }) {
            items = items.map { var i = $0; i.read = true; return i }
        }
        do {
            _ = try await Functions.functions(region: "me-central1")
                .httpsCallable("markActivityRead").call([String: Any]())
        } catch {
            DiagLog.add("activity: markActivityRead failed \(error.localizedDescription)")
        }
    }

    /// Some items read (audit A13: the alert for them was tapped).
    func markRead(ids: [String]) async {
        guard uid != nil else { return }
        let set = Set(ids.filter { !$0.isEmpty && !$0.contains("/") })
        guard !set.isEmpty else { return }
        if items.contains(where: { set.contains($0.id) && !$0.read }) {
            items = items.map { var i = $0; if set.contains(i.id) { i.read = true }; return i }
        }
        do {
            _ = try await Functions.functions(region: "me-central1")
                .httpsCallable("markActivityRead").call(["ids": Array(set)])
        } catch {
            DiagLog.add("activity: markActivityRead(ids) failed \(error.localizedDescription)")
        }
    }

    /// A tap on an item: the same route a "replied to you" push takes (PushManager's tap handler).
    /// The channel opens on top of the Activity page, then that post's Replies, scrolled to the
    /// comment and flashing it (`PostThreadSheet` spends `pendingReplyTarget`).
    ///
    /// ⛔ CHECKED BEFORE IT OPENS (audit X1/A5), with the gate a notification tap uses (`OpenGate`):
    /// a row about a post or a channel that is gone says so and stays on this page, instead of a
    /// channel with a sheet that cannot load, or a blank chat. Offline it opens as before.
    func open(_ item: ActivityItem) {
        let bad: (String) -> Bool = { $0.isEmpty || $0.contains("/") }
        guard !bad(item.cid), !bad(item.mid), opening == nil else { return }
        let atWhere = item.kind == .quote && !bad(item.whereCid) && !bad(item.whereMid)
        let cid = atWhere ? item.whereCid : item.cid
        let mid = atWhere ? item.whereMid : item.mid
        opening = item.id
        Task { @MainActor in
            let gate = await OpenGate.check(cid: cid, mid: mid)
            opening = nil
            switch gate {
            case .open:
                route(item)
            case .postGone:
                ToastNotice.show(atWhere ? "This message was deleted" : "This post was deleted")
            case .chatGone:
                ToastNotice.show("This channel is no longer available")
            case .refused:
                ToastNotice.show("You can't open this channel")
            }
        }
    }

    /// The row being checked before it opens: a second tap meanwhile does nothing.
    @ObservationIgnored private var opening: String?

    private func route(_ item: ActivityItem) {
        let bad: (String) -> Bool = { $0.isEmpty || $0.contains("/") }
        let r = AppRouter.shared
        // A quote (owner 2026-11-09): opens where it was posted when that is a public channel, at
        // the quoting message; otherwise my post, with its Replies and Quotes sheet.
        if item.kind == .quote, !bad(item.whereCid), !bad(item.whereMid) {
            r.pendingRepliesPost = nil
            r.pendingReplyTarget = nil
            r.pendingOpenMid = (item.whereCid, item.whereMid, Date())
            r.pendingChatName = item.whereTitle.isEmpty ? nil : item.whereTitle
            r.pendingChatPhoto = nil
            r.pendingChatPush = true
            r.pendingChatId = item.whereCid
            return
        }
        let t = item.kind == .quote ? ActivityItem.Ref() : item.target
        // A quote opens the sheet on its Quotes tab (audit A14), the rest on Replies.
        r.pendingRepliesPost = (item.cid, item.mid, Date(), item.kind == .quote)
        r.pendingReplyTarget = bad(t.rid) ? nil
            : (item.mid, t.rid, (t.aid.isEmpty || t.aid.contains("/")) ? nil : t.aid, Date())
        r.pendingOpenMid = nil
        r.pendingChatName = item.chTitle.isEmpty ? nil : item.chTitle
        r.pendingChatPhoto = item.chPhoto.isEmpty ? nil : item.chPhoto
        r.pendingChatPush = true   // Back returns to the Activity page
        r.pendingChatId = item.cid
    }
}

/// The Activity row's Mute (owner 2026-11-10: swipe the row left, Mute). Muted = no pushes about
/// replies, reactions or quotes; items and the unread count still come. The switch lives on the
/// server (`users/{me}/activityMeta/prefs.muted`, written only by groups:setActivityMute, read by
/// replyPushJob); this mirrors it for the row and the swipe button.
@MainActor
@Observable
final class ActivityMute {
    static let shared = ActivityMute()
    private(set) var muted = false
    private var loadedFor = ""

    /// Reads the switch once per signed-in account.
    func loadIfNeeded() {
        guard let uid = Auth.auth().currentUser?.uid, loadedFor != uid else { return }
        loadedFor = uid
        muted = false
        Firestore.firestore().document("users/\(uid)/activityMeta/prefs").getDocument { [weak self] snap, _ in
            Task { @MainActor in
                guard let self, Auth.auth().currentUser?.uid == uid else { return }
                self.muted = snap?.data()?["muted"] as? Bool ?? false
            }
        }
    }

    /// Flips at once; goes back if the server says no.
    func set(_ on: Bool) {
        let was = muted
        muted = on
        Task {
            do {
                _ = try await Functions.functions(region: "me-central1")
                    .httpsCallable("setActivityMute").call(["muted": on])
            } catch {
                await MainActor.run { self.muted = was }
                DiagLog.add("activity: setActivityMute failed \(error.localizedDescription)")
            }
        }
    }
}
