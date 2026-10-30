import SwiftUI
import LocalAuthentication
import FirebaseAuth
import AuthenticationServices   // 2026-09-24 fix-all #204: Apple's re-auth button
import Security                 // SecAddSharedWebCredential (SavePasswordOffer)

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
    /// Set when a save was stopped for a fresh sign-in; the sign-in's success finishes that save.
    @State private var saveAfterReauth = false
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
            case .checking:      BusyArc(size: 40, lineWidth: 4)
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
            // A beat after the alert has gone: asked while it is still closing, the dismiss is dropped
            // (owner 2026-10-29, the reset flow's twin of this bug).
            Button("Done") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { dismiss() } }
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
            // ⛔ A LINK, NOT A CARD — owner, 2026-09-29, with a picture: plain underlined text under
            // the rules, no rounded row. Clear list background so no card is drawn behind it.
            if !isFirstPassword {
                Section {
                    Button { Task { await forgot() } } label: {
                        Text("Forgot password?").underline()
                            .font(.body)
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                }
            }

            if let error {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }
        }
        .onAppear { focused = true }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // 2026-10-18 (owner): a FIRST password (Apple / Google account) says "Create" on a
                // blue button; both show a spinner in the button's place while the save runs.
                Button { save() } label: {
                    if busy {
                        BusyArc.small(isFirstPassword ? .white : .secondary)
                    } else {
                        Text(isFirstPassword ? "Create" : "Save").fontWeight(.semibold)
                    }
                }
                .disabled(!canSave)
                .modifier(CreateProminent(on: isFirstPassword))
            }
        }
        .navigationDestination(isPresented: $resetCodeOpen) {
            PasswordResetCodeView(address: resetAddress) {
                // The password is changed; this whole flow is done, so leave together.
                // ⛔ AFTER THE ALERT HAS GONE (owner 2026-10-29: "Password saved", Done, and he stayed on
                // the page). Done runs while its own alert is still being dismissed, and a dismiss asked
                // for in that moment is dropped by SwiftUI. Asked a beat later, it pops this page and the
                // code page above it in one move.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { dismiss() }
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
                await MainActor.run {
                    busy = false; gate = .open
                    // A change resuming its save still needs the current password it was typed with.
                    if !saveAfterReauth { currentPassword = "" }
                    // ⛔ 2026-10-18, owner: after the Apple check the form came back and wanted Save a
                    // second time. The re-check was asked FOR a save, and the new password is still in
                    // the fields, so the save finishes now.
                    if saveAfterReauth {
                        saveAfterReauth = false
                        if rules.allMet { save() }
                    }
                }
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
                SavePasswordOffer.offer(password: password)
            } catch let e as NSError where e.code == AuthErrorCode.requiresRecentLogin.rawValue {
                // Not an error to show, a step to offer. Firebase's own wording here is "This
                // operation is sensitive and requires recent authentication", which reads as a
                // failure and gives nobody anything to do about it.
                await MainActor.run { busy = false; error = nil; saveAfterReauth = true; gate = .needsReauth }
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

    // ⛔ TWO STEPS IN THE SIGN-UP PAGES' DESIGN (owner, 2026-10-17, "the exact same design" as the
    // code page): the six boxes alone first, checked by the server (`checkPasswordResetCode`, which
    // does not spend the code), and only then the new-password boxes. It was one grouped list with
    // the code and both passwords at once and Save in the bar.
    private enum Step { case code, password }
    @State private var step: Step = .code

    @State private var code = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var working = false
    @State private var error: String?
    @State private var done = false
    @State private var resendIn = 30
    @FocusState private var codeFocused: Bool
    // UIKit password fields (RevealablePasswordField), so plain @State focus, as on sign-up.
    @State private var newFocused = false
    @State private var confirmFocused = false
    @State private var reveal = false

    private var rules: PasswordRules { PasswordRules(password: password, confirm: confirm) }
    private var canSave: Bool { !working && code.count == 6 && rules.allMet }

    var body: some View {
        ZStack {
            AuthPalette.page.ignoresSafeArea()
                .dismissesKeyboardOnTap()
            ScrollView {
                VStack(spacing: 14) {
                    VStack(spacing: 6) {
                        Text(step == .code ? "Check your email" : "Create a new password")
                            .font(.system(size: 30, weight: .bold)).foregroundStyle(.primary)
                            .multilineTextAlignment(.center)
                        Text(step == .code
                             ? "Enter the 6-digit code we sent to \(address). It expires in 10 minutes."
                             : "Use at least 8 characters, with a letter and a number.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                    }
                    .padding(.top, 36).padding(.bottom, 12)

                    if step == .code {
                        CodeBoxes(code: $code, length: 6, focused: $codeFocused,
                                  invalid: error != nil && code.isEmpty)
                            .onChange(of: code) { _, v in
                                let digits = String(v.filter(\.isNumber).prefix(6))
                                if digits != v { code = digits; return }
                                if !digits.isEmpty { error = nil }
                                // Six digits in: check, without making them find a button.
                                if digits.count == 6 && !working { Task { await check() } }
                            }
                        pill("Continue", enabled: code.count == 6) { Task { await check() } }
                            .padding(.top, 4)
                        Button(resendIn > 0 ? "Send another code in \(resendIn)s" : "Send another code") {
                            Task { await resend() }
                        }
                        .font(.subheadline.weight(resendIn > 0 ? .regular : .semibold))
                        .foregroundStyle(resendIn > 0 ? Color.secondary : Color.primary)
                        .disabled(resendIn > 0 || working)
                        .padding(.top, 6)
                    } else {
                        passwordBox(text: $password, focused: $newFocused, placeholder: "New password",
                                    onSubmit: { newFocused = false; confirmFocused = true })
                        passwordBox(text: $confirm, focused: $confirmFocused, placeholder: "Confirm new password",
                                    onSubmit: { if canSave { Task { await save() } } })
                        PasswordChecklist(rules: rules)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4).padding(.top, 2)
                        pill("Save password", enabled: canSave) { Task { await save() } }
                            .padding(.top, 4)
                        Text("After changing, all other devices will need to log in again.")
                            .font(.footnote).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                    }

                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .animation(.easeInOut(duration: 0.2), value: step)
        .onAppear { if step == .code { codeFocused = true } }
        // The resend cooldown; the server limits sends too, this only keeps the button honest.
        .task(id: resendIn) {
            guard resendIn > 0 else { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if resendIn > 0 { resendIn -= 1 }
        }
        .alert("Password saved", isPresented: $done) {
            Button("Done") { onDone() }
        } message: {
            Text("Your old password no longer works.")
        }
    }

    /// The sign-up page's main button.
    private func pill(_ title: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if working { BusyArc.small(.white) } else { Text(title) }
            }
            .authActionPill(enabled: enabled || working)
        }
        .buttonStyle(.plain)
        .disabled(!enabled && !working)
        .allowsHitTesting(!working)   // busy is not disabled: disabled draws faded (owner 2026-10-26)
    }

    /// The sign-up page's password box: lock, UIKit field, eye.
    private func passwordBox(text: Binding<String>, focused: Binding<Bool>, placeholder: String,
                             onSubmit: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "lock").foregroundStyle(.secondary).frame(width: 22)
            RevealablePasswordField(text: text, secure: !reveal, focused: focused,
                                    placeholder: placeholder, contentType: .newPassword,
                                    onSubmit: onSubmit)
            Button { reveal.toggle() } label: {
                Image(systemName: reveal ? "eye.slash" : "eye")
                    .font(.system(size: 16)).foregroundStyle(.secondary)
                    .frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(reveal ? "Hide password" : "Show password")
        }
        .authField(focused: focused.wrappedValue)
    }

    /// Step 1: ask the server whether the code is right, without spending it.
    private func check() async {
        guard code.count == 6, !working else { return }
        guard NetworkState.shared.isOnline else {
            error = "No internet connection. Check your connection and try again."
            return
        }
        working = true; error = nil
        defer { working = false }
        do {
            _ = try await AccountCall.run("checkPasswordResetCode", ["code": code])
            codeFocused = false
            step = .password
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { newFocused = true }
        } catch {
            // Cleared, so the next try does not start with six wrong digits to delete.
            self.error = error.localizedDescription
            code = ""
        }
    }

    private func resend() async {
        working = true; error = nil
        defer { working = false }
        do {
            _ = try await AccountCall.run("startPasswordReset")
            resendIn = 30
            code = ""
        } catch {
            self.error = error.localizedDescription
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
            // Bug hunt 2026-09-25: `confirmPasswordReset` also deletes EVERY one-tap device key, this
            // phone's included, but the Keychain still held the dead one, so `ensureIssued` (which
            // only issues when there is no key) never replaced it and this phone's saved-account
            // card quietly lost one-tap. Drop it and ask for a fresh one now.
            if let uid = Auth.auth().currentUser?.uid {
                DeviceSessionKeys.forget(uid)
                await DeviceSessionKeys.ensureIssued()
            }
            done = true
            SavePasswordOffer.offer(password: password)
        } catch {
            let words = error.localizedDescription
            // owner 2026-10-26: the code ran out while the password was being chosen, and the page
            // only said "ask for a new one" with no way to. Back to the code boxes with a new code
            // already sent; the password typed stays for when the new code is in.
            if words.contains("Ask for a new one") {
                step = .code
                await resend()
                if self.error == nil { self.error = "That code expired. We sent you a new one." }
                codeFocused = true
                return
            }
            self.error = words
        }
    }
}

/// ⛔ "SAVE PASSWORD?" AFTER A PASSWORD IS SET — owner, 2026-09-25, with the reference app's
/// screenshot: Apple's own card (Passwords icon, Not Now / Save) right after creating or changing the
/// password. These pages have no username field, so iOS's automatic offer never fires; this asks for
/// it outright. `SecAddSharedWebCredential` is Apple's call for exactly that: the system shows the
/// card, the user decides, and the app never sees the Passwords app's contents. It works because
/// fariin.com is in the app's `webcredentials` entitlement (the same link passkeys use).
enum SavePasswordOffer {
    static func offer(password: String) {
        // The address the PASSWORD sign-in is on, not `user.email`: on an Apple or Google account
        // that is often the Hide My Email relay, and a saved login under it could never be typed
        // or matched (bug hunt 2026-09-25). Same fallback the password link itself uses.
        let user = Auth.auth().currentUser
        let onPassword = user?.providerData.first(where: { $0.providerID == "password" })?.email
        guard let email = onPassword ?? AuthService.shared.passwordAddress,
              !email.isEmpty, !password.isEmpty else { return }
        SecAddSharedWebCredential("fariin.com" as CFString, email as CFString, password as CFString) { _ in
            // Saved, declined or unavailable: nothing to do either way.
        }
    }
}

/// Applies `.focused` to exactly one field. A Bool `@FocusState` has one true state, so the
/// modifier has to be attached conditionally rather than to every row.
/// The blue bar button for "Create" (iOS 26 draws a prominent bar item as a tinted glass capsule).
private struct CreateProminent: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.buttonStyle(.borderedProminent).tint(.blue) } else { content }
    }
}

private struct FocusIf: ViewModifier {
    let active: Bool
    @FocusState.Binding var flag: Bool

    func body(content: Content) -> some View {
        if active { content.focused($flag) } else { content }
    }
}

/// The rules a new password must meet (owner, 2026-09-25): 8+ characters, a letter, a number, and
/// the two entries matching, and (owner 2026-10-26) not easy to guess. `allMet` is the ONLY gate on
/// the button; the meter grades above that line.
struct PasswordRules {
    let password: String
    let confirm: String

    var longEnough: Bool { password.count >= 8 }
    var hasLetter: Bool { password.contains { $0.isLetter } }
    var hasNumber: Bool { password.contains { $0.isNumber } }
    var matches: Bool { !confirm.isEmpty && confirm == password }
    /// owner 2026-10-26 ("12345567a is poor, ours says Fair"): an easy guess is refused too, the way
    /// big apps refuse "too easy to guess" rather than only counting rules.
    var allMet: Bool { longEnough && hasLetter && hasNumber && !guessable && matches }

    /// Easy to guess: one of the passwords people use most, or built mostly from runs and repeats
    /// (1234, abcd, 5555, 4321), or only one to three different characters. Checked on this phone.
    var guessable: Bool {
        let p = password.lowercased()
        guard !p.isEmpty else { return false }
        if Set(p).count <= 3 { return true }
        // The common words with their usual dressing (digits and symbols around them) taken off.
        let core = p.trimmingCharacters(in: CharacterSet.letters.inverted)
        if Self.common.contains(core) || Self.common.contains(p) { return true }
        if Self.keyboardRuns.contains(where: { p.contains($0) }) && core.count <= 8 { return true }
        // Runs and repeats: neighbours of the same kind one step apart or equal (1-2, b-c, 7-7).
        let chars = Array(p.unicodeScalars)
        guard chars.count > 1 else { return false }
        var predictable = 0
        for i in 1..<chars.count {
            let a = chars[i - 1], b = chars[i]
            let sameKind = (CharacterSet.decimalDigits.contains(a) && CharacterSet.decimalDigits.contains(b))
                || (CharacterSet.letters.contains(a) && CharacterSet.letters.contains(b))
            if sameKind && abs(Int(b.value) - Int(a.value)) <= 1 { predictable += 1 }
        }
        return Double(predictable) >= Double(chars.count - 1) * 0.6
    }

    private static let common: Set<String> = [
        "password", "passw", "passwd", "passwor", "qwerty", "qwertyuiop", "asdfgh", "asdfghjkl", "letmein",
        "welcome", "admin", "iloveyou", "monkey", "dragon", "football", "baseball", "soccer", "sunshine",
        "princess", "master", "shadow", "superman", "batman", "trustno", "hello", "freedom", "whatever",
        "secret", "login", "abc", "abcd", "fariin", "somalia", "somali", "allah", "bismillah", "love",
    ]
    private static let keyboardRuns = ["qwert", "asdfg", "zxcvb", "qazwsx", "1qaz", "zaq1"]

    /// 0 Too short, 1 Weak (8+ but no letter or no number, or easy to guess), 2 Fair (the minimum),
    /// 3 Good (12+), 4 Strong (12+ with a symbol or mixed case).
    var level: Int {
        guard longEnough else { return 0 }
        guard hasLetter, hasNumber, !guessable else { return 1 }
        guard password.count >= 12 else { return 2 }
        let mixed = password.contains { $0.isLowercase } && password.contains { $0.isUppercase }
        let symbol = password.contains { !$0.isLetter && !$0.isNumber }
        return mixed || symbol ? 4 : 3
    }
}

/// ⛔ ONE LINE NOW, NOT FOUR (owner 2026-10-24, reverses the 2026-09-25 checklist: "that takes the
/// space of Create account, make it one line"). Four segments that fill and colour with the level,
/// the word on the right, and on the left the ONE thing that matters next: what is missing, then
/// whether the two entries match. He picked this from three drawn options (artifact "Password
/// Strength Options", option A). The name stays so the three password screens need no change.
struct PasswordChecklist: View {
    let rules: PasswordRules

    private var empty: Bool { rules.password.isEmpty }

    private var word: String {
        if empty { return "" }
        return ["Too short", "Weak", "Fair", "Good", "Strong"][rules.level]
    }

    private var color: Color {
        switch rules.level {
        case 1: return Color(hex: 0xE5484D)
        case 2: return Color(hex: 0xF5A524)
        case 3: return Color(hex: 0x0A84FF)
        case 4: return Color(hex: 0x30A46C)
        default: return .secondary
        }
    }

    /// Left side: what is missing first, then the match, else nothing. `bad` (owner 2026-10-26:
    /// "don't match should be red"): a problem that stops Save is red; a step still to type is grey.
    private var hint: (text: String, ok: Bool, bad: Bool)? {
        if empty { return nil }
        if !rules.longEnough {
            let n = 8 - rules.password.count
            return ("\(n) more \(n == 1 ? "character" : "characters")", false, false)
        }
        if !rules.hasNumber { return ("Add a number", false, false) }
        if !rules.hasLetter { return ("Add a letter", false, false) }
        if rules.guessable { return ("Too easy to guess", false, true) }
        if rules.confirm.isEmpty { return nil }
        return rules.matches ? ("Passwords match", true, false) : ("Passwords don't match", false, true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule()
                        .fill(!empty && rules.level > 0 && i < rules.level ? color : Color(.tertiarySystemFill))
                        .frame(height: 4)
                }
            }
            HStack(spacing: 8) {
                if let hint {
                    HStack(spacing: 5) {
                        if hint.ok {
                            Image(systemName: "checkmark").font(.footnote.weight(.semibold))
                                .foregroundStyle(Color(hex: 0x30A46C))
                        }
                        Text(hint.text).foregroundStyle(hint.ok ? Color.primary
                                                        : hint.bad ? Color(hex: 0xE5484D) : Color.secondary)
                    }
                }
                Spacer(minLength: 0)
                Text(word).fontWeight(.semibold).foregroundStyle(color)
            }
            .font(.footnote)
            .frame(minHeight: 18)
        }
        .animation(.easeOut(duration: 0.2), value: rules.level)
        .animation(.easeOut(duration: 0.15), value: rules.matches)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(empty ? "Password strength" : "Password strength, \(word)")
        .accessibilityValue(hint?.text ?? "")
    }
}
