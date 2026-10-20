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

    // owner 2026-10-18: "a professional account deletion experience". The order, from what the large
    // messengers do, in our own words: what happens (and what does not), a way to take your data
    // first, an optional reason, prove it is you, one last destructive confirm, then a page that
    // says the deletion is scheduled and on which day. `done` is that last page.
    private enum Step { case confirm, verify, working, done }
    @State private var step: Step = .confirm
    @State private var error: String?
    @State private var password = ""
    /// The final "are you sure" after the sign-in check, before anything is written.
    @State private var confirmFinal = false
    @State private var reason: LeaveReason = .none
    @State private var exportFile: ExportFile?
    @State private var exporting = false
    @State private var scheduledFor: Date?

    /// The optional answer. Raw values are the slugs `scheduleAccountDeletion` accepts.
    private enum LeaveReason: String, CaseIterable, Identifiable {
        case none = "", notUsing = "not-using", privacy, otherApp = "other-app",
             unwanted = "unwanted-messages", problems, other
        var id: String { rawValue }
        var label: String {
            switch self {
            case .none: return "Prefer not to say"
            case .notUsing: return "I don't use it any more"
            case .privacy: return "Privacy worries"
            case .otherApp: return "I use another app"
            case .unwanted: return "Unwanted messages"
            case .problems: return "Something isn't working"
            case .other: return "Something else"
            }
        }
    }

    /// The day the server will purge: its own date once scheduled, else the same arithmetic.
    private var dueText: String {
        let d = scheduledFor ?? Calendar.current.date(byAdding: .day, value: ProfileStore.gracePeriodDays, to: Date()) ?? Date()
        return d.formatted(.dateTime.day().month(.wide).year())
    }
    /// 2026-09-24 fix-all #144: true from the moment a re-auth is confirmed until it succeeds or
    /// fails. The page stays on the verify screen with a spinner under the doors, instead of
    /// `.working` swapping back to the step-one form while the request runs.
    @State private var verifying = false

    private var handle: String { profile.me?.handle ?? "" }

    var body: some View {
        Group {
            // The verify step is ONE focused security gate, so it gets a centred page of its own. As a
            // Form section it stacked at the top and left two thirds of the screen empty under a bare
            // white bar, which is what looked unfinished.
            if step == .done {
                donePage
            } else if step == .verify || verifying {   // 2026-09-24 fix-all #144
                verifyPage
            } else {
                deleteForm
            }
        }
        .navigationTitle("Delete Account")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        // owner 2026-10-18: once scheduled, the only way out is Done, which signs out.
        .navigationBarBackButtonHidden(step == .done)
        .interactiveDismissDisabled(step == .working || step == .done)
        .disabled(step == .working)
        .alert(handle.isEmpty ? "Delete your account?" : "Delete @\(handle)?", isPresented: $confirmFinal) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Account", role: .destructive) { scheduleNow() }
        } message: {
            Text("You will be logged out and your account hidden. It is deleted for good on \(dueText) unless you log in before then.")
        }
        .sheet(item: $exportFile, onDismiss: { DataExport.cleanup() }) { f in ActivityView(items: [f.url]) }
    }

    // MARK: - Last page: scheduled

    private var donePage: some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.secondary)
                    .padding(.top, 48)
                Text("Deletion Scheduled").font(.title2.weight(.bold))
                Text(handle.isEmpty
                     ? "Your account will be deleted on \(dueText)."
                     : "@\(handle) will be deleted on \(dueText).")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Until then nobody can find you or see your profile. Changed your mind? Sign in before that day and choose Cancel Deletion.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button { Task { await finishSignOut() } } label: {
                    Text("Done").fontWeight(.semibold)
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .foregroundStyle(Color(.systemBackground))
                        .background(Color.primary, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 20)
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
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

    /// ⛔ CALM, NOT ALARMING — owner, 2026-09-25: "redesign, good design, clean and minimalist, Apple
    /// style". The red shield and the maroon disabled button read as an error screen. Apple's own
    /// confirm steps lead with WHO (the account's face and name), one plain sentence, the sign-in
    /// door, and put the consequence in small print. Red is kept for the one button that deletes,
    /// and only once it can be pressed.
    private var verifyPage: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 10) {
                    AvatarView(name: profile.me?.name ?? "", photoUrl: profile.me?.photoUrl, size: 76)
                        .padding(.bottom, 6)
                    Text("Confirm It's You").font(.title2.weight(.bold))
                    Text(handle.isEmpty
                         ? "Sign in again to delete your account. Nothing has been deleted yet."
                         : "Sign in again to delete @\(handle). Nothing has been deleted yet.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.top, 28)

                VStack(spacing: 12) { verifyControls }
                    .opacity(verifying ? 0.5 : 1)   // 2026-09-24 fix-all #144

                if verifying { BusyArc.small(.secondary) }   // 2026-09-24 fix-all #144

                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                // Must agree with step one and with `ProfileStore`: hidden now, gone after the grace
                // period, restorable by signing in before then.
                Text("Your account is hidden as soon as you confirm and deleted for good after \(ProfileStore.gracePeriodDays) days. Sign in before then to restore it.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
    }

    // MARK: - Step 1: what this does, and to whom

    @ViewBuilder private var confirmSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Delete Your Account")
                    .font(.title2.weight(.bold))
                Text("Read what happens before you go on. Nothing is deleted on this page.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }

        // owner 2026-10-18: what happens, step by step, and what it does NOT reach. Must agree with
        // kpurgeOne (functions-loginalert) and with the restore screen.
        Section("What happens") {
            factRow("eye.slash", "Hidden right away",
                    "You are logged out. Nobody can find you, see your profile or your stories.")
            factRow("calendar", "Deleted for good on \(dueText)",
                    "Your profile, photo, username, stories and group memberships are removed. Your username becomes free for others after a while.")
            factRow("arrow.uturn.backward", "You can change your mind",
                    "Sign in before that day and choose Cancel Deletion. Everything comes back as it was.")
            // Honest about what deleting your account does NOT reach: messages already
            // delivered live on other people's phones, and we can't reach into those.
            factRow("bubble.left.and.bubble.right", "What stays",
                    "Messages you already sent stay with the people who got them. Your name there becomes Deleted Account.")
        }

        // Take a copy first: the account report from Settings, offered where it matters most.
        Section {
            Button { Task { await exportData() } } label: {
                HStack {
                    Label("Download My Data First", systemImage: "arrow.down.doc")
                    Spacer()
                    if exporting { BusyArc.small(.secondary) }
                }
            }
            .disabled(exporting)
        } footer: {
            Text("A file with your account details, before they are gone.")
        }

        Section {
            Picker("Reason", selection: $reason) {
                ForEach(LeaveReason.allCases) { r in Text(r.label).tag(r) }
            }
        } header: {
            Text("Why are you leaving? (optional)")
        } footer: {
            Text("Only the reason is kept, not who gave it.")
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
                        BusyArc.small(.red)
                    } else {
                        Text("Continue").fontWeight(.semibold)   // owner 2026-10-18: not the last step
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
                .frame(height: 52)
                .clipShape(Capsule())
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
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(Color.primary, in: Capsule())
                }
                .buttonStyle(.plain)
            }

            if methods.contains(.email) {
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .submitLabel(.done)
                    .padding(.horizontal, 18).frame(height: 52)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                Button {
                    run { try await AuthService.shared.reauthEmail(password: password) }
                } label: {
                    // Grey until there is a password, the way a system button is disabled; red only
                    // once pressing it would actually delete.
                    Text("Continue").fontWeight(.semibold)   // owner 2026-10-18: a confirm follows
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .foregroundStyle(password.isEmpty ? Color.secondary : Color.white)
                        .background(password.isEmpty ? Color(uiColor: .tertiarySystemFill) : Color.red,
                                    in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(password.isEmpty)
            }

            // No linked provider (a legacy anonymous session): nothing to verify against, so
            // deletion can proceed directly — Firebase doesn't demand a recent login for those.
            if methods.isEmpty {
                Button { deleteNow() } label: {
                    Text("Delete Account").fontWeight(.semibold)
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .foregroundStyle(.white)
                        .background(Color.red, in: Capsule())
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
        verifying = true   // 2026-09-24 fix-all #144: stay on this page while it runs
        error = nil
        Task {
            defer { verifying = false }   // 2026-09-24 fix-all #144
            do {
                try await work()
                // owner 2026-10-18: proven, now the one last confirm. Nothing written yet.
                step = .verify
                confirmFinal = true
            } catch {
                // Only the password is in question on this screen; the email is not something the
                // person typed, so the front door's "wrong email or password" would send them
                // looking for a mistake they could not have made. A cancel comes back nil and
                // simply clears the line.
                self.error = AuthService.plainMessage(error,
                                                      credentialHint: "That password is not right.")
                step = .verify
            }
        }
    }

    /// No sign-in door to check (legacy anonymous session): straight to the last confirm.
    private func deleteNow() {
        error = nil
        confirmFinal = true
    }

    /// The last confirm said yes.
    private func scheduleNow() {
        step = .working
        error = nil
        Task { await performScheduling() }
    }

    private func factRow(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    /// The same account report Settings › Download My Data makes (`DataExport.accountReport`).
    private func exportData() async {
        exporting = true
        defer { exporting = false }
        do { exportFile = ExportFile(url: try await DataExport.accountReport()) }
        catch { self.error = error.localizedDescription }
    }

    /// The normal path now SCHEDULES the deletion instead of performing it, so a change of mind within
    /// the grace period costs nothing. The account is hidden immediately and signed out here; the real
    /// destruction is done by the server once the date passes (or by "Delete It Now" on the restore
    /// screen). Nothing on the device is wiped, because the encryption key is exactly what makes a
    /// restore able to read old messages.
    private func performScheduling() async {
        do {
            await AuthService.shared.reportAccountDeletion()
            try await profile.scheduleDeletion(reason: reason.rawValue)
            // owner 2026-10-18: show the date before signing out. If the app is killed on this page
            // the next launch lands on the restore screen anyway (RootView reads the same field).
            scheduledFor = profile.me?.deletionScheduledFor
            step = .done
        } catch {
            self.error = AuthService.plainMessage(error)
            step = .confirm
        }
    }

    /// Done on the scheduled page: the sign-out half of what used to follow the schedule at once.
    private func finishSignOut() async {
        step = .working
        do {   // nothing here throws; kept as a block so the steps read in order
            if let uid = Auth.auth().currentUser?.uid { LastAccount.forget(uid) }   // not offered on Log In
            // Same order Settings uses: stop this phone's pushes while we still have auth, then sign out.
            await Push.unregister()
            await DeviceRegistry.shared.removeThisDevice()   // and drop our row in Settings › Devices
            await SessionWipe.endCallsBeforeSignOut()   // audit M-015, 2026-10-07: while writes are allowed
            try? Auth.auth().signOut()
            // WIPE THE DEVICE COPY TOO (audit). The comment above justified skipping this to protect
            // the encryption key — but SessionWipe never touches the Keychain key (wipeIdentity only
            // clears the in-memory copy), which is exactly why plain Sign Out can call it. What was
            // actually left behind was everything else: decrypted messages, unsent drafts, nicknames,
            // cached voice notes and videos, all readable by whoever signs up next on this phone.
            SessionWipe.wipeAccountData()
            dismiss()
            onDeleted()
        }
    }

    private func performDelete() async {
        do {
            // Send the confirmation BEFORE deleting: afterwards the auth record is gone and there's
            // no address left to write to. Worded as "we received your request", so it's accurate
            // even in the rare case the delete below fails. Fire-and-forget — email must never
            // block or fail the deletion itself.
            await AuthService.shared.reportAccountDeletion()
            // audit M-015, 2026-10-07: a call ends before the account (and the right to write) goes.
            await SessionWipe.endCallsBeforeSignOut()
            try await profile.deleteAccount()
            SessionWipe.wipeAccountData()   // server data is gone; clear the device copy too
            dismiss()
            onDeleted()
        } catch {
            self.error = AuthService.plainMessage(error)
            step = .confirm
        }
    }
}
