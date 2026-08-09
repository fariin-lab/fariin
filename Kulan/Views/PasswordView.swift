import SwiftUI
import LocalAuthentication
import FirebaseAuth

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
    @State private var busy = false
    @State private var error: String?
    @State private var done = false
    @FocusState private var focused: Bool

    private var longEnough: Bool { password.count >= 6 }
    private var matches: Bool { !confirm.isEmpty && confirm == password }
    private var canSave: Bool { longEnough && matches && !busy }

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
        .navigationTitle(isFirstPassword ? "Set Password" : "Change Password")
        .navigationBarTitleDisplayMode(.inline)
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

    @ViewBuilder private var form: some View {
        Form {
            Section {
                SecureField("At least 6 characters", text: $password)
                    .textContentType(.newPassword)
                    .focused($focused)
                SecureField("Type it again", text: $confirm)
                    .textContentType(.newPassword)
            } header: {
                Text(isFirstPassword ? "New password" : "Choose a new password")
            } footer: {
                // NAMES THE ADDRESS. For a Google or Apple account this is the moment a second way
                // in appears, and the address it works with is not something they chose or would
                // necessarily remember. Telling them here means the security email is a reminder
                // rather than a surprise.
                Text(isFirstPassword
                     ? "You'll sign in with \(address) and this password. The way you sign in now keeps working too."
                     : "Signing in with \(address) will use the new password. The old one stops working.")
            }

            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }

            Section {
                Button(isFirstPassword ? "Set Password" : "Change Password") { save() }
                    .disabled(!canSave)
                    .fontWeight(.semibold)
            } footer: {
                if !password.isEmpty && !longEnough {
                    Text("At least 6 characters.")
                } else if !confirm.isEmpty && !matches {
                    Text("Those two do not match.")
                }
            }
        }
        .onAppear { focused = true }
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
                        Button("Continue with Apple") {
                            // Apple's own button is required for a real Apple re-auth, and it does
                            // not belong inside a Form row. Sending them the long way round would
                            // be worse than saying so plainly.
                            error = "Open Sign-in Methods to verify with Apple, then come back."
                        }
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
