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

    // REBUILT 2026-08-04. It used to lead with "Your account is scheduled for deletion" under an
    // orange warning clock, with Delete It Now given a full-width button identical in size and
    // shape to Restore. That is a notice, not a door back: it repeats the bad news to somebody who
    // is already half-regretting, and hands the exit the same weight as the way home.
    //
    // Three deliberate changes, all in service of the one job this screen has.
    //   1. LEAD WITH WHAT IS STILL TRUE. Nothing has been deleted. That single fact is the reason
    //      anybody stays, and it was buried under the headline and two grey lines.
    //   2. THE EXIT IS TEXT, NOT A BUTTON. Still there, still red, still one tap plus a confirm.
    //      Just no longer dressed as an equal choice.
    //   3. MONOCHROME, and matching the front door. This screen appears INSTEAD of the app when you
    //      sign in, so the last thing the person saw was the Log In screen and its black capsules;
    //      the same button here reads as one continuous flow rather than a system alert that
    //      ambushed them. The old blue came from `Color.accentColor`, which reads the asset
    //      catalogue and quietly ignores the `.tint(.primary)` KulanApp sets to keep iOS blue out
    //      of this app — so this screen was the one place the blue got back in.
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 56)

                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.secondary)

                Text("Everything is still here")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 18).padding(.horizontal, 28)

                Text(handle.isEmpty
                     ? "Your chats, your photos and your name. Nothing has been deleted."
                     : "@\(handle), your chats and your photos. Nothing has been deleted.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10).padding(.horizontal, 32)

                Button {
                    act { try await ProfileStore.shared.restoreAccount(); onRestored() }
                } label: {
                    Group {
                        if working { ProgressView().tint(AuthPalette.page) }
                        else { Text("Bring my account back") }
                    }
                    .authDoorPill()
                }
                .buttonStyle(.plain)
                .disabled(working)
                .padding(.horizontal, 24).padding(.top, 34)

                // The deadline is a fact, not a threat, so it sits UNDER the way back rather than
                // above it. A date as well as a countdown: one is checkable, the other is felt.
                Text(daysLeft == 0
                     ? "Today is the last day. It is deleted on \(dueText)."
                     : "It is deleted on \(dueText), \(daysLeft) day\(daysLeft == 1 ? "" : "s") from now.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 32).padding(.top, 14)

                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 28).padding(.top, 14)
                }

                Button { confirmDeleteNow = true } label: {
                    Text("Delete it now")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .disabled(working)
                .padding(.top, 28)

                // Said plainly rather than promising everything back: with end-to-end encryption
                // the key that reads old messages exists only on the device that had it.
                Text("Restoring on a different phone brings back your account and your username, but older messages stay unreadable. The key that opens them is only on the phone you deleted from.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 32).padding(.top, 34)

                Spacer(minLength: 48)
            }
            .frame(maxWidth: .infinity)
        }
        .background(AuthPalette.page.ignoresSafeArea())
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
