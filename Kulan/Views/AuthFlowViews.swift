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

    /// "Last used" — the small badge that says which door you came in by on this phone.
    ///
    /// TikTok's "Last login: Phone", and Google and Facebook do the same. It answers a real question
    /// with a bad failure mode: pick the wrong door and the app says there is no account, which
    /// reads as your account being gone rather than as you having knocked in the wrong place.
    ///
    /// Drawn as an OVERLAY pinned to the top-trailing corner, so it costs the row no height and the
    /// three doors stay the identical 50pt pills they were. `alignmentGuide` lifts it half out of
    /// the capsule the way a notification dot sits on an icon; `allowsHitTesting(false)` keeps the
    /// whole pill tappable, since a label that swallowed the tap in its corner would be a bug that
    /// only shows up on the one button people most want to press.
    ///
    /// It says the METHOD and nothing else. Never an address: this screen is shown to whoever is
    /// holding a signed-out phone.
    @ViewBuilder
    func lastUsedBadge(_ show: Bool) -> some View {
        if show {
            self.overlay(alignment: .topTrailing) {
                Text("Last used")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AuthPalette.page)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.accentColor, in: Capsule())
                    // SwiftUI places the badge so its guide lands on the parent's edge, so the sign
                    // of each number is the opposite of what it looks like. `.top + 6` puts the
                    // guide 6pt down the badge, which lifts the badge 6pt ABOVE the capsule — the
                    // half-out-of-the-edge look. `.trailing + 10` puts the guide 10pt past the
                    // badge's right edge, which pulls it 10pt INSIDE the capsule. Using -10 there
                    // (the intuitive-looking sign) pushes it outside the button instead.
                    .alignmentGuide(.top) { $0[.top] + 6 }
                    .alignmentGuide(.trailing) { $0[.trailing] + 10 }
                    .allowsHitTesting(false)
            }
        } else {
            self
        }
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

    /// Which door to mark "Last used" — ON THE LOG IN SCREEN ONLY.
    ///
    /// On Create Account it would point at the account you already have while you are deliberately
    /// making a new one, which is the opposite of helpful. Read once per body evaluation rather than
    /// held in @State: it changes only on a successful sign-in, by which point this screen is gone.
    private var lastDoor: AuthService.SignInMethod? {
        mode == .login ? AuthService.lastSignInMethod : nil
    }

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
                .lastUsedBadge(lastDoor == .apple)

                Button {
                    run { try await AuthService.shared.signInWithGoogle(requireExistingAccount: mode == .login,
                                                                        requireNewAccount: mode == .create) }
                } label: {
                    // Google's brand rules also call for a white button with dark text, so the
                    // matched set costs us nothing on either company's guidelines.
                    Label(title: { Text("Continue with Google") },
                          icon: { GoogleGIcon(size: 20) })
                        .authDoorPill()
                        .lastUsedBadge(lastDoor == .google)
                }
                .disabled(busy)

                NavigationLink { EmailAuthView(mode: mode, onAuthed: onAuthed) } label: {
                    Label(title: { Text(mode == .create ? "Sign up with Email" : "Log in with Email") },
                          icon: { Image(systemName: "envelope.fill").font(.system(size: 18)) })
                        .authDoorPill()
                        .lastUsedBadge(lastDoor == .email)
                }

                if busy { ProgressView().padding(.top, 6) }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                        .multilineTextAlignment(.center).padding(.top, 4)
                }

                if mode == .create {
                    // THE AGE LINE IS NOT DECORATION, and it is deliberately in the SAME sentence
                    // as the terms rather than a second line or a tick box.
                    //
                    // The privacy policy already promises "Fariin is not intended for children
                    // under 13. We do not knowingly hold data about them." Nothing in the app asked
                    // anybody anything, so that promise rested on never finding out. "Not
                    // knowingly" only holds while you have actually asked, and until now we never
                    // had.
                    //
                    // 13 is the owner's call and it matches two things: the number already written
                    // in our own privacy policy, and WhatsApp, who moved Europe DOWN from 16 to 13
                    // this year. Telegram says 16 and still carries a 17+ App Store rating, so the
                    // higher number does not buy the thing people assume it buys.
                    //
                    // ⚠️ THIS IS THE FLOOR, NOT THE FEATURE. A child can tap past it, exactly as
                    // they can on WhatsApp and Telegram, neither of which verifies anything either.
                    // What it buys is the record that we asked. The real protection is Apple's
                    // Declared Age Range API (iOS 26, which is our floor anyway, so every user has
                    // it) plus what actually CHANGES for a minor: not findable by username search,
                    // no public stories, messages from accepted contacts only. A number nobody acts
                    // on protects nobody.
                    //
                    // One sentence on purpose. A separate age checkbox is one more thing to tap on
                    // the screen where people are already deciding whether to bother.
                    Text("By continuing you confirm you are 13 or older and agree to Fariin's [Terms](https://fariin.com/terms) and [Privacy Policy](https://fariin.com/privacy).")
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

    /// Set when the address still has to be proved with a code, which pushes the code screen instead
    /// of finishing. One optional drives the whole thing through `navigationDestination(item:)`, so
    /// there is no separate "is it showing" flag that could fall out of step with the purpose.
    @State private var prove: LoginCodeView.Purpose?

    // No `= false`: FocusState's init takes no arguments and defaults to false on its own.
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
                        // NO PLACEHOLDER. "you@example.com" sat here and the owner called it
                        // unprofessional, which it was: the row already carries an "Email" label
                        // directly above it, so the ghost text repeated the label and dressed the
                        // repeat up as a fake address. Apple's own sign-in fields label the row and
                        // leave the box empty. An empty box under a label is not missing anything.
                        TextField("", text: $email)
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
                    // ONE LINK NOW, NOT TWO. "Log in with a code instead" used to sit above this
                    // one, and the pair of them made a person choose between two doors that both
                    // ended in the same place. The owner's call (2026-08-08): the code stops being
                    // its own advertised way in and becomes the machinery UNDER Forgot Password,
                    // which is what people actually go looking for. Snapchat's model, and his words
                    // for the old one were "users hate alot steps".
                    //
                    // It no longer mails a reset link either. Six digits, typed here, and you are
                    // in. Setting a password is a separate thing you can do whenever you like from
                    // Settings › Password, because what somebody locked out actually wants is their
                    // account back, not homework.
                    //
                    // ForgotPasswordView is gone with it. Its whole job was to show the address back
                    // before firing a send that could not be undone; LoginCodeView shows the same
                    // address at the top of the code step, so the page had nothing left to do.
                    //
                    // Keep `.secondary` here. `.primary` was right for the bold code link that used
                    // to lead, and this line is not leading anything.
                    NavigationLink {
                        LoginCodeView(email: email, purpose: .forgot, onAuthed: onAuthed)
                    } label: {
                        Text("Forgot password?")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
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
        // A PUSH, not a sheet and not an alert. This is the next step of the same errand, not an
        // interruption of it, and the code screen needs to stay put while somebody leaves the app to
        // go and read their mail. An alert would be dismissed and gone by the time they came back.
        .navigationDestination(item: $prove) { purpose in
            LoginCodeView(email: email.trimmingCharacters(in: .whitespaces),
                          purpose: purpose,
                          onAuthed: onAuthed)
        }
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
                    // SIGN-UP ALWAYS PROVES THE ADDRESS, and this is the step that closes the typo
                    // hole for good. `createUser` checks nothing: mean `abdil@`, type `abdi@`, and
                    // that address is attached to the account on your word alone. Everything the old
                    // code tried to do about that afterwards (the confirm-before-code wall) could be
                    // walked past with one click, because the cure it posted went to the very
                    // mailbox it was defending. Proving it here, before the account is any use, is
                    // the only version that holds.
                    //
                    // NOT `onAuthed()`. The person is signed in to Firebase at this point, but the
                    // app deliberately does not move on Firebase's state — RootView waits for this
                    // callback — so the code screen gets its turn.
                    await MainActor.run { prove = .signUp }
                } else {
                    try await AuthService.shared.signInEmail(email: email.trimmingCharacters(in: .whitespaces),
                                                             password: password)
                    // EVERY ACCOUNT THAT PREDATES THE LINE ABOVE comes through here unproven, and
                    // this is where each of them quietly gets fixed, one sign-in at a time, without
                    // anybody being told to go and click anything in a mailbox.
                    if await AuthService.shared.emailNeedsProof {
                        await MainActor.run { prove = .unproven }
                    } else {
                        await MainActor.run { onAuthed() }
                    }
                }
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

// ForgotPasswordView LIVED HERE AND IS DELETED (2026-08-08, owner's call).
//
// It collected the address, called requestPasswordReset, and then sat on a "Check your email"
// state with the address left readable. All of that was sound for the flow it served, and the
// flow underneath it is what went. Forgot Password no longer mails a link at all: it asks for
// six digits and signs you in, on LoginCodeView, which shows the same address at the top of the
// code step. So the one job this page still had, catching a typo before an unrecoverable send,
// is done a screen later by the screen that replaced it.
//
// Recover it from git if the link flow ever comes back; do not rewrite it from memory.
