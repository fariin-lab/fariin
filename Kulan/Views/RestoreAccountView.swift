import SwiftUI

// Shown INSTEAD of the app when you sign in to an account that is scheduled for deletion.
//
// The point of the grace period is that a change of mind costs nothing. Before this, deletion was
// immediate and irreversible: signing back in with the same Google or Apple silently created a brand
// new account and dropped you into onboarding with no explanation and nothing back.
//
// This screen is deliberately a dead end until you choose. There is no way past it into the app,
// because being half-signed-in to an account that is hidden from everyone else would be worse than
// either outcome.
struct RestoreAccountView: View {
    let handle: String
    let scheduledFor: Date
    var onRestored: () -> Void
    var onDeletedNow: () -> Void

    @State private var working = false
    @State private var error: String?
    @State private var confirmDeleteNow = false

    private var dueText: String {
        scheduledFor.formatted(.dateTime.day().month(.wide))
    }

    private var daysLeft: Int {
        max(0, Calendar.current.dateComponents([.day], from: Date(), to: scheduledFor).day ?? 0)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 48)

                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 46))
                    .foregroundStyle(.orange)

                Text("Your account is scheduled for deletion")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14).padding(.horizontal, 28)

                VStack(spacing: 8) {
                    Text(handle.isEmpty
                         ? "It will be permanently deleted on \(dueText)."
                         : "@\(handle) will be permanently deleted on \(dueText).")
                    Text(daysLeft == 0
                         ? "This is your last day to bring it back."
                         : "You have \(daysLeft) day\(daysLeft == 1 ? "" : "s") to bring it back exactly as it was.")
                }
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10).padding(.horizontal, 28)

                VStack(spacing: 12) {
                    Button {
                        act { try await ProfileStore.shared.restoreAccount(); onRestored() }
                    } label: {
                        Group {
                            if working { ProgressView().tint(.white) }
                            else { Text("Restore My Account").fontWeight(.semibold) }
                        }
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .foregroundStyle(.white)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button { confirmDeleteNow = true } label: {
                        Text("Delete It Now").fontWeight(.semibold)
                            .frame(maxWidth: .infinity).frame(height: 52)
                            .foregroundStyle(.red)
                            .background(Color(uiColor: .secondarySystemGroupedBackground),
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .disabled(working)
                .padding(.horizontal, 20).padding(.top, 30)

                // Said plainly rather than promising everything back: with end-to-end encryption the
                // key that reads old messages exists only on the device that had it.
                Text("Restoring on a different phone brings back your account and username, but older messages stay unreadable — the key that unlocks them is only on the phone you deleted from.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 28).padding(.top, 18)

                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28).padding(.top, 14)
                }

                Spacer(minLength: 48)
            }
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .alert("Delete now?", isPresented: $confirmDeleteNow) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                act { try await ProfileStore.shared.deleteAccount(); onDeletedNow() }
            }
        } message: {
            Text("This finishes the deletion straight away instead of waiting until \(dueText). It cannot be undone.")
        }
    }

    private func act(_ work: @escaping () async throws -> Void) {
        working = true; error = nil
        Task {
            do { try await work() }
            catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}
