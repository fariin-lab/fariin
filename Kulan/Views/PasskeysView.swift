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

    /// A passkey's id as the server stores it (base64url) back to the raw credential id.
    static func credentialData(_ id: String) -> Data? { data(fromB64url: id) }

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
                                      (["challengeId": challengeId, "response": response, "label": label] as [String: Any])
                                        .merging(AuthService.deviceFields) { a, _ in a })
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
    private struct Row: Identifiable, Codable {
        let id: String
        let name: String
        let created: Date?
        let lastUsed: Date?
    }

    /// ⛔ THE LAST LIST, KEPT — owner, 2026-09-25: "every time I enter, it is loading". The list was
    /// @State only, so every visit started empty and showed a spinner until `listPasskeys` answered.
    /// The reference app draws what it last knew and refreshes behind it. Stored per account in
    /// UserDefaults: names and dates only, nothing that signs anything.
    private static func cacheKey() -> String? {
        Auth.auth().currentUser.map { "passkeys.list.\($0.uid)" }
    }
    private static func cachedRows() -> [Row]? {
        guard let k = cacheKey(), let data = UserDefaults.standard.data(forKey: k) else { return nil }
        return try? JSONDecoder().decode([Row].self, from: data)
    }
    private static func storeRows(_ rows: [Row]) {
        guard let k = cacheKey(), let data = try? JSONEncoder().encode(rows) else { return }
        UserDefaults.standard.set(data, forKey: k)
    }

    @State private var rows: [Row]
    /// True only when there is nothing cached to show: the first visit ever on this phone.
    @State private var loading: Bool

    init() {
        let cached = Self.cachedRows()
        _rows = State(initialValue: cached ?? [])
        _loading = State(initialValue: cached == nil)
    }
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
                    Text("Create Passkey")   // no spinner: the system sheet is the feedback (see Add Passkey)
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
                // ⛔ SHORT — owner, 2026-09-25 evening, with the reference app's page: a title and one
                // line. The where-it-is-stored note is the card's footer, as theirs is.
                VStack(spacing: 10) {
                    hero
                    Text("Passkeys").font(.title.weight(.bold))
                    Text("Sign in with Face ID. No password needed.")
                        .font(.body).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            Section {
                ForEach(rows) { row in
                    passkeyRow(row)
                }

                // ⛔ LAST IN THE CARD AND NO SPINNER — owner, 2026-09-25: "when I click Add Passkey it
                // is loading … the reference app is not". The spinner sat beside the row for the whole
                // time the system sheet was up. The sheet is the feedback; the row only stops a
                // second tap while it is open.
                Button { Task { await add() } } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "plus").font(.system(size: 20, weight: .medium)).frame(width: 34)
                        Text("Add Passkey")
                        Spacer()
                    }
                    .foregroundStyle(brand)
                }
                .disabled(working)
            } footer: {
                Text("Your passkeys are stored securely in your password manager.")
            }

            if let error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        }
    }

    private func passkeyRow(_ row: Row) -> some View {
        HStack(spacing: 14) {
            providerIcon(row.name)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.displayName(row.name))
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
        if let c = r.created { parts.append("created \(c.formatted(f))") }
        if let u = r.lastUsed { parts.append("used \(u.formatted(f))") }
        return parts.joined(separator: " · ")
    }

    /// ⛔ THE PASSWORD MANAGER'S OWN NAME AND ICON — owner, 2026-09-25, with the reference app's list:
    /// "Apple Passwords" with the Passwords app icon, "Google Password Manager" with Google's. Names and
    /// icons are the community passkey AAGUID list's (github.com/passkeydeveloper/passkey-authenticator-aaguids),
    /// which is where that list gets them too. The server still says "iCloud Keychain" for Apple's
    /// (its older name for the same id), so it is renamed here as well.
    private static func displayName(_ provider: String) -> String {
        provider.hasPrefix("iCloud Keychain") ? "Apple Passwords" : provider
    }

    @ViewBuilder private func providerIcon(_ provider: String) -> some View {
        let name = Self.displayName(provider)
        let tile = RoundedRectangle(cornerRadius: 7, style: .continuous)
        if name == "Apple Passwords" {
            // This icon carries its own white rounded tile.
            Image("pk_provider_apple").resizable().scaledToFit()
                .frame(width: 34, height: 34)
                .clipShape(tile)
        } else if name == "Google Password Manager" {
            Image("pk_provider_google").resizable().scaledToFit()
                .padding(4)
                .frame(width: 34, height: 34)
                .background(Color.white, in: tile)
        } else {
            Image(systemName: "person.badge.key.fill")
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color.gray, in: tile)
        }
    }

    // MARK: - Data

    private func load() async {
        // No spinner over a list we already have: the refresh happens behind it.
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
            Self.storeRows(rows)
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
            // Bug hunt 2026-09-25: the server forgot it, but the Passwords app kept offering it at
            // sign-in, where it could only fail. iOS 26's credential updater tells the password
            // manager this credential is gone so it can remove it. The row id IS the credential id
            // (base64url), which is how the server keys it. Best effort.
            if let credentialID = Passkeys.credentialData(row.id) {
                try? await ASCredentialUpdater().reportUnknownPublicKeyCredential(
                    relyingPartyIdentifier: passkeyRelyingParty, credentialID: credentialID)
            }
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
