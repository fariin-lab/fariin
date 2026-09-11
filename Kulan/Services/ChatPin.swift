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
/// ⛔ THE ROWS THAT SHOW THE KEY HAVE TO BE TOLD WHEN IT CHANGES — audit L1, 2026-09-11.
///
/// `ChatPin` is an enum of statics over UserDefaults and the Keychain, and Settings › Chats and
/// Privacy › Messages both read it straight from their `body`. Neither of those is observable, so
/// setting a key and going back left the row saying "Off" until something unrelated happened to
/// re-render it — the value was right, nothing asked for it again.
///
/// One observable object holding one counter, bumped by every write. A row reads `ChatPinState
/// .shared.version` and SwiftUI does the rest. Deliberately not a copy of the key itself: two
/// stores of one secret is how they come to disagree, and the Keychain remains the only place the
/// digits live.
/// ⚠️ NOT `@MainActor`-ISOLATED, DELIBERATELY, AND `StoryDoorState` IS THE PRECEDENT. A SwiftUI
/// `View` holds this as a plain stored property (`private var pinState = ChatPinState.shared`), and
/// a stored property's initialiser does not run on the main actor — isolating `shared` would refuse
/// to compile at every one of those. Mutation is hopped to the main actor by the writers instead.
@Observable final class ChatPinState {
    static let shared = ChatPinState()
    private(set) var version = 0
    func changed() { version &+= 1 }
}

enum ChatPin {
    static let minDigits = 4
    static let maxDigits = 6
    static let genericFailure = "Unable to verify Chat Key."

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
        /// When the caller's cooldown ends, for the refusals that have one. The sheet disables its
        /// own button until then — see `lockedUntil`.
        var lockedUntil: Date?
        var errorDescription: String? { message }
    }

    /// ⛔ THIS PHONE'S OWN COOLDOWN — audit U8. The sentence alone left the sheet with a live Enter
    /// button that could not work: re-opening it told you nothing until you spent another attempt on
    /// a refusal you could not have avoided. The server sends the deadline in the error's `details`;
    /// it is a fact about the CALLER, so it reveals nothing about the key or its owner.
    ///
    /// Kept per account and in UserDefaults rather than in memory, because the lockout outlives the
    /// sheet, the screen and usually the app launch that earned it.
    static var lockedUntil: Date? {
        get {
            let t = UserDefaults.standard.double(forKey: "chatPin.lock.\(uid)")
            guard t > 0 else { return nil }
            let d = Date(timeIntervalSince1970: t)
            return d > Date() ? d : nil
        }
        set {
            let k = "chatPin.lock.\(uid)"
            if let newValue { UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: k) }
            else { UserDefaults.standard.removeObject(forKey: k) }
        }
    }

    /// Set or change. Validated here too, so a malformed pin never costs a round trip.
    static func set(_ pin: String) async throws {
        guard isValid(pin) else {
            throw Failure(message: "A Chat Key is \(minDigits) to \(maxDigits) digits.")
        }
        // ⛔ NOT THE VERIFY SENTENCE — owner, 2026-09-11, with "Unable to verify Chat Key." under
        // his own Save button. That line is for typing somebody ELSE's pin, where nothing may be
        // revealed; saving my own has nothing to hide, and the phone should say what happened.
        _ = try await call("setChatPin", ["pin": pin], onFailure: "Couldn’t save your Chat Key. Try again.")
        Keychain.set(keychainKey, pin)
        UserDefaults.standard.set(true, forKey: statusKey)
        await MainActor.run { ChatPinState.shared.changed() }
    }

    static func remove() async throws {
        _ = try await call("setChatPin", ["pin": ""], onFailure: "Couldn’t remove your Chat Key. Try again.")
        Keychain.delete(keychainKey)
        UserDefaults.standard.set(false, forKey: statusKey)
        await MainActor.run { ChatPinState.shared.changed() }
    }

    /// Forget this device's copy. The server keeps nothing to forget here — deleting the account is
    /// what removes the hash (`onUserDeleted`) — but the digits in this Keychain would otherwise
    /// outlive the account that chose them, under a uid nothing will ever sign in as again.
    static func forgetLocalCopy(uid: String) {
        guard !uid.isEmpty else { return }
        Keychain.delete("chatPin.\(uid)")
        UserDefaults.standard.removeObject(forKey: "chatPin.set.\(uid)")
    }

    /// Ask the server whether I have one. Returns nil when it could not be asked, and in that case
    /// changes nothing — the page keeps showing what it last knew rather than guessing.
    @discardableResult
    static func refreshStatus() async -> Bool? {
        guard let r = try? await call("chatPinStatus", [:]), let set = r["set"] as? Bool else { return nil }
        let was = UserDefaults.standard.bool(forKey: statusKey)
        UserDefaults.standard.set(set, forKey: statusKey)
        // Removed from another device: the copy here would be a pin that opens nothing.
        if !set { Keychain.delete(keychainKey) }
        // When the server's answer changed what this phone believed, the rows showing it have to
        // hear about it too — the same reason `set` and `remove` post.
        if was != set { await MainActor.run { ChatPinState.shared.changed() } }
        // ⛔ WHEN IT WAS SET, for the "set on another device" line — audit L8. The server has always
        // returned this and nothing read it, so a phone that could not show the key could not say
        // anything about it either.
        lastSetAt = (r["updatedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return set
    }

    /// When the server says the key was last set, from the most recent `refreshStatus`. nil until
    /// one has answered, or when there is no key.
    private(set) static var lastSetAt: Date?

    /// Somebody else's pin. Returns the conversation id, now accepted, on success; throws with the
    /// sentence to show on failure.
    static func verify(uid other: String, pin: String) async throws -> String {
        guard isValid(pin) else { throw Failure(message: genericFailure) }
        if let until = lockedUntil { throw Failure(message: lockSentence(until), lockedUntil: until) }
        let r = try await call("verifyChatPin", ["uid": other, "pin": pin])
        guard r["ok"] as? Bool == true, let cid = r["cid"] as? String, !cid.isEmpty else {
            throw Failure(message: genericFailure)
        }
        // A key that opened something proves this phone is not in a guessing run.
        lockedUntil = nil
        return cid
    }

    /// The lockout in this phone's own words, so a locally-known lock reads exactly like the
    /// server's. Minutes, rounded up, never zero.
    static func lockSentence(_ until: Date) -> String {
        let mins = max(1, Int(ceil(until.timeIntervalSinceNow / 60)))
        return "Too many attempts. Try again in \(mins) minute\(mins == 1 ? "" : "s")."
    }

    /// `onFailure` is the sentence for everything the server did not word itself: the verify
    /// sentence by default (it must give nothing away), a plain "couldn't save" for my own pin.
    private static func call(_ name: String, _ data: [String: Any],
                             onFailure: String = genericFailure) async throws -> [String: Any] {
        do {
            let result = try await functions.httpsCallable(name).call(data)
            return result.data as? [String: Any] ?? [:]
        } catch {
            // A lockout carries its deadline in `details`; latch it so the sheet can refuse before
            // spending another attempt, and hand it to the caller for this refusal's own button.
            let until = lockDeadline(in: error)
            if let until { lockedUntil = until }
            throw Failure(message: sentence(for: error, fallback: onFailure), lockedUntil: until)
        }
    }

    /// `{ lockedUntil: <ms since epoch> }` out of a callable error's details, when there is one.
    private static func lockDeadline(in error: Error) -> Date? {
        let ns = error as NSError
        guard ns.domain == FunctionsErrorDomain,
              FunctionsErrorCode(rawValue: ns.code) == .resourceExhausted,
              // ⚠️ THE LITERAL, NOT `FunctionsErrorDetailsKey`. That constant is public in the
              // Functions SDK and its VALUE is this string, but there is no Mac here to compile
              // against — a name that turns out not to be exported costs a 40-minute round trip,
              // and the string cannot.
              let details = ns.userInfo["details"] as? [String: Any],
              let ms = details["lockedUntil"] as? Double, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    /// The server's own words where they are safe to repeat, the fallback everywhere else.
    /// `resourceExhausted` is the lockout and `invalidArgument` is "4 to 6 digits" — both about the
    /// caller, neither about the pin. A `permissionDenied` carries the generic sentence already but
    /// is mapped here too, so a future server message cannot leak through a client that predates it.
    /// A function that is not deployed yet answers `notFound`, which also lands on the fallback —
    /// the case behind his "Unable to verify Chat Key." under Save on 2026-09-11.
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
