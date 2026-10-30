import Foundation
import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions

/// ⛔ A CHANNEL'S EMOJI, COMPARED THE SERVER'S WAY (owner 2026-10-29 audit E2/E3). "❤" and "❤️"
/// differ only by a variation selector (U+FE0F, or U+FE0E for the text style), and the server
/// (`canonEmoji`) treats them as one. The app compared them exactly: an allowed "❤️" refused a
/// typed "❤", my pick was not marked as mine on its chip, and an old post with both keys drew two
/// chips. Every channel comparison and count merge goes through here.
enum ChannelEmoji {
    static func key(_ e: String) -> String {
        e.replacingOccurrences(of: "\u{FE0F}", with: "").replacingOccurrences(of: "\u{FE0E}", with: "")
    }
    static func same(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return key(a) == key(b)
    }
    static func contains(_ list: [String], _ e: String) -> Bool { list.contains { same($0, e) } }

    /// A post's counts as shown: keys that are the same emoji folded into one (shown in the form
    /// with the selector), and my pick still on its way moved in at once.
    static func merged(_ base: [String: Int], mine: String?, held: String?) -> [String: Int] {
        var shown: [String: String] = [:]   // key -> the form drawn
        var total: [String: Int] = [:]      // key -> count
        for (e, n) in base {
            let k = key(e)
            if let cur = shown[k], cur.unicodeScalars.count >= e.unicodeScalars.count {} else { shown[k] = e }
            total[k, default: 0] += n
        }
        if (mine != nil || held != nil) && !same(mine, held) {
            if let h = held { total[key(h)] = max(0, (total[key(h)] ?? 0) - 1) }
            if let x = mine {
                let k = key(x)
                if shown[k] == nil { shown[k] = x }
                total[k, default: 0] += 1
            }
        }
        var out: [String: Int] = [:]
        for (k, n) in total where n > 0 { out[shown[k] ?? k] = n }
        return out
    }
}

/// CHANNELS (owner 2026-10-28): a group with a hat. Only admins post, nobody sees who follows, and
/// followers are not members: they live in conversations/{cid}/followers/{uid} (server-written),
/// mirrored in users/{me}/channels/{cid} with my `read` count and `muted`. The server calls live in
/// functions-groups (makeChannel, followChannel, unfollowChannel, addChannelFollowers).
enum ChannelService {
    private static var fn: Functions { Functions.functions(region: "me-central1") }
    private static var me: String { Auth.auth().currentUser?.uid ?? "" }

    /// Turns the group I just created (and am alone in) into a channel.
    static func makeChannel(cid: String) async throws {
        var data: [String: Any] = ["cid": cid]
        // Where Discover lists it: this phone's region (two letters), when it has one.
        if let region = Locale.current.region?.identifier, region.count == 2 { data["country"] = region }
        _ = try await fn.httpsCallable("makeChannel").call(data)
    }

    /// One channel on the Discover page.
    struct Discovered: Identifiable, Equatable {
        let cid: String
        let handle: String
        let title: String
        let photoUrl: String?
        let description: String
        let followerCount: Int
        let verified: Bool
        let label: String
        var id: String { cid }
    }

    /// Public channels, most followed first, this phone's country first (`discoverChannels`).
    static func discover() async throws -> [Discovered] {
        var data: [String: Any] = [:]
        if let region = Locale.current.region?.identifier, region.count == 2 { data["country"] = region }
        let r = try await fn.httpsCallable("discoverChannels").call(data)
        let rows = (r.data as? [String: Any])?["channels"] as? [[String: Any]] ?? []
        return rows.compactMap { d in
            guard let cid = d["cid"] as? String, GroupDirectory.safeId(cid) else { return nil }
            let photo = d["photoUrl"] as? String ?? ""
            return Discovered(cid: cid, handle: d["handle"] as? String ?? "",
                              title: d["title"] as? String ?? "Channel",
                              photoUrl: photo.isEmpty ? nil : photo,
                              description: d["description"] as? String ?? "",
                              followerCount: (d["followerCount"] as? NSNumber)?.intValue ?? 0,
                              verified: d["verified"] as? Bool ?? false,
                              label: d["label"] as? String ?? "")
        }
    }

    /// Follow a public channel, or a private one with its invite `code`. "following" or "already".
    @discardableResult
    static func follow(cid: String, code: String? = nil) async throws -> String {
        var data: [String: Any] = ["cid": cid]
        if let code, !code.isEmpty { data["code"] = code }
        let base = await MainActor.run { knownFollowerCount(cid) }
        let r = try await fn.httpsCallable("followChannel").call(data)
        let status = ((r.data as? [String: Any])?["status"] as? String) ?? "following"
        await MainActor.run {
            LeaveGroupUndo.shared.reopen(cid)   // unfollowed before: back in the list
            // My follow shows in the count at once (the server batches the real one, ~1 min).
            if status != "requested", let base { ChannelCountBias.note(cid, base: base, delta: 1) }
        }
        return status
    }

    static func unfollow(cid: String) async throws {
        let base = await MainActor.run { knownFollowerCount(cid) }
        _ = try await fn.httpsCallable("unfollowChannel").call(["cid": cid])
        if let base { ChannelCountBias.note(cid, base: base, delta: -1) }
    }

    /// The channel's `followerCount` as this phone has it (followed, or one I run), for the bias.
    @MainActor private static func knownFollowerCount(_ cid: String) -> Int? {
        ConversationsRepository.shared.conversations.first { $0.id == cid }?.followerCount
            ?? ChannelFollows.shared.conversations.first { $0.id == cid }?.followerCount
    }

    /// Admins add people; anyone whose own settings refuse it is skipped and comes back in `refused`.
    static func addFollowers(cid: String, uids: [String]) async throws -> (added: [String], refused: [String]) {
        var added: [String] = [], refused: [String] = []
        for start in stride(from: 0, to: uids.count, by: 50) {
            let part = Array(uids[start..<min(uids.count, start + 50)])
            let r = try await fn.httpsCallable("addChannelFollowers").call(["cid": cid, "uids": part])
            let d = r.data as? [String: Any] ?? [:]
            added += d["added"] as? [String] ?? []
            refused += d["refused"] as? [String] ?? []
        }
        return (added, refused)
    }

    /// A text post waiting to go out (functions-groups scheduleChannelPost).
    struct ScheduledPost: Identifiable, Equatable { let id: String; let text: String; let at: Date }

    static func schedule(cid: String, text: String, at: Date) async throws {
        _ = try await fn.httpsCallable("scheduleChannelPost")
            .call(["cid": cid, "text": text, "at": (at.timeIntervalSince1970 * 1000).rounded()])
    }

    static func scheduled(cid: String) async throws -> [ScheduledPost] {
        let r = try await fn.httpsCallable("listScheduledPosts").call(["cid": cid])
        let rows = (r.data as? [String: Any])?["posts"] as? [[String: Any]] ?? []
        return rows.compactMap { d in
            guard let id = d["id"] as? String, let ms = (d["at"] as? NSNumber)?.doubleValue else { return nil }
            return ScheduledPost(id: id, text: d["text"] as? String ?? "", at: Date(timeIntervalSince1970: ms / 1000))
        }
    }

    static func cancelScheduled(id: String) async throws {
        _ = try await fn.httpsCallable("cancelScheduledPost").call(["id": id])
    }

    /// Admins: a page of followers, newest first.
    static func followers(cid: String, after: String?) async throws -> (rows: [ChannelFollowersView.Follower], more: Bool) {
        var data: [String: Any] = ["cid": cid]
        if let after { data["after"] = after }
        let r = try await fn.httpsCallable("listChannelFollowers").call(data)
        let d = r.data as? [String: Any] ?? [:]
        let rows = (d["followers"] as? [[String: Any]] ?? []).compactMap { f -> ChannelFollowersView.Follower? in
            guard let uid = f["uid"] as? String, !uid.isEmpty else { return nil }
            let p = f["photoUrl"] as? String ?? ""
            return .init(uid: uid, name: f["name"] as? String ?? "Fariin user", photoUrl: p.isEmpty ? nil : p)
        }
        return (rows, d["more"] as? Bool ?? false)
    }

    /// Admins: take a follower out, and keep them out when `ban`.
    static func removeFollower(cid: String, uid: String, ban: Bool) async throws {
        _ = try await fn.httpsCallable("removeChannelFollower").call(["cid": cid, "uid": uid, "ban": ban])
    }

    /// Opening a channel wakes the reaction and view steps on the server (2026-10-29): a step
    /// nobody used for a while sleeps, and the first reaction waited a second or two for it.
    /// At most once a minute per channel; the answer is not needed.
    private static var lastWarm: [String: Date] = [:]
    static func warm(cid: String) {
        if let t = lastWarm[cid], Date().timeIntervalSince(t) < 60 { return }
        lastWarm[cid] = Date()
        fn.httpsCallable("reactChannelPost").call(["warm": true]) { _, _ in }
        fn.httpsCallable("channelViews").call(["warm": true]) { _, _ in }
        // Follow or Unfollow is the likely next tap, so wake that one too (owner 2026-10-29: both
        // sat on "…" for seconds on a cold start).
        let next = ChannelFollows.shared.follows(cid) ? "unfollowChannel" : "followChannel"
        fn.httpsCallable(next).call(["warm": true]) { _, _ in }
    }

    /// React to a post (nil takes mine back). The server keeps who picked what private and answers
    /// with the post's counts.
    /// The post's counts with my change in them, as the server answers (nil if it sent none).
    @discardableResult
    static func react(cid: String, mid: String, emoji: String?) async throws -> [String: Int]? {
        var data: [String: Any] = ["cid": cid, "mid": mid]
        if let emoji { data["emoji"] = emoji }
        let r = try await fn.httpsCallable("reactChannelPost").call(data)
        guard let raw = (r.data as? [String: Any])?["counts"] as? [String: Any] else { return nil }
        var out: [String: Int] = [:]
        for (k, v) in raw { if let n = (v as? NSNumber)?.intValue, n > 0 { out[k] = n } }
        return out
    }

    /// The channel's reactions: "all", "some" (with up to 6) or "off".
    /// Returns the set the server kept (audit E2): it drops emoji it refuses, and "some" with none
    /// left comes back "off". nil when the answer has no set (an older server).
    @discardableResult
    static func setReactions(cid: String, mode: String, list: [String]) async throws -> (mode: String, list: [String])? {
        let r = try await fn.httpsCallable("setChannelReactions").call(["cid": cid, "mode": mode, "list": list])
        guard let d = r.data as? [String: Any], let m = d["mode"] as? String else { return nil }
        return (m, d["list"] as? [String] ?? [])
    }

    /// Dismiss an admin (the owner, or the admin who brought them in): they go back to following.
    static func dismissAdmin(cid: String, uid: String) async throws {
        _ = try await fn.httpsCallable("dismissChannelAdmin").call(["cid": cid, "uid": uid])
    }

    /// I have read up to `count` posts (only ever forward).
    static func markRead(cid: String, count: Int) {
        let uid = me
        guard !uid.isEmpty, count > (ChannelFollows.shared.entry(cid)?.read ?? Int.max) else { return }
        ChannelFollows.shared.noteLocal(cid, read: count)
        FirestoreHub.db.collection("users").document(uid).collection("channels").document(cid)
            .updateData(["read": count]) { err in
                if let err { print("[channel] markRead refused:", err.localizedDescription) }
            }
    }

    /// Pinned / archived on my own entry (a follower may not write the channel's document).
    static func setFlag(cid: String, _ key: String, _ on: Bool) {
        let uid = me
        guard !uid.isEmpty, key == "pinned" || key == "archived" else { return }
        ChannelFollows.shared.noteLocal(cid, pinned: key == "pinned" ? on : nil, archived: key == "archived" ? on : nil)
        FirestoreHub.db.collection("users").document(uid).collection("channels").document(cid)
            .updateData([key: on]) { err in
                guard let err else { return }
                print("[channel] \(key) refused:", err.localizedDescription)
                // Said and undone (owner 2026-10-29 audit U12): it used to flip back later in silence.
                DispatchQueue.main.async {
                    ChannelFollows.shared.noteLocal(cid, pinned: key == "pinned" ? !on : nil,
                                                    archived: key == "archived" ? !on : nil)
                    ToastNotice.show("Couldn't change that. Try again.")
                }
            }
    }

    /// Mark as Unread on a followed channel: one post back (the badge shows 1).
    static func markUnread(cid: String, posts: Int) {
        let uid = me
        guard !uid.isEmpty, posts > 0 else { return }
        let back = posts - 1
        ChannelFollows.shared.setReadBack(cid, to: back)
        FirestoreHub.db.collection("users").document(uid).collection("channels").document(cid)
            .updateData(["read": back]) { err in
                if let err { print("[channel] markUnread refused:", err.localizedDescription) }
            }
    }

    /// `until`: ms when the mute ends, 0 = always (owner 2026-10-29: the group menu's durations).
    static func setMuted(cid: String, _ muted: Bool, until: Double = 0) {
        let uid = me
        guard !uid.isEmpty else { return }
        let end = muted ? until : 0
        let before = ChannelFollows.shared.entry(cid)
        ChannelFollows.shared.noteLocal(cid, muted: muted, mutedUntil: end)
        FirestoreHub.db.collection("users").document(uid).collection("channels").document(cid)
            .updateData(["muted": muted, "mutedUntil": end]) { err in
                guard let err else { return }
                print("[channel] setMuted refused:", err.localizedDescription)
                // Said and undone (owner 2026-10-29 audit U12): the bell had already said "Channel
                // muted", then flipped back later with no word.
                DispatchQueue.main.async {
                    if let before {
                        ChannelFollows.shared.noteLocal(cid, muted: before.muted, mutedUntil: before.mutedUntil)
                    }
                    ToastNotice.show("Couldn't change that. Try again.")
                }
            }
    }
}

/// The channels I follow, live: my users/{me}/channels list, plus one listener on each channel's
/// own document (its name, photo, last post, post count). Merged into the chat list by
/// `ConversationsRepository.withPinnedExtras`. Admins of a channel are members and come through
/// the normal chat list instead.
@Observable
final class ChannelFollows {
    static let shared = ChannelFollows()

    struct Entry: Equatable {
        var read: Int; var muted: Bool; var pinned = false; var archived = false
        /// When a timed mute ends, ms (owner 2026-10-29: the group menu's 1 hour … 1 week); 0 = always.
        var mutedUntil: Double = 0
        /// Muted now: on, and its time (if any) not yet passed.
        var isMuted: Bool { muted && (mutedUntil <= 0 || mutedUntil > Date().timeIntervalSince1970 * 1000) }
    }

    /// The most channels kept live at once (a listener each on the channel's own document).
    static let maxLive = 300
    /// The most follow entries read (owner 2026-10-29 audit E4). Was 300, the same as `maxLive`, so
    /// the 301st channel followed was missing everywhere: no bell, no reactions, no stories, and
    /// `follows` said no. Now every entry up to this many is known (`follows`, mute, reactions);
    /// only the chat-list row needs a live document, and those go to the pinned ones first, then
    /// the most recently followed `maxLive`.
    static let maxEntries = 1000

    private(set) var entries: [String: Entry] = [:]
    private var docs: [String: Conversation] = [:]
    /// My reaction on each post, per channel (cid -> mid -> emoji), from my own entry's `rx`.
    /// Apart from `entries` so a reaction never redraws the chat list.
    private(set) var myReactions: [String: [String: String]] = [:]
    /// A pick on screen before the server has it (cid -> mid -> emoji, "" = taken back).
    private(set) var pendingReactions: [String: [String: String]] = [:]
    @ObservationIgnored private var listListener: ListenerRegistration?
    /// My picks in channels I run (owner/admin, 2026-10-29): `users/{me}/channelRx`, kept apart
    /// from follow entries because an admin is not a follower. Merged into `myReactions`.
    @ObservationIgnored private var adminRxListener: ListenerRegistration?
    @ObservationIgnored private var followRx: [String: [String: String]] = [:]
    @ObservationIgnored private var adminRx: [String: [String: String]] = [:]
    @ObservationIgnored private var docListeners: [String: ListenerRegistration] = [:]
    @ObservationIgnored private var uid: String?
    /// Mark as Unread waiting for the server to agree (cid -> the lowered read count).
    @ObservationIgnored private var lowered: [String: Int] = [:]
    /// When each entry was followed (ms), to choose which channels get a live document (E4).
    @ObservationIgnored private var followedAt: [String: Double] = [:]
    /// The first follow-list snapshot has been applied. The launch's first snapshot does not ask
    /// for channel stories again: the tray's own start already did (audit P10, a double run).
    @ObservationIgnored private var listLoaded = false
    /// One chat-list rebuild per burst (audit P9): at launch every channel's document arrives on
    /// its own, and each one rebuilt the whole list.
    @ObservationIgnored private var listRebuildQueued = false
    /// Redraws once the earliest timed mute ends (audit E7/U13): `isMuted` depends on the clock,
    /// and nothing else changes when the hour is up.
    @ObservationIgnored private var muteExpiryTask: Task<Void, Never>?
    /// Bumped when a timed mute ends; read by `entry`, so every view that asks redraws then.
    private(set) var muteTick = 0

    func entry(_ cid: String) -> Entry? { _ = muteTick; return entries[cid] }
    func follows(_ cid: String) -> Bool { entries[cid] != nil }

    /// Each followed channel as a conversation carrying my read count and mute.
    var conversations: [Conversation] {
        docs.compactMap { cid, c in
            guard let e = entries[cid] else { return nil }
            var c = c
            c.followerRead = e.read
            // Muted as of this build, AND its end, so `Conversation.isMuted(me, now:)` also asks the
            // clock (audit E7). The value as of now makes the row differ once a mute runs out, so
            // the list redraws it at `scheduleMuteExpiry`'s rebuild.
            c.followerMuted = e.isMuted
            c.followerMutedUntil = e.mutedUntil
            c.followerPinned = e.pinned
            c.followerArchived = e.archived
            c.followedAtMillis = followedAt[cid] ?? 0
            return c
        }
    }

    func start(uid: String) {
        if self.uid == uid, listListener != nil { return }
        stop()
        self.uid = uid
        listListener = FirestoreHub.db.collection("users").document(uid).collection("channels")
            .limit(to: Self.maxEntries)
            .addSnapshotListener { [weak self] snap, error in
                guard let self, let snap else {
                    if let error { print("[channel] follow list error:", error.localizedDescription) }
                    return
                }
                var next: [String: Entry] = [:]
                var rx: [String: [String: String]] = [:]
                var at: [String: Double] = [:]
                for d in snap.documents {
                    let data = d.data()
                    if let r = data["rx"] as? [String: String], !r.isEmpty { rx[d.documentID] = r }
                    at[d.documentID] = ((data["at"] as? Timestamp)?.dateValue().timeIntervalSince1970 ?? 0) * 1000
                    next[d.documentID] = Entry(read: (data["read"] as? NSNumber)?.intValue ?? 0,
                                               muted: data["muted"] as? Bool ?? false,
                                               pinned: data["pinned"] as? Bool ?? false,
                                               archived: data["archived"] as? Bool ?? false,
                                               mutedUntil: (data["mutedUntil"] as? NSNumber)?.doubleValue ?? 0)
                }
                self.followedAt = at
                self.apply(next)
                self.followRx = rx
                self.mergeRx()
            }
        adminRxListener = FirestoreHub.db.collection("users").document(uid).collection("channelRx")
            .limit(to: Self.maxLive)
            .addSnapshotListener { [weak self] snap, _ in
                guard let self, let snap else { return }
                var rx: [String: [String: String]] = [:]
                for d in snap.documents {
                    if let r = d.data()["rx"] as? [String: String], !r.isEmpty { rx[d.documentID] = r }
                }
                self.adminRx = rx
                self.mergeRx()
            }
    }

    private func mergeRx() {
        let merged = followRx.merging(adminRx) { f, a in f.merging(a) { x, _ in x } }
        if merged != myReactions { myReactions = merged }
    }

    /// My reaction on a post as shown now: a pending pick first, then what the server holds.
    func myReaction(_ cid: String, _ mid: String) -> String? {
        if let p = pendingReactions[cid]?[mid] { return p.isEmpty ? nil : p }
        return myReactions[cid]?[mid]
    }
    /// What the server holds (the counts on the post already include it).
    func confirmedReaction(_ cid: String, _ mid: String) -> String? { myReactions[cid]?[mid] }

    func setPendingReaction(_ cid: String, _ mid: String, _ emoji: String?) {
        pendingReactions[cid, default: [:]][mid] = emoji ?? ""
    }
    /// The server answered: what it holds now, and nothing pending.
    /// ⛔ THE SERVER'S COUNTS UNTIL THE POST CATCHES UP (2026-10-29 review fix). Others' reactions
    /// reach the post in a once-a-minute batch now, so right after my pick lands the post's own
    /// `reactionCounts` do not have it yet, and the chip vanished or showed the old count for up to a
    /// minute. The server's answer (the post's counts with my change applied) is shown instead while
    /// the post still holds the counts it had when I tapped, for two minutes at most.
    struct CountOverride: Hashable { let counts: [String: Int]; let base: [String: Int]; let at: Date }
    private(set) var countOverrides: [String: [String: CountOverride]] = [:]

    func noteServerCounts(_ cid: String, _ mid: String, counts: [String: Int], base: [String: Int]) {
        countOverrides[cid, default: [:]][mid] = CountOverride(counts: counts, base: base, at: Date())
    }

    /// The counts to draw for a post: the server's answer while it is newer than the post.
    func displayCounts(_ cid: String, _ mid: String, post: [String: Int]) -> [String: Int] {
        guard let o = countOverrides[cid]?[mid] else { return post }
        if o.base == post, Date().timeIntervalSince(o.at) < 120 { return o.counts }
        return post   // the batch landed (or it is too old): the post is the truth again
    }

    func settleReaction(_ cid: String, _ mid: String, confirmed: String?) {
        pendingReactions[cid]?[mid] = nil
        // Into the source it came from, so the next snapshot of the OTHER listener's merge keeps it.
        if follows(cid) { followRx[cid, default: [:]][mid] = confirmed }
        else { adminRx[cid, default: [:]][mid] = confirmed }
        mergeRx()
    }

    func stop() {
        FirestoreHub.drop([listListener, adminRxListener] + docListeners.values.map { Optional($0) })
        listListener = nil
        adminRxListener = nil
        docListeners = [:]
        muteExpiryTask?.cancel()
        muteExpiryTask = nil
        listLoaded = false
        followedAt = [:]
        entries = [:]
        docs = [:]
        myReactions = [:]
        followRx = [:]
        adminRx = [:]
        pendingReactions = [:]
        countOverrides = [:]
        uid = nil
    }

    /// After `FirestoreHub.swapped`: the listeners belong to the stuck client. Let go of them but
    /// keep the rows on screen; the next `start` listens again on the fresh client.
    func detachForSwap() {
        FirestoreHub.drop([listListener, adminRxListener] + docListeners.values.map { Optional($0) })
        listListener = nil
        adminRxListener = nil
        docListeners = [:]
        uid = nil
    }

    /// Mark as Unread: the one place `read` goes backwards (noteLocal only moves it forward).
    func setReadBack(_ cid: String, to read: Int) {
        guard var e = entries[cid] else { return }
        e.read = read
        entries[cid] = e
        lowered[cid] = read
        ConversationsRepository.shared.channelsChanged()
    }

    /// The snapshot-driven list rebuild, coalesced to one per 100 ms (audit P9). My own changes
    /// (`noteLocal`, `setReadBack`) still rebuild at once.
    private func queueListRebuild() {
        guard !listRebuildQueued else { return }
        listRebuildQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.listRebuildQueued = false
            ConversationsRepository.shared.channelsChanged()
        }
    }

    /// One wake-up at the earliest timed mute still to end; it redraws and plans the next.
    private func scheduleMuteExpiry() {
        muteExpiryTask?.cancel()
        muteExpiryTask = nil
        let now = Date().timeIntervalSince1970 * 1000
        let ends = entries.values.filter { $0.muted && $0.mutedUntil > now }.map { $0.mutedUntil }
        guard let next = ends.min() else { return }
        // At most a day per wait (review fix 2026-10-29): a far-off or absurd `mutedUntil` (the rules
        // only ask for a number) would overflow UInt64 and trap. A longer mute simply waits again.
        let waitMs = min(max(0, next - now) + 500, 86_400_000)
        let waitNs = UInt64(waitMs) * 1_000_000
        muteExpiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: waitNs)
            guard !Task.isCancelled, let self else { return }
            self.muteTick += 1
            ConversationsRepository.shared.channelsChanged()
            self.scheduleMuteExpiry()
        }
    }

    /// My own change, shown at once (the listener confirms it a moment later).
    func noteLocal(_ cid: String, read: Int? = nil, muted: Bool? = nil, mutedUntil: Double? = nil,
                   pinned: Bool? = nil, archived: Bool? = nil) {
        guard var e = entries[cid] else { return }
        if let read { e.read = max(e.read, read) }
        if let muted { e.muted = muted }
        if let mutedUntil { e.mutedUntil = mutedUntil }
        if let pinned { e.pinned = pinned }
        if let archived { e.archived = archived }
        entries[cid] = e
        ConversationsRepository.shared.channelsChanged()
        if muted != nil || mutedUntil != nil { scheduleMuteExpiry() }
    }

    private func apply(_ next: [String: Entry]) {
        // A channel followed again by any road (link, public page, Follow): back in the list.
        for cid in next.keys where entries[cid] == nil {
            Task { @MainActor in LeaveGroupUndo.shared.reopen(cid) }
        }
        // A channel just followed (or unfollowed): its stories join (or leave) the tray now, not
        // at the next five-minute ask (2026-10-29).
        if listLoaded, Set(next.keys) != Set(entries.keys) {
            Task { @MainActor in StoriesRepository.shared.refreshChannelStories() }
        }
        listLoaded = true
        // A live document for the pinned channels first, then the most recently followed, up to
        // `maxLive` (audit E4). The rest are still followed and known, just not listed live.
        let ranked = next.keys.sorted { a, b in
            let pa = next[a]?.pinned == true, pb = next[b]?.pinned == true
            if pa != pb { return pa }
            return (followedAt[a] ?? 0) > (followedAt[b] ?? 0)
        }
        let live = Set(ranked.prefix(Self.maxLive))
        for (cid, l) in docListeners where !live.contains(cid) {
            l.remove()
            docListeners[cid] = nil
            docs[cid] = nil
        }
        for cid in live where docListeners[cid] == nil {
            docListeners[cid] = FirestoreHub.db.collection("conversations").document(cid)
                .addSnapshotListener { [weak self] snap, _ in
                    guard let self else { return }
                    // A deleted (or no longer readable) channel just drops off the list.
                    guard let snap, snap.exists, let data = snap.data(with: .estimate) else {
                        if self.docs.removeValue(forKey: cid) != nil { self.queueListRebuild() }
                        return
                    }
                    self.docs[cid] = Conversation(id: cid, data: data)
                    self.queueListRebuild()
                }
        }
        // Keep what I marked locally if the server has not caught up yet (a Mark as Unread is
        // taken as the server says once it has).
        var merged = next
        for (cid, e) in merged {
            if let low = lowered[cid] {
                if e.read <= low { lowered[cid] = nil } else { merged[cid]?.read = low; continue }
            }
            if let mine = entries[cid], mine.read > e.read { merged[cid]?.read = mine.read }
        }
        entries = merged
        queueListRebuild()
        scheduleMuteExpiry()
    }
}

/// Channel post views, sent the reference app's way (2026-10-28): the posts that came on screen go
/// into a set per channel, sent no later than 5 s after the first one, at most 100 per call
/// (`channelViews`). A post sent once is never sent again this session; the server counts each
/// person once per post anyway, so a resend after a relaunch only costs a read.
final class ChannelViewQueue {
    static let shared = ChannelViewQueue()

    private let lock = NSLock()
    private var pending: [String: Set<String>] = [:]   // cid -> post ids waiting
    private var sent: Set<String> = []                 // "cid/mid" already sent
    private var flushScheduled = false

    /// Sign-out (audit P14): the next account's views are its own, not skipped as already sent.
    func reset() {
        lock.lock()
        pending = [:]
        sent = []
        lock.unlock()
    }

    func note(cid: String, ids: [String]) {
        guard !ids.isEmpty else { return }
        lock.lock()
        var waiting = pending[cid] ?? []
        for id in ids where !sent.contains("\(cid)/\(id)") { waiting.insert(id) }
        pending[cid] = waiting
        let schedule = !flushScheduled && !waiting.isEmpty
        if schedule { flushScheduled = true }
        lock.unlock()
        guard schedule else { return }
        // 1.5 s (owner 2026-10-29: the first look should count right away), still one call per screenful.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.flush() }
    }

    private func flush() {
        lock.lock()
        let batch = pending
        pending = [:]
        flushScheduled = false
        for (cid, ids) in batch { for id in ids { sent.insert("\(cid)/\(id)") } }
        lock.unlock()
        let fn = Functions.functions(region: "me-central1").httpsCallable("channelViews")
        for (cid, ids) in batch where !ids.isEmpty {
            let all = Array(ids)
            for start in stride(from: 0, to: all.count, by: 100) {
                let part = Array(all[start..<min(all.count, start + 100)])
                fn.call(["cid": cid, "mids": part]) { [weak self] _, error in
                    guard let error, let self else { return }
                    print("[channel] views not sent:", error.localizedDescription)
                    // A refusal (not a follower, banned, channel closed) stays refused: those posts
                    // are not sent again this session (owner 2026-10-29 audit F7: a visitor's views
                    // were refused and re-sent every 1.5 s while they scrolled). Only a failure
                    // that may pass (offline, busy) frees them to go again on the next look.
                    let code = FunctionsErrorCode(rawValue: (error as NSError).code)
                    let refused: Set<FunctionsErrorCode> = [.permissionDenied, .failedPrecondition,
                                                            .notFound, .invalidArgument, .unauthenticated]
                    if (error as NSError).domain == FunctionsErrorDomain, let code, refused.contains(code) { return }
                    self.lock.lock()
                    for id in part { self.sent.remove("\(cid)/\(id)") }
                    self.lock.unlock()
                }
            }
        }
    }
}

/// A channel admin's "post without sound" (2026-10-28), the reference app's bell in the broadcast
/// field: on until switched off, per channel, mine only (users/{me}/channelPrefs/{cid}). The server
/// reads it for each post (onNewMessage) and sends the followers' banner without sound.
@Observable
final class ChannelPosting {
    static let shared = ChannelPosting()
    private(set) var silent: [String: Bool] = [:]
    @ObservationIgnored private var loaded = Set<String>()

    func isSilent(_ cid: String) -> Bool { silent[cid] ?? false }

    /// Read once per channel per launch, when its chat opens.
    func load(_ cid: String) {
        guard let uid = Auth.auth().currentUser?.uid, loaded.insert(cid).inserted else { return }
        FirestoreHub.db.collection("users").document(uid).collection("channelPrefs").document(cid)
            .getDocument { [weak self] snap, _ in
                guard let self, let on = snap?.data()?["silent"] as? Bool else { return }
                DispatchQueue.main.async { self.silent[cid] = on }
            }
    }

    func setSilent(_ cid: String, _ on: Bool) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        silent[cid] = on
        FirestoreHub.db.collection("users").document(uid).collection("channelPrefs").document(cid)
            .setData(["silent": on]) { [weak self] err in
                guard let err else { return }
                print("[channel] silent not saved:", err.localizedDescription)
                DispatchQueue.main.async {
                    self?.silent[cid] = !on
                    ToastNotice.show("Couldn't change that. Try again.")
                }
            }
    }
}

/// Channel admin invites (2026-10-29): invited, never added (functions-groups).
enum ChannelAdminInvites {
    private static var fn: Functions { Functions.functions(region: "me-central1") }

    struct Info: Equatable {
        let code: String, cid: String, title: String, photoUrl: String?
        let expiresAt: Date?, state: String, forMe: Bool, canRevoke: Bool, fromName: String
    }

    struct Pending: Identifiable, Equatable {
        let code: String, uid: String, name: String, photoUrl: String?, expiresAt: Date
        var id: String { code }
    }

    static func link(_ code: String) -> String { "https://fariin.com/a/" + code }

    /// Creates the invites, then sends each person the link in our 1:1 chat. Returns who was refused.
    static func invite(cid: String, title: String, people: [CallMember]) async throws -> [String] {
        let r = try await fn.httpsCallable("inviteChannelAdmins").call(["cid": cid, "uids": people.map(\.uid)])
        let d = r.data as? [String: Any] ?? [:]
        let me = Auth.auth().currentUser?.uid ?? ""
        for row in d["invites"] as? [[String: Any]] ?? [] {
            guard let uid = row["uid"] as? String, let code = row["code"] as? String else { continue }
            let text = "I invited you to be an admin of \u{201C}\(title)\u{201D} on Fariin: " + link(code)
            _ = try? await ChatService.sendText(cid: ChatService.convId(me, uid), text: text)
        }
        let refused = d["refused"] as? [String] ?? []
        return people.filter { refused.contains($0.uid) }.map(\.name)
    }

    static func info(_ code: String) async throws -> Info {
        let r = try await fn.httpsCallable("adminInviteInfo").call(["code": code])
        let d = r.data as? [String: Any] ?? [:]
        let photo = d["photoUrl"] as? String ?? ""
        let exp = (d["expiresAt"] as? NSNumber)?.doubleValue ?? 0
        return Info(code: code, cid: d["cid"] as? String ?? "", title: d["title"] as? String ?? "Channel",
                    photoUrl: photo.isEmpty ? nil : photo,
                    expiresAt: exp > 0 ? Date(timeIntervalSince1970: exp / 1000) : nil,
                    state: d["state"] as? String ?? "open", forMe: d["forMe"] as? Bool ?? false,
                    canRevoke: d["canRevoke"] as? Bool ?? false, fromName: d["fromName"] as? String ?? "Someone")
    }

    /// Accept or decline; the channel's id on accept.
    static func answer(_ code: String, accept: Bool) async throws -> String? {
        let r = try await fn.httpsCallable("answerAdminInvite").call(["code": code, "accept": accept])
        return (r.data as? [String: Any])?["cid"] as? String
    }

    static func revoke(_ code: String) async throws {
        _ = try await fn.httpsCallable("revokeAdminInvite").call(["code": code])
    }

    static func pending(cid: String) async throws -> [Pending] {
        let r = try await fn.httpsCallable("listAdminInvites").call(["cid": cid])
        let rows = (r.data as? [String: Any])?["invites"] as? [[String: Any]] ?? []
        return rows.compactMap { d in
            guard let code = d["code"] as? String, let uid = d["uid"] as? String,
                  let exp = (d["expiresAt"] as? NSNumber)?.doubleValue else { return nil }
            let p = d["photoUrl"] as? String ?? ""
            return Pending(code: code, uid: uid, name: d["name"] as? String ?? "Fariin user",
                           photoUrl: p.isEmpty ? nil : p, expiresAt: Date(timeIntervalSince1970: exp / 1000))
        }
    }
}
