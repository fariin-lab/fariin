import SwiftUI
import FirebaseAuth

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
        /// Sign-up, CODE FIRST (2026-10-17): the address is proved before any account exists. The
        /// code buys a ticket handed to `onTicket`; nobody is signed in here.
        case newAccount

        var title: String {
            switch self {
            case .forgot:     return "Enter your code"
            case .signUp:     return "Confirm your email"
            case .unproven:   return "Confirm your email"
            case .newAccount: return "Check your email"
            }
        }

        var blurb: String {
            switch self {
            case .forgot:     return "Type the email on your account. We will send a code that logs you in, no password needed."
            case .signUp:     return "One code and your account is ready."
            case .unproven:   return "This is a one-time check. It will not be asked again."
            case .newAccount: return "Type the code we send you, then choose a password."
            }
        }

        var action: String {
            switch self {
            case .forgot:     return "Log in"
            case .newAccount: return "Continue"
            default:          return "Confirm"
            }
        }
    }

    var email: String = ""
    var purpose: Purpose = .forgot
    var onAuthed: () -> Void
    /// `.newAccount` only: receives the ticket once the code is right. `onAuthed` is not called.
    var onTicket: ((String) -> Void)? = nil

    /// `newPassword`: FORGOT PASSWORD ONLY, after the code signs you in — owner, 2026-09-29, "after
    /// the correct code give me the option to add a new password, because I forgot the old one".
    /// The code already signed the person in (a fresh sign-in, so Firebase allows the change), and
    /// the app is only entered (`onAuthed`) once they save or choose "Not now".
    private enum Step { case email, code, newPassword }

    @State private var step: Step = .email
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    // UIKit password fields (RevealablePasswordField), so plain @State focus, as on sign-up.
    @State private var newFocused = false
    @State private var confirmFocused = false
    @State private var reveal = false
    private static let passwordMin = 8   // the server's PASSWORD_MIN and PasswordView's rule
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
                // Same header as the email page (EmailAuthView), so the two read as one flow.
                VStack(spacing: 6) {
                    Text(step == .email ? "Get a login code"
                         : step == .newPassword ? "Create a new password" : purpose.title)
                        .font(.system(size: 30, weight: .bold)).foregroundStyle(.primary)
                        .multilineTextAlignment(.center)

                    Text(step == .email ? purpose.blurb
                         : step == .newPassword ? "You will use it to log in next time. Or skip this and keep logging in with a code."
                         : "Enter the 6-digit code we sent to \(trimmedEmail). It expires in 10 minutes.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
                .padding(.top, 36).padding(.bottom, 12)

                if step == .newPassword {
                    // Whose account this is, so nobody sets a password on the wrong one.
                    HStack(spacing: 10) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 26)).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Logged in as").font(.footnote).foregroundStyle(.secondary)
                            Text(trimmedEmail).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(AuthPalette.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    // The sign-up page's password boxes and the SAME four rules, ticked off live
                    // (it asked for 8 characters only, sign-up for 8 + a letter + a number).
                    newPasswordBox(text: $newPassword, focused: $newFocused, placeholder: "New password",
                                   onSubmit: { newFocused = false; confirmFocused = true })
                    newPasswordBox(text: $confirmPassword, focused: $confirmFocused, placeholder: "Confirm password",
                                   onSubmit: { if newPasswordValid { saveNewPassword() } })
                    PasswordChecklist(rules: newRules)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4).padding(.top, 2)

                    primaryButton("Save password", enabled: newPasswordValid) { saveNewPassword() }
                        .padding(.top, 4)
                    Button("Not now") { onAuthed() }
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        .disabled(busy)
                        .padding(.top, 4)

                    // Our own line for the person who came here because they were worried.
                    Text("Think someone else got in? Once you are in, open Settings › Devices and log out any phone you do not know.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8).padding(.horizontal, 8)
                } else if step == .email {
                    // The sign-up page's field: glyph inside, placeholder, no label above
                    // (owner, 2026-10-17: the label-over-grey-box version looked cheap).
                    HStack(spacing: 12) {
                        Image(systemName: "envelope").foregroundStyle(.secondary).frame(width: 22)
                        TextField("Email", text: $address)
                            .keyboardType(.emailAddress)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focused)
                            .submitLabel(.send)
                            .onSubmit { if trimmedEmail.contains("@") { send() } }
                    }
                    .authField(focused: focused)
                    primaryButton("Send code", enabled: trimmedEmail.contains("@")) { send() }
                        .padding(.top, 4)

                    // For the person who is here because they are worried, not because they
                    // forgot: straight to the help page on getting an account back.
                    if purpose == .forgot,
                       let help = URL(string: "https://help.fariin.com/security/if-you-think-someone-else-is-in-your-account") {
                        Button("Someone else is in my account") { WebLink.open(help) }
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .padding(.top, 6)
                    }
                } else {
                    CodeBoxes(code: $code, length: codeLength, focused: $focused,
                              invalid: error != nil && code.isEmpty)
                        .onChange(of: code) { _, v in
                            let digits = v.filter(\.isNumber)
                            if digits != v { code = String(digits.prefix(codeLength)); return }
                            if digits.count > codeLength { code = String(digits.prefix(codeLength)); return }
                            if !digits.isEmpty { error = nil }
                            // Six digits in: go, without making them find a button.
                            if digits.count == codeLength && !busy { verify() }
                        }
                    primaryButton(purpose.action, enabled: code.count == codeLength) { verify() }
                        .padding(.top, 4)

                    Button(resendIn > 0 ? "Send another code in \(resendIn)s" : "Send another code") {
                        send()
                    }
                    .font(.subheadline.weight(resendIn > 0 ? .regular : .semibold))
                    .foregroundStyle(resendIn > 0 ? Color.secondary : Color.primary)
                    .disabled(resendIn > 0 || busy)
                    .padding(.top, 6)

                    // FORGOT PASSWORD ONLY. There, a typo in the login field is a real possibility
                    // and this is the way back from it. On the other two doors the address belongs
                    // to an account that already exists, so "use a different email" would offer to
                    // send a code somewhere that cannot confirm anything — a button that looks like
                    // an escape and is a dead end.
                    if purpose == .forgot {
                        Button("Use a different email") {
                            step = .email; code = ""; error = nil; focused = true
                        }
                        .font(.subheadline).foregroundStyle(.secondary)
                    } else if purpose == .newAccount {
                        // Back to the sign-up page, where the address is typed.
                        Button("Use a different email") { dismiss() }
                            .font(.subheadline).foregroundStyle(.secondary)
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
        // Signed in already on the password step: Back would land on the login form while signed in.
        .navigationBarBackButtonHidden(step == .newPassword)
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
                if purpose == .newAccount {
                    try await AuthService.shared.requestSignupCode(email: trimmedEmail)
                } else {
                    try await AuthService.shared.requestLoginCode(email: trimmedEmail,
                                                                  confirm: purpose != .forgot)
                }
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
                if purpose == .newAccount {
                    let ticket = try await AuthService.shared.verifySignupCode(email: trimmedEmail, code: code)
                    await MainActor.run { onTicket?(ticket) }
                    await MainActor.run { busy = false }
                    return
                }
                try await AuthService.shared.signInWithLoginCode(email: trimmedEmail, code: code)
                await MainActor.run {
                    // Never a password on Apple's hidden relay address: it could never be typed at
                    // the sign-in screen (`AuthService.hasTypableAddress`, `passwordIsOnRelay`).
                    if purpose == .forgot, AuthService.shared.hasTypableAddress {
                        step = .newPassword; error = nil; focused = false; newFocused = true
                    } else {
                        onAuthed()
                    }
                }
            } catch {
                // Clear the field on a bad code: leaving six wrong digits there means the next
                // attempt starts with a delete.
                await MainActor.run { self.error = plain(error); code = "" }
            }
            await MainActor.run { busy = false }
        }
    }

    private var newRules: PasswordRules { PasswordRules(password: newPassword, confirm: confirmPassword) }
    private var newPasswordValid: Bool { newRules.allMet }

    /// The sign-up page's password box (EmailAuthView.passwordBox): lock, UIKit field, eye.
    private func newPasswordBox(text: Binding<String>, focused: Binding<Bool>, placeholder: String,
                                onSubmit: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "lock").foregroundStyle(.secondary).frame(width: 22)
            RevealablePasswordField(text: text, secure: !reveal, focused: focused,
                                    placeholder: placeholder, contentType: .newPassword,
                                    onSubmit: onSubmit)
            Button { reveal.toggle() } label: {
                Image(systemName: reveal ? "eye.slash" : "eye")
                    .font(.system(size: 16)).foregroundStyle(.secondary)
                    .frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(reveal ? "Hide password" : "Show password")
        }
        .authField(focused: focused.wrappedValue)
    }

    /// Same call the Password page makes: `updatePassword` when the account already has a password,
    /// `link` when it only ever signed in with Apple or Google. The code sign-in just happened, so
    /// this is a fresh sign-in and Firebase does not ask for the old password.
    private func saveNewPassword() {
        guard newPasswordValid, !busy else { return }
        busy = true; error = nil
        Task {
            do {
                let hasPassword = Auth.auth().currentUser?.providerData
                    .contains { $0.providerID == "password" } ?? false
                try await AuthService.shared.setPassword(newPassword, isFirst: !hasPassword)
                await MainActor.run { onAuthed() }
            } catch {
                await MainActor.run { self.error = plain(error) }
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
                if busy { BusyArc.small(AuthPalette.page) } else { Text(title) }
            }
            // The email page's button, so a disabled one is a softened black pill, not grey on grey.
            .authActionPill(enabled: enabled || busy)
        }
        .buttonStyle(.plain)
        .disabled(busy || !enabled)
    }

    private func labelled<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            // The email page's field look: white, hairline edge.
            content()
                .font(.system(size: 17))
                .foregroundStyle(.primary)
                .padding(.horizontal, 16).frame(height: 54)
                .background(AuthPalette.page, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
        }
    }
}

/// Six boxes, one digit each, over ONE real text field.
///
/// One field, not six: `.oneTimeCode` (iOS offering the number from the mail notification) and
/// pasting a whole code only work on a single field, and six fields need focus juggling on every
/// key. The field sits on top of the boxes with its text and caret made clear, so a tap anywhere
/// on the row focuses it and a long-press still offers Paste. The boxes only draw what it holds.
struct CodeBoxes: View {
    @Binding var code: String
    let length: Int
    var focused: FocusState<Bool>.Binding
    var invalid = false

    var body: some View {
        let digits = Array(code)
        HStack(spacing: 8) {
            ForEach(0..<length, id: \.self) { i in
                let isNext = focused.wrappedValue && i == min(digits.count, length - 1)
                    && digits.count < length
                let edge: Color = invalid ? .red
                    : isNext ? Color.primary.opacity(0.75) : Color.primary.opacity(0.18)
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AuthPalette.page)
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(edge, lineWidth: isNext || invalid ? 1.4 : 1)
                    if i < digits.count {
                        Text(String(digits[i]))
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                    } else if isNext {
                        CodeCaret()
                    }
                }
                .frame(height: 58)
                .frame(maxWidth: .infinity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: code)
        .animation(.easeOut(duration: 0.15), value: invalid)
        .overlay {
            TextField("", text: $code)
                .keyboardType(.numberPad)
                // The one-time-code content type is what makes iOS offer the number straight
                // from the mail notification, so most people never type it.
                .textContentType(.oneTimeCode)
                .foregroundStyle(.clear)
                .tint(.clear)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .focused(focused)
                .accessibilityLabel("Code")
        }
        .contentShape(Rectangle())
        .onTapGesture { focused.wrappedValue = true }
    }
}

/// The blinking bar in the next empty box.
private struct CodeCaret: View {
    var body: some View {
        // A timeline drives the blink, never repeatForever (iOS 26 deadlock beside the keyboard,
        // build 959; audit H3). Same 0.5s ease in and out.
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.0)
            let x = t < 0.5 ? t / 0.5 : (1 - t) / 0.5          // 0 -> 1 -> 0 over a second
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.primary)
                .frame(width: 2, height: 26)
                .opacity(1 - (x * x * (3 - 2 * x)))
        }
    }
}
