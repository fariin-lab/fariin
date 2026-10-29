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
        _ = try await fn.httpsCallable("makeChannel").call(["cid": cid])
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

    struct Entry: Equatable { var read: Int; var muted: Bool }

    /// The most channels kept live at once (a listener each).
    static let maxLive = 300

    private(set) var entries: [String: Entry] = [:]
    private var docs: [String: Conversation] = [:]
    @ObservationIgnored private var listListener: ListenerRegistration?
    @ObservationIgnored private var docListeners: [String: ListenerRegistration] = [:]
    @ObservationIgnored private var uid: String?

    func entry(_ cid: String) -> Entry? { entries[cid] }
    func follows(_ cid: String) -> Bool { entries[cid] != nil }

    /// Each followed channel as a conversation carrying my read count and mute.
    var conversations: [Conversation] {
        docs.compactMap { cid, c in
            guard let e = entries[cid] else { return nil }
            var c = c
            c.followerRead = e.read
            c.followerMuted = e.muted
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
                                               muted: data["muted"] as? Bool ?? false)
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

    /// My own change, shown at once (the listener confirms it a moment later).
    func noteLocal(_ cid: String, read: Int? = nil, muted: Bool? = nil) {
        guard var e = entries[cid] else { return }
        if let read { e.read = max(e.read, read) }
        if let muted { e.muted = muted }
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
        // Keep what I marked locally if the server has not caught up yet.
        var merged = next
        for (cid, e) in merged {
            if let mine = entries[cid], mine.read > e.read { merged[cid]?.read = mine.read }
        }
        entries = merged
        ConversationsRepository.shared.channelsChanged()
    }
}
