import SwiftUI

// FIRST-RUN SCREENS (rebuild, 2026-09-24). The first run is now:
//   1. AgreementView         (this file)  terms + privacy, once per install
//   2. WelcomeView           (AuthFlowViews.swift) the sign-in doors, with the passkey offered on its own
//   3. OnboardingView        (RootView.swift) name, username, optional photo
//   4. NotificationsExplainerView (this file) why, then the system popup
//   5. the Chats screen
//
// The rules every one of these follows: one job per screen, a title and one short line, one big
// primary button at the bottom. Same page colour, pill and type as the sign-in doors, so the flow
// reads as one piece in light and dark.

/// The local record of the agreement: the moment "Agree and continue" was tapped, as seconds since
/// 1970. Zero means not yet. Lives in UserDefaults, so it is shown once per install.
enum FirstRun {
    static let termsAgreedAtKey = "firstRun.termsAgreedAt"
}

// MARK: - 1. Agreement

struct AgreementView: View {
    var onAgree: () -> Void

    var body: some View {
        ZStack {
            AuthPalette.page.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                // ARTWORK: owner to supply
                ShiningLogo()
                    .frame(width: 108, height: 108)
                    .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
                Text("Welcome to Fariin")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.primary)
                    .padding(.top, 22)
                Text("Read our [Privacy Policy](https://fariin.com/privacy). Tap \"Agree and continue\" to accept our [Terms](https://fariin.com/terms).")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .tint(.primary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
                Text("You must be 13 or older to use Fariin.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
                Spacer()
                Spacer()
                Button(action: onAgree) {
                    Text("Agree and continue").authPrimaryPill()
                }
                .padding(.bottom, 16)
            }
            .padding(.horizontal, 24)
        }
    }
}

// MARK: - 4. Notifications

struct NotificationsExplainerView: View {
    var onDone: () -> Void
    @State private var busy = false

    var body: some View {
        ZStack {
            AuthPalette.page.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                // ARTWORK: owner to supply
                Image(systemName: "bell.badge")
                    .font(.system(size: 64, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 108, height: 108)
                Text("Allow notifications so you don't miss messages")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 22)
                Text("Know right away when you get new messages or calls. Fariin never asks for your contacts.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
                Spacer()
                Spacer()
                Button {
                    finish(allow: true)
                } label: {
                    Text("Continue").authPrimaryPill()
                }
                .disabled(busy)
                Button("Not now") { finish(allow: false) }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(height: 44)
                    .padding(.top, 4)
                    .disabled(busy)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
    }

    /// Continue waits for the system popup's answer before moving on, so the popup sits over this
    /// screen and not over a half-drawn chat list.
    private func finish(allow: Bool) {
        guard !busy else { return }
        busy = true
        Task {
            await Push.finishExplainer(allow: allow)
            // The token save and topic sync `register` does for every signed-in launch. The
            // phone has answered now, so this asks nothing.
            Push.register()
            await MainActor.run { onDone() }
        }
    }
}
