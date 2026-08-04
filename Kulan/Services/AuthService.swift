import Foundation
import Observation
import FirebaseAuth
import FirebaseCore
import FirebaseFunctions
import AuthenticationServices
import CryptoKit
import UIKit

/// Accounts. Three doors — Sign in with Apple, Google, email+password — plus the legacy
/// anonymous sessions existing testers still ride on. Whenever a real credential arrives
/// while an ANONYMOUS user is signed in, we LINK instead of signing in, so the uid (and
/// with it every chat, key and profile) is preserved. If the credential already belongs
/// to an account, we sign into that account instead.
@Observable
final class AuthService: NSObject {
    static let shared = AuthService()
    private override init() {}

    var uid: String?
    /// Apple sends the person's name ONLY on the very first authorization — captured here
    /// so onboarding can prefill it (it is never available again afterwards).
    var pendingDisplayName: String?

    /// Adopt an existing session (anonymous tester or real account). Does NOT create
    /// anything — a signed-out app shows the Welcome screen instead.
    func bootstrap() async {
        #if DEBUG
        if DemoMode.active { return }   // Firebase-free demo already set its own uid
        #endif
        uid = Auth.auth().currentUser?.uid
    }

    var isSignedIn: Bool { uid != nil }

    // MARK: - Shared credential path (link-or-sign-in)

    /// The one rule every door goes through: anonymous session + new credential = LINK
    /// (keep the uid); credential already taken = sign into that existing account.
    private func authenticate(with credential: AuthCredential,
                              requireExistingAccount: Bool = false,
                              requireNewAccount: Bool = false) async throws {
        if let user = Auth.auth().currentUser, user.isAnonymous {
            do {
                let result = try await user.link(with: credential)
                uid = result.user.uid
                reportLogin()
                return
            } catch let e as NSError where e.code == AuthErrorCode.credentialAlreadyInUse.rawValue {
                // This Apple/Google identity already has a Fariin account — enter it.
                // (Apple invalidates the used token; the error carries a fresh credential.)
                let updated = (e.userInfo[AuthErrorUserInfoUpdatedCredentialKey] as? AuthCredential) ?? credential
                let result = try await Auth.auth().signIn(with: updated)
                uid = result.user.uid
                reportLogin()
                return
            } catch let e as NSError where e.code == AuthErrorCode.emailAlreadyInUse.rawValue {
                throw AuthFlowError.emailTaken
            }
        }
        let result = try await Auth.auth().signIn(with: credential)
        // THE LOG-IN DOOR ONLY: this Google/Apple identity has never signed up. Social sign-in cannot
        // ask first — Firebase has already created an empty shell account as a side effect — so roll
        // the shell back and say so, instead of silently dropping the person into a blank app they
        // never created (reference UX: "you haven't logged in with this account before — log in
        // another way or sign up"). The Sign-Up door passes false and keeps today's behaviour.
        if requireExistingAccount, result.additionalUserInfo?.isNewUser == true {
            try? await result.user.delete()
            try? Auth.auth().signOut()
            throw AuthFlowError.noAccount
        }
        // THE SIGN-UP DOOR, mirror guard: this Google/Apple identity ALREADY has a Fariin account.
        // Entering the old account under a "create" flow reads as the app losing your new account —
        // sign back out and point at the right door, exactly like the email door's emailTaken.
        if requireNewAccount, result.additionalUserInfo?.isNewUser != true {
            try? Auth.auth().signOut()
            throw AuthFlowError.accountExists
        }
        uid = result.user.uid
        reportLogin()
    }

    // MARK: - Apple

    private var currentNonce: String?

    func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.randomNonce()
        currentNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)
    }

    func completeApple(authorization: ASAuthorization,
                       requireExistingAccount: Bool = false,
                       requireNewAccount: Bool = false) async throws {
        try await authenticate(with: makeAppleCredential(authorization: authorization),
                               requireExistingAccount: requireExistingAccount,
                               requireNewAccount: requireNewAccount)
    }

    /// Build the Firebase credential from an Apple authorization. Shared by sign-in and by
    /// "Connect Apple" in Account settings, so both go through the identical nonce check.
    private func makeAppleCredential(authorization: ASAuthorization) throws -> AuthCredential {
        guard let appleCred = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = appleCred.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8),
              let nonce = currentNonce else {
            throw AuthFlowError.appleFailed
        }
        if let name = appleCred.fullName {
            let joined = [name.givenName, name.familyName].compactMap { $0 }.joined(separator: " ")
            if !joined.isEmpty { pendingDisplayName = joined }
        }
        return OAuthProvider.appleCredential(withIDToken: idToken, rawNonce: nonce,
                                             fullName: appleCred.fullName)
    }

    private static func randomNonce(length: Int = 32) -> String {
        let chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length
        while remaining > 0 {
            var random: UInt8 = 0
            if SecRandomCopyBytes(kSecRandomDefault, 1, &random) == errSecSuccess {
                if random < chars.count {
                    result.append(chars[Int(random)])
                    remaining -= 1
                }
            }
        }
        return result
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Google (native PKCE via ASWebAuthenticationSession — no SDK dependency,
    // which matters here: Google's SPM binaries are exactly what used to hang our CI)

    private var webSession: ASWebAuthenticationSession?

    func signInWithGoogle(requireExistingAccount: Bool = false, requireNewAccount: Bool = false) async throws {
        try await authenticate(with: obtainGoogleCredential(),
                               requireExistingAccount: requireExistingAccount,
                               requireNewAccount: requireNewAccount)
    }

    /// Run the Google web flow and return the Firebase credential. Shared by sign-in and by
    /// "Connect Google" in Account settings.
    private func obtainGoogleCredential() async throws -> AuthCredential {
        guard let clientID = FirebaseApp.app()?.options.clientID else { throw AuthFlowError.googleFailed }
        // Reversed client id = the registered redirect scheme for this iOS OAuth client.
        let scheme = clientID.split(separator: ".").reversed().joined(separator: ".")
        let redirect = "\(scheme):/oauth2redirect"

        let verifier = Self.randomNonce(length: 64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "openid email profile"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
        ]

        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(url: comps.url!, callbackURLScheme: scheme) { url, err in
                if let url { cont.resume(returning: url) }
                else { cont.resume(throwing: err ?? AuthFlowError.googleFailed) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false   // reuse the phone's Google session
            self.webSession = session
            DispatchQueue.main.async { session.start() }
        }

        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            throw AuthFlowError.googleFailed
        }

        // Exchange the code for tokens (iOS clients use PKCE, no client secret).
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "client_id=\(clientID)",
            "code=\(code)",
            "code_verifier=\(verifier)",
            "redirect_uri=\(redirect)",
            "grant_type=authorization_code",
        ].joined(separator: "&")
        req.httpBody = body.data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let idToken = json["id_token"] as? String else {
            throw AuthFlowError.googleFailed
        }
        let accessToken = json["access_token"] as? String ?? ""

        return GoogleAuthProvider.credential(withIDToken: idToken, accessToken: accessToken)
    }

    // MARK: - Email

    /// Sign up with email. "Sign up with an account you already have" is NOT a dead end: if the
    /// email is already registered and the password matches, we just log you in (Apple and Google
    /// already behave this way, so email now matches them). Only a WRONG password stops you, and
    /// then the message says exactly what to do.
    func createEmailAccount(email: String, password: String) async throws {
        // Anonymous session → LINK, so the existing uid (and every chat/key) is preserved.
        if let user = Auth.auth().currentUser, user.isAnonymous {
            do {
                let result = try await user.link(with: EmailAuthProvider.credential(withEmail: email, password: password))
                uid = result.user.uid
                return
            } catch let e as NSError where e.code == AuthErrorCode.emailAlreadyInUse.rawValue
                                        || e.code == AuthErrorCode.credentialAlreadyInUse.rawValue {
                throw AuthFlowError.emailTaken
            }
        }
        do {
            // Real creation. (The old code called signIn() with an email credential here, which
            // does NOT create anything — so a brand-new signed-out user could never sign up by
            // email at all. That's fixed by using createUser.)
            let result = try await Auth.auth().createUser(withEmail: email, password: password)
            uid = result.user.uid
            reportLogin()
        } catch let e as NSError where e.code == AuthErrorCode.emailAlreadyInUse.rawValue {
            // A SIGN-UP door must not quietly sign you in (user decision 2026-07-24, matching
            // Twitch): this screen says Create Account, so an email that already has an account is
            // an error that points at Log In. Previously we signed them in when the password
            // matched, which left people inside an existing account with no explanation.
            throw AuthFlowError.emailTaken
        }
    }

    func signInEmail(email: String, password: String) async throws {
        let result = try await Auth.auth().signIn(withEmail: email, password: password)
        uid = result.user.uid
        reportLogin()
    }

    // MARK: - New-device security email

    /// Tell the backend this device signed in. The function emails the account owner only when the
    /// device is NEW (and never for the very first device, which is the sign-up itself), so someone
    /// else getting into your account is visible to you.
    ///
    /// Fire-and-forget on purpose: a sign-in must never fail or wait because email is down.
    /// Email the account owner that deletion was requested. AWAITED (unlike reportLogin) because the
    /// auth record is destroyed moments later and the address goes with it — but errors are ignored,
    /// so a mail failure can never stop someone deleting their account.
    func reportAccountDeletion() async {
        guard let uid, !uid.isEmpty, !isAnonymousSession else { return }
        _ = try? await Functions.functions(region: "me-central1")
            .httpsCallable("notifyAccountDeleted")
            .call()
    }

    func reportLogin() {
        guard let uid, !uid.isEmpty else { return }
        guard !isAnonymousSession else { return }   // no email address to warn
        guard let deviceId = UIDevice.current.identifierForVendor?.uuidString, !deviceId.isEmpty else { return }
        let model = UIDevice.current.model
        let os = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        Task.detached {
            _ = try? await Functions.functions(region: "me-central1")
                .httpsCallable("notifyNewLogin")
                .call(["deviceId": deviceId, "device": model, "os": os])
        }
    }

    func resetPassword(email: String) async throws {
        try await Auth.auth().sendPasswordReset(withEmail: email)
    }

    // MARK: - Signing in with a code, for when the password is gone

    /// Ask for a six-digit code by email. The owner's reference was Discord's "check your email for
    /// a login link"; a CODE rather than a link on his pick, because a link that opens the app needs
    /// a domain association and only works when the mail is on the same phone, and a code works from
    /// any device and any mail app.
    ///
    /// SAYS NOTHING ABOUT WHETHER THE ACCOUNT EXISTS. The server answers the same either way, so this
    /// screen cannot be used to find out who has an account here.
    func requestLoginCode(email: String) async throws {
        _ = try await Functions.functions(region: "me-central1")
            .httpsCallable("requestLoginCode")
            .call(["email": email])
    }

    /// Trade the code for a session. The server checks it and mints a CUSTOM TOKEN — the only way to
    /// sign a user in from our own backend without their password. A wrong or expired code throws,
    /// and the message the server sends is already in plain words.
    @discardableResult
    func signInWithLoginCode(email: String, code: String) async throws -> String {
        let result = try await Functions.functions(region: "me-central1")
            .httpsCallable("verifyLoginCode")
            .call(["email": email, "code": code])
        guard let data = result.data as? [String: Any], let token = data["token"] as? String else {
            throw NSError(domain: "Fariin", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not sign you in. Try again."])
        }
        let signIn = try await Auth.auth().signIn(withCustomToken: token)
        uid = signIn.user.uid
        reportLogin()
        return signIn.user.uid
    }

    // MARK: - Sign-in methods (Account settings: see what's connected, connect another)

    /// The sign-in doors Fariin supports, in the order Account settings lists them.
    enum SignInMethod: String, CaseIterable, Identifiable {
        case apple, google, email
        var id: String { rawValue }
        /// Firebase's provider id for this door (email/password is "password").
        var providerId: String {
            switch self {
            case .apple:  return "apple.com"
            case .google: return "google.com"
            case .email:  return "password"
            }
        }
        var title: String {
            switch self {
            case .apple:  return "Apple"
            case .google: return "Google"
            case .email:  return "Email"
            }
        }
    }

    /// The identifier shown next to a connected method (the email Firebase holds for it),
    /// or nil when that method isn't linked to this account.
    func connectedIdentifier(_ method: SignInMethod) -> String? {
        guard let user = Auth.auth().currentUser else { return nil }
        guard let info = user.providerData.first(where: { $0.providerID == method.providerId }) else { return nil }
        // Apple's private relay (or a provider that hides the address) can leave this empty —
        // fall back to the account email, then to a plain "Connected" in the UI.
        return info.email ?? user.email
    }

    func isConnected(_ method: SignInMethod) -> Bool { connectedIdentifier(_: method) != nil }

    /// True while the session is a legacy anonymous one — connecting a real method upgrades it
    /// in place, keeping the same uid (and therefore every chat, key and story).
    var isAnonymousSession: Bool { Auth.auth().currentUser?.isAnonymous ?? false }

    /// Attach another sign-in method to the CURRENT account (same uid, same chats).
    /// `link` is the right call for a signed-in user; the anonymous path already links via
    /// `authenticate(with:)`, so this covers "add a second door to a real account".
    private func link(_ credential: AuthCredential) async throws {
        guard let user = Auth.auth().currentUser else { throw AuthFlowError.notSignedIn }
        do {
            let result = try await user.link(with: credential)
            uid = result.user.uid
        } catch let e as NSError where e.code == AuthErrorCode.credentialAlreadyInUse.rawValue
                                    || e.code == AuthErrorCode.emailAlreadyInUse.rawValue {
            // That identity belongs to a DIFFERENT Fariin account. We must not silently switch
            // accounts here (it would look like the user's chats vanished) — say so plainly.
            throw AuthFlowError.alreadyLinkedElsewhere
        } catch let e as NSError where e.code == AuthErrorCode.providerAlreadyLinked.rawValue {
            throw AuthFlowError.alreadyConnected
        }
    }

    func connectApple(authorization: ASAuthorization) async throws {
        try await link(makeAppleCredential(authorization: authorization))
    }

    func connectGoogle() async throws {
        try await link(obtainGoogleCredential())
    }

    func connectEmail(email: String, password: String) async throws {
        try await link(EmailAuthProvider.credential(withEmail: email, password: password))
    }

    // MARK: - Re-authentication (required before deleting an account)

    /// Firebase refuses `user.delete()` unless the sign-in is recent. Rather than telling people
    /// to sign out and back in (which for an anonymous session would destroy the account), we
    /// re-verify them in place with the provider they already use.
    /// When a reauthenticate() last succeeded, and for which uid.
    ///
    /// Firebase does NOT refresh the cached `currentUser.metadata.lastSignInDate` when you
    /// reauthenticate — that value still reflects the ORIGINAL sign-in. So a metadata-only check kept
    /// reporting "needs recent login" immediately after a successful verification, and the delete-account
    /// backstop in ProfileStore refused with "Please verify it's you and try again" even though the user
    /// had just re-signed in (Google's own confirmation email proved the grant went through).
    private(set) var lastReauthAt: Date?
    private var lastReauthUid: String?

    var needsRecentLogin: Bool {
        guard let user = Auth.auth().currentUser else { return false }
        // Our OWN record of the verification wins, because it is the only one that is actually fresh.
        // Tied to the uid so it can never carry over to a different account on this device.
        if let at = lastReauthAt, lastReauthUid == user.uid,
           Date().timeIntervalSince(at) < 4 * 60 { return false }
        let last = user.metadata.lastSignInDate ?? .distantPast
        return Date().timeIntervalSince(last) >= 4 * 60
    }

    /// Which doors this account can re-verify with (what it's actually linked to).
    var reauthMethods: [SignInMethod] { SignInMethod.allCases.filter { isConnected($0) } }

    private func reauthenticate(with credential: AuthCredential) async throws {
        guard let user = Auth.auth().currentUser else { throw AuthFlowError.notSignedIn }
        _ = try await user.reauthenticate(with: credential)
        // Record it ourselves — see lastReauthAt. Only reached when reauthenticate did NOT throw, so a
        // cancelled or mismatched sign-in never marks the session as verified.
        lastReauthAt = Date()
        lastReauthUid = user.uid
        // Best effort: pull fresh server metadata too, so lastSignInDate stops lying for other callers.
        try? await user.reload()
    }

    func reauthApple(authorization: ASAuthorization) async throws {
        try await reauthenticate(with: makeAppleCredential(authorization: authorization))
    }

    func reauthGoogle() async throws {
        try await reauthenticate(with: obtainGoogleCredential())
    }

    func reauthEmail(password: String) async throws {
        guard let email = Auth.auth().currentUser?.email else { throw AuthFlowError.notSignedIn }
        try await reauthenticate(with: EmailAuthProvider.credential(withEmail: email, password: password))
    }
}

extension AuthService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? ASPresentationAnchor()
    }
}

enum AuthFlowError: LocalizedError {
    case appleFailed, googleFailed, emailTaken, emailTakenWrongPassword
    case notSignedIn, alreadyConnected, alreadyLinkedElsewhere
    case noAccount, accountExists

    var errorDescription: String? {
        switch self {
        case .appleFailed: return "Apple sign-in didn't complete. Please try again."
        case .googleFailed: return "Google sign-in didn't complete. Please try again."
        case .emailTaken: return "This email already has an account. Go back and choose Log In instead."
        case .emailTakenWrongPassword:
            return "You already have an account with this email, but that password doesn't match. Enter the right password to log in, or tap \"Forgot password?\"."
        case .notSignedIn: return "You're not signed in."
        case .alreadyConnected: return "That's already connected to this account."
        case .alreadyLinkedElsewhere:
            return "That login already belongs to a different Fariin account. Sign out and log in with it instead."
        case .noAccount:
            return "You haven't signed up with this account before. Go back and choose Sign Up to continue."
        case .accountExists:
            return "This account already has a Fariin account. Go back and choose Log In instead."
        }
    }
}
