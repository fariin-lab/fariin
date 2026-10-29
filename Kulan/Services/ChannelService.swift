import Foundation
import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions

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
        let r = try await fn.httpsCallable("followChannel").call(data)
        return ((r.data as? [String: Any])?["status"] as? String) ?? "following"
    }

    static func unfollow(cid: String) async throws {
        _ = try await fn.httpsCallable("unfollowChannel").call(["cid": cid])
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
                if let err { print("[channel] \(key) refused:", err.localizedDescription) }
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

    static func setMuted(cid: String, _ muted: Bool) {
        let uid = me
        guard !uid.isEmpty else { return }
        ChannelFollows.shared.noteLocal(cid, muted: muted)
        FirestoreHub.db.collection("users").document(uid).collection("channels").document(cid)
            .updateData(["muted": muted]) { err in
                if let err { print("[channel] setMuted refused:", err.localizedDescription) }
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

    struct Entry: Equatable { var read: Int; var muted: Bool; var pinned = false; var archived = false }

    /// The most channels kept live at once (a listener each).
    static let maxLive = 300

    private(set) var entries: [String: Entry] = [:]
    private var docs: [String: Conversation] = [:]
    @ObservationIgnored private var listListener: ListenerRegistration?
    @ObservationIgnored private var docListeners: [String: ListenerRegistration] = [:]
    @ObservationIgnored private var uid: String?
    /// Mark as Unread waiting for the server to agree (cid -> the lowered read count).
    @ObservationIgnored private var lowered: [String: Int] = [:]

    func entry(_ cid: String) -> Entry? { entries[cid] }
    func follows(_ cid: String) -> Bool { entries[cid] != nil }

    /// Each followed channel as a conversation carrying my read count and mute.
    var conversations: [Conversation] {
        docs.compactMap { cid, c in
            guard let e = entries[cid] else { return nil }
            var c = c
            c.followerRead = e.read
            c.followerMuted = e.muted
            c.followerPinned = e.pinned
            c.followerArchived = e.archived
            return c
        }
    }

    func start(uid: String) {
        if self.uid == uid, listListener != nil { return }
        stop()
        self.uid = uid
        listListener = FirestoreHub.db.collection("users").document(uid).collection("channels")
            .limit(to: Self.maxLive)
            .addSnapshotListener { [weak self] snap, error in
                guard let self, let snap else {
                    if let error { print("[channel] follow list error:", error.localizedDescription) }
                    return
                }
                var next: [String: Entry] = [:]
                for d in snap.documents {
                    let data = d.data()
                    next[d.documentID] = Entry(read: (data["read"] as? NSNumber)?.intValue ?? 0,
                                               muted: data["muted"] as? Bool ?? false,
                                               pinned: data["pinned"] as? Bool ?? false,
                                               archived: data["archived"] as? Bool ?? false)
                }
                self.apply(next)
            }
    }

    func stop() {
        FirestoreHub.drop([listListener] + docListeners.values.map { Optional($0) })
        listListener = nil
        docListeners = [:]
        entries = [:]
        docs = [:]
        uid = nil
    }

    /// After `FirestoreHub.swapped`: the listeners belong to the stuck client. Let go of them but
    /// keep the rows on screen; the next `start` listens again on the fresh client.
    func detachForSwap() {
        FirestoreHub.drop([listListener] + docListeners.values.map { Optional($0) })
        listListener = nil
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

    /// My own change, shown at once (the listener confirms it a moment later).
    func noteLocal(_ cid: String, read: Int? = nil, muted: Bool? = nil, pinned: Bool? = nil, archived: Bool? = nil) {
        guard var e = entries[cid] else { return }
        if let read { e.read = max(e.read, read) }
        if let muted { e.muted = muted }
        if let pinned { e.pinned = pinned }
        if let archived { e.archived = archived }
        entries[cid] = e
        ConversationsRepository.shared.channelsChanged()
    }

    private func apply(_ next: [String: Entry]) {
        for (cid, l) in docListeners where next[cid] == nil {
            l.remove()
            docListeners[cid] = nil
            docs[cid] = nil
        }
        for cid in next.keys where docListeners[cid] == nil {
            docListeners[cid] = FirestoreHub.db.collection("conversations").document(cid)
                .addSnapshotListener { [weak self] snap, _ in
                    guard let self else { return }
                    // A deleted (or no longer readable) channel just drops off the list.
                    guard let snap, snap.exists, let data = snap.data(with: .estimate) else {
                        if self.docs.removeValue(forKey: cid) != nil { ConversationsRepository.shared.channelsChanged() }
                        return
                    }
                    self.docs[cid] = Conversation(id: cid, data: data)
                    ConversationsRepository.shared.channelsChanged()
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
        ConversationsRepository.shared.channelsChanged()
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
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak self] in self?.flush() }
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
                    // Not counted (offline, say): free them to go again on the next look.
                    print("[channel] views not sent:", error.localizedDescription)
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
