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

    // MARK: - Which door you used last

    /// WHICH DOOR YOU CAME IN BY LAST TIME, remembered on THIS PHONE so the sign-in screen can point
    /// at it. TikTok's "Last login: Phone" badge, and Google and Facebook do the same.
    ///
    /// It exists because "which one did I use?" is a real question with a bad failure: pick the wrong
    /// door and you are told there is no account, which reads as your account being gone. The owner
    /// hit the same confusion from the other side, looking at his own settings and asking how one
    /// email could be two logins.
    ///
    /// ⚠️ THE METHOD ONLY. NEVER THE ADDRESS. "Google" is a hint; "abdikasim@gmail.com" printed on a
    /// signed-out phone is somebody's identity shown to whoever is holding it.
    ///
    /// ⚠️ AND IT DELIBERATELY SURVIVES SIGN-OUT, which is the one place it disagrees with
    /// SessionWipe. Everything in that file is cleared so the next person to use this phone inherits
    /// nothing, and that rule is right. This is the exception, because signed-out is exactly when
    /// the hint is needed — after a reinstall or a sign-out, staring at three buttons. What it costs
    /// is that somebody holding the phone learns the last person used Google. Weighed and accepted;
    /// if that trade is ever refused, clear it in `SessionWipe.wipeAccountData()` and this feature
    /// simply stops helping in the case it was built for.
    private static let lastMethodKey = "auth.lastSignInMethod"

    static var lastSignInMethod: SignInMethod? {
        guard let raw = UserDefaults.standard.string(forKey: lastMethodKey) else { return nil }
        return SignInMethod(rawValue: raw)
    }

    static func rememberSignInMethod(_ method: SignInMethod) {
        UserDefaults.standard.set(method.rawValue, forKey: lastMethodKey)
    }

    /// Firebase names providers by id; the sign-in screen thinks in doors. One place to translate,
    /// so a new provider cannot be recorded under a name the badge does not know.
    static func methodFor(providerId: String) -> SignInMethod? {
        SignInMethod.allCases.first { $0.providerId == providerId }
    }

    // MARK: - Shared credential path (link-or-sign-in)

    /// The one rule every door goes through: anonymous session + new credential = LINK
    /// (keep the uid); credential already taken = sign into that existing account.
    private func authenticate(with credential: AuthCredential,
                              requireExistingAccount: Bool = false,
                              requireNewAccount: Bool = false) async throws {
        // Recorded from the CREDENTIAL, at the one place every social door passes through, rather
        // than at each call site — a door added later is remembered without anybody remembering to.
        // Only on the success paths below, so a refused sign-in never rewrites the hint.
        let door = Self.methodFor(providerId: credential.provider)
        if let user = Auth.auth().currentUser, user.isAnonymous {
            do {
                let result = try await user.link(with: credential)
                uid = result.user.uid
                if let door { Self.rememberSignInMethod(door) }
                reportLogin()
                return
            } catch let e as NSError where e.code == AuthErrorCode.credentialAlreadyInUse.rawValue {
                // This Apple/Google identity already has a Fariin account — enter it.
                // (Apple invalidates the used token; the error carries a fresh credential.)
                let updated = (e.userInfo[AuthErrorUserInfoUpdatedCredentialKey] as? AuthCredential) ?? credential
                let result = try await Auth.auth().signIn(with: updated)
                uid = result.user.uid
                if let door { Self.rememberSignInMethod(door) }
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
        if let door { Self.rememberSignInMethod(door) }
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
            Self.rememberSignInMethod(.email)
            reportLogin()
        } catch let e as NSError where e.code == AuthErrorCode.emailAlreadyInUse.rawValue {
            // A SIGN-UP door must not quietly sign you in (user decision 2026-07-24, matching
            // the reference app): this screen says Create Account, so an email that already has an account is
            // an error that points at Log In. Previously we signed them in when the password
            // matched, which left people inside an existing account with no explanation.
            throw AuthFlowError.emailTaken
        }
    }

    func signInEmail(email: String, password: String) async throws {
        let result = try await Auth.auth().signIn(withEmail: email, password: password)
        uid = result.user.uid
        Self.rememberSignInMethod(.email)
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

    /// OUR OWN EMAIL, not Firebase's. `Auth.auth().sendPasswordReset` hands the job to Google's
    /// mailer, and that mailer sent from a domain shared by every Firebase project on earth; Gmail
    /// binned the result and said why, "previous messages from firebaseapp.com were marked as
    /// spam". Worse, the wording could not be changed at all — the console refuses every edit with
    /// "Email template updates are currently unavailable for this project" — so it stayed a wall of
    /// plain text wrapped around a raw 200-character URL, which is what phishing looks like.
    ///
    /// The function mints the same link Firebase would have mailed and posts it through Resend from
    /// noreply@fariin.com, the sender the login codes already use and which already reaches the
    /// inbox. The reset page itself is unchanged.
    ///
    /// SAYS NOTHING ABOUT WHETHER THE ACCOUNT EXISTS, same contract as `requestLoginCode`.
    func resetPassword(email: String) async throws {
        _ = try await Functions.functions(region: "me-central1")
            .httpsCallable("requestPasswordReset")
            .call(["email": email])
    }

    /// The address a password would sign you in with, or nil when this account cannot have one.
    ///
    /// ⚠️ IT MUST BE A **PROVEN** ADDRESS, and the first version of this was not. Found on a real
    /// phone, 2026-08-09: the Password row offered `admintufaax@gmail.com` while the Google row
    /// directly beneath it read `akramsamatar@gmail.com`. Both are on the same account.
    ///
    /// Firebase keeps TWO different things here and they drift apart. `user.email` is an
    /// account-level field that MOVES whenever an email credential is linked, and it carries its own
    /// `isEmailVerified` flag. `providerData` holds what each provider actually handed over. On that
    /// account `user.email` was `admintufaax@gmail.com` with **emailVerified false**, while the
    /// google.com entry said `akramsamatar@gmail.com`.
    ///
    /// Reading `user.email` blindly therefore offered to hang a password on an address NOBODY HAD
    /// PROVED THE OWNER CONTROLS. Whoever really owns that mailbox could then walk in through Forgot
    /// Password. That is precisely the hole the sign-up code was built to close, reopened by the
    /// screen built to close it.
    ///
    /// Order now, strongest evidence first:
    ///   1. `user.email` ONLY when `isEmailVerified` — proven, and the one Firebase itself favours.
    ///   2. an address from `providerData` — Apple and Google verify before handing it over, so
    ///      these are proven by construction. Apple's Hide My Email relay counts: Apple owns the
    ///      domain and runs the forwarding.
    ///   3. nil. The row does not appear. A screen that can only end badly is worse than no screen.
    /// ⚠️ AND AMONG THE PROVEN ONES, PREFER ONE THE PERSON COULD TYPE.
    ///
    /// Same candidates as before and the same order — this only reorders, it never widens the set,
    /// so the proven-address rule above is untouched. What it fixes: an account holding Apple with
    /// Hide My Email AND Google has two proven addresses, and `user.email` is often the Apple relay.
    /// Returning that meant the password was hung on `…@privaterelay.appleid.com` while a perfectly
    /// good Gmail sat one entry further down — a login they could never type, when a usable one
    /// existed. It also made `hasTypableAddress` say no to an account that plainly qualified.
    var passwordAddress: String? {
        guard let user = Auth.auth().currentUser else { return nil }
        let verifiedPrimary = (user.isEmailVerified && !(user.email ?? "").isEmpty) ? user.email : nil
        let candidates = [verifiedPrimary].compactMap { $0 }
            + user.providerData.compactMap(\.email).filter { !$0.isEmpty }
        return candidates.first(where: { !Self.isRelayAddress($0) }) ?? candidates.first
    }

    /// Apple's Hide My Email forwarding address. Real, deliverable, and something the person has
    /// never seen — so it identifies an account perfectly and cannot serve as a typed login.
    static func isRelayAddress(_ address: String) -> Bool {
        address.lowercased().hasSuffix("@privaterelay.appleid.com")
    }

    /// Set the account's password, whether or not it had one.
    ///
    /// TWO DIFFERENT FIREBASE CALLS behind one name, and the difference is not cosmetic.
    /// `updatePassword` changes an existing password credential; it cannot CREATE one, so a Google
    /// or Apple account has to `link` an email credential instead. Getting this wrong is how the
    /// feature would silently work for half the users and fail for the other half.
    ///
    /// The address is never taken from the caller. It is read off the account, which is the whole
    /// reason this screen does not ask for one: we already know it, and a field to retype it is
    /// both a step for nothing and a chance to attach a password to an address you cannot read.
    ///
    /// ⚠️ NOT GUARDED HERE. The proof that it is really you is Face ID, and it lives on the screen
    /// (PasswordView) rather than in this method, because the check is a UI affair and because a
    /// guard buried in a service is one a future caller silently skips. Any new caller of this
    /// method owes the same gate.
    func setPassword(_ newPassword: String, isFirst: Bool) async throws {
        guard let user = Auth.auth().currentUser else { throw AuthFlowError.notSignedIn }

        if isFirst {
            // ⚠️ `passwordAddress`, NEVER `user.email`. This line read `user.email` directly and that
            // was the actual bug behind the mismatched screen: on an account whose account-level
            // email is unverified it would have linked a password to an UNPROVEN address, handing a
            // way in to whoever really owns that mailbox. The property resolves to a proven address
            // or refuses; see its comment for the account this was caught on.
            guard let address = passwordAddress, !address.isEmpty else { throw AuthFlowError.notSignedIn }
            _ = try await user.link(with: EmailAuthProvider.credential(withEmail: address,
                                                                      password: newPassword))
        } else {
            try await user.updatePassword(to: newPassword)
        }

        // TELL THE ACCOUNT, and read the state back first so the mail describes what is now true
        // rather than what we intended. `reload()` also refreshes providerData, which is what the
        // server reads to decide which of the two mails to send.
        try? await user.reload()
        await reportPasswordChanged(isFirst: isFirst)
    }

    /// The security mail after a password is set or changed. Fire-and-forget on purpose: the
    /// password already moved, and failing the call would show an error for something that worked
    /// and send them round to do it again.
    ///
    /// The time is formatted HERE, in the person's own locale and timezone. Doing it on the server
    /// would print a server clock at somebody in Muqdisho or Minneapolis, and a security mail that
    /// states the wrong time is a security mail that reads as fake.
    private func reportPasswordChanged(isFirst: Bool) async {
        let stamp = Date().formatted(date: .abbreviated, time: .shortened)
        _ = try? await Functions.functions(region: "me-central1")
            .httpsCallable("notifyPasswordChanged")
            .call(["when": stamp, "first": isFirst])
    }

    /// Walk away from a session that never finished being set up.
    ///
    /// For the person stuck on the prove-your-address gate, and nowhere else. They are signed in to
    /// Firebase but have never been inside the app: no push token was registered, no profile was
    /// cached, no device row was written. So this is deliberately NOT the Settings sign-out, which
    /// awaits `Push.unregister()` and `DeviceRegistry.removeThisDevice()` — two network writes that
    /// would be undoing work nobody did, on a path where the person is already stuck and a hang is
    /// the last thing they need.
    ///
    /// `async` even though the body is not, because the caller is in a Task and this is the kind of
    /// thing that grows an awaited step later; making it async now means that day is not a change at
    /// every call site.
    func abandonSession() async {
        try? Auth.auth().signOut()
        uid = nil
    }

    /// Does this session still owe us proof that its email address is really theirs?
    ///
    /// TRUE ONLY FOR PASSWORD ACCOUNTS, and that qualifier is the whole point. Apple and Google have
    /// already proved the address before they hand it over, so asking those people for a code would
    /// be an errand for nothing. `createUser` and `link` prove nothing at all, which is the gap this
    /// closes.
    ///
    /// `reload()` first, because `isEmailVerified` is read off a cached token. Straight after
    /// verifyLoginCode marks the address confirmed on the server, the copy on the phone is still the
    /// stale one, and without the refresh a person who had just proved their address would be asked
    /// to prove it again on the very next screen.
    /// The same question as `emailNeedsProof`, answered WITHOUT touching the network, and the
    /// address to send the code to when the answer is yes.
    ///
    /// This is the one the launch path uses. `emailNeedsProof` reloads the user, and an awaited
    /// server call on boot stalls the app for about ten seconds when the phone is offline, which is
    /// the trap RootView.route already warns about twice.
    var unprovenEmailCached: String? {
        guard let user = Auth.auth().currentUser,
              !user.isEmailVerified,
              let address = user.email, !address.isEmpty
        else { return nil }

        // PASSWORD MUST BE THE ONLY WAY IN, and this clause is a lockout bug I shipped this morning
        // and had to be shown.
        //
        // Without it the test was "has a password AND the address is unproven", which is true of a
        // Google account the moment its owner sets a password. Linking an email credential MOVES
        // `user.email` to the new address and flips `emailVerified` false, so a Google user who set
        // a password on any address other than their Google one was thrown into the code screen on
        // the next launch — a screen with no sign-out, no back, and (for this purpose) no "use a
        // different email". If they had mistyped the address, or used one they cannot read, they
        // were permanently locked out of an account they could still authenticate to with Google,
        // and the app would not let them near the Sign-in Methods screen that fixes it. It punished
        // exactly the person who did the security-conscious thing.
        //
        // An account with Apple or Google on it has an identity its provider already proved. It is
        // not locked out and it is not unidentified, so there is nothing for this gate to rescue.
        // The address still gets proved, just at the moment it is SET, on the Password screen, which
        // is where the person is actually standing and can retype it.
        //
        // The gate stays for the account this was written for: password as the sole door, where the
        // address IS the identity and an unproven one means nobody has shown they can read it.
        let providers = Set(user.providerData.map(\.providerID))
        guard providers == ["password"] else { return nil }
        return address
    }

    var emailNeedsProof: Bool {
        get async {
            guard let user = Auth.auth().currentUser else { return false }
            // Same sole-door rule as `unprovenEmailCached`, and it has to be the same or the two
            // disagree: sign-in would demand a code that the next launch does not, or the reverse.
            // Apple and Google prove the address before handing it over, so asking those people for
            // a code is an errand for nothing.
            guard Set(user.providerData.map(\.providerID)) == ["password"] else { return false }
            try? await user.reload()
            guard let fresh = Auth.auth().currentUser else { return false }
            return !fresh.isEmailVerified
        }
    }

    // MARK: - Signing in with a code, for when the password is gone

    /// Ask for a six-digit code by email. The owner's reference was the reference app's "check your email for
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

        // PULL THE FRESH FLAG DOWN NOW. The server marked this address confirmed a moment ago, as
        // part of accepting the code, but the token this phone just signed in with was minted before
        // that write and still says unverified. `unprovenEmailCached` reads exactly that stale copy
        // on every launch, so without this the person would prove their address, get into the app,
        // and be asked to prove it again the very next time they opened Fariin. Forever.
        //
        // Not thrown on. The sign-in worked; a failed refresh costs one unnecessary code screen at
        // some later launch, and throwing here would cost them the sign-in they just earned.
        try? await signIn.user.reload()

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
        /// ⚠️ "Password", NOT "Email", and the difference is not cosmetic (owner, 2026-08-09).
        ///
        /// This row is not a second email identity. The password is always attached to the address
        /// the account already has — `setPassword` reads it off the account and the screen never
        /// asks for one — so it can never show anything the Google or Apple row above it did not
        /// already say. Labelled "Email" it printed the same address twice and read as two separate
        /// accounts; the owner looked at his own settings screen and asked how one email could be
        /// two different logins. Calling it what it is answers that before it is asked.
        var title: String {
            switch self {
            case .apple:  return "Apple"
            case .google: return "Google"
            case .email:  return "Password"
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

    /// Every door currently attached to this account.
    var connectedMethods: [SignInMethod] { SignInMethod.allCases.filter { isConnected($0) } }

    /// ⚠️ APPLE'S HIDDEN ADDRESS CANNOT BE TYPED, AND A PASSWORD ON IT IS A DOOR WITH NO HANDLE.
    ///
    /// Sign in with Apple offers Hide My Email, which gives the account something like
    /// `f6dj84y9z2@privaterelay.appleid.com`. That address works perfectly as an identifier and is
    /// useless as a LOGIN, because the person has never seen it and could not reproduce it. A
    /// password is always attached to the account's own address (see `passwordAddress`, which never
    /// takes one from the caller), so for those accounts "set a password" produces a credential that
    /// can never be used at the sign-in screen.
    ///
    /// It reads as a second way in, which is worse than having none: it is the thing you reach for
    /// on the day you cannot get in, and it fails exactly then.
    /// Asks the question of the address the password would ACTUALLY be created on, which is why it
    /// goes through `passwordAddress` rather than scanning the account itself. An account with a
    /// relay address and a Gmail passes, because `passwordAddress` now hands back the Gmail.
    var hasTypableAddress: Bool {
        guard let a = passwordAddress, !a.isEmpty else { return false }
        return !Self.isRelayAddress(a)
    }

    /// Can this door actually be opened by the person, in practice?
    ///
    /// Apple and Google always can — they are a tap, and the address behind them is theirs to
    /// recover through Apple or Google. A password can only be used by somebody who can type the
    /// address it belongs to, which is why this is not simply "is it connected".
    func isUsable(_ method: SignInMethod) -> Bool {
        switch method {
        case .apple, .google: return true
        case .email:          return hasTypableAddress
        }
    }

    /// Would taking this method off still leave the person a way back in?
    ///
    /// Counting was not enough. The count said two, and both could be unusable: an Apple account
    /// with Hide My Email that also set a password holds Apple + password, and removing Apple leaves
    /// a password on an address they have never seen. The guard passed and they were locked out.
    func removalLeavesAWayIn(_ method: SignInMethod) -> Bool {
        connectedMethods.contains { $0 != method && isUsable($0) }
    }

    /// Take a sign-in method OFF this account.
    ///
    /// This exists because connecting one was a one-way door, and that was the sharpest hole in the
    /// app: somebody holding your unlocked phone could attach THEIR Google account to YOUR Fariin
    /// and sign in as you forever, with nothing anywhere to undo it. A password you can change. That
    /// you could not.
    ///
    /// Two guards, and the second one is the one that matters:
    ///
    /// 1. NEVER the last method. Firebase will happily unlink it and leave an account with no way
    ///    in at all.
    /// 2. The CALLER must have re-verified. Without this, adding disconnect would have opened a
    ///    worse hole than the one it closes: the same person holding your phone connects their
    ///    Google, unlinks your Apple, and now the account is theirs and you are locked out. The
    ///    caller is responsible for re-verifying immediately before calling — see the note in
    ///    DeleteAccountView.start() about why freshness is a different question from ownership.
    func disconnect(_ method: SignInMethod) async throws {
        guard let user = Auth.auth().currentUser else { throw AuthFlowError.notSignedIn }
        guard isConnected(method) else { throw AuthFlowError.notConnected }
        // ⚠️ "AT LEAST ONE LEFT" IS NOT THE SAME AS "A WAY BACK IN", and this used to test the
        // count. An Apple account using Hide My Email that also set a password holds two methods,
        // and removing Apple leaves a password on `f6dj84y9z2@privaterelay.appleid.com` — an address
        // the person has never seen and cannot type. Two became one, the guard was satisfied, and
        // they were locked out of their own account by a screen that told them it was safe.
        guard removalLeavesAWayIn(method) else { throw AuthFlowError.lastSignInMethod }
        // ⚠️ THE WARNING GOES OUT **BEFORE** THE UNLINK, AND IT MUST BE AWAITED. This used to run
        // after, as a detached fire-and-forget, and that combination meant the address being removed
        // never heard about it.
        //
        // The server builds its recipient list from the account as it stands. Once the unlink has
        // happened the removed address is gone from providerData, so it cannot be written to and
        // cannot even be named in the mail. The one person who most needs the sentence "your login
        // was taken off this account" was the only one guaranteed not to get it. On a takeover that
        // is fatal: everything still attached belongs to the attacker, so the alert goes to them and
        // the real owner hears nothing at all.
        //
        // Awaited rather than detached because detaching reintroduces the same bug through the back
        // door — a detached task can just as easily run after the unlink as before it, and then the
        // ordering is a coin toss rather than a guarantee.
        //
        // The cost, stated plainly: if the unlink fails after this, somebody gets told a login was
        // removed when it was not. The guards above catch every ordinary reason it would fail, so
        // what is left is a network error mid-call. A false alarm you can check is a far better
        // failure than a silent takeover you cannot.
        //
        // The server subtracts this provider when it prints "ways in now", so the mail does not list
        // the login it is telling you about. Nothing here passes an address; the server reads it
        // from the account, or this would become a way to mail any stranger a frightening notice.
        await reportSignInMethodChangeAwaiting(providerId: method.providerId, added: false)

        _ = try await user.unlink(fromProvider: method.providerId)

        // UNLINK TAKES THE LOGIN AND LEAVES THE ADDRESS. Firebase clears the provider and does not
        // touch `user.email`, so removing your email login leaves that address on the account
        // permanently. The owner found this on his own account: no password provider left at all,
        // google.com saying one address, and `user.email` still holding the one he had removed.
        //
        // Not cosmetic. `allEmails()` on the server reads `user.email`, so every security notice
        // about the account — new sign-in, method changed, deletion scheduled — kept being posted to
        // an address he had deliberately taken off. It also went on reserving that address against
        // everybody else forever, because Firebase refuses a second account on an email it holds.
        //
        // Server-side because only the admin SDK can rewrite it without dragging the person through
        // a verification round trip for an address they already proved to Apple or Google.
        // Fire-and-forget for the same reason `reportSignInMethodChange` below is: the unlink they
        // asked for has already succeeded, and failing it over bookkeeping would send them back to
        // do it again.
        _ = try? await Functions.functions(region: "me-central1")
            .httpsCallable("reconcileAccountEmail").call([:])

        // providerData is read straight off the cached user, and every screen showing what is
        // connected reads it — without this the removed row stays on screen until the next launch.
        // AFTER the reconcile, so it also picks up the repointed address.
        try? await user.reload()
    }

    /// The same call as `reportSignInMethodChange`, awaited instead of detached.
    ///
    /// Exists for exactly one caller: the removal path, where the mail has to be sent while the
    /// address being removed is still on the account. Detaching would leave the ordering to chance,
    /// which is the bug it was written to fix.
    ///
    /// Still never throws. The mail is a report on the change, and a dead mailbox must not be able
    /// to stop somebody removing a login from their own account.
    private func reportSignInMethodChangeAwaiting(providerId: String, added: Bool) async {
        guard let uid, !uid.isEmpty, !isAnonymousSession else { return }
        _ = try? await Functions.functions(region: "me-central1")
            .httpsCallable("notifySignInMethodChanged")
            .call(Self.methodChangePayload(providerId: providerId, added: added))
    }

    /// WHERE THE CHANGE CAME FROM, for the security mail's detail block. Nothing on the server knows
    /// the handset, so the app has to say. The IP is deliberately NOT sent: the function reads that
    /// off the request itself, because a value the caller supplies is a value the caller can invent.
    private static func methodChangePayload(providerId: String, added: Bool) -> [String: Any] {
        ["provider": providerId,
         "added": added,
         "device": UIDevice.current.model,
         "os": "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"]
    }

    /// Fire-and-forget, exactly like `reportLogin`. An email failing must never fail the change it
    /// was only reporting on — and the function itself is written not to throw for the same reason.
    private func reportSignInMethodChange(providerId: String, added: Bool) {
        guard let uid, !uid.isEmpty, !isAnonymousSession else { return }
        // Built HERE, not inside the detached task: it reads UIDevice, and reportLogin already sets
        // the precedent of gathering those on the calling side rather than on a background thread.
        let payload = Self.methodChangePayload(providerId: providerId, added: added)
        Task.detached {
            _ = try? await Functions.functions(region: "me-central1")
                .httpsCallable("notifySignInMethodChanged")
                .call(payload)
        }
    }

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
            // Tell the owner of the account, whoever is holding the phone. Attaching a login is how
            // an account gets taken over quietly, so it must never be quiet.
            reportSignInMethodChange(providerId: credential.provider, added: true)
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

    /// Did the person simply back out? Then there is nothing to report and nothing went wrong.
    ///
    /// Every door closes differently and none of them are Firebase errors, which is why the shared
    /// message table below cannot answer this. Tapping Cancel on the Google sheet used to put
    /// **"The operation couldn't be completed. (com.apple.AuthenticationServices.WebAuthentication
    /// Session error 1.)"** on screen in red — on the Delete Account page, where a wall of Apple
    /// framework text reads like the deletion broke rather than like the person changed their mind.
    /// The Apple button already guarded its own cancel; Google and the rest never did.
    static func isCancellation(_ error: Error) -> Bool {
        let ns = error as NSError
        switch ns.domain {
        // The in-app browser Google's sign-in runs in. Code 1 is canceledLogin.
        case "com.apple.AuthenticationServices.WebAuthenticationSession": return ns.code == 1
        // Sign in with Apple's own sheet. 1001 is ASAuthorizationError.canceled.
        case ASAuthorizationError.errorDomain: return ns.code == 1001
        // Google's SDK, when it is the one presenting. -5 is its canceled case.
        case "com.google.GIDSignIn": return ns.code == -5
        default: return false
        }
    }

    /// Firebase error codes → normal-person words.
    ///
    /// THIS USED TO BE PRIVATE TO THE SIGN-IN SCREEN, and every other door that can reject you was
    /// left showing `error.localizedDescription` raw. The owner hit the result on Delete Account:
    /// typing the wrong password answered **"The supplied auth credential is malformed or has
    /// expired"**, which is Firebase 17004 read aloud. It says nothing a person can act on, and on
    /// a screen about deleting an account it reads like the app broke rather than like a typo.
    ///
    /// `credentialHint` exists because the same code means different things at different doors. At
    /// the front door you may have got either field wrong. On a re-verify screen your email is not
    /// in question and only the password is, so saying "wrong email or password" there would send
    /// somebody hunting for a mistake they did not make.
    /// RETURNS nil WHEN THERE IS NOTHING TO SAY, which is the point. Every `error` property in the
    /// app is already `String?`, so `self.error = plainMessage(e)` now clears itself on a cancel
    /// instead of each screen needing its own guard to remember. One screen forgetting that guard
    /// is precisely how the Google sheet came to shout Apple framework text at somebody who had
    /// merely tapped Cancel.
    static func plainMessage(_ error: Error,
                             credentialHint: String = "Wrong email or password.") -> String? {
        // Backing out is a decision, not a failure.
        if isCancellation(error) { return nil }

        // Our own errors already speak English; passing them through the code table would lose them.
        if let flow = error as? AuthFlowError { return flow.localizedDescription }

        let ns = error as NSError
        switch ns.code {
        case 17008: return "That doesn't look like an email address."
        case 17026: return "Password must be at least 6 characters."
        case 17009, 17004: return credentialHint
        case 17011: return "No account with that email. Create one instead."
        // NOT a bare "choose Log In instead": that promised a password door which may not exist.
        // Removing a sign-in method calls `unlink` and nothing else, so it takes away the LOGIN and
        // leaves the ADDRESS on the account — Firebase still refuses a second account on it, and no
        // password can be right because the account no longer has one. Google- or Apple-only
        // accounts never had one either. So point at Log In, which is also where the code door is.
        case 17007: return "This email already has an account. Go back and choose Log In, then use the way you signed up or log in with a code."
        case 17020: return "No internet connection. Try again."
        case 17010: return "Too many attempts. Wait a moment and try again."
        case 17014: return "Please sign in again before doing this."
        case 17021: return "Your session expired. Sign in again."
        // 17012 IS REACHED FROM BOTH DIRECTIONS AND THE OLD WORDING ONLY FITTED ONE OF THEM.
        //
        // It used to read "made with Google or Apple... use that button", which is right when
        // somebody types a password at an address that belongs to a social account. It is actively
        // misleading in the other direction: sign up with email and password, sign out, then tap
        // Google with the same address, and it told them to press the button they had just pressed.
        //
        // That second direction is NEWLY COMMON because of the sign-up code. Firebase's documented
        // rule is that a trusted provider takes over an account whose email is UNVERIFIED — the
        // Google sign-in wins and the password credential is dropped — and refuses with this error
        // only once the address is PROVEN. Every account predating today was unverified, so this
        // path used to end in a silent takeover of your own account (your password simply stopped
        // working) and now ends here instead. Better outcome, newly visible error.
        //
        // So the text names neither provider and points at the one door that works whichever way
        // round it happened.
        case 17012: return "This email already has an account that signs in a different way. Go back and use the button you signed up with, or log in with a code."
        // Last resort. Firebase's own text is better than nothing, but it is never a good answer,
        // so anything that lands here is a code worth adding above once we have seen it.
        default: return error.localizedDescription
        }
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
    case notConnected, lastSignInMethod

    var errorDescription: String? {
        switch self {
        case .appleFailed: return "Apple sign-in didn't complete. Please try again."
        case .googleFailed: return "Google sign-in didn't complete. Please try again."
        // Same words as 17007 in `plainMessage`, and for the same reason: this is what that code
        // becomes on the sign-up door. Keep the two in step.
        case .emailTaken: return "This email already has an account. Go back and choose Log In, then use the way you signed up or log in with a code."
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
        case .notConnected: return "That login isn't connected to this account."
        case .lastSignInMethod:
            return "This is the only way into your account. Connect another login first, then you can remove this one."
        }
    }
}
