import SwiftUI
import AuthenticationServices

// The front door. Welcome → Create Account / Log In → Apple / Google / Email →
// onboarding (name, @username) for new accounts, straight in for returning ones.
//
// THE FRONT DOOR FOLLOWS THE PHONE. Owner decision 2026-08-03, reversing the
// always-light call of 2026-07-27: "when user system dark or user turn on dark mode
// in his mobile system must detect".
//
// That earlier call never actually took effect. It was written as five
// `.preferredColorScheme(.light)` calls inside this flow, but KulanApp applies its own
// `.preferredColorScheme` OUTSIDE RootView, and an outer one overrides whatever
// descendants ask for. So the pins were dead code and the front door has been following
// the phone all along — which is how the owner ended up looking at a black Log In screen
// with a black Apple button on it. The dead pins are gone rather than left to mislead
// the next person who reads this file.
//
// Every colour here is semantic (`AuthPalette`, `Color.primary`), so the flow resolves
// correctly in both schemes instead of needing a second set of values.
struct WelcomeView: View {
    var onAuthed: () -> Void
    var onDemo: () -> Void = {}   // Appetize preview: straight to main, no routing

    var body: some View {
        NavigationStack {
            ZStack {
                AuthPalette.page.ignoresSafeArea()
                VStack(spacing: 0) {
                    Spacer()
                    ShiningLogo()
                        .frame(width: 108, height: 108)
                        .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
                    Text("Welcome to Kulan")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.primary)
                        .padding(.top, 22)
                    Text("Private chats, calls and stories.\nMade for Somalis everywhere.")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                    Spacer()
                    Spacer()
                    VStack(spacing: 12) {
                        NavigationLink { AuthMethodView(mode: .create, onAuthed: onAuthed) } label: {
                            Text("Create Account").authPrimaryPill()
                        }
                        NavigationLink { AuthMethodView(mode: .login, onAuthed: onAuthed) } label: {
                            Text("Log In").authSecondaryPill()
                        }
                        #if DEBUG
                        // Appetize preview: a Firebase-free local demo account. Debug-only.
                        Button("Preview demo") {
                            DemoMode.activate()
                            onDemo()
                        }
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                        #endif
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

// MARK: - One palette for the whole entry flow

/// The entry screens' colours, in one place, so no screen can drift from its neighbour.
/// Semantic rather than literal white/black: the flow is pinned light today, and if that
/// decision is ever reversed these resolve correctly instead of needing a hunt.
enum AuthPalette {
    /// The page. White while the flow is pinned light.
    static let page = Color(.systemBackground)
    /// Field boxes and the second-choice button. #F2F2F7 in light.
    static let raised = Color(.secondarySystemBackground)
    /// Hairline edge: on white a light-grey fill alone is too weak to read as a button.
    static let hairline = Color.primary.opacity(0.12)
}

// Not private: the onboarding screen in RootView is the last step of this same flow
// and must wear the same two buttons.
extension View {
    /// The main action: black pill, white text.
    func authPrimaryPill() -> some View {
        self.font(.system(size: 17, weight: .semibold))
            .foregroundStyle(AuthPalette.page)          // always the inverse of the fill
            .frame(maxWidth: .infinity).frame(height: 50)
            .background(Color.primary, in: Capsule())
    }

    /// One of the sign-in doors. Always the opposite of the page: white with dark text on
    /// a dark phone, black with light text on a light one. It was hard-coded white, which
    /// is why on a dark phone two white buttons sat next to an Apple button that had
    /// vanished into the background.
    ///
    /// Both ends stay inside the brand rules. Google's guidelines allow a light button
    /// with dark text and a dark button with light text, and the G keeps its colours in
    /// either. `Color.primary` and `AuthPalette.page` are exact opposites by definition,
    /// so contrast cannot drift.
    func authDoorPill() -> some View {
        self.font(.system(size: 17, weight: .medium))
            .foregroundStyle(AuthPalette.page)
            .labelStyle(.titleAndIcon)
            .frame(maxWidth: .infinity).frame(height: 50)   // 50, not 54: still well over the 44pt tap minimum
            .background(Color.primary, in: Capsule())
    }

    func authSecondaryPill() -> some View {
        self.font(.system(size: 17, weight: .medium))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity).frame(height: 50)
            .background(AuthPalette.raised, in: Capsule())
            .overlay(Capsule().strokeBorder(AuthPalette.hairline, lineWidth: 1))
    }
}

// The chrome logo with a slow light sweep — like the metal is catching light.
private struct ShiningLogo: View {
    @State private var sweep = false

    var body: some View {
        ZStack {
            if let ui = UIImage(named: "welcome-logo") {
                Image(uiImage: ui).resizable().scaledToFill()
            } else {
                Color.black
            }
            LinearGradient(colors: [.clear, .white.opacity(0.22), .clear],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .frame(width: 60)
                .rotationEffect(.degrees(18))
                .offset(x: sweep ? 130 : -130)
                .blendMode(.screen)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: false).delay(0.6)) {
                sweep = true
            }
        }
    }
}

// MARK: - The three doors

struct AuthMethodView: View {
    enum Mode { case create, login }
    let mode: Mode
    var onAuthed: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var busy = false
    @State private var error: String?

    private var title: String { mode == .create ? "Create Account" : "Log In" }

    var body: some View {
        ZStack {
            AuthPalette.page.ignoresSafeArea()
            VStack(spacing: 14) {
                Spacer()
                Text(title)
                    .font(.system(size: 24, weight: .bold)).foregroundStyle(.primary)
                Text(mode == .create ? "Pick a door. Takes less than a minute."
                                     : "Welcome back.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()

                // THE THREE DOORS ARE ONE SET. What made the reference screens (Twitch, and the
                // "How do you want to log in?" pattern) read as professional was that every choice
                // is the SAME button — one shape, one height, one weight — and only the brand mark
                // changes. Apple's own `whiteOutline` style is that button, so we use their API
                // rather than drawing a look-alike, and Google and Email are matched to it.
                SignInWithAppleButton(mode == .create ? .signUp : .signIn) { request in
                    AuthService.shared.prepareAppleRequest(request)
                } onCompletion: { result in
                    switch result {
                    case .success(let auth):
                        run { try await AuthService.shared.completeApple(authorization: auth,
                                                                         requireExistingAccount: mode == .login,
                                                                         requireNewAccount: mode == .create) }
                    case .failure:
                        break   // user cancelled the sheet — not an error worth showing
                    }
                }
                // SOLID FILL, NOT `.whiteOutline`. The outline style draws a 1pt border on the button's
                // own bounds and the `.clipShape(Capsule())` below slices it off at the corners, which is
                // the broken-looking Apple button reported earlier. A solid fill clips to a capsule
                // perfectly.
                //
                // Which solid fill follows the phone. `.black` was hard-coded, so on a dark phone it was
                // a black button on a black page: only its white label showed, and it read as a bare row
                // of text between two real buttons. Apple's guidelines name `.black` for light
                // backgrounds and `.white` for dark ones, so this is the compliant pairing rather than a
                // workaround.
                .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
                .frame(height: 50)              // matches authDoorPill exactly
                .clipShape(Capsule())

                Button {
                    run { try await AuthService.shared.signInWithGoogle(requireExistingAccount: mode == .login,
                                                                        requireNewAccount: mode == .create) }
                } label: {
                    // Google's brand rules also call for a white button with dark text, so the
                    // matched set costs us nothing on either company's guidelines.
                    Label(title: { Text("Continue with Google") },
                          icon: { GoogleGIcon(size: 20) })
                        .authDoorPill()
                }
                .disabled(busy)

                NavigationLink { EmailAuthView(mode: mode, onAuthed: onAuthed) } label: {
                    Label(title: { Text(mode == .create ? "Sign up with Email" : "Log in with Email") },
                          icon: { Image(systemName: "envelope.fill").font(.system(size: 18)) })
                        .authDoorPill()
                }

                if busy { ProgressView().padding(.top, 6) }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                        .multilineTextAlignment(.center).padding(.top, 4)
                }

                if mode == .create {
                    Text("By continuing you agree to Kulan's [Terms](https://kulan-2ef85.web.app/terms.html) and [Privacy Policy](https://kulan-2ef85.web.app/privacy.html).")
                        .font(.caption2).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).tint(.primary)
                        .padding(.top, 10)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func run(_ op: @escaping () async throws -> Void) {
        // Refuse OFFLINE up front, before any sheet opens (user reference: "Network connection
        // issue"). Without this, an offline Continue-with-Google opened the web sign-in straight
        // into Safari's own connection-error page — the worst possible way to learn you are offline.
        guard NetworkState.shared.isOnline else {
            error = "No internet connection. Check your connection and try again."
            return
        }
        busy = true; error = nil
        Task {
            do {
                try await op()
                await MainActor.run { onAuthed() }
            } catch {
                let ns = error as NSError
                // Cancelling a sign-in sheet is a decision, not a failure — show NOTHING for it. The
                // raw pass-through here is what printed Apple's internal
                // "WebAuthenticationSession error 1" (= the user tapped Cancel on the Google consent)
                // in red on the login page (user report). Covered cancels: the web-auth sheet (code 1),
                // the Apple-ID sheet (1001), the Google SDK (-5), and Foundation's generic cancel.
                let cancelled =
                    (ns.domain == "com.apple.AuthenticationServices.WebAuthenticationSession" && ns.code == 1)
                    || (ns.domain == "com.apple.AuthenticationServices.AuthorizationError" && ns.code == 1001)
                    || (ns.domain == "com.google.GIDSignIn" && ns.code == -5)
                    || (ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError)
                #if DEBUG
                if !cancelled { print("[auth] sign-in failed: \(ns.domain) \(ns.code) \(error)") }
                #endif
                await MainActor.run {
                    if let flow = error as? AuthFlowError {
                        // Our own crafted copy (e.g. "You haven't signed up with this account
                        // before...") — show it verbatim.
                        self.error = flow.errorDescription
                    } else if !cancelled {
                        // Real failures speak like a person — never a raw NSError on the front door.
                        //
                        // 17012 is the ONE that used to land here as "Couldn't sign in": the address
                        // already has an account made a DIFFERENT way. The project is set to one
                        // account per email, so this is Firebase refusing to make a second one, not
                        // a failure — and the person needs to be told which door to use rather than
                        // asked to try again at the one that cannot work.
                        switch ns.code {
                        case 17020: self.error = "No internet connection. Try again."
                        case 17012: self.error = "This email already has an account, made a different way. Use the button you signed up with, or log in with a code."
                        default:    self.error = "Couldn't sign in. Please try again."
                        }
                    }
                }
            }
            await MainActor.run { busy = false }
        }
    }
}

// MARK: - Email door

struct EmailAuthView: View {
    let mode: AuthMethodView.Mode
    var onAuthed: () -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var resetSent = false
    @FocusState private var focus: Bool

    var body: some View {
        ZStack {
            AuthPalette.page.ignoresSafeArea()
            VStack(spacing: 14) {
                Spacer().frame(height: 40)
                Text(mode == .create ? "Sign up with Email" : "Log in with Email")
                    .font(.system(size: 22, weight: .bold)).foregroundStyle(.primary)

                field("Email") {
                    TextField("", text: $email, prompt: Text("you@example.com").foregroundStyle(.tertiary))
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus)
                }
                field("Password") {
                    SecureField("", text: $password, prompt: Text(mode == .create ? "At least 6 characters" : "Your password").foregroundStyle(.tertiary))
                        .textContentType(mode == .create ? .newPassword : .password)
                }

                Button {
                    submit()
                } label: {
                    Group {
                        if busy {
                            ProgressView().tint(AuthPalette.page)   // spinner reads on the filled pill
                        } else {
                            Text(mode == .create ? "Create Account" : "Log In")
                        }
                    }
                    .authPrimaryPill()
                }
                .disabled(busy || email.isEmpty || password.isEmpty)
                .opacity(email.isEmpty || password.isEmpty ? 0.55 : 1)

                if mode == .login {
                    // The way in when the password is gone, offered BEFORE the reset link: getting a
                    // code and being in beats setting a new password you also have to remember.
                    NavigationLink {
                        LoginCodeView(email: email, onAuthed: onAuthed)
                    } label: {
                        Text("Log in with a code instead")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .padding(.top, 2)

                    // A line of green text under a button is not an answer. Sending a reset
                    // is exactly the moment a person leaves the app for a mail client, so it
                    // has to stop them and say where to look.
                    Button("Forgot password?") {
                        guard !email.isEmpty else { error = "Type your email above first."; return }
                        Task {
                            do {
                                try await AuthService.shared.resetPassword(email: email)
                                await MainActor.run { resetSent = true; error = nil }
                            } catch {
                                await MainActor.run { self.error = plain(error) }
                            }
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
        .onAppear { focus = true }
        // Names the address, because the commonest reason a reset "never arrives" is that
        // it went somewhere else. Names the spam folder, which is the second commonest.
        // And names the code, which is the door that does not depend on the mail at all.
        .alert("Check your email", isPresented: $resetSent) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("We sent a link to \(email) for setting a new password. It can take a minute. If you cannot find it, look in your spam folder, or log in with a code instead.")
        }
    }

    private func field<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
                .font(.system(size: 17))
                .foregroundStyle(.primary)
                .padding(.horizontal, 16).frame(height: 50)
                .background(AuthPalette.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func submit() {
        // Same early offline refusal as the social doors — say it plainly before trying.
        guard NetworkState.shared.isOnline else {
            error = "No internet connection. Check your connection and try again."
            return
        }
        busy = true; error = nil
        Task {
            do {
                if mode == .create {
                    try await AuthService.shared.createEmailAccount(email: email.trimmingCharacters(in: .whitespaces),
                                                                    password: password)
                } else {
                    try await AuthService.shared.signInEmail(email: email.trimmingCharacters(in: .whitespaces),
                                                             password: password)
                }
                await MainActor.run { onAuthed() }
            } catch {
                await MainActor.run { self.error = plain(error) }
            }
            await MainActor.run { busy = false }
        }
    }

    // Firebase error codes → normal-person words.
    private func plain(_ error: Error) -> String {
        let ns = error as NSError
        switch ns.code {
        case 17008: return "That doesn't look like an email address."
        case 17026: return "Password must be at least 6 characters."
        case 17009, 17004: return "Wrong email or password."
        case 17011: return "No account with that email. Create one instead."
        case 17007: return "This email already has an account. Go back and choose Log In instead."
        case 17020: return "No internet connection. Try again."
        // Same story from the email door: the address belongs to an account created with Google or
        // Apple, so there is no password to be right.
        case 17012: return "This email already has an account, made with Google or Apple. Go back and use that button, or log in with a code."
        default: return error.localizedDescription
        }
    }
}
