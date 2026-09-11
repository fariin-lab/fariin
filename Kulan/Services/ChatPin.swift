import Foundation
import FirebaseAuth
import FirebaseFunctions

/// CHAT PIN — owner's spec, 2026-09-11, with the reference app's four screens as the look.
///
/// A 4 to 6 digit number a person can hand out. Anybody who types it opens a full conversation with
/// them, past Message Requests and past "My Friends": the pin is a private invitation. In this
/// app's terms a successful pin makes the two of you friends, which is to say the conversation is
/// marked accepted — the same field Accept writes, so nothing downstream learns a new state.
///
/// ⛔ THE PIN NEVER TRAVELS TO A PHONE THAT DID NOT TYPE IT. The server keeps a salted hash and
/// compares on the server (`verifyChatPin`, functions-chatpin in the backend repo); this file only
/// sends digits up and reads success or one sentence back. The one place the digits are kept is the
/// Keychain of the phone that SET them, so the owner can read their own pin off their own screen the
/// way the reference app shows you your own number — `mine` is nil on any other device, and that
/// device is told "set on another device" rather than shown a hash.
///
/// ⛔ ONE SENTENCE FOR EVERY FAILURE (spec §7, §34): a wrong pin, no pin, a block in either
/// direction and a deleted account all come back as `genericFailure`. The server already says the
/// same thing for all of them; this file does not try to be more helpful than the server allows.
/// The lockout is the one refusal that names itself, because "try again in 12 minutes" reveals
/// nothing about the pin.
enum ChatPin {
    static let minDigits = 4
    static let maxDigits = 6
    static let genericFailure = "Unable to verify Chat PIN."

    private static var functions: Functions { Functions.functions(region: "me-central1") }
    private static var uid: String { Auth.auth().currentUser?.uid ?? "" }
    /// Keyed by uid, so a second account signing in on this phone does not inherit the first one's
    /// pin, and signing back in finds it again.
    private static var keychainKey: String { "chatPin.\(uid)" }
    private static var statusKey: String { "chatPin.set.\(uid)" }

    static func isValid(_ pin: String) -> Bool {
        pin.count >= minDigits && pin.count <= maxDigits
            && pin.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// My own pin, as this phone last set it. nil when it was set elsewhere, removed, or never set.
    static var mine: String? { Keychain.get(keychainKey) }
    /// Whether the server holds a pin for me, as last learned — from a set, a remove, or
    /// `refreshStatus`. A phone that has never asked reads false until it does.
    static var isSet: Bool { UserDefaults.standard.bool(forKey: statusKey) }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Set or change. Validated here too, so a malformed pin never costs a round trip.
    static func set(_ pin: String) async throws {
        guard isValid(pin) else {
            throw Failure(message: "A Chat PIN is \(minDigits) to \(maxDigits) digits.")
        }
        // ⛔ NOT THE VERIFY SENTENCE — owner, 2026-09-11, with "Unable to verify Chat PIN." under
        // his own Save button. That line is for typing somebody ELSE's pin, where nothing may be
        // revealed; saving my own has nothing to hide, and the phone should say what happened.
        _ = try await call("setChatPin", ["pin": pin], onFailure: "Couldn’t save your Chat PIN. Try again.")
        Keychain.set(keychainKey, pin)
        UserDefaults.standard.set(true, forKey: statusKey)
    }

    static func remove() async throws {
        _ = try await call("setChatPin", ["pin": ""], onFailure: "Couldn’t remove your Chat PIN. Try again.")
        Keychain.delete(keychainKey)
        UserDefaults.standard.set(false, forKey: statusKey)
    }

    /// Ask the server whether I have one. Returns nil when it could not be asked, and in that case
    /// changes nothing — the page keeps showing what it last knew rather than guessing.
    @discardableResult
    static func refreshStatus() async -> Bool? {
        guard let r = try? await call("chatPinStatus", [:]), let set = r["set"] as? Bool else { return nil }
        UserDefaults.standard.set(set, forKey: statusKey)
        // Removed from another device: the copy here would be a pin that opens nothing.
        if !set { Keychain.delete(keychainKey) }
        return set
    }

    /// Somebody else's pin. Returns the conversation id, now accepted, on success; throws with the
    /// sentence to show on failure.
    static func verify(uid other: String, pin: String) async throws -> String {
        guard isValid(pin) else { throw Failure(message: genericFailure) }
        let r = try await call("verifyChatPin", ["uid": other, "pin": pin])
        guard r["ok"] as? Bool == true, let cid = r["cid"] as? String, !cid.isEmpty else {
            throw Failure(message: genericFailure)
        }
        return cid
    }

    /// `onFailure` is the sentence for everything the server did not word itself: the verify
    /// sentence by default (it must give nothing away), a plain "couldn't save" for my own pin.
    private static func call(_ name: String, _ data: [String: Any],
                             onFailure: String = genericFailure) async throws -> [String: Any] {
        do {
            let result = try await functions.httpsCallable(name).call(data)
            return result.data as? [String: Any] ?? [:]
        } catch {
            throw Failure(message: sentence(for: error, fallback: onFailure))
        }
    }

    /// The server's own words where they are safe to repeat, the fallback everywhere else.
    /// `resourceExhausted` is the lockout and `invalidArgument` is "4 to 6 digits" — both about the
    /// caller, neither about the pin. A `permissionDenied` carries the generic sentence already but
    /// is mapped here too, so a future server message cannot leak through a client that predates it.
    /// A function that is not deployed yet answers `notFound`, which also lands on the fallback —
    /// the case behind his "Unable to verify Chat PIN." under Save on 2026-09-11.
    private static func sentence(for error: Error, fallback: String) -> String {
        let ns = error as NSError
        guard ns.domain == FunctionsErrorDomain, let code = FunctionsErrorCode(rawValue: ns.code) else {
            return fallback
        }
        switch code {
        case .resourceExhausted, .invalidArgument: return ns.localizedDescription
        case .unavailable, .deadlineExceeded: return "Try again in a moment."
        default: return fallback
        }
    }
}
