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
    /// The automatic passkey offer runs once per time this screen is built, not on every return
    /// from a pushed door page.
    @State private var passkeyOffered = false
    /// ⛔ ACCOUNT CARDS FIRST — owner, 2026-09-27: "Log In" then the card was one tap too many.
    /// When this phone remembers an account, the signed-out flow opens straight on its card (the
    /// Log In page's accounts face); a phone that remembers none gets the logo page below.
    @State private var hasSaved = !LastAccount.all().isEmpty

    var body: some View {
        NavigationStack {
            Group {
                if hasSaved {
                    AuthMethodView(mode: .login, onAuthed: onAuthed)
                } else {
                    logoPage
                }
            }
            .task { await offerPasskey() }
        }
    }

    private var logoPage: some View {
            ZStack {
                AuthPalette.page.ignoresSafeArea()
                VStack(spacing: 0) {
                    Spacer()
                    // ⛔ HIS BLACK LOGO — owner, 2026-09-28: "change the logo, use the black logo I sent".
                    // The launch screen's mark (`LaunchLogo`): black on this white page, and his white
                    // one when the phone is dark (this flow follows the phone, see the file's head).
                    // It replaced the blue app-icon tile.
                    Image("LaunchLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 120, height: 120)
                        .accessibilityLabel("Fariin")
                    // "Log in", not "Welcome": the first-run agreement screen right before this one
                    // already says "Welcome to Fariin", and the same title twice in a row read as a
                    // loop (2026-09-24).
                    Text("Log in to Fariin")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.primary)
                        .padding(.top, 22)
                    Text("Private chats, calls and stories.")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                    // ⛔ NO "Log in using Passkey" LINK — owner, 2026-09-27. The system passkey sheet
                    // already comes up by itself when this phone holds one (`offerPasskey`), which is
                    // the only case the link served in practice. The 09-25/09-26 link requests were
                    // not the owner's; do not re-add it.
                    Spacer()
                    Spacer()
                    VStack(spacing: 12) {
                        // ⛔ LIQUID GLASS — owner, 2026-09-26: "Create Account and Log In buttons make
                        // liquid glass". iOS 26's own pair: the main action is tinted glass with white
                        // words, the other is plain glass. Only these two; the other sign-in pages keep
                        // their pills.
                        // ⛔ BLACK, NOT BLUE — owner, 2026-09-28: "create account button make black".
                        // Still the tinted glass above, tinted `.primary`: black with white words on a
                        // light phone, and the inverse on a dark one, where a black button would vanish
                        // into the black page (the same rule as `authPrimaryPill`).
                        NavigationLink { AuthMethodView(mode: .create, onAuthed: onAuthed) } label: {
                            Text("Create Account")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(AuthPalette.page)
                                .frame(maxWidth: .infinity).frame(height: 50)
                                .liquidGlass(Capsule(), interactive: true, tint: Color.primary)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        NavigationLink { AuthMethodView(mode: .login, onAuthed: onAuthed) } label: {
                            Text("Log in")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity).frame(height: 50)
                                .liquidGlass(Capsule(), interactive: true)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        #if DEBUG
                        // Appetize preview: a Firebase-free local demo account. Debug-only.
                        // READABLE ON PURPOSE. It was `.caption` in `.tertiary`, which on the white
                        // auth page is grey on almost-white at eleven points — the owner could not
                        // find it in the browser preview he had just been told to open with it. This
                        // whole block is `#if DEBUG`, so it is never in a TestFlight or App Store
                        // build and costs a real user nothing.
                        Button("Preview demo") {
                            DemoMode.activate()
                            onDemo()
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.top, 6)
                        #endif
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
    }

    /// THE FASTEST DOOR, OFFERED WITHOUT ASKING. If this phone holds a Fariin passkey, the system
    /// passkey sheet comes up on its own as the screen appears; `immediateOnly` means a phone with
    /// none shows nothing at all, and the three doors below stay exactly as they were. Every
    /// failure (no passkey, cancelled, offline, server down) is silent for the same reason: this is
    /// an offer, not a step.
    private func offerPasskey() async {
        guard !passkeyOffered else { return }
        passkeyOffered = true
        guard !DemoMode.active, NetworkState.shared.isOnline else { return }
        do {
            try await Passkeys.signIn(immediateOnly: true)
        } catch {
            return
        }
        // Same bookkeeping the other doors do after Firebase accepts them.
        await AuthService.shared.bootstrap()
        AuthService.shared.reportLogin()
        onAuthed()
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

    /// ⛔ THE QUIET DOOR — owner, 2026-09-25: Google and Email in Apple's liquid glass, at Apple's
    /// standard 50pt button height, under the one light Apple button (also 50).
    func authRaisedPill() -> some View {
        self.font(.system(size: 17, weight: .medium))
            .foregroundStyle(.primary)
            .labelStyle(.titleAndIcon)
            .frame(maxWidth: .infinity).frame(height: 50)
            .liquidGlass(Capsule(), interactive: true)
            .contentShape(Capsule())
    }

    /// The email pages' main button: always the solid pill, softened until it can be pressed.
    /// It was a grey pill with grey text, which on a white page read as no button at all (owner,
    /// 2026-10-16, side by side with a large app's sign-up).
    func authActionPill(enabled: Bool) -> some View {
        self.font(.system(size: 17, weight: .semibold))
            .foregroundStyle(AuthPalette.page)
            .frame(maxWidth: .infinity).frame(height: 54)
            .background(Color.primary.opacity(enabled ? 1 : 0.3), in: Capsule())
    }

    /// A field box on the email pages: its glyph inside, no label above, a hairline at rest, dark
    /// while focused, red after a bad address. White with an edge, not grey: a grey box over a
    /// grey button read as two of the same thing.
    func authField(focused: Bool, invalid: Bool = false) -> some View {
        let edge: Color = invalid ? .red : Color.primary.opacity(focused ? 0.75 : 0.18)
        return self.font(.system(size: 17))
            .foregroundStyle(.primary)
            .padding(.horizontal, 18).frame(height: 56)
            .background(AuthPalette.page, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(edge, lineWidth: focused || invalid ? 1.2 : 1))
            .animation(.easeOut(duration: 0.15), value: focused)
            .animation(.easeOut(duration: 0.15), value: invalid)
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
    ///
    /// ⛔ OFF — owner 2026-10-18: "tapping the email / password field still fights; remove tap to
    /// close the keyboard altogether". A tap meant for a field kept landing on this and closing the
    /// keys it had just opened. Kept as a no-op so the call sites stay put; swiping the page down
    /// (`scrollDismissesKeyboard`) and Return close the keyboard.
    func dismissesKeyboardOnTap() -> some View {
        self
    }
}

// The logo, still. The light sweep that used to run across it was removed on the owner's word
// (2026-08-05): the first thing anybody sees should be the mark itself, and a mark that keeps
// moving reads as a loading screen rather than a brand. Kept as its own view because the Welcome
// screen refers to it by name and the artwork note below is worth not losing.
// Not private: the first-run Welcome screen (FirstRunViews.swift) shows the same mark.
struct ShiningLogo: View {
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
    /// State, not a constant: the "Sign up" / "Log in" line at the bottom flips this page in place,
    /// the way the reference's does, instead of stacking a second copy of it.
    @State private var mode: Mode
    var onAuthed: () -> Void

    init(mode: Mode, showDoors: Bool = false, onAuthed: @escaping () -> Void) {
        _mode = State(initialValue: mode)
        _showDoors = State(initialValue: showDoors)
        self.onAuthed = onAuthed
    }

    @Environment(\.colorScheme) private var scheme
    @State private var busy = false
    /// The saved account being signed back into: its own row shows the spinner (see `savedAccountRow`).
    @State private var resumingUid: String?
    /// The door whose button spins (owner 2026-10-24): set only once Apple's Face ID or Google's
    /// account pick has said yes, never on the tap; cleared when the sign-in ends either way.
    @State private var spinningDoor: AuthService.SignInMethod?
    @State private var error: String?
    /// The accounts this phone has used (see `LastAccount`), Log In only, newest first.
    @State private var saved: [LastAccount.Info] = LastAccount.all()
    @State private var photos: [String: UIImage] = Dictionary(
        uniqueKeysWithValues: LastAccount.all().compactMap { a in LastAccount.photo(for: a.uid).map { (a.uid, $0) } })
    @State private var emailPrefill: String?
    /// "Add another account" was tapped: show the sign-in doors instead of the saved accounts.
    @State private var showDoors = false

    /// ⛔ THE SAVED-ACCOUNTS FACE — owner, 2026-09-25, with the design: every account this phone has
    /// used as its own card, "Add another account" under them, then "or" and Sign up. Only on Log In,
    /// only when there is an account to show, and until "Add another account" asks for the doors.
    private var accountsFace: Bool { mode == .login && !saved.isEmpty && !showDoors }

    /// Which door to mark "Last used" — ON THE LOG IN SCREEN ONLY.
    ///
    /// On Create Account it would point at the account you already have while you are deliberately
    /// making a new one, which is the opposite of helpful. Read once per body evaluation rather than
    /// held in @State: it changes only on a successful sign-in, by which point this screen is gone.
    private var lastDoor: AuthService.SignInMethod? {
        mode == .login ? AuthService.lastSignInMethod : nil
    }

    // ⛔ THE DOORS PAGE, ON THE OWNER'S REFERENCE — 2026-09-25, "make it like this, exactly": the
    // app's name, Apple as the one light button, Google and Email as quiet raised pills with an "or"
    // between them, the other mode as one line under them, and the terms at the foot. Both modes
    // are this one page. Log In adds the account this phone last used above the doors.
    var body: some View {
        ZStack {
            AuthPalette.page.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                if accountsFace {
                    // ⛔ OWNER, 2026-09-27: the app's name on top like the doors page, no "or" under
                    // the cards; "Sign up" below is enough.
                    Text("Fariin")
                        .font(.system(size: 22, weight: .semibold)).foregroundStyle(.primary)
                        .padding(.bottom, 28)
                    VStack(spacing: 16) {
                        ForEach(saved) { savedAccountRow($0) }
                        addAnotherAccountRow
                    }
                } else {
                Text("Fariin")
                    .font(.system(size: 22, weight: .semibold)).foregroundStyle(.primary)
                    .padding(.bottom, 28)

                VStack(spacing: 14) {
                    appleButton
                    Button {
                        run { try await AuthService.shared.signInWithGoogle(
                            requireExistingAccount: mode == .login, requireNewAccount: mode == .create,
                            onPicked: { spinningDoor = .google }) }
                    } label: {
                        ZStack {
                            Label(title: { Text("Continue with Google") }, icon: { GoogleGIcon(size: 20) })
                                .opacity(spinningDoor == .google ? 0 : 1)
                            if spinningDoor == .google { BusyArc(size: 20, lineWidth: 2.2, color: .secondary) }
                        }
                            .animation(.easeInOut(duration: 0.2), value: spinningDoor)
                            .authRaisedPill()
                            .lastUsedBadge(lastDoor == .google)
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)

                    orDivider

                    NavigationLink { EmailAuthView(mode: mode, onAuthed: onAuthed) } label: {
                        Text("Continue with Email")
                            .authRaisedPill()
                            .lastUsedBadge(lastDoor == .email)
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                }
                }

                // Space always kept, spinner faded in (owner, 2026-09-25): inserting it on Google's
                // tap grew this centred block and slid every card up, then back down when it went.
                // ⛔ AND THE SPACE IS THE GAP ITSELF NOW — owner, 2026-09-26: "fix the space between
                // Email and Sign up". A 16pt pad, the spinner's own row and 36 more made ~72pt of
                // black. The spinner is drawn inside the 24pt gap above "Sign up" (see there), so
                // it still appears without moving anything.
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                        .multilineTextAlignment(.center).padding(.top, 12)
                }

                Button {
                    error = nil
                    withAnimation(.easeInOut(duration: 0.2)) { mode = mode == .login ? .create : .login }
                } label: {
                    HStack(spacing: 5) {
                        Text(mode == .login ? "Don’t have an account?" : "Already have an account?")
                            .foregroundStyle(.secondary)
                        Text(mode == .login ? "Sign up" : "Log in")
                            .font(.system(size: 17, weight: .semibold)).foregroundStyle(.primary)
                    }
                    .font(.subheadline)
                }
                .buttonStyle(.plain)
                .padding(.top, 24)
                // (The shared spinner that sat above "Sign up" is gone, owner 2026-10-24: the button
                // that was used spins instead, see `spinningDoor`.)

                Spacer()
                // Sign up only (owner, 2026-09-27): making an account is the moment consent matters,
                // and the agreement screen already covered this install. On Log In it was clutter.
                Text("By continuing, you agree to our [Terms of Service](https://fariin.com/terms) and [Privacy Policy](https://fariin.com/privacy).")
                    .font(.footnote).foregroundStyle(.secondary)
                    .tint(.primary)
                    .environment(\.openURL, OpenURLAction { url in WebLink.open(url); return .handled })
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 8)
                    // Faded, not removed, so flipping modes does not slide the centred block.
                    .opacity(mode == .create ? 1 : 0)
                    .allowsHitTesting(mode == .create)
                    .accessibilityHidden(mode != .create)
            }
            .padding(.horizontal, 24)
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $emailPrefill) { address in
            EmailAuthView(mode: .login, prefill: address, onAuthed: onAuthed)
        }
    }

    /// Apple's own button, light on a dark phone and dark on a light one (their guidelines), in the
    /// same capsule as the others. The style is fixed when the button is created, so `.id(scheme)`
    /// rebuilds it when the phone flips appearance.
    private var appleButton: some View {
        SignInWithAppleButton(.continue) { request in
            AuthService.shared.prepareAppleRequest(request)
        } onCompletion: { result in
            switch result {
            case .success(let auth):
                // Face ID has said yes: only now does the button spin.
                if NetworkState.shared.isOnline, !busy { spinningDoor = .apple }
                run { try await AuthService.shared.completeApple(authorization: auth,
                                                                 requireExistingAccount: mode == .login,
                                                                 requireNewAccount: mode == .create) }
            case .failure(let e):
                if !AuthService.isCancellation(e) { error = AuthFlowError.appleFailed.errorDescription }
            }
        }
        .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
        .id(scheme)
        .frame(height: 50)   // Apple's standard button height (owner, 2026-09-25)
        // Apple's button draws its own words, so the spinner covers them with the button's own fill.
        .overlay {
            if spinningDoor == .apple {
                Capsule().fill(scheme == .dark ? Color.white : Color.black)
                    .overlay(BusyArc(size: 20, lineWidth: 2.2, color: scheme == .dark ? .black : .white))
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: spinningDoor)
        .clipShape(Capsule())
        .lastUsedBadge(lastDoor == .apple)
        .disabled(busy)
    }

    private var orDivider: some View {
        HStack(spacing: 12) {
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 0.5)
            Text("or").font(.subheadline).foregroundStyle(.secondary)
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 0.5)
        }
        .padding(.vertical, 2)
    }

    /// ⛔ THE ACCOUNT I USED BEFORE — owner, 2026-09-25. One row: face, name, handle, and the tap
    /// goes back in through that account's own door. The menu forgets it from this phone.
    private func savedAccountRow(_ info: LastAccount.Info) -> some View {
        Button { continueAs(info) } label: {
            HStack(spacing: 12) {
                Group {
                    if let photo = photos[info.uid] {
                        Image(uiImage: photo).resizable().scaledToFill()
                    } else {
                        AvatarView(name: info.name, size: 48)
                    }
                }
                .frame(width: 48, height: 48).clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(info.name.isEmpty ? "@\(info.handle)" : info.name)
                            .font(.body.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                        // The same seal VerifiedMark draws, from what the phone saved (signed out,
                        // there is no server to ask).
                        if info.verified == true {
                            Image(uiImage: VerifiedMark.badge(size: 15 * VerifiedMark.scale, blue: info.gold == true ? VerifiedMark.gold : VerifiedMark.blue, weight: VerifiedMark.weight)).frame(width: 15, height: 15)
                                .accessibilityLabel("Verified")
                        }
                    }
                    Text("@\(info.handle)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                // ⛔ THE SPINNER WHERE THE TAP WAS — owner 2026-10-13: it sat squeezed between "Add
                // another account" and "Sign up". The row you tapped turns its chevron into it.
                if resumingUid == info.uid {
                    BusyArc.small(.secondary)
                } else {
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16).frame(height: 72)
            .background(AuthPalette.raised, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .contextMenu {
            Button(role: .destructive) {
                LastAccount.forget(info.uid)
                withAnimation {
                    saved.removeAll { $0.uid == info.uid }
                    photos[info.uid] = nil
                }
            } label: { Label("Remove from This Phone", systemImage: "xmark.circle") }
        }
    }

    /// "Add another account" pushes the usual doors as their own page, so Back returns to the cards
    /// (this page can be the root of the signed-out flow, where an in-place flip had no way back).
    /// Plain words on one line (owner, 2026-09-27): the three small door badges wrapped the text.
    private var addAnotherAccountRow: some View {
        NavigationLink {
            AuthMethodView(mode: .login, showDoors: true, onAuthed: onAuthed)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 48)
                Text("Add another account")
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    // The words win the width: the badges are what gives way (owner, 2026-09-27:
                    // the badges wrapped this line, which is why they once came out).
                    .layoutPriority(1)
                Spacer(minLength: 8)
                // ⛔ THE THREE DOORS, BACK AND SMALLER — owner, 2026-10-03, with a reference: Google,
                // Apple and email as overlapping circles at the end of the row, saying what the
                // tap leads to without a word.
                HStack(spacing: -7) {
                    doorBadge { Image("google-g").resizable().scaledToFit().frame(width: 14, height: 14) }
                    doorBadge { Image(systemName: "apple.logo").font(.system(size: 13, weight: .medium)) }
                    doorBadge { Image(systemName: "envelope").font(.system(size: 11, weight: .medium)) }
                }
                .accessibilityHidden(true)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 16).frame(height: 72)
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    /// One small round badge in the "Add another account" row: the page's own background with a
    /// hairline, so the three overlap cleanly on any appearance.
    private func doorBadge<Icon: View>(@ViewBuilder _ icon: () -> Icon) -> some View {
        icon()
            .foregroundStyle(.primary)
            .frame(width: 28, height: 28)
            .background(Color(.systemBackground), in: Circle())
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
    }

    /// ⛔ ONE TAP, NO QUESTIONS — owner, 2026-09-25. The account's device key first
    /// (`DeviceSessionKeys`); only if there is none, or the server refused it (30 days unused, the
    /// password changed, this phone signed out elsewhere), the account's own door as before.
    private func continueAs(_ info: LastAccount.Info) {
        guard !busy else { return }
        guard NetworkState.shared.isOnline else {
            error = "No internet connection. Check your connection and try again."
            return
        }
        busy = true; error = nil; resumingUid = info.uid
        Task {
            let resumed = await DeviceSessionKeys.resume(uid: info.uid)
            if resumed {
                await AuthService.shared.bootstrap()
                await MainActor.run { busy = false; resumingUid = nil; onAuthed() }
            } else {
                await MainActor.run { busy = false; resumingUid = nil; continueWithDoor(info) }
            }
        }
    }

    private func continueWithDoor(_ info: LastAccount.Info) {
        switch AuthService.SignInMethod(rawValue: info.method) {
        case .apple:
            resumingUid = info.uid
            run {
                let request = ASAuthorizationAppleIDProvider().createRequest()
                AuthService.shared.prepareAppleRequest(request)
                let ceremony = await PasskeyCeremony()   // holds the controller for the length of the sheet
                let auth = try await ceremony.run([request])
                try await AuthService.shared.completeApple(authorization: auth,
                                                           requireExistingAccount: true, requireNewAccount: false)
            }
        case .google:
            resumingUid = info.uid
            run { try await AuthService.shared.signInWithGoogle(requireExistingAccount: true, requireNewAccount: false) }
        case .email:
            emailPrefill = info.email ?? ""
        case .none:
            break
        }
    }

    private func run(_ op: @escaping () async throws -> Void) {
        // One sign-in at a time (audit 2026-09-24). Only the Google button was disabled while busy,
        // so the Apple sheet could be finished on top of a Google sign-in still in flight, and two
        // credentials raced to sign in on the same screen.
        guard !busy else { return }
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
            await MainActor.run { busy = false; resumingUid = nil; spinningDoor = nil }
        }
    }
}

// MARK: - Email door

struct EmailAuthView: View {
    /// State, so "Sign up" / "Sign in" at the bottom flips the page in place (owner's reference).
    @State private var mode: AuthMethodView.Mode
    var onAuthed: () -> Void

    init(mode: AuthMethodView.Mode, prefill: String? = nil, onAuthed: @escaping () -> Void) {
        _mode = State(initialValue: mode)
        _email = State(initialValue: prefill ?? "")
        self.onAuthed = onAuthed
    }

    @State private var email: String
    @State private var password = ""
    /// Sign-up only: the same password again (owner, 2026-09-25, "Passwords match").
    @State private var confirm = ""
    @State private var busy = false
    @State private var error: String?
    @State private var reveal = false

    /// Set when the address still has to be proved with a code, which pushes the code screen instead
    /// of finishing. One optional drives the whole thing through `navigationDestination(item:)`.
    @State private var prove: LoginCodeView.Purpose?
    /// Sign-up only: the server's one-time proof that this person read the code at `email`.
    /// The password step exists only while this is set.
    @State private var signupTicket: String?

    @FocusState private var emailFocused: Bool
    // The password boxes are UITextFields (see RevealablePasswordField), so their focus is plain
    // @State bridged to first responder, not @FocusState (which SwiftUI would reset to nil).
    @State private var passwordFocused = false
    @State private var confirmFocused = false
    /// ⛔ Where the input boxes sit on the page — owner 2026-10-18: tapping Password raised no
    /// keyboard and tapping back to Email did nothing; only the keyboard's arrows moved between
    /// them. The empty-space tap behind the content (ef64b6b4, 10-16) also fired for taps on the
    /// boxes, so a box resigned the moment it took the keyboard. The tap now skips these frames.
    @State private var boxFrames: [String: CGRect] = [:]
    private static let pageSpace = "emailAuthPage"

    /// Sign-up asks ONE thing at a time: the address, then the password. Log in shows both.
    @State private var showPassword = false
    /// The page's height with the keyboard DOWN. The content is at least this tall, so the empty
    /// part catches taps, "Already have an account?" sits at the bottom, and while typing that line
    /// stays behind the keyboard instead of riding up over the address chips.
    @State private var viewportHeight: CGFloat = 0
    /// Set when Continue is pressed on an address that cannot be one. Cleared by the next edit.
    @State private var emailInvalid = false
    /// Sign-up hit an address that already has an account: offer the way in instead of a red line.
    @State private var showTaken = false
    @State private var takenSheetHeight: CGFloat = 260
    private enum TakenChoice { case code, otherEmail }
    @State private var takenChoice: TakenChoice?
    private var onEmailStep: Bool { mode == .create && !showPassword }

    /// The common address endings, offered above the keyboard once a name has been typed.
    private static let domains = ["gmail.com", "yahoo.com", "hotmail.com", "icloud.com", "outlook.com"]
    /// Endings that fit what is typed after the "@". Empty (row hidden) with no name yet, so a
    /// lone "@gmail.com" cannot be made, and once the ending is complete.
    private var domainChips: [String] {
        guard emailFocused else { return [] }
        let t = email.trimmingCharacters(in: .whitespaces)
        let parts = t.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard let name = parts.first, !name.isEmpty else { return [] }
        let typed = parts.count > 1 ? parts[1].lowercased() : ""
        return Self.domains.filter { $0.hasPrefix(typed) && $0 != typed }
    }
    /// A chip REPLACES whatever follows the "@", so two taps never stack two endings.
    private func applyDomain(_ domain: String) {
        let t = email.trimmingCharacters(in: .whitespaces)
        let name = t.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        email = "\(name)@\(domain)"
    }

    /// ⛔ THE FOUR RULES — owner, 2026-09-25: at least 8 characters, a letter, a number, and the two
    /// entries matching, ticked off live. The same `PasswordRules` the Settings password pages use,
    /// so the account's first password and every later one follow one rule.
    private var rules: PasswordRules { PasswordRules(password: password, confirm: confirm) }
    private var canSubmit: Bool {
        !email.isEmpty && !password.isEmpty && (mode == .login || rules.allMet)
    }

    /// Enough of a check to be worth moving on; Firebase decides the rest.
    private var emailLooksValid: Bool {
        let t = email.trimmingCharacters(in: .whitespaces)
        guard let at = t.firstIndex(of: "@"), at != t.startIndex else { return false }
        let domain = t[t.index(after: at)...]
        return domain.contains(".") && !domain.hasSuffix(".") && !domain.contains("@")
    }
    /// Continue is always pressable: a bad address gets a red box and a reason, not a dead button.
    private var primaryEnabled: Bool { onEmailStep ? true : canSubmit }

    private var title: String {
        switch (mode, onEmailStep) {
        // "Log in" everywhere, never "Sign in" beside it (owner, 2026-10-17: the code page said
        // Log In, this page Sign in, and the mail "login code"). Not "Log in to Fariin": the door
        // page right before this one already says that, and the same title twice reads as a loop.
        case (.login, _): return "Log in with email"
        case (.create, true): return "Create account"
        case (.create, false): return "Create a password"
        }
    }
    private var subtitle: String {
        switch (mode, onEmailStep) {
        // No second line on log in: "Sign in to continue" was the stock template line and said nothing.
        case (.login, _): return ""
        // True: sign-up always proves the address with a code (see `submit`).
        case (.create, true): return "We’ll send a verification code to your email."
        case (.create, false): return "Use at least 8 characters, with a letter and a number."
        }
    }

    // ⛔ THE OWNER'S REFERENCE, 2026-09-25: a bold title with one line under it, fields with their
    // glyph inside and no label above, the focused field outlined, a primary button that stays a
    // quiet raised pill until it can be pressed, "Forgot password?", and the other mode as one line.
    var body: some View {
        ZStack {
            AuthPalette.page.ignoresSafeArea()
                .dismissesKeyboardOnTap()
            // Measures the page as if the keyboard were down (see `viewportHeight`).
            Color.clear
                .ignoresSafeArea(.keyboard)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
                .allowsHitTesting(false)
            // owner 2026-10-20: the keyboard hid the password boxes and "Create account". The UIKit
            // boxes cannot tell the ScrollView they took focus, so it is told to bring the button
            // (the bottom of the form) into view once the keyboard is up.
            ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 14) {
                    VStack(spacing: 6) {
                        // The app's own mark first, so the page says whose door it is. Same
                        // artwork as the Home Screen icon (`ShiningLogo`, welcome-mark).
                        ShiningLogo()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                            .padding(.bottom, 14)
                            .accessibilityHidden(true)
                        Text(title)
                            .font(.system(size: 30, weight: .bold)).foregroundStyle(.primary)
                            .multilineTextAlignment(.center)
                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.subheadline).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(.top, 20).padding(.bottom, 12)

                    if mode == .create && showPassword {
                        Button { backToEmail() } label: {
                            HStack(spacing: 8) {
                                Text(email).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                                Text("Change").font(.footnote.weight(.semibold)).foregroundStyle(.primary)
                                Spacer(minLength: 0)
                            }
                            .font(.system(size: 15))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 4)
                    } else {
                        HStack(spacing: 12) {
                            Image(systemName: "envelope").foregroundStyle(.secondary).frame(width: 22)
                            TextField("Email", text: $email)
                                .keyboardType(.emailAddress)
                                // `.username`, not `.emailAddress` (bug hunt 2026-09-25): it is the
                                // login name of the password beside it, which is what Password
                                // AutoFill pairs for "Save Password?" and for filling it back in.
                                .textContentType(.username)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($emailFocused)
                                .submitLabel(.next)
                                .onSubmit {
                                    if mode == .create { advance() }
                                    else { emailFocused = false; passwordFocused = true }
                                }
                                .onChange(of: email) { emailInvalid = false }
                        }
                        .authField(focused: emailFocused, invalid: emailInvalid)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.pageSpace)) }
                            action: { boxFrames["email"] = $0 }

                        if emailInvalid {
                            Text("Enter a correct email address, like name@example.com")
                                .font(.footnote).foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4).padding(.top, -6)
                        }
                    }

                    if !onEmailStep {
                        passwordBox(text: $password, focused: $passwordFocused,
                                    placeholder: "Password",
                                    contentType: mode == .create ? .newPassword : .password,
                                    onSubmit: {
                                        if mode == .create { passwordFocused = false; confirmFocused = true }
                                        else if canSubmit { submit() }
                                    })
                        if mode == .create {
                            passwordBox(text: $confirm, focused: $confirmFocused,
                                        placeholder: "Confirm password",
                                        contentType: .newPassword,
                                        onSubmit: { if canSubmit { submit() } })
                            PasswordChecklist(rules: rules)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4).padding(.top, 2)
                        }
                    }

                    Button {
                        if onEmailStep { advance() } else { submit() }
                    } label: {
                        Group {
                            if busy {
                                BusyArc.small(AuthPalette.page)
                            } else if onEmailStep {
                                Text("Continue")
                            } else {
                                Text(mode == .create ? "Create account" : "Log in")
                            }
                        }
                        .authActionPill(enabled: primaryEnabled || busy)
                    }
                    .buttonStyle(.plain)
                    .disabled(busy || !primaryEnabled)
                    .animation(.easeInOut(duration: 0.15), value: primaryEnabled)
                    .padding(.top, 4)
                    .id("primaryButton")

                    if mode == .login {
                        // The code sign-in lives under Forgot Password (owner, 2026-08-08): six
                        // digits typed here and you are in; setting a new password is optional later.
                        NavigationLink {
                            LoginCodeView(email: email, purpose: .forgot, onAuthed: onAuthed)
                        } label: {
                            Text("Forgot password?")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                        }
                        .padding(.top, 10)
                    }

                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }

                    // The other mode lives at the foot of the page, like large apps' sign-up: next
                    // to the form it pulled the eye off the field and left the bottom half empty.
                    Spacer(minLength: 24)

                    Button { switchMode() } label: {
                        HStack(spacing: 5) {
                            Text(mode == .login ? "Don’t have an account?" : "Already have an account?")
                                .foregroundStyle(.secondary)
                            Text(mode == .login ? "Sign up" : "Log in")
                                .font(.system(size: 17, weight: .semibold)).foregroundStyle(.primary)
                        }
                        .font(.subheadline)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 12)
                }
                .padding(.horizontal, 24)
                // The ScrollView covers the page, so the page's own tap never fires: the empty
                // space has to live inside the scroll content, at least one screen tall.
                .frame(maxWidth: .infinity, minHeight: viewportHeight, alignment: .top)
                .coordinateSpace(.named(Self.pageSpace))
                // (Tap on empty space to close the keyboard: removed, owner 2026-10-18, see
                // `dismissesKeyboardOnTap`.)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)
            // Above the keyboard: the ScrollView ends at the keyboard, so its bottom inset does too.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                let chips = domainChips
                if !chips.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(chips, id: \.self) { d in
                                Button { applyDomain(d) } label: {
                                    Text("@" + d)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .padding(.horizontal, 14).frame(height: 36)
                                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
                                        .contentShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                    .padding(.vertical, 8)
                    .background(AuthPalette.page)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: domainChips)
            .onChange(of: passwordFocused) { revealButton(proxy) }
            .onChange(of: confirmFocused) { revealButton(proxy) }
            }
        }
        // ONE sheet in place of the red "already has an account" line, which came after both
        // passwords and left people to find Log In on their own. The main way in is a code, as a
        // large app's sign-up does: whoever is here was making a new password, so the old one is
        // likely gone. Asked only at Create, never at Continue, so the address box cannot be used
        // to test addresses one by one without also typing a password.
        // The choice runs in onDismiss: a push or a focus change while the sheet is still leaving
        // is dropped or lands under it.
        .sheet(isPresented: $showTaken, onDismiss: {
            let choice = takenChoice
            takenChoice = nil
            switch choice {
            case .code?: prove = .forgot   // the code page sends the code by itself on open
            case .otherEmail?: backToEmail()
            case nil: break
            }
        }) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Are you trying to log in?")
                    .font(.system(size: 24, weight: .bold))
                Text("This email already has an account. We can send a code to it so you can log in.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    takenChoice = .code
                    showTaken = false
                } label: { Text("Log in with a code").authPrimaryPill() }
                .buttonStyle(.plain)
                .padding(.top, 6)
                Button {
                    takenChoice = .otherEmail
                    showTaken = false
                } label: { Text("Use a different email").authSecondaryPill() }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24).padding(.top, 28).padding(.bottom, 12)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { takenSheetHeight = $0 }
            .frame(maxHeight: .infinity, alignment: .top)
            // A little over the measured content, so a rounding gap never clips the last button.
            .presentationDetents([.height(takenSheetHeight + 16)])
            .presentationDragIndicator(.visible)
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // A prefilled address (the saved-account row) goes straight to the password.
            // onAppear runs again when the code page pops; on the password step that focus is
            // `ticketArrived`'s, not the email box's.
            if showPassword { return }
            if mode == .login && !email.isEmpty { passwordFocused = true } else { emailFocused = true }
        }
        // A PUSH, not a sheet: the code screen has to stay put while somebody goes to read their mail.
        .navigationDestination(item: $prove) { purpose in
            LoginCodeView(email: email.trimmingCharacters(in: .whitespaces),
                          purpose: purpose,
                          onAuthed: onAuthed,
                          onTicket: purpose == .newAccount ? { ticketArrived($0) } : nil)
        }
    }

    /// One password box: the lock glyph, the field, and the eye. The field is UIKit so the eye flips
    /// secure entry on the live field and the keyboard never bounces (see RevealablePasswordField).
    private func passwordBox(text: Binding<String>, focused: Binding<Bool>, placeholder: String,
                             contentType: UITextContentType, onSubmit: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "lock").foregroundStyle(.secondary).frame(width: 22)
            RevealablePasswordField(text: text, secure: !reveal, focused: focused,
                                    placeholder: placeholder, contentType: contentType,
                                    onSubmit: onSubmit,
                                    returnKey: (mode == .create && placeholder == "Password") ? .next : .go)
            Button { reveal.toggle() } label: {
                Image(systemName: reveal ? "eye.slash" : "eye")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(reveal ? "Hide password" : "Show password")
        }
        .authField(focused: focused.wrappedValue)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.pageSpace)) }
            action: { boxFrames[placeholder] = $0 }
    }

    /// After the keyboard has finished rising (its inset only exists by then), scroll so the button
    /// under the password boxes is the last thing above the keyboard.
    private func revealButton(_ proxy: ScrollViewProxy) {
        guard passwordFocused || confirmFocused, mode == .create else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("primaryButton", anchor: .bottom) }
        }
    }

    private func switchMode() {
        error = nil
        password = ""; confirm = ""; reveal = false
        withAnimation(.easeInOut(duration: 0.2)) {
            mode = mode == .login ? .create : .login
            showPassword = false
        }
        emailFocused = true
    }

    /// Email step → password step, handing first responder straight over.
    private func advance() {
        error = nil
        // Checked BEFORE trimming: trimming edits `email`, and that edit's onChange would clear the
        // red box straight after it was set. `emailLooksValid` trims for itself.
        guard emailLooksValid else {
            emailInvalid = true
            emailFocused = true
            return
        }
        email = email.trimmingCharacters(in: .whitespaces)
        // CODE FIRST (2026-10-17): the address is proved before the password is even asked for.
        // The code page sends the code itself on open and hands back a ticket (`ticketArrived`).
        emailFocused = false
        prove = .newAccount
    }

    /// The code was right: back from the code page onto the password step, ticket in hand.
    private func ticketArrived(_ ticket: String) {
        signupTicket = ticket
        prove = nil
        withAnimation(.easeInOut(duration: 0.2)) { showPassword = true }
        // After the pop has finished, or the field asks for focus while it is still off screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { passwordFocused = true }
    }

    /// Back to the address. Both passwords are CLEARED: they were made for the address on screen.
    private func backToEmail() {
        error = nil
        signupTicket = nil   // it proves the address on screen, not the next one typed
        password = ""; confirm = ""
        reveal = false
        passwordFocused = false; confirmFocused = false
        withAnimation(.easeInOut(duration: 0.2)) { showPassword = false }
        emailFocused = true
    }

    private func submit() {
        // The keyboard's return key calls this too; one request at a time (audit 2026-09-24).
        guard !busy else { return }
        guard NetworkState.shared.isOnline else {
            error = "No internet connection. Check your connection and try again."
            return
        }
        busy = true; error = nil
        Task {
            do {
                if mode == .create {
                    // The address was proved on the code page before this step appeared, so the
                    // server makes the account already confirmed and there is no code after it.
                    guard let ticket = signupTicket else {
                        await MainActor.run { backToEmail(); busy = false }
                        return
                    }
                    do {
                        try await AuthService.shared.completeSignup(ticket: ticket, password: password)
                    } catch AuthFlowError.signupExpired {
                        // Ticket expired or spent: the only way on is a fresh code.
                        await MainActor.run {
                            backToEmail()
                            self.error = AuthFlowError.signupExpired.errorDescription
                            busy = false
                        }
                        return
                    }
                    await MainActor.run { onAuthed() }
                } else {
                    try await AuthService.shared.signInEmail(email: email.trimmingCharacters(in: .whitespaces),
                                                             password: password)
                    // Accounts that predate proving are fixed here, one sign-in at a time.
                    if await AuthService.shared.emailNeedsProof {
                        await MainActor.run { prove = .unproven }
                    } else {
                        await MainActor.run { onAuthed() }
                    }
                }
            } catch AuthFlowError.emailTaken where mode == .create {
                await MainActor.run {
                    passwordFocused = false; confirmFocused = false
                    showTaken = true
                }
            } catch {
                await MainActor.run { self.error = AuthService.plainMessage(error) }
            }
            await MainActor.run { busy = false }
        }
    }
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
    /// Next on the first of two boxes, Go on the last one.
    var returnKey: UIReturnKeyType = .go

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
        tf.returnKeyType = returnKey
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
        // ⛔ Only when the flag CHANGED (owner 2026-10-20: tapping Confirm password would not take
        // the keyboard). Tapping the second box ends editing in the first, but the first's flag is
        // written back on the next runloop; any SwiftUI update in that gap (a box frame report) saw
        // "focused, but not first responder" and pulled the keyboard back to the first box.
        // `wanted` is only recorded once the field is on screen, so a request made early still lands.
        let c = context.coordinator
        guard focused != c.wanted else { return }
        if focused, !tf.isFirstResponder {
            if tf.window != nil { c.wanted = true; tf.becomeFirstResponder() }
            else { DispatchQueue.main.async { [weak tf] in _ = tf?.becomeFirstResponder() } }
        } else {
            c.wanted = focused
            if !focused, tf.isFirstResponder { tf.resignFirstResponder() }
        }
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
        /// The focus flag as last acted on, so only a CHANGE moves the keyboard (see updateUIView).
        var wanted = false
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
