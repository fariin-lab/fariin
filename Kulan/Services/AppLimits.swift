import Foundation
import Observation
import FirebaseFirestore

// EVERY CEILING THE APP ENFORCES, IN ONE DOCUMENT THE OWNER CAN EDIT WITHOUT A RELEASE.
//
// Read from the reference app, which keeps its limits in one server-delivered blob of named values
// instead of in the client. Their client asks for it at startup and again whenever the server says
// it changed, and their own documentation writes down the rule for a key that is not there: "a
// default value must be used". That single design is why they can widen a limit for everybody on a
// Tuesday and nobody installs anything.
//
// Ours is `config/limits`, one small document, and this is the listener on it. The owner writes it;
// every signed-in phone reads it; `firestore.rules` reads it too, so ONE edit in the console moves
// the app's answer and the database's answer together. That mattered here: the app refuses BEFORE
// the picker opens and the rules refuse at the write, and if the two numbers ever disagree somebody
// gets a picker that opens onto a post that cannot land.
//
// WHY A LISTENER AND NOT A FETCH. Theirs carries a hash so an unchanged config costs nothing to ask
// for, plus a separate push telling clients to ask again. A Firestore snapshot listener is both of
// those already — it delivers on change and stays quiet otherwise — and it answers from the SDK's
// own disk cache on the frame the app launches, which is the piece their cached-config rule exists
// to provide. So the port is smaller than the original, not because corners were cut, but because
// the transport already does two thirds of it.
//
// ⚠️ THE FALLBACKS BELOW AND THE ONES IN `firestore.rules` ARE THE SAME NUMBERS AND HAVE TO STAY
// THAT WAY. A rule cannot read Swift and Swift cannot read a rule, so they are two copies of one
// decision. Change one, change the other, in the same commit.
@Observable
final class AppLimits {
    static let shared = AppLimits()
    private init() {}

    /// THE NUMBERS THIS BUILD SHIPS WITH, and the ones in force until `config/limits` exists at all.
    /// Not "defaults" in the sense of something weak — until somebody writes that document these ARE
    /// the limits, on every phone, and the same values are written into the rules.
    ///
    /// ⚠️ The two hourly numbers are deliberately identical. A badge buys a bigger DAY, which is what
    /// was asked for; the hour is a runaway-loop brake and a verified account can run away just as
    /// fast as anybody else. The pair exists so that raising it later is an edit rather than a build.
    enum Fallback {
        static let storiesPerDayDefault = 50
        static let storiesPerDayVerified = 100
        static let storiesPerHourDefault = 40
        static let storiesPerHourVerified = 40
        static let groupMembersMax = 30   // appLimit('group_members_max', 30) in firestore.rules
        static let pinnedChatsMax = 3
        static let groupsOwnedMax = 10   // groups_owned_max, functions-groups groupCreateCheck
        static let groupDescMax = 150    // group_desc_max (owner 2026-10-21, set from the panel; 150 owner 2026-10-22)
    }

    private var listener: ListenerRegistration?

    /// The document as it stands. Empty until the first snapshot, which is the state every accessor
    /// below is written to survive.
    private(set) var values: [String: Any] = [:]

    // MARK: - The listener

    func start() {
        stop()
        watchSwaps()
        listener = FirestoreHub.db.collection("config").document("limits")
            .addSnapshotListener { [weak self] snap, _ in
                // ⚠️ AN ERROR LEAVES THE LAST GOOD VALUES ALONE. A dropped listener, a rules refusal
                // during a sign-out, a blip — none of those are a reason to fall back to the shipped
                // numbers, which for a raised limit would mean silently taking the raise away from
                // somebody mid-session. `snap` is nil in exactly those cases.
                guard let snap else { return }
                self?.values = snap.data() ?? [:]
            }
    }

    /// Stopped on sign-out with the rest of the listeners. The VALUES are deliberately left in place:
    /// they describe the app, not the person, so there is nothing here for the next account on this
    /// phone to inherit — and clearing them would drop a raised limit back to the shipped one for the
    /// second between one sign-in and the next snapshot.
    func stop() { listener?.remove(); listener = nil }

    /// 2026-10-20 (owner): after `FirestoreHub.swap` the listener belongs to the stuck client. Let go
    /// of it off-main and attach again on the fresh one. The values stay. Added once, on first start.
    @ObservationIgnored private var swapObserver: NSObjectProtocol?
    private func watchSwaps() {
        guard swapObserver == nil else { return }
        swapObserver = NotificationCenter.default.addObserver(
            forName: FirestoreHub.swapped, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.listener != nil else { return }
            FirestoreHub.drop([self.listener])
            self.listener = nil
            self.start()
        }
    }

    // MARK: - Reading one

    /// One key, or the fallback.
    ///
    /// ⚠️ ONLY A WHOLE NUMBER COUNTS, and this is not fussiness — it is what keeps this half honest
    /// with the rules half. The console types a new field as a STRING unless it is told otherwise,
    /// and `appLimit()` in the rules ignores anything that is not an int. If the app were more
    /// generous than the rule here, a limit typed as text would open the picker on a post the
    /// database then refuses.
    ///
    /// Zero and negatives are ignored for a different reason: a limit of zero is indistinguishable
    /// from a mistake, and the mistake locks every account out of the feature.
    private func number(_ key: String, _ fallback: Int) -> Int {
        guard let n = values[key] as? Int, n > 0 else { return fallback }
        return n
    }

    /// ⛔ A SWITCH, NOT A CEILING, AND ZERO IS THE WHOLE POINT OF IT.
    ///
    /// `number` above throws away a 0 on purpose — a ceiling of zero is indistinguishable from a
    /// mistake and the mistake locks everybody out of a feature. For a switch that reasoning
    /// inverts: 0 IS the setting, and dropping it would mean the off switch silently did nothing on
    /// every phone while the database refused every post. That is the worst of both, and it is
    /// exactly what would have shipped if these two had shared one reader.
    ///
    /// Everything else about it is the same: not an integer, missing, or any other number all land
    /// on the fallback, which for every switch is on.
    private func flag(_ key: String, _ fallback: Int) -> Int {
        guard let n = values[key] as? Int else { return fallback }
        return n
    }

    /// Does the SIGNED-IN account carry an active badge?
    ///
    /// Read live off the profile rather than cached, so a badge granted while the app is open takes
    /// effect on the next tap. `showsBadge` is the one definition of verified in this app — a
    /// suspended or revoked record answers false — and it is the same field the rules read.
    ///
    /// ⚠️ Nil profile reads as NOT verified. It is nil for one moment at launch and after a sign-out,
    /// and the honest failure there is the ordinary allowance: the rules are what actually hold the
    /// line, so the cost of being wrong for a moment is a button that says no slightly too early,
    /// never a post that gets through.
    private var amVerified: Bool {
        ProfileStore.shared.me?.verification?.showsBadge == true
    }

    /// A `<thing>_default` / `<thing>_verified` pair, resolved for whoever is signed in — the same
    /// two-tier shape the reference app gives every limit it has.
    ///
    /// ⚠️ A VERIFIED ACCOUNT IS NEVER GIVEN LESS THAN AN ORDINARY ONE. If the owner raises
    /// `_default` and forgets `_verified`, the pair inverts and the badge becomes a punishment. Every
    /// value in play is compared rather than assumed, so the worst a half-finished edit can do is
    /// nothing.
    private func tiered(_ base: String, _ defaultFallback: Int, _ verifiedFallback: Int) -> Int {
        let ordinary = number("\(base)_default", defaultFallback)
        guard amVerified else { return ordinary }
        return max(ordinary, number("\(base)_verified", verifiedFallback))
    }

    // MARK: - Is the feature on at all

    /// ⛔ MAY THIS ACCOUNT POST A STORY, decided on the server and read before anything opens
    /// (owner, 2026-08-21: "the app should check it before opening the photo/video picker").
    ///
    /// Two INDEPENDENT switches, one per kind of account, so all four states are reachable: off for
    /// everybody, on for everybody, verified only, ordinary only. A single three-valued setting —
    /// which is what the reference app uses — cannot express the fourth.
    ///
    /// ⚠️ FAILS OPEN, and every road to this answer does. An unknown value, a value typed as text, a
    /// listener that has not answered yet, a profile that has not loaded: all of them land on true.
    /// The database is the enforcement and it refuses on its own; the only thing this decides is
    /// whether somebody is told before or after choosing a photo, and being told too late is a
    /// smaller failure than a phone that will not let you post when the server says you can.
    ///
    /// ⚠️ AND IT IS THE SAME `!= 0` THE RULE USES, deliberately, not `== 1`. A 3 that means nothing
    /// has to read as ON in both halves or they disagree about who is locked out.
    var storiesEnabled: Bool {
        // A banned account is refused by the rules (`isBanned()` on stories); say it before the
        // picker rather than after the whole story has been made. Fails open like the rest: no
        // profile yet reads as not banned.
        if ProfileStore.shared.me?.banned == true { return false }
        let key = amVerified ? "stories_enabled_verified" : "stories_enabled_default"
        return flag(key, 1) != 0
    }

    /// What to say when it is off. One sentence, his words, and deliberately not a reason: the
    /// reason is ours and it changes, and "the server says no" is not something to put in front of
    /// somebody who only wants to know whether to keep tapping.
    static let storiesOffMessage = "Can't upload story right now."

    // MARK: - The limits themselves

    /// How many stories this account may post in a day. 50, or 100 with a badge, until the document
    /// says otherwise. See the daily counter in `firestore.rules`, which enforces it.
    var storiesPerDay: Int {
        tiered("stories_per_day", Fallback.storiesPerDayDefault, Fallback.storiesPerDayVerified)
    }

    /// How many in an hour. A brake on a runaway loop rather than a policy about people — see the
    /// hourly counter in `firestore.rules`.
    var storiesPerHour: Int {
        tiered("stories_per_hour", Fallback.storiesPerHourDefault, Fallback.storiesPerHourVerified)
    }

    /// The most people a group may hold, you included. Set from the admin panel (2 to 500); the rules
    /// (group create and add) and functions-groups (invite join, request approve) read the same key
    /// with the same fallback of 30.
    var groupMembersMax: Int {
        // Never above Limits.e2eeGroupMax: every group is end-to-end encrypted (owner 2026-10-25).
        min(number("group_members_max", Fallback.groupMembersMax), Limits.e2eeGroupMax)
    }

    /// The member cap of ONE group: the 100 only binds a group that is end-to-end encrypted. A legacy
    /// plain group (`e2ee == false`) keeps the admin panel's own number, as the rules and the server do.
    func groupMembersMax(legacyPlain: Bool) -> Int {
        legacyPlain ? number("group_members_max", Fallback.groupMembersMax) : groupMembersMax
    }

    /// How many chats one person may pin (owner 2026-10-19: 3), from the panel's `pinned_chats_max`.
    var pinnedChatsMax: Int {
        number("pinned_chats_max", Fallback.pinnedChatsMax)
    }

    /// How long a group description may be (owner 2026-10-21: "I want to control it in the admin
    /// panel"), from the panel's `group_desc_max`.
    var groupDescMax: Int {
        number("group_desc_max", Fallback.groupDescMax)
    }

    /// GROUP STORIES NEED A REAL GROUP (owner 2026-10-23): at least this many members, app admins
    /// excepted. Panel row "Members a group needs for stories"; firestore.rules `groupPoster` reads the
    /// same key with the same fallback.
    var groupStoryMinMembers: Int {
        groupStoryMinMembers(country: Locale.current.region?.identifier ?? "")
    }

    /// A country's own number from the panel (`group_story_countries`, "SO": 20), else the global one.
    /// The country is the phone's region, the same one Fariin's country stories use; the rules read it
    /// from the story's `posterCountry`.
    func groupStoryMinMembers(country: String) -> Int {
        if let byCountry = values["group_story_countries"] as? [String: Any],
           let n = byCountry[country.uppercased()] as? Int, n > 0 { return n }
        return number("group_story_min_members", 50)
    }

    /// How many groups one person may own at once (owner 2026-10-20: 10), from the panel's
    /// `groups_owned_max`. The server counts and judges it (groupCreateCheck).
    var groupsOwnedMax: Int {
        number("groups_owned_max", Fallback.groupsOwnedMax)
    }
}
