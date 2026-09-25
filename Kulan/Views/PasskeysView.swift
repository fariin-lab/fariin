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

    /// `immediateOnly`: show the sheet only if this phone already holds a matching passkey, and fail
    /// quietly (no sheet at all) when it does not. Used by the automatic offer on the sign-in screen.
    func run(_ requests: [ASAuthorizationRequest], immediateOnly: Bool = false) async throws -> ASAuthorization {
        try await withCheckedThrowingContinuation { cont in
            continuation = cont
            let c = ASAuthorizationController(authorizationRequests: requests)
            c.delegate = self
            c.presentationContextProvider = self
            controller = c
            if immediateOnly {
                c.performRequests(options: .preferImmediatelyAvailableCredentials)
            } else {
                c.performRequests()
            }
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
    /// The server's one-time challenge for adding a passkey, fetched AHEAD of the tap.
    ///
    /// ⛔ WHY AHEAD — owner, 2026-09-25: "when I tap Add Passkey, the passkey sheet takes a bit late".
    /// The system sheet cannot open until the challenge is back, and that is a round trip to
    /// me-central1, plus a cold start when the function has been idle. The Passkeys page now fetches
    /// one as it opens, so the tap goes straight to the sheet. The server keeps a challenge for five
    /// minutes; one older than four is fetched again rather than risk it expiring mid-sheet.
    struct Prepared {
        let challengeId: String
        let challenge: Data
        let userId: Data
        let name: String
        let fetchedAt: Date
        var isFresh: Bool { Date().timeIntervalSince(fetchedAt) < 240 }
    }

    @MainActor
    static func prepareRegistration() async throws -> Prepared {
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
        return Prepared(challengeId: challengeId, challenge: challenge, userId: userId,
                        name: name, fetchedAt: Date())
    }

    /// `prepared`: a challenge fetched in advance (see `Prepared`). A stale or missing one is fetched
    /// now. Either way it is single-use: the server spends it on verify.
    @MainActor
    static func register(label: String, prepared: Prepared? = nil) async throws {
        let p: Prepared
        if let prepared, prepared.isFresh { p = prepared } else { p = try await prepareRegistration() }
        let challengeId = p.challengeId

        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: passkeyRelyingParty)
        let request = provider.createCredentialRegistrationRequest(
            challenge: p.challenge, name: p.name, userID: p.userId)

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
    ///
    /// `immediateOnly` passes through to the ceremony: with it, a phone with no Fariin passkey shows
    /// nothing and this throws, which the caller swallows.
    @MainActor
    static func signIn(immediateOnly: Bool = false) async throws {
        let start = try await AccountCall.run("passkeyAuthOptions")
        guard let options = start["options"] as? [String: Any],
              let challengeId = start["challengeId"] as? String,
              let challengeStr = options["challenge"] as? String,
              let challenge = data(fromB64url: challengeStr) else {
            throw AccountCall.Failure.message("Could not start signing in.")
        }

        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: passkeyRelyingParty)
        let request = provider.createCredentialAssertionRequest(challenge: challenge)

        let authorization = try await PasskeyCeremony().run([request], immediateOnly: immediateOnly)
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
    // ⛔ REBUILT 2026-09-25 — owner, with the reference app's two screens: "why does our passkey page
    // not look pro … even you can't delete what you made". It was one emoji, one line, and a delete
    // hidden behind a swipe nobody finds. Now: an intro that explains it and offers one button when
    // there is no passkey, and a manage screen with a visible "…" menu per passkey once there is.
    private struct Row: Identifiable {
        let id: String
        let name: String
        let created: Date?
        let lastUsed: Date?
    }

    @State private var rows: [Row] = []
    @State private var loading = true
    @State private var working = false
    @State private var error: String?
    @State private var toDelete: Row?
    /// A challenge fetched as the page opens, so Add goes straight to the sheet (see Passkeys.Prepared).
    @State private var prepared: Passkeys.Prepared?

    private let brand = Color(hex: 0x0A84FF)

    var body: some View {
        Group {
            if loading && rows.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                intro
            } else {
                manage
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Passkeys")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task {
            async let list: Void = load()
            async let warm: Void = prefetch()
            _ = await (list, warm)
        }
        .alert("Delete passkey?", isPresented: Binding(get: { toDelete != nil },
                                                       set: { if !$0 { toDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let r = toDelete { Task { await remove(r) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will no longer be able to sign in to Fariin with this passkey.")
        }
    }

    // MARK: - No passkey yet

    private var intro: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 28) {
                    hero
                    Text("Sign in securely and protect your account")
                        .font(.title.weight(.bold))
                        .multilineTextAlignment(.center)
                    VStack(alignment: .leading, spacing: 22) {
                        point("checkmark.shield", "Create a passkey for a secure, easy way to sign in to your account.")
                        point("faceid", "Sign in to Fariin with Face ID, Touch ID or your device passcode.")
                        point("laptopcomputer.and.iphone", "Your passkey is stored safely in your password manager, such as iCloud Keychain.")
                    }
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 24)
            }
            Button { Task { await add() } } label: {
                Group {
                    if working { ProgressView().tint(.white) } else { Text("Create Passkey") }
                }
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 54)
                .background(brand, in: Capsule())
            }
            .disabled(working)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
    }

    private func point(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.primary)
                .frame(width: 32)
            Text(text).font(.body).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hero: some View {
        ZStack {
            Circle().fill(brand.opacity(0.14)).frame(width: 112, height: 112)
            Image(systemName: "person.badge.key.fill")
                .font(.system(size: 50, weight: .medium))
                .foregroundStyle(brand)
        }
    }

    // MARK: - Manage

    private var manage: some View {
        List {
            Section {
                VStack(spacing: 14) {
                    hero
                    Text("Manage your passkeys").font(.title.weight(.bold))
                    Text("Sign in to Fariin the same way you unlock your phone: with Face ID, Touch ID or your device passcode.")
                        .font(.body).multilineTextAlignment(.center)
                    Text("Your passkeys are stored safely in your password manager.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            Section {
                Button { Task { await add() } } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "plus").font(.system(size: 20, weight: .medium)).frame(width: 28)
                        Text("Add Passkey")
                        Spacer()
                        if working { ProgressView() }
                    }
                    .foregroundStyle(brand)
                }
                .disabled(working)

                ForEach(rows) { row in
                    passkeyRow(row)
                }
            }

            if let error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        }
    }

    private func passkeyRow(_ row: Row) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "person.badge.key")
                .font(.system(size: 20))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                Text(subtitle(row)).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button(role: .destructive) { toDelete = row } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .disabled(working)
        }
        .padding(.vertical, 4)
        .swipeActions {
            Button("Delete", role: .destructive) { toDelete = row }.tint(.red)
        }
    }

    private func subtitle(_ r: Row) -> String {
        let f = Date.FormatStyle(date: .abbreviated, time: .omitted)
        var parts: [String] = []
        if let c = r.created { parts.append("Created \(c.formatted(f))") }
        if let u = r.lastUsed { parts.append("Used \(u.formatted(f))") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Data

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let d = try await AccountCall.run("listPasskeys")
            let list = d["passkeys"] as? [[String: Any]] ?? []
            rows = list.map { item in
                // The password manager's name when the server knows it ("iCloud Keychain"); the label
                // saved with an older passkey otherwise.
                let provider = item["provider"] as? String ?? ""
                let label = item["label"] as? String ?? "Passkey"
                return Row(id: item["id"] as? String ?? UUID().uuidString,
                           name: provider.isEmpty ? label : provider,
                           created: (item["createdAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) },
                           lastUsed: (item["lastUsedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) })
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func add() async {
        guard !working else { return }
        working = true
        error = nil
        defer { working = false }
        do {
            let ready = prepared
            prepared = nil   // single-use: the server spends it on verify
            try await Passkeys.register(label: "Passkey", prepared: ready)
            await load()
        } catch let e as ASAuthorizationError where e.code == .canceled {
            // Backing out of the system sheet is not a failure and must not be reported as one.
        } catch {
            self.error = error.localizedDescription
        }
        // Whatever happened, the next tap should be instant too.
        await prefetch()
    }

    /// Quietly fetch the next challenge. A failure here is not shown: the tap fetches its own.
    private func prefetch() async {
        prepared = try? await Passkeys.prepareRegistration()
    }

    private func remove(_ row: Row) async {
        guard !working else { return }
        working = true
        error = nil
        defer { working = false }
        do {
            try await AccountCall.run("deletePasskey", ["id": row.id])
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
