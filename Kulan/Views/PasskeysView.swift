import SwiftUI
import AuthenticationServices
import FirebaseAuth

// ⛔ PASSKEYS — his item 7, and the page in his screenshot: a large key, the title, one line of
// reassurance, then a card listing each passkey with when it was made and last used, a green
// "+ Add Passkey" row at the bottom of the same card, and a footnote.
//
// The server is `passkeys.js` in `functions-account`; why WebAuthn verification is a library and not
// hand-written is argued there.
//
// ── THE TWO THINGS THAT MAKE THIS WORK AT ALL ─────────────────────────────────────────────────────
//
// 1. `webcredentials:fariin.com` in `Kulan.entitlements`. Without it iOS will not create or offer a
//    passkey for this app, and it fails SILENTLY — no error, just an empty sheet.
// 2. A `webcredentials` block naming 47FUM8F4KJ.com.kulan.messenger.native in
//    fariin.com/.well-known/apple-app-site-association. Same silent failure if it is missing.
//
// Both are in place. The relying-party id below must stay equal to the domain in both of them: a
// passkey created for one RP id cannot be used for another, and a mismatch is that same quiet
// nothing rather than anything you could debug from the phone.

/// The relying party. Bare domain, matching the entitlement and the association file.
private let passkeyRelyingParty = "fariin.com"

// MARK: - The bridge to AuthenticationServices

/// ⚠️ `ASAuthorizationController` IS DELEGATE-BASED AND ONE-SHOT, so each request is wrapped in its
/// own continuation and the controller is held for the length of it. Letting it go out of scope
/// cancels the sheet, which presents as the prompt appearing and vanishing.
@MainActor
final class PasskeyCeremony: NSObject, ASAuthorizationControllerDelegate,
                             ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<ASAuthorization, Error>?
    private var controller: ASAuthorizationController?

    func run(_ requests: [ASAuthorizationRequest]) async throws -> ASAuthorization {
        try await withCheckedThrowingContinuation { cont in
            continuation = cont
            let c = ASAuthorizationController(authorizationRequests: requests)
            c.delegate = self
            c.presentationContextProvider = self
            controller = c
            c.performRequests()
        }
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        continuation?.resume(returning: authorization)
        continuation = nil
        self.controller = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
        self.controller = nil
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? ASPresentationAnchor()
    }
}

enum Passkeys {
    /// Base64url, which is what WebAuthn speaks everywhere and what the server expects.
    private static func b64url(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func data(fromB64url s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    /// Add a passkey to the account that is signed in now.
    @MainActor
    static func register(label: String) async throws {
        let start = try await AccountCall.run("passkeyRegistrationOptions")
        guard let options = start["options"] as? [String: Any],
              let challengeId = start["challengeId"] as? String,
              let challengeStr = options["challenge"] as? String,
              let challenge = data(fromB64url: challengeStr),
              let user = options["user"] as? [String: Any],
              let userIdStr = user["id"] as? String,
              let userId = data(fromB64url: userIdStr),
              let name = user["name"] as? String else {
            throw AccountCall.Failure.message("Could not start adding a passkey.")
        }

        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: passkeyRelyingParty)
        let request = provider.createCredentialRegistrationRequest(
            challenge: challenge, name: name, userID: userId)

        let authorization = try await PasskeyCeremony().run([request])
        guard let credential = authorization.credential
                as? ASAuthorizationPlatformPublicKeyCredentialRegistration else {
            throw AccountCall.Failure.message("That passkey could not be added.")
        }

        // The shape `@simplewebauthn/server` expects. Assembled here rather than on the server
        // because only this side has the raw objects.
        let response: [String: Any] = [
            "id": b64url(credential.credentialID),
            "rawId": b64url(credential.credentialID),
            "type": "public-key",
            "clientExtensionResults": [:],
            "response": [
                "clientDataJSON": b64url(credential.rawClientDataJSON),
                "attestationObject": b64url(credential.rawAttestationObject ?? Data()),
            ],
        ]
        _ = try await AccountCall.run("passkeyRegistrationVerify",
                                      ["challengeId": challengeId, "response": response, "label": label])
    }

    /// Sign in with a passkey, with no session yet. Returns once Firebase has accepted the custom
    /// token the server minted.
    ///
    /// ⚠️ THE SERVER'S TOKEN IS THE WHOLE TRUST BOUNDARY HERE. Nothing on this side decides who you
    /// are — the assertion goes up, the server verifies it against a stored public key and a
    /// single-use challenge it issued, and only then is a token minted.
    @MainActor
    static func signIn() async throws {
        let start = try await AccountCall.run("passkeyAuthOptions")
        guard let options = start["options"] as? [String: Any],
              let challengeId = start["challengeId"] as? String,
              let challengeStr = options["challenge"] as? String,
              let challenge = data(fromB64url: challengeStr) else {
            throw AccountCall.Failure.message("Could not start signing in.")
        }

        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: passkeyRelyingParty)
        let request = provider.createCredentialAssertionRequest(challenge: challenge)

        let authorization = try await PasskeyCeremony().run([request])
        guard let credential = authorization.credential
                as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
            throw AccountCall.Failure.message("That passkey was not recognised.")
        }

        let response: [String: Any] = [
            "id": b64url(credential.credentialID),
            "rawId": b64url(credential.credentialID),
            "type": "public-key",
            "clientExtensionResults": [:],
            "response": [
                "clientDataJSON": b64url(credential.rawClientDataJSON),
                "authenticatorData": b64url(credential.rawAuthenticatorData),
                "signature": b64url(credential.signature),
                "userHandle": b64url(credential.userID),
            ],
        ]
        let out = try await AccountCall.run("passkeyAuthVerify",
                                            ["challengeId": challengeId, "response": response])
        guard let token = out["token"] as? String else {
            throw AccountCall.Failure.message("That passkey was not recognised.")
        }
        _ = try await Auth.auth().signIn(withCustomToken: token)
    }
}

// MARK: - The page

struct PasskeysView: View {
    private struct Row: Identifiable {
        let id: String
        let label: String
        let created: Date?
        let lastUsed: Date?
    }

    @State private var rows: [Row] = []
    @State private var loading = true
    @State private var working = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Text("🔑").font(.system(size: 88))
                    Text("Passkeys").font(.system(size: 30, weight: .bold))
                    Text("Log in safely and keep your account secure.")
                        .font(.body).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            Section {
                if loading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.label)
                            Text(subtitle(row)).font(.footnote).foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) { Task { await remove(row) } }
                        }
                    }
                }
                // The green add row, at the bottom of the same card — his layout.
                Button { Task { await add() } } label: {
                    Label("Add Passkey", systemImage: "plus")
                        .foregroundStyle(Color.green)
                }
                .disabled(working)
            } footer: {
                Text("Your passkeys are stored securely in your password manager.")
            }

            if let error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Passkeys")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task { await load() }
    }

    private func subtitle(_ r: Row) -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"
        var parts: [String] = []
        if let c = r.created { parts.append("created \(f.string(from: c))") }
        if let u = r.lastUsed { parts.append("used \(f.string(from: u))") }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let d = try await AccountCall.run("listPasskeys")
            let list = d["passkeys"] as? [[String: Any]] ?? []
            rows = list.map {
                Row(id: $0["id"] as? String ?? UUID().uuidString,
                    label: $0["label"] as? String ?? "Passkey",
                    created: ($0["createdAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) },
                    lastUsed: ($0["lastUsedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) })
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func add() async {
        working = true
        error = nil
        defer { working = false }
        do {
            try await Passkeys.register(label: UIDevice.current.name)
            await load()
        } catch let e as ASAuthorizationError where e.code == .canceled {
            // Backing out of the system sheet is not a failure and must not be reported as one.
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func remove(_ row: Row) async {
        working = true
        defer { working = false }
        do {
            try await AccountCall.run("deletePasskey", ["id": row.id])
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
