import Foundation
import LocalAuthentication

/// "Prove you are the person holding this phone."
///
/// Pulled out of PasswordView the moment a second screen needed it, because the third caller is the
/// one that matters and it is a security gate: a guard that gets re-typed per screen is a guard that
/// gets typed slightly differently per screen.
///
/// ═══ WHAT THIS DEFENDS AND WHAT IT DOES NOT ═══
///
/// There are two attackers on an account and they need two different locks. Getting them the wrong
/// way round feels secure and protects nobody:
///
///   · SOMEBODY HOLDING YOUR UNLOCKED PHONE. An emailed code is no defence at all here — their
///     inbox is your inbox, on the device in their hand. THIS is what stops them, because their
///     face is not yours.
///   · SOMEBODY FAR AWAY who knows your address. This is no defence against them, they never touch
///     the phone. An emailed code is what stops those, which is why Forgot Password uses one.
///
/// So: this gate belongs on anything reachable from inside an already-signed-in app that changes how
/// the account can be entered. Adding a sign-in method, removing one, setting a password.
enum DeviceLock {
    enum Outcome {
        case proved
        /// Cancelled or failed. Offer it again; do not treat it as an error worth scolding over.
        case refused
        /// No Face ID, no Touch ID, and no passcode. Nothing can be proved on this phone.
        case noLock
    }

    /// ⚠️ `.deviceOwnerAuthentication`, NEVER `.deviceOwnerAuthenticationWithBiometrics`.
    ///
    /// The first falls back to the device passcode on its own when Face ID is not enrolled, fails,
    /// or the phone only has Touch ID. The biometrics-only variant refuses outright instead, which
    /// would shut out anyone wearing a mask, anyone with a dirty sensor, and every iPhone SE.
    ///
    /// Note Face ID cannot exist without a passcode — iOS requires one before it will enrol a face —
    /// so `noLock` means the person turned the lock off entirely, not that their phone is old.
    static func prove(reason: String) async -> Outcome {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return .noLock }
        do {
            let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return ok ? .proved : .refused
        } catch {
            return .refused
        }
    }

    /// ⚠️ DELIBERATELY DIFFERENT FROM APP LOCK, and this is the line worth reading twice.
    ///
    /// RootView's App Lock treats "no device lock" as UNLOCK, so a phone with no passcode cannot
    /// trap its owner out of their own messages. Every caller of THIS helper must treat it as
    /// REFUSE, because letting the screen open anyway makes the guard decorative for exactly the
    /// phones that are easiest to pick up off a table.
    ///
    /// The two screens disagreeing is intentional. It is not an inconsistency to tidy away later.
    static let noLockAdvice =
        "This iPhone has no Face ID, Touch ID or passcode, so we cannot tell it is you holding it. "
        + "Add a passcode and come back.\n\nIt is worth doing anyway: without one, anyone who picks "
        + "up this phone can read all your messages."
}
