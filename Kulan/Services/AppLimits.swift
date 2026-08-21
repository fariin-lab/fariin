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
    }

    private var listener: ListenerRegistration?

    /// The document as it stands. Empty until the first snapshot, which is the state every accessor
    /// below is written to survive.
    private(set) var values: [String: Any] = [:]

    // MARK: - The listener

    func start() {
        stop()
        listener = Firestore.firestore().collection("config").document("limits")
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
}
