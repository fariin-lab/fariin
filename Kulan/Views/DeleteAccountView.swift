import SwiftUI
import FirebaseAuth
import AuthenticationServices

// Permanent account deletion, as a real PAGE rather than a one-tap alert: say plainly what is
// destroyed, show WHICH account is about to go, then re-verify the person before doing it.
//
// The re-verification step is not ceremony — Firebase refuses `user.delete()` unless the sign-in
// is recent, and the old flow discovered that only AFTER it had already deleted the user's
// stories, photo and profile document. That left accounts half-deleted with no way to finish or
// recover. Verifying first means the delete either happens completely or not at all.
struct DeleteAccountView: View {
    var onDeleted: () -> Void
    // Explicit init: a private stored property below makes the implicit memberwise
    // initializer private, so SettingsView couldn't construct this view.
    init(onDeleted: @escaping () -> Void) { self.onDeleted = onDeleted }

    @Environment(\.dismiss) private var dismiss
    private var profile = ProfileStore.shared

    private enum Step { case confirm, verify, working }
    @State private var step: Step = .confirm
    @State private var error: String?
    @State private var password = ""

    private var handle: String { profile.me?.handle ?? "" }

    var body: some View {
        Form {
            switch step {
            case .confirm, .working: confirmSection
            case .verify:            verifySection
            }

            if let error {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }
        }
        .navigationTitle("Delete Account")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(step == .working)
        .disabled(step == .working)
    }

    // MARK: - Step 1: what this does, and to whom

    @ViewBuilder private var confirmSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                Text("Permanently Delete Account")
                    .font(.title2.weight(.bold))
                Text("This erases your profile, your photo and your stories, and releases your username. It cannot be undone.")
                    .font(.subheadline).foregroundStyle(.secondary)
                // Honest about what deleting your account does NOT reach: messages already
                // delivered live on other people's phones, and we can't reach into those.
                Text("Messages you already sent stay on the phones of the people you sent them to.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }

        if !handle.isEmpty {
            Section("Account to delete") {
                HStack {
                    AvatarView(name: profile.me?.name ?? "", photoUrl: profile.me?.photoUrl, size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(profile.me?.name ?? "You").foregroundStyle(.primary)
                        Text("@\(handle)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }

        Section {
            Button(role: .destructive) { start() } label: {
                HStack {
                    Spacer()
                    if step == .working {
                        ProgressView()
                    } else {
                        Text("Delete Account").fontWeight(.semibold)
                    }
                    Spacer()
                }
            }
            .disabled(step == .working)
        }
    }

    // MARK: - Step 2: prove it's you (with the door this account actually uses)

    @ViewBuilder private var verifySection: some View {
        // A lock badge + centred copy, so this reads as a deliberate security step rather than a
        // blank card with a stray button on it.
        Section {
            VStack(spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.red)
                Text("Verify it's you").font(.title2.weight(.bold))
                Text("Confirm your account to finish deleting it. Nothing has been deleted yet.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .listRowBackground(Color.clear)
        }

        let methods = AuthService.shared.reauthMethods
        Section {
            if methods.contains(.apple) {
                SignInWithAppleButton(.continue) { request in
                    AuthService.shared.prepareAppleRequest(request)
                } onCompletion: { result in
                    switch result {
                    case .success(let auth):
                        run { try await AuthService.shared.reauthApple(authorization: auth) }
                    case .failure(let e):
                        // Only a real cancel is silent; anything else must say something.
                        if (e as NSError).code != ASAuthorizationError.canceled.rawValue {
                            error = "Apple couldn't verify you. Please try again."
                        }
                    }
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            if methods.contains(.google) {
                Button {
                    run { try await AuthService.shared.reauthGoogle() }
                } label: {
                    HStack(spacing: 10) {
                        GoogleGIcon(size: 20)
                        Text("Continue with Google")
                            .font(.system(size: 17, weight: .semibold)).foregroundStyle(.black)
                    }
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.black.opacity(0.14), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            if methods.contains(.email) {
                SecureField("Your password", text: $password)
                    .textContentType(.password)
                Button("Verify and Delete") {
                    run { try await AuthService.shared.reauthEmail(password: password) }
                }
                .disabled(password.isEmpty)
                .fontWeight(.semibold)
            }

            // No linked provider (a legacy anonymous session): nothing to verify against, so
            // deletion can proceed directly — Firebase doesn't demand a recent login for those.
            if methods.isEmpty {
                Button(role: .destructive) { deleteNow() } label: {
                    Text("Delete Account").fontWeight(.semibold)
                }
            }
        } footer: {
            Text("Your account is deleted as soon as you're verified.")
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - Actions

    private func start() {
        error = nil
        // Verified recently enough? Then there's nothing to prove — go straight through.
        if AuthService.shared.needsRecentLogin && !AuthService.shared.reauthMethods.isEmpty {
            step = .verify
        } else {
            deleteNow()
        }
    }

    /// Re-verify, then delete. Any verification failure stops BEFORE data is touched.
    private func run(_ work: @escaping () async throws -> Void) {
        step = .working
        error = nil
        Task {
            do {
                try await work()
                await performDelete()
            } catch {
                self.error = error.localizedDescription
                step = .verify
            }
        }
    }

    private func deleteNow() {
        step = .working
        error = nil
        Task { await performDelete() }
    }

    private func performDelete() async {
        do {
            try await profile.deleteAccount()
            SessionWipe.wipeAccountData()   // server data is gone; clear the device copy too
            dismiss()
            onDeleted()
        } catch {
            self.error = error.localizedDescription
            step = .confirm
        }
    }
}
