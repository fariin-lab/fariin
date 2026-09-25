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
    @State private var passkeyBusy = false
    @State private var passkeyError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                AuthPalette.page.ignoresSafeArea()
                VStack(spacing: 0) {
                    Spacer()
                    ShiningLogo()
                        .frame(width: 108, height: 108)
                        .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
                    // "Sign in", not "Welcome": the first-run agreement screen right before this one
                    // already says "Welcome to Fariin", and the same title twice in a row read as a
                    // loop (2026-09-24).
                    Text("Sign in to Fariin")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.primary)
                        .padding(.top, 22)
                    Text("Private chats, calls and stories.\nMade for Somalis everywhere.")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                    // ⛔ THE PASSKEY DOOR, ASKED FOR — owner, 2026-09-25. The automatic offer below
                    // only appears when this phone already holds a Fariin passkey; this link opens the
                    // system passkey sheet on request, including a passkey on another device.
                    Button { Task { await passkeyLogin() } } label: {
                        HStack(spacing: 6) {
                            if passkeyBusy { ProgressView().controlSize(.small) }
                            Text("Log in using Passkey")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(passkeyBusy)
                    .padding(.top, 10)
                    if let passkeyError {
                        Text(passkeyError).font(.footnote).foregroundStyle(.red)
                            .multilineTextAlignment(.center).padding(.horizontal, 24)
                    }
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
            .task { await offerPasskey() }
        }
    }

    /// The link's passkey sign-in: the full system sheet (not `immediateOnly`). A cancel says nothing.
    private func passkeyLogin() async {
        guard !passkeyBusy else { return }
        guard NetworkState.shared.isOnline else {
            passkeyError = "No internet connection. Check your connection and try again."
            return
        }
        passkeyBusy = true; passkeyError = nil
        defer { passkeyBusy = false }
        do {
            try await Passkeys.signIn(immediateOnly: false)
        } catch {
            if !AuthService.isCancellation(error) {
                passkeyError = "Couldn't sign in with a passkey. Try again or use another way to log in."
            }
            return
        }
        await AuthService.shared.bootstrap()
        AuthService.shared.reportLogin()
        onAuthed()
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

    /// The email pages' main button: the light pill once it can be pressed, a raised grey pill with
    /// dim text until then (the reference's disabled look, not a faded copy of the enabled one).
    func authActionPill(enabled: Bool) -> some View {
        self.font(.system(size: 17, weight: .semibold))
            .foregroundStyle(enabled ? AuthPalette.page : Color.primary.opacity(0.3))
            .frame(maxWidth: .infinity).frame(height: 54)
            .background(enabled ? Color.primary : AuthPalette.raised, in: Capsule())
    }

    /// A field box on the email pages: its glyph inside, no label above, outlined while focused.
    func authField(focused: Bool) -> some View {
        self.font(.system(size: 17))
            .foregroundStyle(.primary)
            .padding(.horizontal, 18).frame(height: 56)
            .background(AuthPalette.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(focused ? 0.75 : 0), lineWidth: 1.2))
            .animation(.easeOut(duration: 0.15), value: focused)
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

    init(mode: Mode, onAuthed: @escaping () -> Void) {
        _mode = State(initialValue: mode)
        self.onAuthed = onAuthed
    }

    @Environment(\.colorScheme) private var scheme
    @State private var busy = false
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
                    VStack(spacing: 16) {
                        ForEach(saved) { savedAccountRow($0) }
                        addAnotherAccountRow
                    }
                    orDivider.padding(.top, 36)
                } else {
                Text("Fariin")
                    .font(.system(size: 22, weight: .semibold)).foregroundStyle(.primary)
                    .padding(.bottom, 28)

                VStack(spacing: 14) {
                    appleButton
                    Button {
                        run { try await AuthService.shared.signInWithGoogle(requireExistingAccount: mode == .login,
                                                                            requireNewAccount: mode == .create) }
                    } label: {
                        Label(title: { Text("Continue with Google") }, icon: { GoogleGIcon(size: 20) })
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
                ProgressView().padding(.top, 16).opacity(busy ? 1 : 0)
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
                .padding(.top, accountsFace ? 24 : 36)

                Spacer()
                Text("By continuing, you agree to our [Terms of Service](https://fariin.com/terms) and [Privacy Policy](https://fariin.com/privacy).")
                    .font(.footnote).foregroundStyle(.secondary)
                    .tint(.primary)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 8)
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
                    Text(info.name.isEmpty ? "@\(info.handle)" : info.name)
                        .font(.body.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                    Text("@\(info.handle)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
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

    /// "Add another account", with the ways in drawn small on the right (Google, Apple, email), as in
    /// his design. Opens the usual doors on this same page.
    private var addAnotherAccountRow: some View {
        Button {
            error = nil
            withAnimation(.easeInOut(duration: 0.2)) { showDoors = true }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 48)
                Text("Add another account")
                    .font(.body.weight(.medium))
                Spacer(minLength: 8)
                HStack(spacing: -6) {
                    doorBadge { GoogleGIcon(size: 15) }
                    doorBadge { Image(systemName: "apple.logo").font(.system(size: 14)) }
                    doorBadge { Image(systemName: "envelope").font(.system(size: 13)) }
                }
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

    private func doorBadge<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .frame(width: 30, height: 30)
            .background(AuthPalette.raised, in: Circle())
            .overlay(Circle().strokeBorder(AuthPalette.page, lineWidth: 2))
    }

    private func continueAs(_ info: LastAccount.Info) {
        switch AuthService.SignInMethod(rawValue: info.method) {
        case .apple:
            run {
                let request = ASAuthorizationAppleIDProvider().createRequest()
                AuthService.shared.prepareAppleRequest(request)
                let ceremony = await PasskeyCeremony()   // holds the controller for the length of the sheet
                let auth = try await ceremony.run([request])
                try await AuthService.shared.completeApple(authorization: auth,
                                                           requireExistingAccount: true, requireNewAccount: false)
            }
        case .google:
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
            await MainActor.run { busy = false }
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

    @FocusState private var emailFocused: Bool
    // The password boxes are UITextFields (see RevealablePasswordField), so their focus is plain
    // @State bridged to first responder, not @FocusState (which SwiftUI would reset to nil).
    @State private var passwordFocused = false
    @State private var confirmFocused = false

    /// Sign-up asks ONE thing at a time: the address, then the password. Log in shows both.
    @State private var showPassword = false
    private var onEmailStep: Bool { mode == .create && !showPassword }

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
    private var primaryEnabled: Bool { onEmailStep ? emailLooksValid : canSubmit }

    private var title: String {
        switch (mode, onEmailStep) {
        case (.login, _): return "Welcome back"
        case (.create, true): return "Create account"
        case (.create, false): return "Create a password"
        }
    }
    private var subtitle: String {
        switch (mode, onEmailStep) {
        case (.login, _): return "Sign in to continue"
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
            ScrollView {
                VStack(spacing: 14) {
                    VStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 30, weight: .bold)).foregroundStyle(.primary)
                        Text(subtitle)
                            .font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 36).padding(.bottom, 12)

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
                                .textContentType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($emailFocused)
                                .submitLabel(.next)
                                .onSubmit {
                                    if mode == .create { if emailLooksValid { advance() } }
                                    else { emailFocused = false; passwordFocused = true }
                                }
                        }
                        .authField(focused: emailFocused)
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
                                ProgressView().tint(AuthPalette.page)
                            } else if onEmailStep {
                                Text("Continue")
                            } else {
                                Text(mode == .create ? "Create account" : "Sign in")
                            }
                        }
                        .authActionPill(enabled: primaryEnabled || busy)
                    }
                    .buttonStyle(.plain)
                    .disabled(busy || !primaryEnabled)
                    .animation(.easeInOut(duration: 0.15), value: primaryEnabled)
                    .padding(.top, 4)

                    if mode == .login {
                        // The code sign-in lives under Forgot Password (owner, 2026-08-08): six
                        // digits typed here and you are in; setting a new password is optional later.
                        NavigationLink {
                            LoginCodeView(email: email, purpose: .forgot, onAuthed: onAuthed)
                        } label: {
                            Text("Forgot password?")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 10)
                    }

                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }

                    Button { switchMode() } label: {
                        HStack(spacing: 5) {
                            Text(mode == .login ? "Don’t have an account?" : "Already have an account?")
                                .foregroundStyle(.secondary)
                            Text(mode == .login ? "Sign up" : "Sign in")
                                .font(.system(size: 17, weight: .semibold)).foregroundStyle(.primary)
                        }
                        .font(.subheadline)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 24)
                }
                .padding(.horizontal, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // A prefilled address (the saved-account row) goes straight to the password.
            if mode == .login && !email.isEmpty { passwordFocused = true } else { emailFocused = true }
        }
        // A PUSH, not a sheet: the code screen has to stay put while somebody goes to read their mail.
        .navigationDestination(item: $prove) { purpose in
            LoginCodeView(email: email.trimmingCharacters(in: .whitespaces),
                          purpose: purpose,
                          onAuthed: onAuthed)
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
                                    onSubmit: onSubmit)
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
        email = email.trimmingCharacters(in: .whitespaces)
        withAnimation(.easeInOut(duration: 0.2)) { showPassword = true }
        passwordFocused = true
    }

    /// Back to the address. Both passwords are CLEARED: they were made for the address on screen.
    private func backToEmail() {
        error = nil
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
                    try await AuthService.shared.createEmailAccount(email: email.trimmingCharacters(in: .whitespaces),
                                                                    password: password)
                    // SIGN-UP ALWAYS PROVES THE ADDRESS with a code before the account is any use.
                    // NOT `onAuthed()`: RootView waits for this callback, so the code screen gets its turn.
                    await MainActor.run { prove = .signUp }
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
