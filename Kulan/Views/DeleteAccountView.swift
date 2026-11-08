import SwiftUI
import FirebaseAuth
import AuthenticationServices

// Account deletion as a short sheet (owner 2026-11-07, who asked for it simpler than the old long
// page plus "Deletion Scheduled" page). Two steps in one sheet:
//   1. "We're sorry to see you go": one required reason, and a required note for "Other reason".
//   2. "Delete @handle?": three plain lines, a way to take your data first, and the red button.
// The red button proves it is you (the sign-in door this account uses), schedules the deletion on
// the server, signs out and lands straight on the log in screen, where a small banner names the
// date. Nothing is written before the sign-in check passes, so a failed check deletes nothing.
//
// The re-verification is not ceremony. The server's `scheduleAccountDeletion` refuses unless the
// account's own token shows a sign-in from the last five minutes, and an unlocked phone left on a
// table must not be one tap away from deleting the account behind it.
struct DeleteAccountView: View {
    var onDeleted: () -> Void
    // Explicit init: the private stored properties below make the memberwise one private.
    init(onDeleted: @escaping () -> Void) { self.onDeleted = onDeleted }

    @Environment(\.dismiss) private var dismiss
    private var profile = ProfileStore.shared

    @State private var reason: LeaveReason?
    @State private var otherText = ""
    @State private var showConfirm = false
    @State private var password = ""
    @State private var deleting = false
    @State private var error: String?
    @State private var exportFile: ExportFile?
    @State private var exporting = false
    /// Held for the length of the Apple sheet; letting it go cancels the sheet.
    @State private var ceremony = PasskeyCeremony()

    /// Raw values are the `reasonCode` values `scheduleAccountDeletion` accepts (shared with Android).
    private enum LeaveReason: String, CaseIterable, Identifiable {
        case otherAccount = "other_account", abusive = "abusive_users", appProblem = "app_problem",
             notUsing = "not_using", other
        var id: String { rawValue }
        var label: String {
            switch self {
            case .otherAccount: return "I want to use another account"
            case .abusive: return "I met abusive users"
            case .appProblem: return "Something in the app didn't work for me"
            case .notUsing: return "I don't use Fariin anymore"
            case .other: return "Other reason"
            }
        }
    }

    private static let otherLimit = 255

    private var handle: String { profile.me?.handle ?? "" }

    /// The day the server will purge, by the same arithmetic it uses (its own now + grace period).
    private var dueText: String {
        let d = Calendar.current.date(byAdding: .day, value: ProfileStore.gracePeriodDays, to: Date()) ?? Date()
        return d.formatted(.dateTime.day().month(.wide).year())
    }

    /// The sign-in door the red button will open. Apple and Google show their own sheet; a
    /// password-only account types its password on this page.
    private var methods: [AuthService.SignInMethod] { AuthService.shared.reauthMethods }
    private var needsPassword: Bool {
        !methods.contains(.apple) && !methods.contains(.google) && methods.contains(.email)
    }

    /// Height of the step on screen, measured, so the sheet is exactly as tall as what it shows
    /// (owner 2026-11-07: no empty band under Cancel). Re-measured when "Other reason" opens its field.
    @State private var contentHeight: CGFloat = 420

    var body: some View {
        Group {
            if showConfirm { confirmPage } else { reasonPage }
        }
        .padding(.horizontal, 20)
        .padding(.top, 26)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .presentationDetents([.height(contentHeight)])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(deleting)
        .sheet(item: $exportFile, onDismiss: { DataExport.cleanup() }) { f in ActivityView(items: [f.url]) }
    }

    // MARK: - Step 1: why

    // One way out on both steps (owner rule, same as Android): no corner button, only the plain
    // Cancel under the main button. Dragging the sheet down still closes it.
    // A reason is required (owner 2026-11-08): Continue stays grey until one is picked, and for
    // "Other reason" until the note has words in it.
    private var reasonPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor.opacity(0.12), in: Circle())
                    .padding(.bottom, 6)
                    .accessibilityHidden(true)
                Text("We're sorry to see you go").font(.title2.weight(.bold))
                Text("Tell us what happened so we can do better. Your answer goes only to the Fariin team.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                ForEach(Array(LeaveReason.allCases.enumerated()), id: \.element) { i, r in
                    if i > 0 { Divider().padding(.leading, 52) }
                    Button {
                        withAnimation(.snappy(duration: 0.22)) { reason = r }
                    } label: {
                        // The radio sits at the leading edge on every row, so the text column is
                        // the same width picked or not and never re-wraps.
                        HStack(spacing: 14) {
                            RadioMark(on: reason == r)
                            Text(r.label).foregroundStyle(.primary).multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12).frame(minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(reason == r ? [.isSelected] : [])
                }
                if reason == .other {
                    Divider().padding(.leading, 16)
                    TextField("Tell us more", text: $otherText, axis: .vertical)
                        .lineLimit(2...5)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .onChange(of: otherText) { _, v in
                            if v.count > Self.otherLimit { otherText = String(v.prefix(Self.otherLimit)) }
                        }
                }
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            if reason == .abusive {
                Text("You can also report someone from their profile, or block them, without leaving.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .transition(.opacity)
            }

            VStack(spacing: 6) {
                Button { withAnimation(.snappy) { showConfirm = true } } label: {
                    Text("Continue").fontWeight(.semibold)
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .foregroundStyle(Color.onFariinAction)
                        .background(Color.fariinAction, in: Capsule())
                        .opacity(canContinue ? 1 : 0.35)
                }
                .buttonStyle(.plain)
                .disabled(!canContinue)
                Button("Cancel") { dismiss() }
                    .frame(maxWidth: .infinity).frame(height: 44)
            }
        }
    }

    private var trimmedOther: String { otherText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canContinue: Bool {
        guard let reason else { return false }
        return reason != .other || !trimmedOther.isEmpty
    }

    // MARK: - Step 2: confirm

    private var confirmPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(handle.isEmpty ? "Delete your account?" : "Delete @\(handle)?")
                .font(.title2.weight(.bold))

            VStack(alignment: .leading, spacing: 12) {
                line("calendar", "Your account will be deleted on \(dueText). Sign in before then to cancel.")
                line("person.crop.circle.badge.xmark", "Your profile, photo and stories are removed.")
                line("bubble.left.and.bubble.right", "Messages you sent stay with the people who got them.")
            }

            Button { Task { await exportData() } } label: {
                HStack(spacing: 6) {
                    Text("Download my data first")
                    if exporting { BusyArc.small(.secondary) }
                }
                .font(.subheadline)
            }
            .disabled(exporting || deleting)

            if needsPassword {
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .submitLabel(.done)
                    .padding(.horizontal, 18).frame(height: 52)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                    .disabled(deleting)
            }

            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                Button { deleteTapped() } label: {
                    HStack(spacing: 10) {
                        if deleting {
                            BusyArc.small(.white)
                            Text("Deleting...")
                        } else {
                            Text("Delete Account")
                        }
                    }
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .foregroundStyle(.white)
                    .background(Color.red.opacity(deleteEnabled || deleting ? 1 : 0.4), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!deleteEnabled)

                Button("Cancel") { dismiss() }
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .disabled(deleting)
            }
            .padding(.top, 6)
        }
    }

    private var deleteEnabled: Bool { !deleting && !(needsPassword && password.isEmpty) }

    private func line(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 17)).foregroundStyle(.secondary).frame(width: 24)
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

    /// The spinner shows on the same frame as the tap, before any network or sign-in sheet.
    private func deleteTapped() {
        guard !deleting else { return }   // one request per tap, however fast the taps
        deleting = true
        error = nil
        Task { await performDeletion() }
    }

    private func performDeletion() async {
        do {
            try await verify()
            try await profile.scheduleDeletion(reasonCode: reason?.rawValue ?? "",
                                               reasonText: reason == .other ? String(trimmedOther.prefix(Self.otherLimit)) : "")
            let due = profile.me?.deletionScheduledFor
                ?? Calendar.current.date(byAdding: .day, value: ProfileStore.gracePeriodDays, to: Date())
                ?? Date()
            AccountDeletionNotice.pending =
                "Deletion scheduled for \(due.formatted(.dateTime.day().month(.wide).year()))"
            await signOut()
            // The sheet stays up with its spinner until the root swaps to the log in screen, so no
            // frame of the settings pages shows in between.
            onDeleted()
        } catch {
            deleting = false
            // A cancelled Apple or Google sheet is a decision, not a failure: no message.
            if (error as NSError).domain == ASAuthorizationError.errorDomain,
               (error as NSError).code == ASAuthorizationError.canceled.rawValue { return }
            // Only the password is in question on this screen; the email is not something the
            // person typed here.
            self.error = AuthService.plainMessage(error, credentialHint: "That password is not right.")
        }
    }

    /// Prove it is you with this account's own door. Legacy anonymous sessions have none, and the
    /// server lets them through without one (refusing would trap them in an account they cannot leave).
    private func verify() async throws {
        if methods.contains(.apple) {
            let request = ASAuthorizationAppleIDProvider().createRequest()
            AuthService.shared.prepareAppleRequest(request)
            let auth = try await ceremony.run([request])
            try await AuthService.shared.reauthApple(authorization: auth)
        } else if methods.contains(.google) {
            try await AuthService.shared.reauthGoogle()
        } else if methods.contains(.email) {
            try await AuthService.shared.reauthEmail(password: password)
        }
    }

    /// Same order Settings uses: stop this phone's pushes while we still have auth, then sign out,
    /// then wipe the device copy (decrypted messages, drafts, cached media). The Keychain key is
    /// left alone, which is what lets a restore within the grace period read old messages.
    private func signOut() async {
        if let uid = Auth.auth().currentUser?.uid { LastAccount.forget(uid) }   // not offered on Log In
        await SessionWipe.cleanUpBeforeSignOut()
        try? Auth.auth().signOut()
        SessionWipe.wipeAccountData()
    }

    /// The same account report Settings › Download My Data makes (`DataExport.accountReport`).
    private func exportData() async {
        exporting = true
        defer { exporting = false }
        do { exportFile = ExportFile(url: try await DataExport.accountReport()) }
        catch { self.error = error.localizedDescription }
    }
}

/// Leading radio for the leave reasons: an empty ring, or the accent ring with a dot inside.
/// Always the same 22pt box, so picking a row never shifts its text.
private struct RadioMark: View {
    var on: Bool
    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(on ? Color.accentColor : Color(uiColor: .tertiaryLabel), lineWidth: on ? 2 : 1.5)
            Circle()
                .fill(Color.accentColor)
                .frame(width: 11, height: 11)
                .scaleEffect(on ? 1 : 0.01)
                .opacity(on ? 1 : 0)
        }
        .frame(width: 22, height: 22)
    }
}

/// The line the log in screen shows once, right after a deletion was scheduled on this phone.
@MainActor
enum AccountDeletionNotice {
    static var pending: String?
}
