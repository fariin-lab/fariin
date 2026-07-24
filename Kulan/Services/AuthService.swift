import Foundation
import Observation
import FirebaseAuth
import FirebaseCore
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
    private func authenticate(with credential: AuthCredential) async throws {
        if let user = Auth.auth().currentUser, user.isAnonymous {
            do {
                let result = try await user.link(with: credential)
                uid = result.user.uid
                return
            } catch let e as NSError where e.code == AuthErrorCode.credentialAlreadyInUse.rawValue {
                // This Apple/Google identity already has a Kulan account — enter it.
                // (Apple invalidates the used token; the error carries a fresh credential.)
                let updated = (e.userInfo[AuthErrorUserInfoUpdatedCredentialKey] as? AuthCredential) ?? credential
                let result = try await Auth.auth().signIn(with: updated)
                uid = result.user.uid
                return
            } catch let e as NSError where e.code == AuthErrorCode.emailAlreadyInUse.rawValue {
                throw AuthFlowError.emailTaken
            }
        }
        let result = try await Auth.auth().signIn(with: credential)
        uid = result.user.uid
    }

    // MARK: - Apple

    private var currentNonce: String?

    func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.randomNonce()
        currentNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)
    }

    func completeApple(authorization: ASAuthorization) async throws {
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
        let credential = OAuthProvider.appleCredential(withIDToken: idToken, rawNonce: nonce,
                                                       fullName: appleCred.fullName)
        try await authenticate(with: credential)
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

    func signInWithGoogle() async throws {
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

        let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: accessToken)
        try await authenticate(with: credential)
    }

    // MARK: - Email

    func createEmailAccount(email: String, password: String) async throws {
        let credential = EmailAuthProvider.credential(withEmail: email, password: password)
        do {
            try await authenticate(with: credential)
        } catch let e as NSError where e.code == AuthErrorCode.emailAlreadyInUse.rawValue {
            throw AuthFlowError.emailTaken
        }
    }

    func signInEmail(email: String, password: String) async throws {
        let result = try await Auth.auth().signIn(withEmail: email, password: password)
        uid = result.user.uid
    }

    func resetPassword(email: String) async throws {
        try await Auth.auth().sendPasswordReset(withEmail: email)
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
    case appleFailed, googleFailed, emailTaken

    var errorDescription: String? {
        switch self {
        case .appleFailed: return "Apple sign-in didn't complete. Please try again."
        case .googleFailed: return "Google sign-in didn't complete. Please try again."
        case .emailTaken: return "That email already has an account. Try logging in instead."
        }
    }
}
