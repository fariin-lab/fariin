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
    @Environment(\.colorScheme) private var scheme
    private var profile = ProfileStore.shared

    private enum Step { case confirm, verify, working }
    @State private var step: Step = .confirm
    @State private var error: String?
    @State private var password = ""

    private var handle: String { profile.me?.handle ?? "" }

    var body: some View {
        Group {
            // The verify step is ONE focused security gate, so it gets a centred page of its own. As a
            // Form section it stacked at the top and left two thirds of the screen empty under a bare
            // white bar, which is what looked unfinished.
            if step == .verify {
                verifyPage
            } else {
                deleteForm
            }
        }
        .navigationTitle("Delete Account")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(step == .working)
        .disabled(step == .working)
    }

    private var deleteForm: some View {
        Form {
            confirmSection
            if let error {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }
        }
    }

    // MARK: - Step 2 as a page

    private var verifyPage: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 40)
                VStack(spacing: 12) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.red)
                    Text("Verify it's you").font(.title2.weight(.bold))
                    Text("Confirm your account to finish deleting it. Nothing has been deleted yet.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 32)

                VStack(spacing: 12) { verifyControls }
                    .padding(.horizontal, 20)
                    .padding(.top, 32)

                Text("Your account is deleted as soon as you're verified.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32).padding(.top, 14)

                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32).padding(.top, 12)
                }
                Spacer(minLength: 40)
            }
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
    }

    // MARK: - Step 1: what this does, and to whom

    @ViewBuilder private var confirmSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                Text("Permanently Delete Account")
                    .font(.title2.weight(.bold))
                Text("Your account is hidden straight away and deleted for good after \(ProfileStore.gracePeriodDays) days. Sign in before then to bring it back exactly as it was.")
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

    /// Just the sign-in doors this account actually has. The heading and footer live in verifyPage.
    @ViewBuilder private var verifyControls: some View {
        let methods = AuthService.shared.reauthMethods
        Group {
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
                .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
                // Same rebuild the Log In door needs, and for the same reason: Apple's button
                // cannot be restyled after it exists. See AuthFlowViews.swift for the full note.
                // Changed together on purpose — a report about one of these has already left the
                // other behind once on this project.
                .id(scheme)
                .frame(height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            if methods.contains(.email) {
                SecureField("Your password", text: $password)
                    .textContentType(.password)
                    .padding(.horizontal, 14).frame(height: 50)
                    .background(Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Button {
                    run { try await AuthService.shared.reauthEmail(password: password) }
                } label: {
                    Text("Verify and Delete").fontWeight(.semibold)
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .foregroundStyle(.white)
                        .background(password.isEmpty ? Color.red.opacity(0.4) : Color.red,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(password.isEmpty)
            }

            // No linked provider (a legacy anonymous session): nothing to verify against, so
            // deletion can proceed directly — Firebase doesn't demand a recent login for those.
            if methods.isEmpty {
                Button { deleteNow() } label: {
                    Text("Delete Account").fontWeight(.semibold)
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .foregroundStyle(.white)
                        .background(Color.red, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Actions

    private func start() {
        error = nil
        // ALWAYS ask, however fresh the session is. `needsRecentLogin` answers a different
        // question: whether Firebase will accept the call with the token we are holding. It
        // says nothing about whether the person holding the phone is the person who owns the
        // account, and this is the one screen where those two must not be confused. An
        // unlocked phone left on a table was one tap from deleting the account behind it.
        //
        // For a Google account this opens Google's own account picker, so choosing the wrong
        // one fails instead of deleting. Same for Apple. Email asks for the password.
        if !AuthService.shared.reauthMethods.isEmpty {
            step = .verify
        } else {
            // No door to knock on: an account with no sign-in provider cannot be re-verified,
            // and refusing here would trap the user in an account they cannot leave.
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
                await performScheduling()
            } catch {
                self.error = error.localizedDescription
                step = .verify
            }
        }
    }

    private func deleteNow() {
        step = .working
        error = nil
        Task { await performScheduling() }
    }

    /// The normal path now SCHEDULES the deletion instead of performing it, so a change of mind within
    /// the grace period costs nothing. The account is hidden immediately and signed out here; the real
    /// destruction is done by the server once the date passes (or by "Delete It Now" on the restore
    /// screen). Nothing on the device is wiped, because the encryption key is exactly what makes a
    /// restore able to read old messages.
    private func performScheduling() async {
        do {
            await AuthService.shared.reportAccountDeletion()
            try await profile.scheduleDeletion()
            // Same order Settings uses: stop this phone's pushes while we still have auth, then sign out.
            await Push.unregister()
            await DeviceRegistry.shared.removeThisDevice()   // and drop our row in Settings › Devices
            try? Auth.auth().signOut()
            // WIPE THE DEVICE COPY TOO (audit). The comment above justified skipping this to protect
            // the encryption key — but SessionWipe never touches the Keychain key (wipeIdentity only
            // clears the in-memory copy), which is exactly why plain Sign Out can call it. What was
            // actually left behind was everything else: decrypted messages, unsent drafts, nicknames,
            // cached voice notes and videos, all readable by whoever signs up next on this phone.
            SessionWipe.wipeAccountData()
            dismiss()
            onDeleted()
        } catch {
            self.error = error.localizedDescription
            step = .confirm
        }
    }

    private func performDelete() async {
        do {
            // Send the confirmation BEFORE deleting: afterwards the auth record is gone and there's
            // no address left to write to. Worded as "we received your request", so it's accurate
            // even in the rare case the delete below fails. Fire-and-forget — email must never
            // block or fail the deletion itself.
            await AuthService.shared.reportAccountDeletion()
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
