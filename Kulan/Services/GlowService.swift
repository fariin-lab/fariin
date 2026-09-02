import Foundation
import FirebaseFirestore

// ===== GLOW — the relationship behind Glow Stories =====
//
// His feature, specified 2026-09-02 with five screens: two people who are not friends and have
// never chatted can reach each other's stories by one of them giving the other a Glow.
//
// THE VOCABULARY, exactly as he wrote it, because the three words are one letter apart and the
// whole feature is telling them apart:
//   · GLOWERS  = people who have given ME a glow        (glows where to   == me)
//   · GLOWING  = people I have given a glow             (glows where from == me)
//   · a glow is REMOVABLE (his call) — an edge, not an event.
//
// THE RULINGS THAT SHAPE THE DATA (all his, 2026-09-02):
//   · The Glowers STORY AUDIENCE is the relationship in EITHER direction — glowers plus glowing —
//     so the moment A glows B, B can watch A's glow stories. "Glow back" is social, not a key.
//   · Counts are PUBLIC (they ride the user document, which any signed-in account can get);
//     the NAME LISTS are the owner's alone. That split is enforced by the rules: `glows` documents
//     are listable only by a participant, and only with a query pinned to your own uid — the same
//     shape of decision that closed the user directory on 2026-08-10.
//
// ⛔ SEPARATE FROM FRIENDS BY CONSTRUCTION. Nothing here reads or writes the conversations
// collection; a person can be friend, glower, glowing, all three or none, and no code path merges
// the relationships — his explicit requirement 9.
//
// ONE DOCUMENT PER EDGE: `glows/{from}_{to}` with exactly {from, to, createdAt}. The id is
// deterministic so giving twice is one edge (a set, not a counter), removing is one delete with no
// query, and the rules can check the id against the payload so nobody can write an edge under
// somebody else's name.
//
// COUNTERS ARE THE SERVER'S. `glowerCount` / `glowingCount` live on the user document, maintained
// by the `onGlowWrite` Cloud Function, and both field names sit in `serverOnlyUserFields()` in the
// rules so no phone can inflate its own numbers. This service never writes them.
/// ⚠️ `@Observable`, NOT `ObservableObject`, AND THE DIFFERENCE IS WHETHER THE SCREENS WORK AT ALL.
/// Every store in this app that a view reads is `@Observable` (`ProfileStore`, `StoryAudienceStore`),
/// and the house way to read one is a plain `private var x = Store.shared`. That line observes an
/// `@Observable` and observes NOTHING on an `ObservableObject` — the view would render once with the
/// right answer and then never move again, which is the worst kind of wrong because it looks correct
/// on the first frame. Caught before the Glow screens shipped, not after.
@MainActor @Observable final class GlowService {
    static let shared = GlowService()

    /// Uids of people who glowed me. Live.
    private(set) var glowers: Set<String> = []
    /// Uids of people I glowed. Live.
    private(set) var glowing: Set<String> = []
    /// True once BOTH listeners have delivered their first snapshot. The audience resolve refuses
    /// to post a Glowers story before this is up, for the same reason `resolveAudience` waits for
    /// the chat list: an empty set that means "not loaded yet" must never be read as "no people".
    private(set) var hasLoaded = false

    /// When the person last opened the Glow notifications page — everything newer is "unread".
    /// Kept on the phone: it is a reading position, not shared state, and the notifications page
    /// derives its badge from it without another server field to guard.
    private(set) var seenUpTo: Date

    /// The union, which IS the Glowers story audience (his ruling: either direction).
    var glowRelationship: Set<String> { glowers.union(glowing) }

    private let db = Firestore.firestore()
    private var glowersListener: ListenerRegistration?
    private var glowingListener: ListenerRegistration?
    private var glowersLoaded = false
    private var glowingLoaded = false
    private var uid = ""
    private static let seenKey = "glowSeenUpTo"

    private init() {
        seenUpTo = UserDefaults.standard.object(forKey: Self.seenKey) as? Date
            ?? Date(timeIntervalSince1970: 0)
    }

    /// Called from the same place every other per-account listener starts. Restarting for the same
    /// uid is a no-op; a different uid tears the old pair down first, so an account switch can never
    /// show one account the other's people.
    func start(uid newUid: String) {
        guard newUid != uid else { return }
        stop()
        uid = newUid
        guard !newUid.isEmpty else { return }
        // ⚠️ TWO LISTENERS, NOT ONE OR-QUERY. The rules can only prove a `list` is owner-scoped
        // when the query pins ONE field to the caller's uid; an `or` across from/to is not provable
        // and would be refused wholesale. Two queries, each provable, unioned here.
        glowersListener = db.collection("glows").whereField("to", isEqualTo: newUid)
            .addSnapshotListener { [weak self] snap, _ in
                guard let self, let snap else { return }
                self.glowers = Set(snap.documents.compactMap { $0.data()["from"] as? String })
                self.glowersLoaded = true
                self.hasLoaded = self.glowersLoaded && self.glowingLoaded
            }
        glowingListener = db.collection("glows").whereField("from", isEqualTo: newUid)
            .addSnapshotListener { [weak self] snap, _ in
                guard let self, let snap else { return }
                self.glowing = Set(snap.documents.compactMap { $0.data()["to"] as? String })
                self.glowingLoaded = true
                self.hasLoaded = self.glowersLoaded && self.glowingLoaded
            }
    }

    func stop() {
        glowersListener?.remove(); glowersListener = nil
        glowingListener?.remove(); glowingListener = nil
        glowers = []; glowing = []
        glowersLoaded = false; glowingLoaded = false
        hasLoaded = false
        uid = ""
    }

    /// Give somebody a glow. Optimistic: the set updates now, the snapshot confirms it, and a
    /// refusal (rules) rolls it back by simply not being in the next snapshot.
    func give(to other: String) {
        guard !uid.isEmpty, other != uid, !other.isEmpty else { return }
        glowing.insert(other)
        db.collection("glows").document("\(uid)_\(other)").setData([
            "from": uid,
            "to": other,
            "createdAt": FieldValue.serverTimestamp(),
        ])
    }

    /// Take a glow back — his ruling, removable like a follow. Deleting a document that is not
    /// there is a no-op server-side, so this needs no existence check.
    func remove(to other: String) {
        guard !uid.isEmpty else { return }
        glowing.remove(other)
        db.collection("glows").document("\(uid)_\(other)").delete()
    }

    /// A glower I no longer want on my list — the receiving side's half of "handle a relationship
    /// change" (his requirement 16). The rules let the `to` participant delete the edge too.
    func removeGlower(_ other: String) {
        guard !uid.isEmpty else { return }
        glowers.remove(other)
        db.collection("glows").document("\(other)_\(uid)").delete()
    }

    func isGlowing(_ other: String) -> Bool { glowing.contains(other) }
    func isGlower(_ other: String) -> Bool { glowers.contains(other) }

    /// The newest glows aimed at me, for the notifications page and its badge. The `glows`
    /// documents themselves ARE the record — they carry from + createdAt, which is the whole row —
    /// so there is no second "notifications" collection to keep in sync with the truth.
    func recentGlowers(limit: Int = 50) async -> [(uid: String, at: Date)] {
        guard !uid.isEmpty else { return [] }
        let snap = try? await db.collection("glows")
            .whereField("to", isEqualTo: uid)
            .order(by: "createdAt", descending: true)
            .limit(to: limit).getDocuments()
        return (snap?.documents ?? []).compactMap { d in
            guard let from = d.data()["from"] as? String else { return nil }
            return (from, (d.data()["createdAt"] as? Timestamp)?.dateValue() ?? .distantPast)
        }
    }

    func markSeen() {
        seenUpTo = Date()
        UserDefaults.standard.set(seenUpTo, forKey: Self.seenKey)
    }
}
