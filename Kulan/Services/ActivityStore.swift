import Foundation
import Observation
import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions

/// One row of the Activity page: someone answered or reacted to one of my comments on a channel post.
/// Written only by the server (`users/{me}/activity/{id}`); see fariin-activity/SPEC.md.
struct ActivityItem: Identifiable, Equatable {
    enum Kind: String { case reply, react, quote }
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
    var target: Ref { kind == .reply ? newRef : mine }

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
    var lastKind: String
    var lastName: String
    var lastText: String
    var lastEmoji: String
    /// When the latest event happened, ms, the same unit as `Conversation.listSortDate`.
    var lastAtMillis: Double

    init(data d: [String: Any]) {
        unread = max(0, (d["unread"] as? NSNumber)?.intValue ?? 0)
        let l = d["last"] as? [String: Any] ?? [:]
        lastKind = l["kind"] as? String ?? ""
        lastName = l["n"] as? String ?? ""
        lastText = l["text"] as? String ?? ""
        lastEmoji = l["emoji"] as? String ?? ""
        lastAtMillis = ((l["at"] as? Timestamp)?.dateValue().timeIntervalSince1970 ?? 0) * 1000
    }

    /// "Nan replied to your comment: thanks" / "Nan reacted ❤️ to your comment".
    var preview: String {
        let name = lastName.isEmpty ? "Someone" : lastName
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
    /// The first answer for the items has come in.
    private(set) var loaded = false

    @ObservationIgnored private var summaryListener: ListenerRegistration?
    @ObservationIgnored private var listListener: ListenerRegistration?
    @ObservationIgnored private var uid: String?

    private init() {}

    /// The chat list's Activity row (owner 2026-11-09): there whenever I have any activity at all,
    /// like a chat, with its badge only while something is unread. nil = no activity, no row.
    var rowSummary: ActivitySummary? {
        if let s = summary, s.lastAtMillis > 0 { return s }
        guard let first = items.first else { return nil }
        // No summary yet (or an old one without `last`): the newest item stands in.
        var s = summary ?? ActivitySummary(data: [:])
        s.lastKind = first.kind.rawValue
        s.lastName = first.fromName
        s.lastText = first.text
        s.lastEmoji = first.emoji
        s.lastAtMillis = first.at.timeIntervalSince1970 * 1000
        return s
    }

    /// The row pinned at the top of Pinned. Kept on this phone per account (the app cannot write
    /// to the activity documents); `SessionWipe` clears it through `wipe()`.
    private(set) var pinned = false

    private static func pinKey(_ uid: String) -> String { "activityPinned.\(uid)" }

    func setPinned(_ on: Bool) {
        guard let uid else { return }
        pinned = on
        if on { UserDefaults.standard.set(true, forKey: Self.pinKey(uid)) }
        else { UserDefaults.standard.removeObject(forKey: Self.pinKey(uid)) }
    }

    /// Sign-out: the listeners, and this account's pin.
    func wipe() {
        if let uid { UserDefaults.standard.removeObject(forKey: Self.pinKey(uid)) }
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
        listListener = me.collection("activity")
            .order(by: "at", descending: true)
            .limit(to: 100)
            .addSnapshotListener { [weak self] snap, _ in
                Task { @MainActor in
                    guard let self, self.uid == uid, let snap else { return }
                    let list = snap.documents.compactMap { ActivityItem(id: $0.documentID, data: $0.data()) }
                    if self.items != list { self.items = list }
                    self.loaded = true
                }
            }
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
    }

    /// Opening the Activity page reads everything. The row's badge goes at once; the
    /// server's answer then comes back through the listeners.
    func markAllRead() async {
        guard uid != nil else { return }
        if var s = summary, s.unread > 0 { s.unread = 0; summary = s }
        do {
            _ = try await Functions.functions(region: "me-central1")
                .httpsCallable("markActivityRead").call([String: Any]())
        } catch {
            DiagLog.add("activity: markActivityRead failed \(error.localizedDescription)")
        }
    }

    /// A tap on an item: the same route a "replied to you" push takes (PushManager's tap handler).
    /// The channel opens on top of the Activity page, then that post's Replies, scrolled to the
    /// comment and flashing it (`PostThreadSheet` spends `pendingReplyTarget`).
    func open(_ item: ActivityItem) {
        let bad: (String) -> Bool = { $0.isEmpty || $0.contains("/") }
        guard !bad(item.cid), !bad(item.mid) else { return }
        let r = AppRouter.shared
        // A quote (owner 2026-11-09): opens where it was posted when that is a public channel, at
        // the quoting message; otherwise my post, with its Replies and Quotes sheet.
        if item.kind == .quote, !bad(item.whereCid), !bad(item.whereMid) {
            r.pendingRepliesPost = nil
            r.pendingReplyTarget = nil
            r.pendingOpenMid = item.whereMid
            r.pendingChatName = item.whereTitle.isEmpty ? nil : item.whereTitle
            r.pendingChatPhoto = nil
            r.pendingChatPush = true
            r.pendingChatId = item.whereCid
            return
        }
        let t = item.kind == .quote ? ActivityItem.Ref() : item.target
        r.pendingRepliesPost = (item.cid, item.mid, Date())
        r.pendingReplyTarget = bad(t.rid) ? nil
            : (item.mid, t.rid, (t.aid.isEmpty || t.aid.contains("/")) ? nil : t.aid, Date())
        r.pendingOpenMid = nil
        r.pendingChatName = item.chTitle.isEmpty ? nil : item.chTitle
        r.pendingChatPhoto = item.chPhoto.isEmpty ? nil : item.chPhoto
        r.pendingChatPush = true   // Back returns to the Activity page
        r.pendingChatId = item.cid
    }
}
