import SwiftUI
import FirebaseAuth
import FirebaseFunctions

// ⛔ ACCOUNT SECURITY — the screens for his 2026-09-16 Account page: Email address, Password and
// Two-step verification. The server for all three is `functions-account` in the backend repo, and
// the reasoning behind the mechanism lives there rather than being repeated here.
//
// ⚠️ THREE RULES THESE SCREENS SHARE, so they are stated once:
//
// 1. **The bottom bar is hidden on every one of them** — his ask, twice ("also hide bottom nav bar
//    when iam in email page", and again for the password page). A tab bar under a page that is one
//    step of a flow invites you to walk out halfway through.
//
// 2. **The server decides, the screen reports.** Not one of these views checks whether a code is
//    right, whether an address is taken or how many tries are left. Every refusal arrives as an
//    `HttpsError` and is shown as its own sentence, because the server is deliberately vague about
//    some of them (a taken address answers "sent" and mails nothing — see `startEmailChange`) and a
//    screen that second-guessed that would leak exactly what the server is hiding.
//
// 3. **A fresh sign-in is the server's demand, not ours.** `requireFresh` refuses a token older than
//    five minutes on anything that changes an address or a password, and returns `reauth: true` in
//    its details. `AccountCall` turns that into `.needsReauth` so a screen can send the person back
//    through the door rather than showing them an error they cannot act on.

// MARK: - Calling the account functions

/// The one place these screens talk to `functions-account`.
enum AccountCall {
    enum Failure: LocalizedError {
        /// The server wants a fresh sign-in first — `requireFresh`'s `reauth: true`.
        case needsReauth
        /// Anything else, already phrased for a person by the function that refused.
        case message(String)

        var errorDescription: String? {
            switch self {
            case .needsReauth: return "For your security, sign in again to continue."
            case .message(let m): return m
            }
        }
    }

    @discardableResult
    static func run(_ name: String, _ payload: [String: Any] = [:]) async throws -> [String: Any] {
        do {
            let result = try await Functions.functions(region: "me-central1")
                .httpsCallable(name)
                .call(payload)
            return result.data as? [String: Any] ?? [:]
        } catch {
            let ns = error as NSError
            // ⚠️ THE DETAILS DICTIONARY IS WHERE THE SERVER PUTS MACHINE-READABLE FACTS — `reauth`
            // here, `lockedUntil` and `retryAfter` elsewhere. The message is for the person; this is
            // for the screen.
            // ⚠️ THE LITERAL "details", NOT `FunctionsErrorDetailsKey`. `ChatPin.lockDeadline`
            // already records why: the constant is public in the Functions SDK and its value IS this
            // string, but there is no Mac here to compile against, and a name that turns out not to
            // be exported costs a 40-minute round trip where the string cannot.
            if let details = ns.userInfo["details"] as? [String: Any],
               details["reauth"] as? Bool == true {
                throw Failure.needsReauth
            }
            throw Failure.message(ns.localizedDescription)
        }
    }
}

// MARK: - 5. Email address

/// "Change email" — his first screenshot: the current connection in one card, the new address in
/// another, and **Send code** in the navigation bar rather than at the bottom of the page.
struct ChangeEmailView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var newEmail = ""
    @State private var sending = false
    @State private var error: String?
    /// Set once the server has accepted the request, which pushes the code screen.
    @State private var awaitingCode = false

    private var auth: AuthService { .shared }

    /// What the account signs in with today. Apple first, then Google, then a password address —
    /// the order the Sign-in Methods list already uses, so the two screens agree about which door is
    /// "the" one when several are attached.
    private var currentDoor: (method: AuthService.SignInMethod, address: String)? {
        for m in [AuthService.SignInMethod.apple, .google, .email] {
            if let id = auth.connectedIdentifier(m) { return (m, id) }
        }
        return nil
    }

    private var canSend: Bool {
        !sending && newEmail.contains("@") && newEmail.contains(".")
            && newEmail.trimmingCharacters(in: .whitespaces).lowercased() != (Auth.auth().currentUser?.email ?? "").lowercased()
    }

    var body: some View {
        List {
            if let door = currentDoor {
                Section {
                    HStack(spacing: 12) {
                        providerMark(door.method)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(door.method.title).font(.body)
                            Text(door.address)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        // His green tick: this address is confirmed, which is a fact about the
                        // account rather than decoration.
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: 20))
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("Current email").textCase(nil)
                }
            }

            Section {
                TextField("you@example.com", text: $newEmail)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(sending)
            } header: {
                Text("New email").textCase(nil)
            } footer: {
                Text("We'll send a 6-digit code to your new address to confirm it's yours.")
            }

            if let error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Change email")
        .navigationBarTitleDisplayMode(.inline)
        // His ask, and the reason is in the file header.
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Send code") { Task { await send() } }
                    .disabled(!canSend)
                    .opacity(sending ? 0.4 : 1)
            }
        }
        .navigationDestination(isPresented: $awaitingCode) {
            EmailCodeView(address: newEmail.trimmingCharacters(in: .whitespaces).lowercased()) {
                // The address is live now; this whole flow is done, so leave together.
                dismiss()
            }
        }
    }

    @ViewBuilder private func providerMark(_ m: AuthService.SignInMethod) -> some View {
        switch m {
        case .apple:
            Image(systemName: "apple.logo").font(.system(size: 22)).frame(width: 28)
        case .google:
            // The mark the sign-in doors already use.
            Image("google-g").resizable().scaledToFit().frame(width: 22, height: 22).frame(width: 28)
        case .email:
            Image(systemName: "envelope.fill").font(.system(size: 19)).frame(width: 28)
        }
    }

    private func send() async {
        guard canSend else { return }
        sending = true
        error = nil
        defer { sending = false }
        do {
            try await AccountCall.run("startEmailChange",
                                      ["newEmail": newEmail.trimmingCharacters(in: .whitespaces)])
            awaitingCode = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The second screen: the code, and **Confirm** in the bar. Pushed only once the server has accepted
/// the address, so there is never a code screen for a request that was refused.
struct EmailCodeView: View {
    let address: String
    var onDone: () -> Void

    @State private var code = ""
    @State private var working = false
    @State private var error: String?

    private var canConfirm: Bool { !working && code.count == 6 }

    var body: some View {
        List {
            Section {
                TextField("6-digit code", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .disabled(working)
                    // ⚠️ A NUMBER PAD HAS NO RETURN KEY AND CANNOT REFUSE A PASTE, so the field is
                    // the wrong place to trust — same rule the Chat Key sheet follows.
                    .onChange(of: code) { _, new in
                        let digits = String(new.filter(\.isNumber).prefix(6))
                        if digits != new { code = digits }
                    }
            } header: {
                Text("Verification code").textCase(nil)
            } footer: {
                Text("We sent a code to \(address). Enter it below to confirm.")
            }

            if let error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Change email")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Confirm") { Task { await confirm() } }
                    .disabled(!canConfirm)
                    .opacity(working ? 0.4 : 1)
            }
        }
    }

    private func confirm() async {
        guard canConfirm else { return }
        working = true
        error = nil
        defer { working = false }
        do {
            try await AccountCall.run("confirmEmailChange", ["code": code])
            // ⛔ THE TOKEN IS REFRESHED BEFORE ANYTHING READS THE NEW STATE. `confirmEmailChange`
            // revokes every refresh token — the address is an account's recovery route, so the other
            // devices come back through the front door — and this one has to pick up its new token
            // before the app asks Firebase who it is, or it reads the old address back.
            _ = try? await Auth.auth().currentUser?.getIDTokenResult(forcingRefresh: true)
            await ProfileStore.shared.refreshMe()
            onDone()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
