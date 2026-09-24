import SwiftUI
import FirebaseAuth

// ⛔ TWO-STEP VERIFICATION — item 8 of his 2026-09-16 list, and his order was "go read how the
// reference app does it, then make it like that". The server is `functions-account`; the mechanism,
// the three claim states and why a password screen alone would be a curtain rather than a lock are
// all written there rather than repeated here.
//
// ⚠️ THE BODY TEXT IS NOT THEIRS WORD FOR WORD, AND THAT IS DELIBERATE. Their intro says the
// password is required "in addition to the code you get via SMS". This app has no SMS step — it
// signs in with Apple, Google or a password — so repeating their sentence would describe a flow that
// does not exist here. The shape of the screen is theirs; the sentence is ours and is true.

/// The page behind the Account row: an explanation and one action until it is on, a list once it is.
struct TwoStepVerificationView: View {
    @State private var enabled = false
    @State private var hint = ""
    @State private var maskedRecovery = ""
    @State private var loading = true
    @State private var error: String?
    @State private var setting = false
    @State private var confirmingOff = false
    /// True once the server has answered at least once; until then `enabled` means nothing.
    @State private var loadedOnce = false

    var body: some View {
        Group {
            if loading {
                ProgressView().controlSize(.large)
            } else if !loadedOnce {
                // THE STATUS NEVER ARRIVED (audit 2026-09-24). A failed first load fell through to
                // the intro, so an account WITH two-step on was told it was off and offered "Set
                // Additional Password". Say it failed and let them ask again instead.
                ContentUnavailableView {
                    Label("Two-step verification", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error ?? "Something went wrong. Try again.")
                } actions: {
                    Button("Try Again") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                }
            } else if enabled {
                onState
            } else {
                introState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Two-step verification")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task { await load() }
        .sheet(isPresented: $setting, onDismiss: { Task { await load() } }) {
            NavigationStack { SetAdditionalPasswordView(isChange: enabled) }
        }
        .sheet(isPresented: $confirmingOff, onDismiss: { Task { await load() } }) {
            NavigationStack { DisableAdditionalPasswordView() }
        }
    }

    /// His screenshot of their intro: artwork, title, one paragraph, and a full-width green action
    /// pinned at the bottom.
    private var introState: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Text("🔐").font(.system(size: 96))
            Text("Additional Password")
                .font(.system(size: 30, weight: .bold))
                .padding(.top, 18)
            Text("You can set a password that will be required when you sign in to Fariin on a new device, in addition to your usual sign-in.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
                .padding(.horizontal, 32)
            if let error {
                Text(error)
                    .font(.footnote).foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.top, 12).padding(.horizontal, 32)
            }
            Spacer(minLength: 0)
        }
        // Edge-attached, the distinction he has now sent more than once: content sits inside the
        // safe area, an action rests on the edge.
        .safeAreaInset(edge: .bottom) {
            Button { setting = true } label: {
                Text("Set Additional Password")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 54)
                    .background(Color.green, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
    }

    /// Once it is on there is state to report, so the poster becomes a list.
    private var onState: some View {
        List {
            Section {
                Label("Two-step verification is on", systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.green)
            } footer: {
                Text("An additional password is required when you sign in on a new device.")
            }

            Section {
                if !hint.isEmpty {
                    HStack { Text("Hint"); Spacer(); Text(hint).foregroundStyle(.secondary) }
                }
                if !maskedRecovery.isEmpty {
                    HStack { Text("Recovery email"); Spacer(); Text(maskedRecovery).foregroundStyle(.secondary) }
                }
            } footer: {
                // ⚠️ SAID WHILE IT CAN STILL BE ACTED ON. Without a recovery address a forgotten
                // additional password cannot be turned off by anyone — `startTwoStepRecovery`
                // refuses — so this warning belongs here, not on the screen you reach after
                // forgetting it.
                Text(maskedRecovery.isEmpty
                     ? "No recovery email is set. If you forget this password there is no way to turn it off."
                     : "If you forget this password, we can turn it off using your recovery email.")
            }

            Section {
                Button("Change Additional Password") { setting = true }
                Button("Turn Off Two-step Verification", role: .destructive) { confirmingOff = true }
            }

            if let error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let d = try await AccountCall.run("twoStepStatus")
            enabled = d["enabled"] as? Bool ?? false
            hint = d["hint"] as? String ?? ""
            maskedRecovery = d["recoveryEmail"] as? String ?? ""
            loadedOnce = true
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Setting it, or changing it.
///
/// ⚠️ THE OLD ONE IS DEMANDED ON A CHANGE BECAUSE THE SERVER DEMANDS IT. `setAdditionalPassword`
/// refuses without `current` once a record exists, so that somebody holding an unlocked phone cannot
/// quietly replace the password that is meant to stop them.
struct SetAdditionalPasswordView: View {
    let isChange: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var hint = ""
    @State private var recovery = ""
    @State private var busy = false
    @State private var error: String?

    private var canSave: Bool {
        !busy && password.count >= 6 && password == confirm && (!isChange || !current.isEmpty)
    }

    var body: some View {
        Form {
            if isChange {
                Section {
                    SecureField("Current additional password", text: $current)
                } header: { Text("Current").textCase(nil) }
            }
            Section {
                SecureField("New password", text: $password)
                SecureField("Confirm", text: $confirm)
            } header: {
                Text(isChange ? "New" : "Additional password").textCase(nil)
            } footer: {
                Text("At least 6 characters. You will be asked for this when you sign in on a new device.")
            }
            Section {
                TextField("Hint (optional)", text: $hint)
            } footer: {
                // The server refuses a hint equal to the password outright. Saying so here saves a
                // round trip and explains a refusal that would otherwise look arbitrary.
                Text("Anyone holding your signed-in phone can read the hint, so it must not be the password itself.")
            }
            Section {
                TextField("Recovery email (optional)", text: $recovery)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                Text("The only way back if you forget this password. Without one, it cannot be turned off.")
            }
            if let error {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }
        }
        .navigationTitle(isChange ? "Change Password" : "Additional Password")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { Task { await save() } }.disabled(!canSave).fontWeight(.semibold)
            }
        }
    }

    private func save() async {
        busy = true; error = nil
        defer { busy = false }
        var payload: [String: Any] = ["password": password, "hint": hint, "recoveryEmail": recovery]
        if isChange { payload["current"] = current }
        do {
            try await AccountCall.run("setAdditionalPassword", payload)
            // Turning it on revokes every refresh token, this device included. Its new token has to
            // be picked up before anything reads the account's state back, or the app believes it is
            // still outside its own door.
            _ = try? await Auth.auth().currentUser?.getIDTokenResult(forcingRefresh: true)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Turning it off, and the way back when the password is gone.
///
/// The password is required to turn it off, because a switch that disables a lock without asking for
/// the key is not a lock.
struct DisableAdditionalPasswordView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var recoveryCode = ""
    @State private var recoverySent = false

    var body: some View {
        Form {
            Section {
                SecureField("Additional password", text: $password)
            } footer: {
                Text("Enter your additional password to turn two-step verification off.")
            }
            Section {
                Button("I forgot this password") { Task { await startRecovery() } }
                    .disabled(busy)
            }
            if recoverySent {
                Section {
                    TextField("6-digit code", text: $recoveryCode)
                        .keyboardType(.numberPad)
                        .onChange(of: recoveryCode) { _, new in
                            let digits = String(new.filter(\.isNumber).prefix(6))
                            if digits != new { recoveryCode = digits }
                        }
                    Button("Turn Off With Code") { Task { await finishRecovery() } }
                        .disabled(recoveryCode.count != 6 || busy)
                } footer: {
                    Text("We sent a code to your recovery email.")
                }
            }
            if let error {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }
        }
        .navigationTitle("Turn Off")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Turn Off") { Task { await turnOff() } }
                    .disabled(password.isEmpty || busy)
                    .foregroundStyle(.red)
            }
        }
    }

    private func turnOff() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            try await AccountCall.run("disableAdditionalPassword", ["password": password])
            _ = try? await Auth.auth().currentUser?.getIDTokenResult(forcingRefresh: true)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func startRecovery() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            try await AccountCall.run("startTwoStepRecovery")
            recoverySent = true
        } catch { self.error = error.localizedDescription }
    }

    private func finishRecovery() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            try await AccountCall.run("confirmTwoStepRecovery", ["code": recoveryCode])
            _ = try? await Auth.auth().currentUser?.getIDTokenResult(forcingRefresh: true)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
