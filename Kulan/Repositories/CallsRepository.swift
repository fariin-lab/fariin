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

    var mine: Bool { callerUid == (Auth.auth().currentUser?.uid ?? "") }
    var missed: Bool { outcome == "missed" || outcome == "declined" }
    /// Red/badge-worthy only when THEY called and I didn't pick up — my own
    /// unanswered outgoing call is just "Outgoing" (standard call-history rule).
    var missedIncoming: Bool { missed && !mine }
}

// Aggregates call records across all of my conversations into one history list.
// Each per-conversation query is an equality filter (type == "call"), which uses the
// automatic single-field index — no composite index to deploy. Sorted client-side.
@Observable
final class CallsRepository {
    static let shared = CallsRepository()
    private init() {}

    private let db = Firestore.firestore()
    var calls: [CallEntry] = []
    var loading = false
    var hasLoaded = false   // false until the first load finishes -> drives the skeleton
    private var lastLoadedAt: Date?

    /// Bumped by reset(). A load that was already in flight when the account changed must NOT
    /// publish its results afterwards — it would repaint the previous account's call log for the
    /// next person, and the 30s TTL then blocked the correcting reload (audit).
    private var generation = 0

    /// Sign-out/delete: drop the previous account's call log.
    func reset() {
        generation &+= 1
        calls = []
        hasLoaded = false
        loading = false
        lastLoadedAt = nil
    }

    // force: true bypasses the 30s TTL (pull-to-refresh). Normal tab-switch passes false so we
    // don't re-fire N concurrent Firestore queries every time the Calls tab becomes visible.
    func load(force: Bool = false) async {
        if !force, hasLoaded, let last = lastLoadedAt, Date().timeIntervalSince(last) < 30 { return }
        // Atomically claim the load so two concurrent calls can't both fan out N queries.
        let proceed = await MainActor.run { () -> Bool in
            if loading { return false }
            loading = true
            return true
        }
        guard proceed else { return }
        guard let me = Auth.auth().currentUser?.uid else { await MainActor.run { loading = false; hasLoaded = true }; return }
        let myGeneration = await MainActor.run { generation }   // see `generation`
        let database = db

        // Safety net: never leave the shimmer skeleton up forever if a query stalls on bad network.
        Task { try? await Task.sleep(nanoseconds: 8_000_000_000)
            await MainActor.run { if !self.hasLoaded { self.hasLoaded = true; self.loading = false } } }

        let convSnap = try? await database.collection("conversations")
            .whereField("users", arrayContains: me).getDocuments()
        let convs = (convSnap?.documents ?? []).map { Conversation(id: $0.documentID, data: $0.data(with: .estimate)) }
            // A silently blocked contact's activity is hidden everywhere else — frozen previews, no
            // unread badges, no reordering — but their timed-out call still wrote a shared record,
            // so the Calls tab showed "Missed call" and badged it red (audit).
            .filter { !$0.isBlockedByMe(me) }

        // Fetch every chat's call records CONCURRENTLY (was sequential = N round-trips in
        // series). Each task builds its own CallEntry list off-main; results merged after.
        var all: [CallEntry] = []
        await withTaskGroup(of: [CallEntry].self) { group in
            for c in convs {
                group.addTask {
                    let other = c.otherUid(me), name = c.name(for: me), photo = c.photoUrl(for: me)
                    guard let snap = try? await database.collection("conversations").document(c.id)
                        .collection("messages").whereField("type", isEqualTo: "call").getDocuments()
                    else { return [] }
                    return snap.documents.map { d in
                        let data = d.data()
                        let ts = data["createdAt"] as? Timestamp
                        return CallEntry(
                            id: d.documentID, cid: c.id,
                            name: name, photoUrl: photo, otherUid: other,
                            callerUid: data["callerUid"] as? String ?? "",
                            outcome: data["callOutcome"] as? String ?? "answered",
                            video: data["callVideo"] as? Bool ?? false,
                            durationSec: (data["callDuration"] as? NSNumber)?.intValue ?? 0,
                            date: ts?.dateValue() ?? Date(timeIntervalSince1970: 0))
                    }
                }
            }
            for await chunk in group { all.append(contentsOf: chunk) }
        }
        all.removeAll { HiddenMessages.isHidden($0.id) }   // locally deleted entries stay gone
        all.sort { $0.date > $1.date }
        await MainActor.run {
            // The account changed while this was in flight → drop the results on the floor.
            guard self.generation == myGeneration else { return }
            self.calls = all; self.loading = false; self.hasLoaded = true; self.lastLoadedAt = Date()
        }
    }

    // DELETING A CALL IS LOCAL-ONLY (audit). A call entry IS the shared
    // conversations/<cid>/messages/call_<id> doc — it is also the other person's history row and the
    // call bubble in both threads. Deleting the doc from a swipe (no confirmation) destroyed THEIR
    // record too, or, if the rules refuse a delete of a doc the other side authored, did nothing at
    // all and the row came straight back on the next load. Every standard messenger hides call-log
    // entries per user, which is what HiddenMessages already does for messages.
    func delete(_ entry: CallEntry) async {
        await MainActor.run {
            HiddenMessages.hide(entry.id)
            calls.removeAll { $0.id == entry.id }
        }
    }

    func delete(ids: Set<String>) async {
        await MainActor.run {
            for id in ids { HiddenMessages.hide(id) }
            calls.removeAll { ids.contains($0.id) }
        }
    }
}
