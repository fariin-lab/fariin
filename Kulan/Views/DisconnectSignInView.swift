import SwiftUI
import AuthenticationServices

// REMOVING A SIGN-IN METHOD, and proving it is you first.
//
// The hole this closes: connecting a login was a one-way door. Somebody holding your unlocked phone
// could attach THEIR Google account to YOUR Fariin under Settings, Account, Sign-in Methods, and
// then sign in as you forever. Nothing in the app could undo it. A password you can change; that you
// could not.
//
// The reason this screen exists at all, rather than a Disconnect button that just works: adding
// removal WITHOUT a verification step would have opened a worse hole than the one it closes. The
// same person holding your phone connects their Google, removes your Apple, and now the account is
// theirs and you are the one locked out. So removal always asks, exactly like deleting the account
// does, and for exactly the reason written at DeleteAccountView.start(): whether Firebase will
// accept our token is a different question from whether the person holding the phone owns the
// account, and this is another screen where confusing the two is the whole risk.
//
// ⚠️ TWIN. The provider buttons below are deliberately near-identical to DeleteAccountView's
// `verifyControls`, including Apple's `.id(scheme)` rebuild (its button takes its colour at birth
// and cannot be restyled). The two are not shared because the delete flow is one of the most
// sensitive screens in the app and folding them together to save forty lines is not a trade worth
// making today. If you change how a door is drawn here, change it there too. This project has
// already had one report where a fix landed on one of a pair and not the other.
struct DisconnectSignInView: View {
    let method: AuthService.SignInMethod
    var onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var password = ""
    @State private var working = false
    @State private var error: String?

    /// What is left afterwards. Named in the copy on purpose: "you will still be able to sign in
    /// with Google" is the sentence that makes this safe to tap.
    private var remaining: [AuthService.SignInMethod] {
        AuthService.shared.connectedMethods.filter { $0 != method }
    }

    private var remainingLabel: String {
        let names = remaining.map(\.title)
        switch names.count {
        case 0:  return "nothing"
        case 1:  return names[0]
        case 2:  return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Remove \(method.title) from this account?")
                        .font(.title3.weight(.semibold))
                    Text("You will still be able to sign in with \(remainingLabel). Nothing in your account changes: your chats, your username and your photos all stay exactly as they are.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let id = AuthService.shared.connectedIdentifier(method), !id.isEmpty {
                        Text(id).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                verifyControls
            } header: {
                Text("Verify it's you")
            } footer: {
                Text("We ask every time, even if you just signed in. Removing a login is how somebody who picked up your phone would lock you out of your own account.")
            }

            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Remove \(method.title)")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(working)
        .overlay { if working { ProgressView() } }
    }

    /// Only the doors this account actually has. The one being removed is still a valid way to
    /// prove ownership, which is deliberate: it is the person's own login until the moment it is not.
    @ViewBuilder private var verifyControls: some View {
        let methods = AuthService.shared.reauthMethods
        if methods.contains(.apple) {
            SignInWithAppleButton(.continue) { request in
                AuthService.shared.prepareAppleRequest(request)
            } onCompletion: { result in
                switch result {
                case .success(let auth):
                    run { try await AuthService.shared.reauthApple(authorization: auth) }
                case .failure(let e):
                    if (e as NSError).code != ASAuthorizationError.canceled.rawValue {
                        error = "Apple couldn't verify you. Please try again."
                    }
                }
            }
            .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
            .id(scheme)   // see the TWIN note at the top of this file
            .frame(height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        }

        if methods.contains(.google) {
            Button {
                run { try await AuthService.shared.reauthGoogle() }
            } label: {
                HStack(spacing: 10) {
                    GoogleGIcon(size: 20)
                    Text("Continue with Google")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color(.systemBackground))
                }
                .frame(maxWidth: .infinity).frame(height: 50)
                .background(Color.primary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        }

        if methods.contains(.email) {
            SecureField("Your password", text: $password)
                .textContentType(.password)
            Button {
                run { try await AuthService.shared.reauthEmail(password: password) }
            } label: {
                Text("Verify and Remove").fontWeight(.semibold)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .foregroundStyle(.white)
                    .background(password.isEmpty ? Color.red.opacity(0.4) : Color.red,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(password.isEmpty)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        }
    }

    /// Verify, and only then unlink. A verification failure stops BEFORE anything is removed.
    private func run(_ verify: @escaping () async throws -> Void) {
        working = true
        error = nil
        Task {
            do {
                try await verify()
                try await AuthService.shared.disconnect(method)
                await MainActor.run { working = false; onDone(); dismiss() }
            } catch {
                await MainActor.run {
                    working = false
                    // A cancelled provider sheet is not a failure and must not be dressed as one.
                    if AuthService.isCancellation(error) { return }
                    self.error = error.localizedDescription
                }
            }
        }
    }
}
