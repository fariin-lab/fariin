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
                    Text("Welcome to Fariin")
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

    /// The second choice: OUTLINED, not filled.
    ///
    /// It used to be a light grey capsule with a hairline on top, and grey-on-white is the weakest
    /// thing a button can be — it competed with the black pill above it while looking washed out
    /// rather than deliberately quieter. Filled-primary beside outlined-secondary is the pairing
    /// Apple, Stripe and Linear all use, and it reads as a real choice instead of a disabled one.
    ///
    /// Derived from `Color.primary`, so it inverts on a dark phone with no second set of values.
    /// `.contentShape` matters here and did not before: with no fill, the middle of the capsule is
    /// empty space, and without a declared shape a tap in the centre would fall straight through.
    func authSecondaryPill() -> some View {
        self.font(.system(size: 17, weight: .medium))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity).frame(height: 50)
            .contentShape(Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.22), lineWidth: 1.5))
    }

    /// Tap the page to put the keyboard away.
    ///
    /// None of the entry screens had ANY way to dismiss it. They are ZStack over VStack, not
    /// scrolling content, so there is no swipe-down to fall back on and no Done bar above the
    /// keys — once it was up it stayed up, sitting over the buttons underneath.
    ///
    /// APPLY THIS TO THE BACKGROUND COLOUR, never to the whole screen. On the background it sits
    /// BEHIND the fields and buttons, so a tap on a control still reaches the control and only
    /// taps that hit nothing dismiss. Wrapping the whole stack instead would swallow the first
    /// tap on every button on the page.
    ///
    /// resignFirstResponder rather than a FocusState binding, because it does not care which of
    /// several fields is up, and it works the same on a screen that has two.
    func dismissesKeyboardOnTap() -> some View {
        self.onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                            to: nil, from: nil, for: nil)
        }
    }
}

// The logo, still. The light sweep that used to run across it was removed on the owner's word
// (2026-08-05): the first thing anybody sees should be the mark itself, and a mark that keeps
// moving reads as a loading screen rather than a brand. Kept as its own view because the Welcome
// screen refers to it by name and the artwork note below is worth not losing.
private struct ShiningLogo: View {
    var body: some View {
        ZStack {
            // THE CURRENT MARK, not the retired one. This pointed at `welcome-logo`, a 512px PNG of
            // the TRI-ARROW — the logo the speech bubble replaced, and which the owner had removed
            // from the alternate app icons back on 2026-07-29 (see the note in project.yml). The
            // Welcome screen was the last place in the whole product still showing it, so the first
            // thing anybody saw was a brand we had already retired.
            //
            // `welcome-mark` is the app icon's own 1024px master, so it is the same artwork on the
            // Home Screen and on this page, at a resolution that holds up at 108pt. The AltIcons
            // files could not be used: they are 120 and 180px, made for a 60pt tile, and would have
            // been visibly soft here.
            if let ui = UIImage(named: "welcome-mark") {
                Image(uiImage: ui).resizable().scaledToFill()
            } else {
                Color.black
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

                // THE THREE DOORS ARE ONE SET. What made the reference screens (the reference app, and the
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
                // ...and the style has to be re-BUILT, not re-applied. This is Apple's own
                // `ASAuthorizationAppleIDButton`, which takes its colour in its initialiser and
                // exposes no way to change it afterwards, so the modifier above only decides what
                // the button is BORN as. Google and Email survive an appearance flip without this
                // because `Color.primary` is a dynamic colour UIKit repaints in place; nothing has
                // to re-run for them. The Apple button just kept the instance it already had, which
                // is how a black button ended up on a black page mid-session.
                // `.id(scheme)` makes SwiftUI discard it and make a new one when the phone flips.
                .id(scheme)
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
                    Text("By continuing you agree to Fariin's [Terms](https://fariin.com/terms) and [Privacy Policy](https://fariin.com/privacy).")
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
    @State private var reveal = false
    // No `= false`: FocusState's init takes no arguments and defaults to false on its own. The other
    // FocusState in this file (ForgotPasswordView) was already written the right way.
    @FocusState private var emailFocused: Bool
    // The password box is a UITextField (see RevealablePasswordField), so its focus CANNOT ride on
    // @FocusState: setting a FocusState to a value no SwiftUI view claims gets reset to nil by
    // SwiftUI on the same pass, which would have resigned the keyboard the instant we asked for it.
    // Plain @State, bridged to first responder inside the representable.
    @State private var passwordFocused = false

    /// Sign-up asks ONE thing at a time: the address, then the password. Log in still shows both,
    /// because there you are recalling a pair you already know rather than making one up.
    @State private var showPassword = false
    private var onEmailStep: Bool { mode == .create && !showPassword }

    /// Sign-up's only rule, checked live so the answer is on screen before the button is pressed
    /// rather than after a round trip to Firebase.
    private var passwordLongEnough: Bool { password.count >= 6 }
    private var canSubmit: Bool {
        !email.isEmpty && !password.isEmpty && (mode == .login || passwordLongEnough)
    }

    /// Enough of a check to be worth moving on. Not a full RFC address parser: Firebase decides,
    /// and the point is only to catch the typo BEFORE somebody invents a password behind it.
    private var emailLooksValid: Bool {
        let t = email.trimmingCharacters(in: .whitespaces)
        guard let at = t.firstIndex(of: "@"), at != t.startIndex else { return false }
        let domain = t[t.index(after: at)...]
        return domain.contains(".") && !domain.hasSuffix(".") && !domain.contains("@")
    }
    private var primaryEnabled: Bool { onEmailStep ? emailLooksValid : canSubmit }

    var body: some View {
        ZStack {
            AuthPalette.page.ignoresSafeArea()
                .dismissesKeyboardOnTap()
            // TWO SPACERS, not a fixed 40 at the top. Pinned to the top, the form left a dead gap
            // between the button and the keyboard that made the page look unfinished. Balanced
            // spacers centre it in whatever room the keyboard leaves, so the block rises with the
            // keyboard instead of stranding itself above it.
            VStack(spacing: 14) {
                Spacer(minLength: 24)
                Text(mode == .create ? "Sign up with Email" : "Log in with Email")
                    .font(.system(size: 22, weight: .bold)).foregroundStyle(.primary)
                    .padding(.bottom, 4)

                // Step 2 of sign-up keeps the address on screen, but as a line rather than a box:
                // you are past it, and it must still be fixable without losing the page.
                if mode == .create && showPassword {
                    Button { backToEmail() } label: {
                        HStack(spacing: 8) {
                            Text(email).lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(.secondary)
                            Text("Change").font(.footnote.weight(.semibold))
                                .foregroundStyle(.primary)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 15))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 2)
                } else {
                    field("Email") {
                        TextField("", text: $email, prompt: Text("you@example.com").foregroundStyle(.tertiary))
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($emailFocused)
                            // Return moves on rather than closing the keyboard, so the whole form is
                            // fillable without ever reaching for the screen.
                            .submitLabel(.next)
                            .onSubmit {
                                if mode == .create { if emailLooksValid { advance() } }
                                else { emailFocused = false; passwordFocused = true }
                            }
                    }
                }

                if !onEmailStep { passwordStep }

                Button {
                    if onEmailStep { advance() } else { submit() }
                } label: {
                    Group {
                        if busy {
                            ProgressView().tint(AuthPalette.page)   // spinner reads on the filled pill
                        } else if onEmailStep {
                            Text("Continue")
                        } else {
                            Text(mode == .create ? "Create Account" : "Log In")
                        }
                    }
                    .authPrimaryPill()
                }
                .disabled(busy || !primaryEnabled)
                // 0.3, not 0.55. At 0.55 the black pill turned a solid mid-grey that read as a
                // broken button rather than one waiting for you; faded far enough back, it reads
                // as not-yet.
                .opacity(primaryEnabled ? 1 : 0.3)
                .animation(.easeInOut(duration: 0.15), value: primaryEnabled)
                .padding(.top, 4)

                if mode == .login {
                    // The way in when the password is gone, offered BEFORE the reset link: getting a
                    // code and being in beats setting a new password you also have to remember.
                    //
                    // `.primary`, NOT `Color.accentColor`. accentColor reads the asset catalogue and
                    // ignores the `.tint(.primary)` KulanApp sets to keep iOS blue out of this app,
                    // so this link was rendering system blue on an otherwise monochrome screen. Same
                    // mistake as the restore screen; two places, one cause.
                    NavigationLink {
                        LoginCodeView(email: email, onAuthed: onAuthed)
                    } label: {
                        Text("Log in with a code instead")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                    .padding(.top, 2)

                    // A PAGE, not a tap that fires. This used to call resetPassword the instant it
                    // was pressed, with no chance to read the address back — and refused outright
                    // with "Type your email above first" when the field was empty, which tells
                    // somebody off instead of helping them.
                    //
                    // That pairing was the dangerous part: the backend answers identically whether
                    // or not an account exists (so it cannot be used to discover who is on Fariin),
                    // so a typo'd address produces a cheerful "sent" and a wait for mail that was
                    // never going to come. Showing the address on its own page, before anything is
                    // sent, is the only place that mistake can still be caught.
                    NavigationLink {
                        ForgotPasswordView(email: email)
                    } label: {
                        Text("Forgot password?")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 24)
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { emailFocused = true }
        // The "Check your email" alert that used to live here has moved INTO ForgotPasswordView.
        // An alert is the wrong shape for that moment anyway: it is dismissed and gone, and the
        // one thing a person needs at exactly that second is the address to check, still readable
        // while they go looking for the mail.
    }

    /// Plain text now rather than a styled `Text`. It was shared so a TextField and a SecureField
    /// could not drift apart; there is one field left, and it colours its own placeholder.
    private var passwordPrompt: String {
        mode == .create ? "At least 6 characters" : "Your password"
    }

    /// The password box and its rule. Its own property only so the step check in `body` stays one
    /// readable line instead of wrapping fifty.
    @ViewBuilder private var passwordStep: some View {
        field("Password") {
            HStack(spacing: 8) {
                // ONE field that flips, not two that swap. This used to hold a SwiftUI TextField
                // and a SecureField and exchange them on every tap of the eye, because SecureField
                // cannot be told to show its text and no modifier adds that. Swapping REPLACES the
                // view the keyboard is attached to: first responder dropped, the keyboard started
                // to leave, and a hand-written `focus = .password` on the next runloop hauled it
                // back. That bounce is what the owner photographed. UIKit flips `isSecureTextEntry`
                // on the live field, so nothing is replaced and the keyboard never moves at all.
                RevealablePasswordField(
                    text: $password,
                    secure: !reveal,
                    focused: $passwordFocused,
                    placeholder: passwordPrompt,
                    contentType: mode == .create ? .newPassword : .password,
                    onSubmit: { if canSubmit { submit() } }
                )

                if !password.isEmpty {
                    Button {
                        reveal.toggle()   // no focus to restore: nothing is being replaced
                    } label: {
                        Image(systemName: reveal ? "eye.slash" : "eye")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)   // a real target, not a glyph
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        // The rule, kept ON SCREEN while it is being met. It used to live in the placeholder,
        // which disappears the moment somebody starts typing — exactly when they need to know how
        // far they have to go.
        if mode == .create {
            HStack(spacing: 6) {
                Image(systemName: passwordLongEnough ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                Text("At least 6 characters")
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(passwordLongEnough ? .primary : .secondary)
            .animation(.easeInOut(duration: 0.15), value: passwordLongEnough)
            .padding(.top, -6)
        }
    }

    /// Email step → password step. The email box is removed and the password box created in the
    /// same pass, so UIKit hands first responder straight over and the keyboard never drops.
    private func advance() {
        error = nil
        email = email.trimmingCharacters(in: .whitespaces)
        withAnimation(.easeInOut(duration: 0.2)) { showPassword = true }
        passwordFocused = true
    }

    /// Back to the address. The password is CLEARED on the way: it was invented for the address on
    /// screen a second ago, and carrying it silently behind a changed email is how somebody ends up
    /// with an account whose password they never meant to pair with it.
    private func backToEmail() {
        error = nil
        password = ""
        reveal = false
        passwordFocused = false
        withAnimation(.easeInOut(duration: 0.2)) { showPassword = false }
        emailFocused = true
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

    // Moved to AuthService.plainMessage so every door that can reject somebody shares it. It lived
    // here as a private function, which is exactly why Delete Account was still showing people
    // "The supplied auth credential is malformed or has expired".
    private func plain(_ error: Error) -> String? { AuthService.plainMessage(error) }
}

// MARK: - The password box that can show itself

/// A password field whose eye does not move the keyboard.
///
/// SwiftUI genuinely cannot do this. `SecureField` has no way to reveal its text, no modifier adds
/// one, and iOS 26 still has not shipped an API for it, so every pure-SwiftUI version swaps in a
/// `TextField` — which replaces the view the keyboard is attached to and makes it bounce. UIKit has
/// always had the right shape: `isSecureTextEntry` is a property on a live field, and setting it
/// replaces nothing.
///
/// Standing rule from the owner (2026-08-05): where SwiftUI cannot do the thing, drop to UIKit
/// rather than force SwiftUI through a workaround.
struct RevealablePasswordField: UIViewRepresentable {
    @Binding var text: String
    /// Hidden while true. Owned by the caller's eye button; this view only reads it.
    var secure: Bool
    /// Two-way. SwiftUI drives it (Return on the email field hands over), and the coordinator writes
    /// back when the field is tapped directly, so the flag and the real first responder stay in step.
    @Binding var focused: Bool
    var placeholder: String
    var contentType: UITextContentType
    var onSubmit: () -> Void

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField()
        tf.delegate = context.coordinator
        // Set here, not in SwiftUI: `field()`'s .font and .foregroundStyle cannot reach a UIView.
        // All system colours, because the front door follows the phone into dark mode.
        tf.font = .systemFont(ofSize: 17)
        tf.textColor = .label
        tf.tintColor = .label            // the caret, kept out of iOS blue like the rest of the app
        tf.autocapitalizationType = .none
        tf.autocorrectionType = .no
        tf.spellCheckingType = .no
        tf.returnKeyType = .go
        tf.textContentType = contentType   // this is what keeps the iOS Passwords offer alive
        tf.isSecureTextEntry = secure
        tf.text = text
        tf.attributedPlaceholder = Self.placeholder(placeholder)
        tf.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)),
                     for: .editingChanged)
        // Without these the field refuses to give up any width and the eye loses its 28pt.
        tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return tf
    }

    func updateUIView(_ tf: UITextField, context: Context) {
        context.coordinator.parent = self       // keep the bindings fresh
        if tf.text != text { tf.text = text }
        if tf.textContentType != contentType { tf.textContentType = contentType }
        if tf.attributedPlaceholder?.string != placeholder {
            tf.attributedPlaceholder = Self.placeholder(placeholder)
        }
        applySecure(tf)
        // Focus LAST, so the field is fully dressed before it is allowed to raise a keyboard.
        if focused, !tf.isFirstResponder { tf.becomeFirstResponder() }
        else if !focused, tf.isFirstResponder { tf.resignFirstResponder() }
    }

    /// ⚠️ The one UIKit trap in here. Switching secure entry ON while the field is being edited
    /// leaves it primed to replace its whole contents on the next keystroke, so the password
    /// silently vanishes the moment somebody types after tapping the eye. Re-entering the text
    /// through the field's own editing path consumes that state. Assigning `.text` does not.
    ///
    /// NOT `selectAll` + `insertText`, which is the version everybody posts. On a live field
    /// selectAll flashes the blue selection and can pop the Cut/Copy/Paste bar — the owner saw that
    /// as a shake, and only with the keyboard up, which is exactly when this branch runs.
    /// `deleteBackward` does the same job invisibly.
    ///
    /// It is written to survive either UIKit behaviour, because the quirk is that deleteBackward
    /// sometimes removes the WHOLE contents here rather than one character, and which one you get
    /// is not something to assume.
    private func applySecure(_ tf: UITextField) {
        guard tf.isSecureTextEntry != secure else { return }
        tf.isSecureTextEntry = secure
        guard secure, tf.isFirstResponder, let saved = tf.text, !saved.isEmpty else { return }
        tf.deleteBackward()
        if (tf.text ?? "").isEmpty {
            tf.insertText(saved)                      // it cleared everything
        } else {
            tf.insertText(String(saved.suffix(1)))    // it took one character
        }
    }

    private static func placeholder(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.foregroundColor: UIColor.tertiaryLabel])
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: RevealablePasswordField
        init(_ parent: RevealablePasswordField) { self.parent = parent }

        @objc func editingChanged(_ tf: UITextField) { parent.text = tf.text ?? "" }

        // Written back on the NEXT runloop, never inside the delegate call. A field that becomes
        // first responder from `updateUIView` is doing so while SwiftUI is mid-update, and writing
        // state there is the "Modifying state during view update" warning — and a redraw loop.
        func textFieldDidBeginEditing(_ tf: UITextField) {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.parent.focused else { return }
                self.parent.focused = true
            }
        }

        func textFieldDidEndEditing(_ tf: UITextField) {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.parent.focused else { return }
                self.parent.focused = false
            }
        }

        func textFieldShouldReturn(_ tf: UITextField) -> Bool {
            parent.onSubmit()
            // false, not true: Go submits, and it must not ALSO drop the keyboard, or a refused
            // attempt leaves somebody staring at a closed keyboard and an error.
            return false
        }
    }
}

// MARK: - Forgot password

/// One field, one button, and then the address you sent it to, left on screen.
///
/// This replaced a "Forgot password?" that fired on the tap itself. Two things were wrong with
/// that. It refused an empty field with "Type your email above first", which is a telling-off
/// rather than help. And with a filled field it sent instantly, so nobody ever saw the address
/// before it went — which matters more here than almost anywhere, because `requestPasswordReset`
/// answers identically whether or not an account exists (deliberately, so the box cannot be used
/// to discover who is on Fariin). A typo therefore produced a confident "sent" and a wait for mail
/// that could never arrive. This page is the last place that mistake is catchable.
///
/// Kept to one screen on purpose: the sent state REPLACES the form rather than pushing another
/// page. The address stays readable at exactly the moment somebody switches to their mail app to
/// go looking for it, which an alert cannot do, because an alert is gone the second it is
/// dismissed.
struct ForgotPasswordView: View {
    @State var email: String

    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var error: String?
    @State private var sentTo: String?
    @FocusState private var focus: Bool

    private var trimmed: String { email.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        ZStack {
            AuthPalette.page.ignoresSafeArea()
                .dismissesKeyboardOnTap()
            VStack(spacing: 14) {
                Spacer().frame(height: 40)
                if let sentTo { sentState(sentTo) } else { form }
                Spacer()
            }
            .padding(.horizontal, 24)
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focus = sentTo == nil }
    }

    @ViewBuilder private var form: some View {
        Text("Reset your password")
            .font(.system(size: 22, weight: .bold)).foregroundStyle(.primary)

        Text("We'll email you a link to set a new one.")
            .font(.subheadline).foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 6)

        VStack(alignment: .leading, spacing: 6) {
            Text("Email").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextField("", text: $email, prompt: Text("you@example.com").foregroundStyle(.tertiary))
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.send)
                .onSubmit { send() }
                .focused($focus)
                .font(.system(size: 17))
                .foregroundStyle(.primary)
                .padding(.horizontal, 16).frame(height: 50)
                .background(AuthPalette.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }

        Button { send() } label: {
            Group {
                if busy { ProgressView().tint(AuthPalette.page) }
                else { Text("Send reset link") }
            }
            .authPrimaryPill()
        }
        .disabled(busy || trimmed.isEmpty)
        .opacity(trimmed.isEmpty ? 0.55 : 1)

        if let error {
            Text(error).font(.footnote).foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func sentState(_ address: String) -> some View {
        Text("Check your email")
            .font(.system(size: 22, weight: .bold)).foregroundStyle(.primary)

        // NAMED, not "we sent it to you". The commonest reason a reset never arrives is that it
        // went somewhere else, and the person cannot notice that unless the address is in front
        // of them.
        Text("We sent a link to \(address).")
            .font(.subheadline).foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

        // The second commonest reason, said before they go hunting rather than after.
        Text("It can take a minute. If it is not there, look in your spam folder.")
            .font(.footnote).foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)

        Button { dismiss() } label: {
            Text("Back to log in").authPrimaryPill()
        }
        .padding(.top, 18)
    }

    private func send() {
        guard !trimmed.isEmpty, !busy else { return }
        // Say it plainly before trying, the same early refusal the other doors make.
        guard NetworkState.shared.isOnline else {
            error = "No internet connection. Check your connection and try again."
            return
        }
        busy = true; error = nil
        focus = false
        Task {
            do {
                try await AuthService.shared.resetPassword(email: trimmed)
                await MainActor.run { sentTo = trimmed; error = nil }
            } catch {
                await MainActor.run { self.error = AuthService.plainMessage(error) }
            }
            await MainActor.run { busy = false }
        }
    }
}
