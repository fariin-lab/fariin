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

    /// True while either listener's latest callback was an error instead of a snapshot. Before
    /// this, both listeners swallowed the error and bailed, so a refused query looked exactly like
    /// "still loading" forever: `hasLoaded` false, sets empty, nothing to say why. A screen can now
    /// tell the two apart. Cleared by the next good snapshot from that listener, and by
    /// `start`/`stop`.
    private(set) var hasFailed = false

    /// The error from the most recent give/remove the server refused; nil once a write succeeds.
    /// By the time it is set the local set has already been rolled back, so a screen only has to
    /// show it, not repair anything. Cleared by `stop()`.
    private(set) var lastWriteError: (any Error)?

    /// When the person last opened the Glow notifications page — everything newer is "unread".
    /// Kept on the phone: it is a reading position, not shared state, and the notifications page
    /// derives its badge from it without another server field to guard.
    ///
    /// Stored per uid (see `seenKey(for:)`) because a reading position is one account's memory.
    /// Under a single key the next account signed in on this phone inherited the previous one's
    /// "read up to here" and saw its own new glows as already seen. Loaded in `start`, reset in
    /// `stop`.
    private(set) var seenUpTo = Date(timeIntervalSince1970: 0)

    /// The union, which IS the Glowers story audience (his ruling: either direction).
    ///
    /// ⚠️ THE DEMO IS ADDED HERE, AT THE ONE PLACE EVERY SURFACE ALREADY ASKS, so the Stories grid,
    /// the lists, the counts and the audience subtitle all see the same invented people without a
    /// single screen learning that demo mode exists. Two gates guard it — TestFlight-or-debug, and
    /// his handle — see `GlowDemo`.
    ///
    /// ⛔ **DELIBERATELY NOT IN THE POSTED AUDIENCE.** `StoryAudienceStore` reads
    /// `glowRelationship` for the Glowers subtitle's COUNT, which is what should include them, but
    /// `ShareStorySheet` resolves the real recipients through `GlowService.shared.glowRelationship`
    /// too — and a demo uid in `recipientUids` would write a fake person into a REAL story
    /// document, permanently, with `recipientUids` pinned immutable. So the post path strips them:
    /// see `realGlowRelationship`, which is what the sheet and `resolveAudience` use.
    var glowRelationship: Set<String> {
        GlowDemo.isOn ? glowers.union(glowing).union(GlowDemo.glowerIds).union(GlowDemo.glowingIds)
                      : glowers.union(glowing)
    }

    /// The union with NO demo people in it — what a real post is addressed to. A demo uid reaching
    /// `recipientUids` would be written into a story document that can never be edited afterwards.
    ///
    /// The sets should never hold a demo uid in the first place (`give`, `remove` and
    /// `removeGlower` all refuse them), but the filter stays anyway: the cost of one slipping
    /// through is a fake recipient pinned into a real story forever, and a filter is free.
    var realGlowRelationship: Set<String> {
        glowers.union(glowing).filter { !GlowDemo.isDemoPerson($0) }
    }

    /// The lists as the SCREENS see them, demo included.
    var displayGlowers: Set<String> { GlowDemo.isOn ? glowers.union(GlowDemo.glowerIds) : glowers }
    var displayGlowing: Set<String> { GlowDemo.isOn ? glowing.union(GlowDemo.glowingIds) : glowing }

    private let db = Firestore.firestore()
    private var glowersListener: ListenerRegistration?
    private var glowingListener: ListenerRegistration?
    private var glowersLoaded = false
    private var glowingLoaded = false
    private var glowersFailed = false
    private var glowingFailed = false
    private var uid = ""

    /// One reading position per account, so a shared phone never carries one person's position
    /// into another's session.
    private static func seenKey(for uid: String) -> String { "glowSeenUpTo.\(uid)" }

    private init() {}

    /// Called from the same place every other per-account listener starts. Restarting for the same
    /// uid is a no-op; a different uid tears the old pair down first, so an account switch can never
    /// show one account the other's people.
    func start(uid newUid: String) {
        guard newUid != uid else { return }
        stop()
        uid = newUid
        guard !newUid.isEmpty else { return }
        seenUpTo = UserDefaults.standard.object(forKey: Self.seenKey(for: newUid)) as? Date
            ?? Date(timeIntervalSince1970: 0)
        // ⚠️ TWO LISTENERS, NOT ONE OR-QUERY. The rules can only prove a `list` is owner-scoped
        // when the query pins ONE field to the caller's uid; an `or` across from/to is not provable
        // and would be refused wholesale. Two queries, each provable, unioned here.
        //
        // ⚠️ EACH CLOSURE CHECKS IT STILL BELONGS TO THIS UID BEFORE TOUCHING ANYTHING. A callback
        // can already be queued when `stop()` runs; without the check it lands after the next
        // `start` and fills the new account's sets with the old account's people, which is the
        // exact leak `SessionWipe` calls `stop()` to prevent. `newUid` is captured for that.
        //
        // An error callback records the failure instead of vanishing. `hasLoaded` stays false on
        // error on purpose: an empty set that means "refused" must not be read as "no people".
        glowersListener = db.collection("glows").whereField("to", isEqualTo: newUid)
            .addSnapshotListener { [weak self] snap, error in
                guard let self, self.uid == newUid else { return }
                guard let snap else {
                    if let error { print("glow: glowers listener failed:", error) }
                    self.glowersFailed = true
                    self.hasFailed = true
                    return
                }
                self.glowers = Set(snap.documents.compactMap { $0.data()["from"] as? String })
                self.glowersLoaded = true
                self.glowersFailed = false
                self.hasLoaded = self.glowersLoaded && self.glowingLoaded
                self.hasFailed = self.glowersFailed || self.glowingFailed
            }
        glowingListener = db.collection("glows").whereField("from", isEqualTo: newUid)
            .addSnapshotListener { [weak self] snap, error in
                guard let self, self.uid == newUid else { return }
                guard let snap else {
                    if let error { print("glow: glowing listener failed:", error) }
                    self.glowingFailed = true
                    self.hasFailed = true
                    return
                }
                self.glowing = Set(snap.documents.compactMap { $0.data()["to"] as? String })
                self.glowingLoaded = true
                self.glowingFailed = false
                self.hasLoaded = self.glowersLoaded && self.glowingLoaded
                self.hasFailed = self.glowersFailed || self.glowingFailed
            }
    }

    func stop() {
        glowersListener?.remove(); glowersListener = nil
        glowingListener?.remove(); glowingListener = nil
        glowers = []; glowing = []
        glowersLoaded = false; glowingLoaded = false
        glowersFailed = false; glowingFailed = false
        hasLoaded = false
        hasFailed = false
        lastWriteError = nil
        // The reading position belongs to the account that just left; the next `start` loads its own.
        seenUpTo = Date(timeIntervalSince1970: 0)
        uid = ""
    }

    /// Give somebody a glow. Optimistic: the set updates now and the snapshot confirms it. If the
    /// server refuses, the completion rolls the set back and records the error in
    /// `lastWriteError`, so a refused glow never sits in the list looking accepted.
    ///
    /// CREATE-ONLY. The rules accept a `glows` document as a create and refuse it as an update, so
    /// giving a glow that already exists is not a harmless repeat but a refused write. When the
    /// edge is already in `glowing` nothing is sent.
    ///
    /// Demo people are refused before anything moves: they exist only on this device, and an edge
    /// written under one of their ids would be a real document naming nobody.
    ///
    /// `completion` is called exactly once: nil when the write succeeded or there was nothing to
    /// send, the error otherwise. The no-argument call keeps working for every existing button.
    func give(to other: String, completion: (((any Error)?) -> Void)? = nil) {
        guard !uid.isEmpty, other != uid, !other.isEmpty, !GlowDemo.isDemoPerson(other),
              !glowing.contains(other) else { completion?(nil); return }
        let forUid = uid
        glowing.insert(other)
        db.collection("glows").document("\(forUid)_\(other)").setData([
            "from": forUid,
            "to": other,
            "createdAt": FieldValue.serverTimestamp(),
        ]) { [weak self] error in
            // A completion that lands after an account switch must not touch the new account's
            // set in either direction; the error is still handed to whoever asked.
            guard let self, self.uid == forUid else { completion?(error); return }
            if let error {
                self.glowing.remove(other)
                self.lastWriteError = error
            } else {
                self.lastWriteError = nil
            }
            completion?(error)
        }
    }

    /// Take a glow back — his ruling, removable like a follow. Deleting a document that is not
    /// there is a no-op server-side, so this needs no existence check. Same guards as `give`: an
    /// empty or demo uid was never written and must not be deleted under either. A refusal puts
    /// the edge back locally (only if it was there) and records the error in `lastWriteError`.
    func remove(to other: String, completion: (((any Error)?) -> Void)? = nil) {
        guard !uid.isEmpty, other != uid, !other.isEmpty, !GlowDemo.isDemoPerson(other) else {
            completion?(nil); return
        }
        let forUid = uid
        let wasGlowing = glowing.remove(other) != nil
        db.collection("glows").document("\(forUid)_\(other)").delete { [weak self] error in
            guard let self, self.uid == forUid else { completion?(error); return }
            if let error {
                if wasGlowing { self.glowing.insert(other) }
                self.lastWriteError = error
            } else {
                self.lastWriteError = nil
            }
            completion?(error)
        }
    }

    /// A glower I no longer want on my list — the receiving side's half of "handle a relationship
    /// change" (his requirement 16). The rules let the `to` participant delete the edge too.
    /// Guards and rollback as in `remove`.
    func removeGlower(_ other: String, completion: (((any Error)?) -> Void)? = nil) {
        guard !uid.isEmpty, other != uid, !other.isEmpty, !GlowDemo.isDemoPerson(other) else {
            completion?(nil); return
        }
        let forUid = uid
        let wasGlower = glowers.remove(other) != nil
        db.collection("glows").document("\(other)_\(forUid)").delete { [weak self] error in
            guard let self, self.uid == forUid else { completion?(error); return }
            if let error {
                if wasGlower { self.glowers.insert(other) }
                self.lastWriteError = error
            } else {
                self.lastWriteError = nil
            }
            completion?(error)
        }
    }

    func isGlowing(_ other: String) -> Bool { glowing.contains(other) }
    func isGlower(_ other: String) -> Bool { glowers.contains(other) }

    /// The newest glows aimed at me, for the notifications page and its badge. The `glows`
    /// documents themselves ARE the record — they carry from + createdAt, which is the whole row —
    /// so there is no second "notifications" collection to keep in sync with the truth.
    ///
    /// THROWS ON A FAILED READ. The notifications page has to tell "nobody has glowed you" from
    /// "the request failed", the same distinction `fetchViewers` keeps with its nil; an error
    /// swallowed here painted an empty page over a dropped connection. Signed out returns [],
    /// which is the honest answer, not a failure.
    func fetchRecentGlowers(limit: Int = 50) async throws -> [(uid: String, at: Date)] {
        guard !uid.isEmpty else { return [] }
        let snap = try await db.collection("glows")
            .whereField("to", isEqualTo: uid)
            .order(by: "createdAt", descending: true)
            .limit(to: limit).getDocuments()
        return snap.documents.compactMap { d in
            guard let from = d.data()["from"] as? String else { return nil }
            return (from, (d.data()["createdAt"] as? Timestamp)?.dateValue() ?? .distantPast)
        }
    }

    /// The old shape, kept only so its one caller compiles until it moves to
    /// `fetchRecentGlowers`. It collapses a failed read into [], the very thing the throwing
    /// version exists to stop, so nothing new should call it.
    @available(*, deprecated, message: "Use fetchRecentGlowers(limit:); it throws on a failed read instead of returning [].")
    func recentGlowers(limit: Int = 50) async -> [(uid: String, at: Date)] {
        (try? await fetchRecentGlowers(limit: limit)) ?? []
    }

    func markSeen() {
        // Nobody signed in means no account to remember the position for.
        guard !uid.isEmpty else { return }
        seenUpTo = Date()
        UserDefaults.standard.set(seenUpTo, forKey: Self.seenKey(for: uid))
    }
}
