import Foundation
import UIKit
import DeclaredAgeRange

/// Ask Apple how old this person is, without ever asking them for a birthday.
///
/// ═══ WHY THIS EXISTS AND WHY IT IS APPLE'S JOB ═══
///
/// Fariin knew nothing about anybody's age. The privacy policy promises "not intended for children
/// under 13... we do not knowingly hold data about them", and the Terms say 13 or older, and until
/// today the app asked nothing at all, so both promises rested on never finding out. The sign-up
/// line added in 95cf506 is the floor: a child taps past it, exactly as they do on WhatsApp,
/// Telegram and Signal, none of which verify anything either.
///
/// This is the part that is not a checkbox. Apple holds a real age on the Apple ID, and for children
/// in a Family Sharing group a parent set it. `AgeRangeService` returns a BAND, never a birthday, so
/// nothing sensitive is collected or stored.
///
/// ⚠️ THE THING THE OTHERS CANNOT DO. WhatsApp and Signal must support ten-year-old Android phones,
/// so this API can never be their answer. Fariin's deployment target is iOS 26, which is exactly the
/// version this shipped in, so EVERY user has it. The constraint the owner already accepted, cutting
/// off old phones, is what makes this available.
///
/// ⚠️ DOES NOT WORK UNTIL THE ENTITLEMENT IS ON, AND THE ENTITLEMENT CANNOT SHIP ALONE.
/// `com.apple.developer.declared-age-range` is deliberately NOT in Kulan.entitlements yet. The App ID
/// com.kulan.messenger.native must have the Declared Age Range capability enabled in the Apple
/// Developer portal FIRST; signing here is manual, so nothing enables it for us, and a profile minted
/// without the entitlement kills the build at the signing step. That exact failure already happened
/// on this project with Associated Domains, and the note is still in Kulan.entitlements.
/// Until then every call here lands in `.unknown`, which is the same behaviour the app has today.
///
/// ⚠️ AND KNOWING IS WORTH NOTHING ON ITS OWN. A band nobody acts on protects nobody. What has to
/// follow is what CHANGES for a minor: not findable by username search, absent from search entirely,
/// public stories off, messages from accepted contacts only. That is the same set of switches as the
/// search-privacy work, which is the argument for building them together.
enum AgeCheck {

    /// What we act on. Deliberately three buckets and not a number, because the decisions the app
    /// makes are three-way and storing anything finer would be collecting more than we need.
    enum Band: String {
        case child     // under 13. Below our own stated minimum.
        case teen      // 13 to 17. Allowed, but not to be findable by strangers.
        case adult     // 18 and over.
        /// They were asked and said no. A SETTLED ANSWER, not a missing one.
        ///
        /// ⚠️ THIS CASE EXISTS BECAUSE ITS ABSENCE WAS A BUG. A decline used to be recorded as
        /// `unknown`, and `hasAnswer` reads `unknown` as "never asked" — so declining put Apple's
        /// sheet up again on EVERY launch, forever. The commit that shipped it claimed the opposite
        /// in as many words. Nagging is bad anywhere and worst here: Apple's "never share" is set by
        /// a parent, so the people re-asked hardest would have been the families most careful about
        /// their children's privacy. Exactly backwards.
        case declined
        /// Nobody has answered yet, or the attempt failed before reaching an answer: no window to
        /// present from, the service unavailable, or the entitlement not yet live. Genuinely
        /// transient, so this one IS retried on a later launch — which is also what lets an install
        /// that predates the entitlement start working once it lands, instead of being written off
        /// forever on one early failure.
        case unknown
    }

    /// The two gates we care about, and they are ours: 13 is the floor in our Terms and privacy
    /// policy, 18 is the line for anything a stranger can reach.
    ///
    /// Apple may OVERRIDE these based on local law where the person is, and that is the correct
    /// behaviour rather than something to work around: a country that sets 16 should get 16 without
    /// us shipping a table of every country's rules and keeping it right forever.
    private static let lowerGate = 13
    private static let upperGate = 18

    /// Remembered so the system sheet is not put in front of the same person on every launch.
    /// Storing the BAND, never a birthday or a bound.
    private static let storeKey = "ageBand.v1"

    static var storedBand: Band {
        Band(rawValue: UserDefaults.standard.string(forKey: storeKey) ?? "") ?? .unknown
    }

    /// True once the question is SETTLED, which is not the same as knowing the age.
    ///
    /// `.declined` counts. Somebody who said no has answered, and the only thing re-asking achieves
    /// is a sheet in their face on every launch. Only `.unknown` reopens the question, and only
    /// because it means the attempt never reached a person.
    static var hasAnswer: Bool { storedBand != .unknown }

    /// Whether anything is actually known about the age, as opposed to the question being closed.
    /// Callers deciding what a minor may do want THIS one, not `hasAnswer` — a decline must read as
    /// "we do not know", never as "adult".
    static var isKnown: Bool {
        switch storedBand {
        case .child, .teen, .adult: return true
        case .declined, .unknown:   return false
        }
    }

    /// Ask Apple. Presents a system sheet, so call it at a moment that makes sense to the person,
    /// not on a cold launch.
    ///
    /// NEVER THROWS. Every failure is `.unknown`, which means "carry on as before". An age check
    /// that can block someone out of a messenger because a system service was unavailable would do
    /// more harm than the thing it is guarding against.
    @discardableResult
    @MainActor
    static func ask() async -> Band {
        guard let presenter = topViewController() else { return .unknown }
        do {
            // ⚠️ IF THIS LINE FAILS TO COMPILE, IT IS THE ONE TO LOOK AT. The signature was read
            // from Apple's published documentation index rather than from the header:
            // `requestAgeRange(ageGates: Int, Int?, Int?, in: UIViewController) async throws
            // -> AgeRangeService.Response`. Three gates are accepted; we pass two and nil.
            let response = try await AgeRangeService.shared.requestAgeRange(
                ageGates: lowerGate, upperGate, nil, in: presenter)

            switch response {
            case .declinedSharing:
                // A refusal is an answer we must accept, and `.declined` rather than `.unknown` is
                // what makes that true in practice: it closes the question so the sheet is never
                // put up again. Apple lets a parent set "never share", and treating a refusal as
                // either suspicion or an invitation to ask again would punish the families most
                // careful about their children's privacy.
                return record(.declined)

            case .sharing(let range):
                return record(band(from: range))

            @unknown default:
                // A future case must not be read as "adult". Unknown is the safe direction because
                // it changes nothing rather than granting something.
                return record(.unknown)
            }
        } catch {
            // Covers AgeRangeService.Error.notAvailable and .invalidRequest, and crucially the
            // missing-entitlement state described at the top of this file.
            return record(.unknown)
        }
    }

    /// Read the band off the bounds Apple returns.
    ///
    /// ⚠️ BOTH BOUNDS ARE OPTIONAL and the nil cases carry the meaning. Apple answers in gates, so a
    /// person over the top gate comes back with a lower bound and NO upper bound, and a child under
    /// the bottom gate comes back with an upper bound and NO lower bound. Reading only `lowerBound`
    /// would quietly classify every child as unknown.
    private static func band(from range: AgeRangeService.AgeRange) -> Band {
        if let upper = range.upperBound, upper < lowerGate { return .child }
        if let lower = range.lowerBound, lower >= upperGate { return .adult }
        if let lower = range.lowerBound, lower >= lowerGate { return .teen }
        // Bounds that straddle a gate, or neither bound present. Do not guess.
        return .unknown
    }

    @discardableResult
    private static func record(_ band: Band) -> Band {
        UserDefaults.standard.set(band.rawValue, forKey: storeKey)
        return band
    }

    /// Same window-scene walk `AuthService.presentationAnchor` uses, for the same reason: there is no
    /// single "the" view controller in a SwiftUI app and the system sheet needs one to hang off.
    private static func topViewController() -> UIViewController? {
        let root = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.rootViewController
        var top = root
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
