import SwiftUI

// Signing in without a password: we email a six-digit code and you type it here.
//
// The owner's reference was the reference app's "check your email for a login link — no password needed"
// (2026-08-03). He chose a CODE over a link when asked, and the reasons are worth keeping: a link
// that opens the app needs a domain association and an Apple entitlement, it only works when the
// mail is opened on the phone you are signing in on, and Google shut down the piece that used to
// make those links open apps. A code has none of those problems.
//
// TWO STEPS, ONE SCREEN. Asking for the email on one page and the code on another loses the email
// on a back-swipe and makes "wrong code" feel like starting over.
// ONE SCREEN, THREE DOORS (owner's call, 2026-08-08). Signing up, forgetting your password, and
// signing in with an address nobody has proved yet all land here. It is one screen to build and one
// thing for a person to learn, and it is why the copy is driven by `purpose` rather than forked into
// three near-identical views.
//
// It also replaced the reset LINK entirely. That link left the app, landed on a Google-branded page
// at kulan-2ef85.firebaseapp.com reading "you can now sign in with your new account" to somebody who
// had reset a password on a year-old account, and then expected them to work out on their own that
// they had to come back and start over. His words: "users hate alot steps".
struct LoginCodeView: View {
    /// Identifiable so a caller can drive `navigationDestination(item:)` straight off it, which is
    /// what sign-up and the unproven-address check both do: one optional, set from inside an async
    /// submit, and the push happens without a second piece of state to keep in step with it.
    enum Purpose: Identifiable, Hashable {
        var id: Self { self }

        /// Forgot Password. Six digits and you are in, and nothing else is asked — a new password is
        /// NOT demanded here. That is deliberate: what this person wants is their account back, and
        /// Settings › Password is there whenever they want to set one.
        case forgot
        /// Straight after sign-up, proving the address before the account is any use.
        case signUp
        /// Signing in to an account whose address has never been proved. Clears itself: spending the
        /// code marks the address confirmed server-side, so this door is one-time per account.
        case unproven

        var title: String {
            switch self {
            case .forgot:   return "Enter your code"
            case .signUp:   return "Confirm your email"
            case .unproven: return "Confirm your email"
            }
        }

        var blurb: String {
            switch self {
            case .forgot:   return "No password needed. Type the code and you are back in."
            case .signUp:   return "One code and your account is ready."
            case .unproven: return "This is a one-time check. It will not be asked again."
            }
        }

        var action: String { self == .forgot ? "Log In" : "Confirm" }
    }

    var email: String = ""
    var purpose: Purpose = .forgot
    var onAuthed: () -> Void

    private enum Step { case email, code }

    @State private var step: Step = .email
    /// onAppear fires again on every back-navigation, and the auto-send below must not re-post a
    /// code each time somebody swipes back into this screen. Sends are rate-limited server-side, so
    /// without this guard the second visit would be answered with "too many codes requested".
    @State private var autoSent = false
    @State private var address = ""
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @State private var resendIn = 0
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    private let codeLength = 6
    private var trimmedEmail: String { address.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        ZStack {
            AuthPalette.page.ignoresSafeArea()
                .dismissesKeyboardOnTap()
            VStack(spacing: 14) {
                Spacer().frame(height: 40)

                Text(step == .email ? "What is your email?" : purpose.title)
                    .font(.system(size: 22, weight: .bold)).foregroundStyle(.primary)

                Text(step == .email
                     ? purpose.blurb
                     : "We sent a six-digit code to \(trimmedEmail). It expires in 10 minutes.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)

                if step == .email {
                    labelled("Email") {
                        TextField("", text: $address, prompt: Text("you@example.com").foregroundStyle(.tertiary))
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focused)
                    }
                    primaryButton("Send Code", enabled: trimmedEmail.contains("@")) { send() }
                } else {
                    labelled("Code") {
                        TextField("", text: $code, prompt: Text("123456").foregroundStyle(.tertiary))
                            .keyboardType(.numberPad)
                            // The one-time-code content type is what makes iOS offer the number
                            // straight from the mail notification, so most people never type it.
                            .textContentType(.oneTimeCode)
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .kerning(6)
                            .multilineTextAlignment(.center)
                            .focused($focused)
                            .onChange(of: code) { _, v in
                                let digits = v.filter(\.isNumber)
                                if digits != v { code = String(digits.prefix(codeLength)); return }
                                if digits.count > codeLength { code = String(digits.prefix(codeLength)); return }
                                // Six digits in: go, without making them find a button.
                                if digits.count == codeLength && !busy { verify() }
                            }
                    }
                    primaryButton(purpose.action, enabled: code.count == codeLength) { verify() }

                    Button(resendIn > 0 ? "Send another code in \(resendIn)s" : "Send another code") {
                        send()
                    }
                    .font(.footnote)
                    .foregroundStyle(resendIn > 0 ? Color.secondary : Color.accentColor)
                    .disabled(resendIn > 0 || busy)

                    // FORGOT PASSWORD ONLY. There, a typo in the login field is a real possibility
                    // and this is the way back from it. On the other two doors the address belongs
                    // to an account that already exists, so "use a different email" would offer to
                    // send a code somewhere that cannot confirm anything — a button that looks like
                    // an escape and is a dead end.
                    if purpose == .forgot {
                        Button("Use a different email") {
                            step = .email; code = ""; error = nil; focused = true
                        }
                        .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if address.isEmpty { address = email }
            // EVERY DOOR THAT LEADS HERE ALREADY KNOWS THE ADDRESS. Forgot Password carries it over
            // from the login field, and sign-up and the unproven-address check both read it off the
            // account that was just touched. Showing an email box and a Send button on top of that
            // is a whole screen asking a question we can already answer, which is the kind of step
            // the owner asked to have removed. So post the code and open straight on the six digits.
            //
            // The empty case is still reachable and still works: nothing routes here without an
            // address today, but a future caller that does will get the old two-step behaviour
            // rather than a dead screen.
            if !autoSent, !trimmedEmail.isEmpty, step == .email {
                autoSent = true
                send()
                return
            }
            focused = true
        }
        // One ticker for the resend cooldown. The server rate-limits too — this is only so the
        // button does not look broken while it refuses.
        .task(id: resendIn) {
            guard resendIn > 0 else { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if resendIn > 0 { resendIn -= 1 }
        }
    }

    private func send() {
        guard NetworkState.shared.isOnline else {
            error = "No internet connection. Check your connection and try again."
            return
        }
        busy = true; error = nil
        Task {
            do {
                try await AuthService.shared.requestLoginCode(email: trimmedEmail)
                await MainActor.run {
                    step = .code
                    code = ""
                    resendIn = 30
                    focused = true
                }
            } catch {
                await MainActor.run { self.error = plain(error) }
            }
            await MainActor.run { busy = false }
        }
    }

    private func verify() {
        guard NetworkState.shared.isOnline else {
            error = "No internet connection. Check your connection and try again."
            return
        }
        busy = true; error = nil
        Task {
            do {
                try await AuthService.shared.signInWithLoginCode(email: trimmedEmail, code: code)
                await MainActor.run { onAuthed() }
            } catch {
                // Clear the field on a bad code: leaving six wrong digits there means the next
                // attempt starts with a delete.
                await MainActor.run { self.error = plain(error); code = "" }
            }
            await MainActor.run { busy = false }
        }
    }

    /// The server already answers in plain words, so its message is used as-is when there is one.
    private func plain(_ error: Error) -> String {
        let ns = error as NSError
        if let msg = ns.userInfo["NSLocalizedDescription"] as? String, !msg.isEmpty,
           !msg.lowercased().contains("internal") {
            return msg
        }
        return "Something went wrong. Try again."
    }

    private func primaryButton(_ title: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if busy { ProgressView().tint(AuthPalette.page) } else { Text(title) }
            }
            .authPrimaryPill()
        }
        .disabled(busy || !enabled)
        .opacity(enabled ? 1 : 0.55)
    }

    private func labelled<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
                .font(.system(size: 17))
                .foregroundStyle(.primary)
                .padding(.horizontal, 16).frame(height: 50)
                .background(AuthPalette.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}
