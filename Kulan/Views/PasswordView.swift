import SwiftUI
import LocalAuthentication
import FirebaseAuth
import AuthenticationServices   // 2026-09-24 fix-all #204: Apple's re-auth button

// Settings › Password. Set one if you have none, change the one you have.
//
// WHY THIS SCREEN EXISTS AT ALL. Until now the only way to get a password onto a Google or Apple
// account was Settings › Account › Sign-in Methods › Connect Email, which asks for an address we
// already know and is filed under a name nobody looking for the word "password" would ever open.
// The owner's instruction was to put it where people look.
//
// ═══ THE LOCK, AND WHY IT IS THIS LOCK ═══
//
// It does NOT ask for your old password. That is deliberate and it is the whole point: the people
// who need this screen most are the ones who never set one, or who just got in with a code
// precisely because they had forgotten it. An old-password field would lock out exactly them.
//
// What guards it instead is the phone's own lock, and the reasoning is not the obvious one. There
// are two attackers and they need two different locks:
//
//   · SOMEBODY HOLDING YOUR UNLOCKED PHONE. An emailed code is NO defence here at all — your inbox
//     is on that same phone and they would simply read it. Face ID stops them, because their face
//     is not yours.
//   · SOMEBODY FAR AWAY who knows your address. Face ID means nothing to them; they do not have the
//     phone. The emailed code is what stops them, which is why the code guards Forgot Password and
//     not this screen.
//
// Getting those two the wrong way round would have felt secure and protected nobody.
//
// ⚠️ `.deviceOwnerAuthentication`, NOT `.deviceOwnerAuthenticationWithBiometrics`. The first falls
// back to the passcode on its own when Face ID fails, is not enrolled, or the phone only has Touch
// ID. The biometrics-only variant refuses instead, which would lock out anybody wearing a mask or
// holding a phone with a dirty sensor.
//
// ⚠️ AND IT DELIBERATELY DISAGREES WITH APP LOCK. RootView's lock screen unlocks when the phone has
// no passcode at all, so a phone with no lock cannot trap you out of your own messages. Here the
// opposite is correct: opening this screen anyway would make the guard decorative for exactly the
// phones that are easiest to pick up. So this one refuses and says why. That divergence is
// intentional; it is not a bug to be tidied up later.
struct PasswordView: View {
    /// Filled by the caller from the signed-in account, so nobody retypes an address we already
    /// know. For a Google account this is the Google address; for Apple with Hide My Email it is
    /// the privaterelay one, which is shown ON PURPOSE — it becomes their login and nobody would
    /// otherwise guess it.
    let address: String
    /// True when the account has no password yet, which changes every word on the screen and which
    /// of the two security emails goes out.
    let isFirstPassword: Bool

    @Environment(\.dismiss) private var dismiss

    private enum Gate {
        case checking          // the Face ID sheet is up
        case open              // proved, show the fields
        case refused           // they cancelled or failed
        case noDeviceLock      // the phone has no Face ID, no Touch ID and no passcode
        case needsReauth       // Firebase wants a fresh sign-in before it will move the password
    }

    @State private var gate: Gate = .checking
    @State private var password = ""
    @State private var confirm = ""
    @State private var currentPassword = ""
    // One reveal flag per row — his design puts an eye on each, and a single shared flag would show
    // all three at once, which is exactly what somebody looking over your shoulder wants.
    @State private var showCurrent = false
    @State private var showNew = false
    @State private var showConfirm = false
    // 2026-09-24 audit: "Forgot password?" mailed a code the app had nowhere to type. It now pushes
    // `PasswordResetCodeView`, the same shape as the email-change code page.
    @State private var resetCodeOpen = false
    @State private var resetAddress = ""
    @State private var busy = false
    @Environment(\.colorScheme) private var scheme   // 2026-09-24 fix-all #204: Apple button style
    @State private var error: String?
    @State private var done = false
    @FocusState private var focused: Bool

    /// ⛔ EIGHT, HIS NUMBER — 2026-09-16: "Use at least 8 characters" is the footnote he drew on the
    /// page, and `functions-account` refuses anything shorter on the reset path. Six was Firebase's
    /// own floor and is no longer the one that decides.
    // 2026-09-25: the four rules live in `PasswordRules`, shown as the checklist under the fields.
    private var rules: PasswordRules { PasswordRules(password: password, confirm: confirm) }
    // 2026-09-24 decision D2: changing needs the current password every time, however fresh the session.
    private var canSave: Bool { rules.allMet && !busy && (isFirstPassword || !currentPassword.isEmpty) }

    var body: some View {
        Group {
            switch gate {
            case .checking:      ProgressView().controlSize(.large)
            case .open:          form
            case .refused:       refusedState
            case .noDeviceLock:  noLockState
            case .needsReauth:   reauthState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // ⛔ "Password" — his page title, 2026-09-16, the same word on both variants. The screen used
        // to rename itself Set/Change depending on whether one existed; the card below already says
        // which it is by whether there is a Current row.
        .navigationTitle("Password")
        .navigationBarTitleDisplayMode(.inline)
        // His ask, for the same reason as the email page.
        .toolbar(.hidden, for: .tabBar)
        .task { await proveItIsYou() }
        .alert("Password saved", isPresented: $done) {
            Button("Done") { dismiss() }
        } message: {
            Text(isFirstPassword
                 ? "You can now sign in with \(address) and this password."
                 : "Your old password no longer works.")
        }
    }

    // MARK: - The three states before the form

    // ⛔ HIS PAGE, 2026-09-16 — one card holding Current / New / Confirm with an eye on each row, the
    // requirement as a footnote under it, "Forgot password?" in a card of its own, and Save in the
    // navigation bar rather than as a row in the form.
    //
    // ⚠️ THE SHAPE IS CONDITIONAL AND THAT IS THE POINT OF HIS ASK: "if user before doesn't have
    // password show only new password and dont show also forget password current password". An
    // account with no password has nothing to prove and nothing to recover, so both of those rows
    // would be asking about something that does not exist.
    //
    // ⚠️ THE FACE ID GATE ABOVE THIS IS UNTOUCHED. He asked about the layout; the gate is why this
    // screen can show the fields at all, and removing it was not part of that.
    @ViewBuilder private var form: some View {
        Form {
            Section {
                if !isFirstPassword {
                    revealRow("Current password", text: $currentPassword,
                              reveal: $showCurrent, content: .password)
                }
                revealRow("New password", text: $password,
                          reveal: $showNew, content: .newPassword, focus: true)
                revealRow("Confirm new password", text: $confirm,
                          reveal: $showConfirm, content: .newPassword)
            } footer: {
                // The checklist replaces "Use at least 8 characters" (owner, 2026-09-25). The second
                // sentence is a promise the server keeps: `confirmPasswordReset` and Firebase's own
                // update both revoke every refresh token.
                VStack(alignment: .leading, spacing: 10) {
                    PasswordChecklist(rules: rules)
                    Text("After changing, all other devices will need to sign in again.")
                }
                .padding(.top, 4)
            }

            // Only where there is a password to have forgotten — his rule.
            if !isFirstPassword {
                Section {
                    Button("Forgot password?") { Task { await forgot() } }
                        .disabled(busy)
                        .foregroundStyle(Color.accentColor)
                }
            }

            if let error {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }
        }
        .onAppear { focused = true }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { save() }
                    .disabled(!canSave)
                    .fontWeight(.semibold)
            }
        }
        .navigationDestination(isPresented: $resetCodeOpen) {
            PasswordResetCodeView(address: resetAddress) {
                // The password is changed; this whole flow is done, so leave together.
                dismiss()
            }
        }
    }

    /// One row of the card: a secure field with an eye that turns it into a plain one.
    ///
    /// ⚠️ TWO FIELDS RATHER THAN A TOGGLED `isSecureTextEntry`. Swapping that flag on a live
    /// `UITextField` is what makes iOS clear the text on the next keystroke; two fields sharing one
    /// binding keep what has been typed, which is the whole reason somebody taps the eye.
    @ViewBuilder private func revealRow(_ title: String, text: Binding<String>,
                                        reveal: Binding<Bool>,
                                        content: UITextContentType,
                                        focus: Bool = false) -> some View {
        HStack(spacing: 10) {
            Group {
                if reveal.wrappedValue {
                    TextField(title, text: text)
                        .textContentType(content)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    SecureField(title, text: text)
                        .textContentType(content)
                }
            }
            // ⚠️ ONLY THE ROW THAT ASKED FOR IT. `focused` is a Bool `@FocusState`, so
            // `.focused($focused)` binds a view to its true state; attaching it to every row would
            // make three views claim the same flag and the last one laid out would win.
            .modifier(FocusIf(active: focus, flag: $focused))

            Button {
                reveal.wrappedValue.toggle()
            } label: {
                Image(systemName: reveal.wrappedValue ? "eye.slash" : "eye")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(reveal.wrappedValue ? "Hide \(title)" : "Show \(title)")
        }
    }

    /// "Forgot password?" — his flow: a code to the address already on the account, and the same mail
    /// carries a link to fariin.com for somebody reading it on a laptop. Both doors, one code; see
    /// `startPasswordReset` in `functions-account`.
    private func forgot() async {
        guard NetworkState.shared.isOnline else {
            error = "No internet connection. Check your connection and try again."
            return
        }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let reply = try await AccountCall.run("startPasswordReset")
            // The server says where it actually sent it (masked); that is the address to name.
            resetAddress = (reply["maskedEmail"] as? String) ?? address
            resetCodeOpen = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    @ViewBuilder private var refusedState: some View {
        ContentUnavailableView {
            Label("Not verified", systemImage: "faceid")
        } description: {
            Text("Unlock with Face ID, Touch ID or your passcode to change your password.")
        } actions: {
            Button("Try Again") { Task { await proveItIsYou() } }
                .buttonStyle(.borderedProminent)
        }
    }

    /// The phone has no lock at all, and there is no honest way around it.
    ///
    /// Think about what else we could ask for. An emailed code arrives ON that phone. An old
    /// password does not exist, which is why they are here. A security question would be answerable
    /// from the messages sitting on that phone. Every secret either lands on the device or already
    /// lives on it, so a phone with no lock cannot prove who is holding it. There is no clever
    /// substitute, only a worse one dressed up.
    ///
    /// Apple takes the same position: no device passcode, no Apple Pay, no Passwords app. And the
    /// advice is right for its own sake — a phone with no lock means anyone who picks it up already
    /// reads every message this person has ever sent, which is a far bigger problem than the one
    /// they came here to solve.
    @ViewBuilder private var noLockState: some View {
        ContentUnavailableView {
            Label("Lock your iPhone first", systemImage: "lock.slash")
        } description: {
            Text(DeviceLock.noLockAdvice)
        } actions: {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    /// Firebase refused because the sign-in is old, and this is the COMMON case, not an edge.
    ///
    /// Moving a password is one of the operations Firebase calls sensitive: it wants a sign-in from
    /// the last few minutes, and this app's own threshold is four. So anybody who opened Fariin more
    /// than a few minutes before wandering into Settings lands here. Left unhandled they would have
    /// seen Firebase's own words, "This operation is sensitive and requires recent authentication",
    /// which tells a person nothing they can act on.
    ///
    /// Face ID already proved the human. This is not a second security question, it is Firebase
    /// wanting a fresh token, so the cheapest honest door for the account is the one to offer:
    /// changing a password means you know the current one, and setting a first password means you
    /// have Apple or Google, which is a single tap.
    @ViewBuilder private var reauthState: some View {
        Form {
            Section {
                if isFirstPassword {
                    // Apple and Google accounts: one tap on the sheet they already know.
                    if AuthService.shared.isConnected(.google) {
                        Button("Continue with Google") {
                            reauth { try await AuthService.shared.reauthGoogle() }
                        }
                    }
                    if AuthService.shared.isConnected(.apple) {
                        // 2026-09-24 fix-all #204: this row was a dead "Continue with Apple" that
                        // only told you to go elsewhere. It is Apple's own button now, wired to the
                        // same re-auth Delete Account uses (`reauthApple(authorization:)`), styled
                        // and rebuilt on a scheme change exactly as that page does.
                        SignInWithAppleButton(.continue) { request in
                            AuthService.shared.prepareAppleRequest(request)
                        } onCompletion: { result in
                            switch result {
                            case .success(let auth):
                                reauth { try await AuthService.shared.reauthApple(authorization: auth) }
                            case .failure(let e):
                                // Only a real cancel is silent, as on Delete Account.
                                if (e as NSError).code != ASAuthorizationError.canceled.rawValue {
                                    error = "Apple couldn't verify you. Please try again."
                                }
                            }
                        }
                        .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
                        .id(scheme)
                        .frame(height: 44)
                        .disabled(busy)
                    }
                } else {
                    // Changing, not recovering: they know the current one by definition.
                    SecureField("Your current password", text: $currentPassword)
                        .textContentType(.password)
                    Button("Verify") {
                        reauth { try await AuthService.shared.reauthEmail(password: currentPassword) }
                    }
                    .disabled(currentPassword.isEmpty || busy)
                }
            } header: {
                Text("One more check")
            } footer: {
                Text("You have been signed in a while, so we need to confirm it is really you before changing this.")
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
    }

    private func reauth(_ work: @escaping () async throws -> Void) {
        busy = true; error = nil
        Task {
            do {
                try await work()
                await MainActor.run { busy = false; currentPassword = ""; gate = .open }
            } catch {
                await MainActor.run {
                    busy = false
                    self.error = AuthService.plainMessage(error) ?? "Could not verify that. Try again."
                }
            }
        }
    }

    // MARK: - Proving it is you

    private func proveItIsYou() async {
        gate = .checking
        // Moved into DeviceLock once a second screen needed the same gate. The reasoning for why
        // this is Face ID and not an emailed code lives there, next to the code, rather than being
        // restated in every caller.
        switch await DeviceLock.prove(reason: isFirstPassword ? "Set your Fariin password"
                                                              : "Change your Fariin password") {
        case .proved:  gate = .open
        case .refused: gate = .refused
        case .noLock:  gate = .noDeviceLock
        }
    }

    // MARK: - Saving

    private func save() {
        guard NetworkState.shared.isOnline else {
            error = "No internet connection. Check your connection and try again."
            return
        }
        busy = true; error = nil
        Task {
            do {
                // ⛔ THE CURRENT PASSWORD IS SPENT HERE, not left as decoration. His card asks for it,
                // so it has to be the thing that proves who is typing — otherwise the row is a box
                // that does nothing and Firebase decides on its own whether to demand a fresh login,
                // which is the `.needsReauth` detour below.
                //
                // 2026-09-24 decision D2: NO LONGER BEST EFFORT. It was `try?`, so a wrong current
                // password went unnoticed whenever the session was fresh enough for Firebase, and the
                // password moved anyway. Now a change always re-authenticates with the current
                // password first, and a wrong one stops here with its own message.
                if !isFirstPassword {
                    do {
                        try await AuthService.shared.reauthEmail(password: currentPassword)
                    } catch {
                        await MainActor.run {
                            busy = false
                            // Same wording DeleteAccountView uses for a wrong password on its page.
                            self.error = AuthService.plainMessage(error, credentialHint: "That password is not right.")
                                ?? "Could not verify that. Try again."
                        }
                        return
                    }
                }
                try await AuthService.shared.setPassword(password, isFirst: isFirstPassword)
                await MainActor.run { busy = false; done = true }
            } catch let e as NSError where e.code == AuthErrorCode.requiresRecentLogin.rawValue {
                // Not an error to show, a step to offer. Firebase's own wording here is "This
                // operation is sensitive and requires recent authentication", which reads as a
                // failure and gives nobody anything to do about it.
                await MainActor.run { busy = false; error = nil; gate = .needsReauth }
            } catch {
                await MainActor.run {
                    busy = false
                    self.error = AuthService.plainMessage(error) ?? "Could not save that. Try again."
                }
            }
        }
    }
}

/// 2026-09-24 audit: the in-app half of "Forgot password?". `startPasswordReset` mails six digits and
/// says "Enter this code in Fariin", but no screen took them, so `confirmPasswordReset` had no caller
/// and the only way through was the web link. Same shape as `EmailCodeView`: the code, the two new
/// password rows from the page above, and Save in the bar. Every string is one already used on
/// those two pages.
struct PasswordResetCodeView: View {
    let address: String
    var onDone: () -> Void

    @State private var code = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var working = false
    @State private var error: String?
    @State private var done = false

    private var rules: PasswordRules { PasswordRules(password: password, confirm: confirm) }
    private var canSave: Bool { !working && code.count == 6 && rules.allMet }

    var body: some View {
        List {
            Section {
                TextField("6-digit code", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .disabled(working)
                    // A number pad cannot refuse a paste, so the field is filtered, as on the email page.
                    .onChange(of: code) { _, new in
                        let digits = String(new.filter(\.isNumber).prefix(6))
                        if digits != new { code = digits }
                    }
            } header: {
                Text("Verification code").textCase(nil)
            } footer: {
                Text("We sent a code to \(address). Enter it below to confirm.")
            }

            Section {
                SecureField("New password", text: $password)
                    .textContentType(.newPassword)
                    .disabled(working)
                SecureField("Confirm new password", text: $confirm)
                    .textContentType(.newPassword)
                    .disabled(working)
            } footer: {
                VStack(alignment: .leading, spacing: 10) {
                    PasswordChecklist(rules: rules)
                    Text("After changing, all other devices will need to sign in again.")
                }
                .padding(.top, 4)
            }

            if let error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Password")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { Task { await save() } }
                    .disabled(!canSave)
                    .fontWeight(.semibold)
                    .opacity(working ? 0.4 : 1)
            }
        }
        .alert("Password saved", isPresented: $done) {
            Button("Done") { onDone() }
        } message: {
            Text("Your old password no longer works.")
        }
    }

    private func save() async {
        guard canSave else { return }
        guard NetworkState.shared.isOnline else {
            error = "No internet connection. Check your connection and try again."
            return
        }
        working = true
        error = nil
        defer { working = false }
        do {
            try await AccountCall.run("confirmPasswordReset",
                                      (["code": code, "newPassword": password] as [String: Any])
                                        .merging(AuthService.deviceFields) { a, _ in a })
            // ⚠️ `confirmPasswordReset` revokes EVERY refresh token, this phone's included, so without
            // a fresh sign-in this device would be thrown out at its next token refresh. Signing
            // straight back in with the password just set keeps it in. Best effort: if it fails the
            // password is still changed, and the worst case is the ordinary sign-in screen.
            try? await AuthService.shared.reauthEmail(password: password)
            done = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Applies `.focused` to exactly one field. A Bool `@FocusState` has one true state, so the
/// modifier has to be attached conditionally rather than to every row.
private struct FocusIf: ViewModifier {
    let active: Bool
    @FocusState.Binding var flag: Bool

    func body(content: Content) -> some View {
        if active { content.focused($flag) } else { content }
    }
}

/// The four rules a new password must meet — owner, 2026-09-25, with the reference page's checklist.
/// ⛔ A CHECKLIST, NOT A RED/YELLOW/GREEN STRENGTH METER. His question, my call: a meter guesses at
/// strength and people argue with it ("why is mine only yellow?"); a checklist says exactly what is
/// needed and ticks each part off as it happens, which is what the large apps do on this screen.
struct PasswordRules {
    let password: String
    let confirm: String

    var longEnough: Bool { password.count >= 8 }
    var hasLetter: Bool { password.contains { $0.isLetter } }
    var hasNumber: Bool { password.contains { $0.isNumber } }
    var matches: Bool { !confirm.isEmpty && confirm == password }
    var allMet: Bool { longEnough && hasLetter && hasNumber && matches }
}

/// Grey until a rule is met, then a green tick and full-strength text. Nothing is ever red: an
/// unfinished password is not an error, it is a password still being typed.
struct PasswordChecklist: View {
    let rules: PasswordRules

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("At least 8 characters", rules.longEnough)
            row("At least 1 letter", rules.hasLetter)
            row("At least 1 number", rules.hasNumber)
            row("Passwords match", rules.matches)
        }
        .font(.subheadline)
        .animation(.easeOut(duration: 0.15), value: rules.allMet)
    }

    private func row(_ text: String, _ met: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(met ? Color.green : Color.secondary)
                .frame(width: 16)
            Text(text)
                .foregroundStyle(met ? Color.primary : Color.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(met ? "Done" : "Not yet")
    }
}
