import Foundation
import Observation
import FirebaseAuth
import FirebaseFirestore

// One row in the call history. Direction is derived by the viewer (callerUid == me).
struct CallEntry: Identifiable, Hashable {
    let id: String          // call message doc id
    let cid: String
    let name: String
    let photoUrl: String?
    let otherUid: String
    let callerUid: String
    let outcome: String     // answered | missed ("declined" exists only in legacy records and counts as missed)
    let video: Bool         // placed as a video call (old records default to voice)
    let durationSec: Int
    let date: Date
    /// Set only on a multi-person (ad-hoc) call; nil on every 1:1 row. For those rows `id` and `cid`
    /// are the room id, `callerUid` is whoever started it, and `name` is the people's title.
    var adhoc: AdhocCallInfo? = nil
    /// Set on a group chat's call (owner 2026-10-20: "group calls show the group's photo and
    /// name"): the group's cid. Its row shows the group and calls the group again.
    var groupCid: String? = nil

    var mine: Bool { callerUid == (Auth.auth().currentUser?.uid ?? "") }
    /// A live row still reading "ringing" after 120s is a call nobody finalised (both phones died
    /// or went offline mid-ring). Audit 2026-09-24: it listed here as an answered call forever. Same
    /// 120s ageing rule the chat bubble already uses.
    var missed: Bool {
        outcome == "missed" || outcome == "declined"
            || (outcome == "ringing" && Date().timeIntervalSince(date) >= 120)
    }
    /// Red/badge-worthy only when THEY called and I didn't pick up — my own
    /// unanswered outgoing call is just "Outgoing" (standard call-history rule).
    var missedIncoming: Bool { missed && !mine }
}

/// ⛔ A GROUP CHAT'S CALL, AS I SAW IT (group call audit 2026-10-23, the reference app's rule).
/// The record (`conversations/{cid}/messages/gcall_*`) is one row shared by the whole group, so its
/// `callOutcome` used to be everybody's: a member who joined a call the server closed "missed" saw
/// red Missed, and one who ignored the ring saw "Incoming · 3 min" because somebody else answered.
/// The server now writes `joinedUids` (everyone who was in it, any device) when the call closes, and
/// `rungUids` (who it rang) when it knows them. Each phone works out its own line from those:
/// - I started it: answered if anybody else came, otherwise my unanswered call ("No answer").
/// - I was in it on any device: answered, whatever else happened.
/// - Rung and never in it: missed.
/// - Never rung (muted group, a group too big to ring) and never in it: `notJoined`, a plain call
///   line with no length, neither missed nor answered (controls audit 5-5, 2026-10-23: it read
///   "answered", an answered-call line for someone who was not in the call).
/// A record without `joinedUids` (an older server, a call still going, any 1:1 call) keeps its
/// stored outcome exactly as before.
/// The server keeps at most `listCap` uids in each list (sorted, `functions/groupCallRecord.js`
/// JOINED_MAX), so a full list may have left me out: a full `joinedUids` makes no claim (stored
/// outcome), and a full `rungUids` counts as not known (rung).
enum GroupCallOutcome {
    static let listCap = 64
    /// Neither missed nor answered; `CallEntry` rows drop the call's length for it.
    static let notJoined = "notJoined"

    static func mine(stored: String?, callerUid: String?, joined: [String]?, rung: [String]?,
                     me: String) -> String? {
        guard let joined, !me.isEmpty, stored != "ongoing", stored != "ringing" else { return stored }
        if callerUid == me { return joined.contains(where: { $0 != me }) ? "answered" : "missed" }
        if joined.contains(me) { return "answered" }
        if joined.count >= listCap { return stored }
        if let rung, rung.count < listCap, !rung.contains(me) { return notJoined }
        return "missed"
    }
}

/// The people on a multi-person call, read from groupCalls/{roomId} (kind == "adhoc").
struct AdhocCallInfo: Hashable {
    let roomId: String
    let members: [String]            // everyone invited, starter included
    let names: [String: String]
    let photos: [String: String]
    let joined: [String]             // everyone who actually connected
    let startedBy: String
    let video: Bool
    let active: Bool
    let startedAt: Date
    let endedAt: Date?

    func name(_ uid: String) -> String { names[uid] ?? "Unknown" }
    func photo(_ uid: String) -> String? { photos[uid].flatMap { $0.isEmpty ? nil : $0 } }
    func others(_ me: String) -> [String] { members.filter { $0 != me } }
    func joinedOthers(_ me: String) -> [String] { joined.filter { $0 != me && members.contains($0) } }
    /// Who the row is named after: the people who joined, or everyone invited when nobody did.
    func titleUids(_ me: String) -> [String] {
        let j = joinedOthers(me)
        return j.isEmpty ? others(me) : j
    }

    init?(id: String, data: [String: Any]) {
        guard data["kind"] as? String == "adhoc" else { return nil }
        roomId = id
        members = data["members"] as? [String] ?? []
        names = data["names"] as? [String: String] ?? [:]
        photos = data["photos"] as? [String: String] ?? [:]
        joined = data["joined"] as? [String] ?? []
        startedBy = data["startedBy"] as? String ?? ""
        video = data["video"] as? Bool ?? false
        active = data["active"] as? Bool ?? false
        startedAt = (data["startedAt"] as? Timestamp)?.dateValue() ?? Date(timeIntervalSince1970: 0)
        endedAt = (data["endedAt"] as? Timestamp)?.dateValue()
    }

    /// The call as I saw it. Started by me and nobody else came → my unanswered outgoing call.
    /// I joined → answered. Invited and never joined → missed. While the room is still live and I
    /// have not joined it reads "ringing", which CallEntry.missed ages into a miss after 120s,
    /// the same rule the 1:1 rows use for a call nobody finalised.
    func entry(me: String, title: String) -> CallEntry {
        let outcome: String
        if startedBy == me {
            outcome = !joinedOthers(me).isEmpty ? "answered" : (active && endedAt == nil ? "ringing" : "missed")
        } else if joined.contains(me) {
            outcome = "answered"
        } else {
            outcome = active && endedAt == nil ? "ringing" : "missed"
        }
        var duration = 0
        if outcome == "answered", let end = endedAt { duration = max(0, Int(end.timeIntervalSince(startedAt))) }
        let first = titleUids(me).first ?? ""
        return CallEntry(
            id: roomId, cid: roomId,
            name: title, photoUrl: photo(first), otherUid: first,
            callerUid: startedBy, outcome: outcome, video: video,
            durationSec: duration, date: startedAt, adhoc: self)
    }
}

// Aggregates call records across all of my conversations into one history list.
// Each per-conversation query is an equality filter (type == "call"), which uses the
// automatic single-field index — no composite index to deploy. Sorted client-side.
@Observable
final class CallsRepository {
    static let shared = CallsRepository()
    private init() {
        // 2026-10-20 (owner): the Firestore client froze and `FirestoreHub` swapped in a fresh one. A
        // load waiting on the stuck client never ends, and `loading` would turn every later load away.
        // Its answer is retired (`generation`) and the log is read again on the fresh client.
        NotificationCenter.default.addObserver(forName: FirestoreHub.swapped, object: nil, queue: .main) { _ in
            let repo = CallsRepository.shared
            guard repo.loading else { return }
            repo.generation &+= 1
            repo.loading = false
            repo.reloadRequested = false
            Task { await repo.load(force: true) }
        }
    }

    private var db: Firestore { FirestoreHub.db }
    var calls: [CallEntry] = []
    var loading = false
    var hasLoaded = false   // false until the first load finishes -> drives the skeleton
    private var lastLoadedAt: Date?
    /// audit M-090, 2026-10-07: a forced load that arrived while another was running used to be
    /// dropped, so the post-call refresh could publish the row as it was BEFORE the call's final
    /// write. Now it is remembered here and the load runs once more when the current one ends.
    private var reloadRequested = false

    /// Bumped by reset(). A load that was already in flight when the account changed must NOT
    /// publish its results afterwards — it would repaint the previous account's call log for the
    /// next person, and the 30s TTL then blocked the correcting reload (audit).
    private var generation = 0

    /// One chat's call rows as last read, with the chat's `updatedAt` at that read (05-calls F3).
    struct ChatCalls {
        let updatedAtMillis: Double
        let entries: [CallEntry]
        let readAt: Date
    }
    @ObservationIgnored private var chatCache: [String: ChatCalls] = [:]
    @ObservationIgnored private var lastFullAt: Date?

    /// A chat's calls are read again when the chat moved since (a new call record bumps `updatedAt`),
    /// when one of its calls may still close (ringing / ongoing: the close does not bump the chat),
    /// or when it had a call in the last two hours (the server closes a record late, after a sweep).
    static func needsRead(_ hit: ChatCalls, updatedAtMillis: Double) -> Bool {
        if updatedAtMillis != hit.updatedAtMillis { return true }
        let recent = Date().addingTimeInterval(-2 * 3600)
        return hit.entries.contains { $0.outcome == "ongoing" || $0.outcome == "ringing" || $0.date > recent }
    }

    /// Sign-out/delete: drop the previous account's call log.
    func reset() {
        generation &+= 1
        chatCache = [:]
        lastFullAt = nil
        calls = []
        hasLoaded = false
        loading = false
        reloadRequested = false
        lastLoadedAt = nil
        HiddenCalls.clear()   // the Calls tab's own hidden set is account-scoped too
    }

    // force: true bypasses the 30s TTL (pull-to-refresh). Normal tab-switch passes false so we
    // don't re-fire N concurrent Firestore queries every time the Calls tab becomes visible.
    func load(force: Bool = false) async {
        if !force, hasLoaded, let last = lastLoadedAt, Date().timeIntervalSince(last) < 30 { return }
        // Atomically claim the load so two concurrent calls can't both fan out N queries.
        let proceed = await MainActor.run { () -> Bool in
            if loading {
                if force { reloadRequested = true }   // audit M-090: run again after, never drop it
                return false
            }
            loading = true
            return true
        }
        guard proceed else { return }
        guard let me = Auth.auth().currentUser?.uid else { await MainActor.run { loading = false; hasLoaded = true }; return }
        let myGeneration = await MainActor.run { generation }   // see `generation`
        let database = db

        // Multi-person calls I was part of, read alongside the chats. `members` array-contains is the
        // automatic single-field index; kind is filtered client-side so no composite index is needed.
        async let adhocSnap = database.collection("groupCalls")
            .whereField("members", arrayContains: me).getDocuments()

        // Safety net: never leave the shimmer skeleton up forever if a query stalls on bad network.
        Task { try? await Task.sleep(nanoseconds: 8_000_000_000)
            await MainActor.run { if !self.hasLoaded { self.hasLoaded = true; self.loading = false } } }

        // audit M-090, 2026-10-07: a thrown query is NOT an empty history. `try?` made the two the
        // same, so a weak network published "No calls", zeroed the badge, and the 30 s TTL then
        // protected the empty list. On a failure the list on screen stays as it was.
        guard let convSnap = try? await database.collection("conversations")
            .whereField("users", arrayContains: me).getDocuments() else {
            let again = await MainActor.run { () -> Bool in
                guard self.generation == myGeneration else { return false }
                self.loading = false; self.hasLoaded = true
                defer { self.reloadRequested = false }
                return self.reloadRequested
            }
            if again { await load(force: true) }
            return
        }
        let convs = convSnap.documents.map { Conversation(id: $0.documentID, data: $0.data(with: .estimate)) }
            // A silently blocked contact's activity is hidden everywhere else — frozen previews, no
            // unread badges, no reordering — but their timed-out call still wrote a shared record,
            // so the Calls tab showed "Missed call" and badged it red (audit).
            .filter { !$0.isBlockedByMe(me) }
            // 2026-09-24 fix-all #97: groups carry call records (GroupCallService.writeRecord).
            // Owner 2026-10-20: they are listed too, as the GROUP (its photo and name), and a tap
            // calls the group again, never one member.

        // Fetch every chat's call records CONCURRENTLY (was sequential = N round-trips in
        // series). Each task builds its own CallEntry list off-main; results merged after.
        var all: [CallEntry] = []
        // audit M-090: the chats whose query failed keep the rows already on screen (below).
        var failedCids: Set<String> = []
        // Full audit 05-calls F3 (2026-10-23): every foreground re-downloaded every call row of every
        // chat. Now a chat is read again only when it can have changed (see `needsRead`); the rest
        // reuse what the last read of that chat found. Every 10 minutes the whole log is read anyway.
        let (cache, fullDue) = await MainActor.run { () -> ([String: ChatCalls], Bool) in
            (self.chatCache, self.lastFullAt.map { Date().timeIntervalSince($0) > 600 } ?? true)
        }
        var reused: [String: ChatCalls] = [:]
        var toRead: [Conversation] = []
        for c in convs {
            if !fullDue, let hit = cache[c.id], !Self.needsRead(hit, updatedAtMillis: c.updatedAtMillis) {
                reused[c.id] = hit
                all.append(contentsOf: hit.entries)
            } else {
                toRead.append(c)
            }
        }
        var freshCache: [String: ChatCalls] = reused
        await withTaskGroup(of: (String, Double, [CallEntry]?).self) { group in
            for c in toRead {
                group.addTask {
                    let group = c.isGroup
                    let other = group ? "" : c.otherUid(me)
                    let name = group ? (c.title.isEmpty ? "Group" : c.title) : c.name(for: me)
                    let photo = group ? c.avatarUrl : c.photoUrl(for: me)
                    guard let snap = try? await database.collection("conversations").document(c.id)
                        .collection("messages").whereField("type", isEqualTo: "call").getDocuments()
                    else { return (c.id, c.updatedAtMillis, nil) }
                    return (c.id, c.updatedAtMillis,
                            Self.entries(snap.documents, cid: c.id, name: name, photo: photo, other: other,
                                         group: group))
                }
            }
            for await (cid, updated, chunk) in group {
                if let chunk {
                    all.append(contentsOf: chunk)
                    freshCache[cid] = ChatCalls(updatedAtMillis: updated, entries: chunk, readAt: Date())
                } else {
                    failedCids.insert(cid)
                }
            }
        }
        let newCache = freshCache, wasFull = fullDue
        let adhocResult = try? await adhocSnap
        let adhocInfos = (adhocResult?.documents ?? [])
            .compactMap { AdhocCallInfo(id: $0.documentID, data: $0.data(with: .estimate)) }
        // The title comes from GroupCallService, which lives on the main actor.
        let adhocEntries = await MainActor.run {
            adhocInfos.map { info in
                info.entry(me: me, title: GroupCallService.title(for: info.titleUids(me).map { info.name($0) }))
            }
        }
        all.append(contentsOf: adhocEntries)
        let loaded = all, failed = failedCids, adhocFailed = adhocResult == nil
        let again = await MainActor.run { () -> Bool in
            // The account changed while this was in flight → drop the results on the floor.
            guard self.generation == myGeneration else { return false }
            var merged = loaded
            // audit M-090: what could not be read this time stays as it was, instead of vanishing.
            if !failed.isEmpty { merged += self.calls.filter { $0.adhoc == nil && failed.contains($0.cid) } }
            if adhocFailed { merged += self.calls.filter { $0.adhoc != nil } }
            merged.removeAll { HiddenCalls.isHidden($0.id) }   // locally deleted entries stay gone
            merged.sort { $0.date > $1.date }
            self.calls = merged; self.loading = false; self.hasLoaded = true
            self.chatCache = newCache   // chats gone from my list drop out with it
            // A partial read is not a fresh list: leave the TTL open so the next visit tries again.
            if failed.isEmpty, !adhocFailed {
                self.lastLoadedAt = Date()
                if wasFull { self.lastFullAt = Date() }
            }
            defer { self.reloadRequested = false }
            return self.reloadRequested
        }
        if again { await load(force: true) }
    }

    /// One chat's call rows as history entries (shared by the full load and the post-call refresh).
    private static func entries(_ docs: [QueryDocumentSnapshot], cid: String,
                                name: String, photo: String?, other: String,
                                group: Bool = false) -> [CallEntry] {
        let me = Auth.auth().currentUser?.uid ?? ""
        return docs.map { d in
            let data = d.data()
            let ts = data["createdAt"] as? Timestamp
            let caller = data["callerUid"] as? String ?? ""
            // A group chat's call reads as I saw it (`GroupCallOutcome`); a 1:1 record never carries
            // `joinedUids`, so it is untouched.
            let stored = data["callOutcome"] as? String ?? "answered"
            let outcome = group
                ? (GroupCallOutcome.mine(stored: stored, callerUid: caller,
                                         joined: data["joinedUids"] as? [String],
                                         rung: data["rungUids"] as? [String], me: me) ?? stored)
                : stored
            var e = CallEntry(
                id: d.documentID, cid: cid,
                name: name, photoUrl: photo, otherUid: other,
                callerUid: caller,
                outcome: outcome,
                video: data["callVideo"] as? Bool ?? false,
                // 5-5: a call I was never in has no length for me.
                durationSec: outcome == GroupCallOutcome.notJoined
                    ? 0 : (data["callDuration"] as? NSNumber)?.intValue ?? 0,
                date: ts?.dateValue() ?? Date(timeIntervalSince1970: 0))
            if group { e.groupCid = cid }
            return e
        }
    }

    /// audit M-150, 2026-10-07: the end of a 1:1 call. Every call end ran a FULL load, one query per
    /// chat downloading every call row ever made, when only this one chat's rows can have changed.
    /// Now just that chat is re-read and swapped in. Falls back to the full load when the list has
    /// no row for this chat yet (its name and photo come from there), or a load is already running
    /// (the forced load then queues a re-run, see `reloadRequested`).
    func refreshAfterCall(cid: String) async {
        let known: CallEntry? = await MainActor.run {
            (hasLoaded && !loading) ? calls.first(where: { $0.cid == cid && $0.adhoc == nil }) : nil
        }
        guard let known else { await load(force: true); return }
        let myGeneration = await MainActor.run { generation }
        guard let snap = try? await db.collection("conversations").document(cid)
            .collection("messages").whereField("type", isEqualTo: "call").getDocuments() else { return }
        // A group's rows stay group rows (audit 2026-10-23: group calls refresh through here too).
        let fresh = Self.entries(snap.documents, cid: cid, name: known.name,
                                 photo: known.photoUrl, other: known.otherUid,
                                 group: known.groupCid != nil)
        await MainActor.run {
            guard self.generation == myGeneration else { return }
            // A full load started meanwhile will publish this chat too, after it ends.
            guard !self.loading else { self.reloadRequested = true; return }
            // Full audit 05-calls F5: HiddenCalls is a plain Set a swipe-delete changes on main; this
            // runs from ChatService.recordCall off main, so it is read here, on main, not before.
            let shown = fresh.filter { !HiddenCalls.isHidden($0.id) }
            var merged = self.calls.filter { !($0.cid == cid && $0.adhoc == nil) } + shown
            merged.sort { $0.date > $1.date }
            self.calls = merged
        }
    }

    // DELETING A CALL IS LOCAL-ONLY (audit). A call entry IS the shared
    // conversations/<cid>/messages/call_<id> doc — it is also the other person's history row and the
    // call bubble in both threads. Deleting the doc from a swipe (no confirmation) destroyed THEIR
    // record too, or, if the rules refuse a delete of a doc the other side authored, did nothing at
    // all and the row came straight back on the next load. Every standard messenger hides call-log
    // entries per user, which is what HiddenMessages already does for messages.
    // A multi-person row's id is its room id, so the same hide covers those too.
    func delete(_ entry: CallEntry) async {
        await MainActor.run {
            // Owner audit 2026-10-06 #37: HiddenCalls, not HiddenMessages, so the chat bubble stays.
            HiddenCalls.hide(entry.id)
            calls.removeAll { $0.id == entry.id }
        }
    }

    func delete(ids: Set<String>) async {
        await MainActor.run {
            for id in ids { HiddenCalls.hide(id) }
            calls.removeAll { ids.contains($0.id) }
        }
    }
}

/// The Calls tab's own "deleted for me" set. Owner audit 2026-10-06 #37: history rows and chat call
/// bubbles used to share HiddenMessages, so deleting in one place hid the call in the other.
/// Upgrade: the first time it is read, the set is seeded from the existing HiddenMessages ids, so
/// every call row already deleted stays gone (and those bubbles stay hidden in chat, as before).
enum HiddenCalls {
    private static let key = "hiddenCalls"
    private static var cache: Set<String> = {
        let d = UserDefaults.standard
        if let stored = d.string(forKey: key) {
            return Set(stored.split(separator: " ").map(String.init))
        }
        let seed = d.string(forKey: "hiddenMessages") ?? ""
        d.set(seed, forKey: key)
        return Set(seed.split(separator: " ").map(String.init))
    }()
    static func isHidden(_ id: String) -> Bool { cache.contains(id) }
    static func hide(_ id: String) {
        guard !id.isEmpty, !cache.contains(id) else { return }
        cache.insert(id)
        UserDefaults.standard.set(cache.joined(separator: " "), forKey: key)
    }
    static func clear() {
        cache.removeAll()
        UserDefaults.standard.removeObject(forKey: key)
    }
}
