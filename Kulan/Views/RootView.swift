import SwiftUI
import LocalAuthentication
import UIKit

struct RootView: View {
    enum Phase { case loading, welcome, onboarding, main }
    @State private var phase: Phase = .loading
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appLockEnabled") private var lockEnabled = false
    @AppStorage("appLockDelay") private var lockDelay = 0   // grace period (seconds) before re-locking
    @AppStorage("screenSecurity") private var screenSecurity = false
    @State private var locked = false
    @State private var backgroundedAt: Date?

    var body: some View {
        ZStack {
            Theme.bg(scheme == .dark).ignoresSafeArea()
            switch phase {
            case .loading:
                // Static branded launch screen (no spinner) — matches the native iOS launch
                // screen so boot feels instant, like other chat apps. No "loading" UI.
                Text("Kulan").font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
            case .welcome:
                // Signed out → the front door (Apple / Google / email). After any door
                // succeeds, route() decides onboarding (new account) vs main (returning).
                WelcomeView(onAuthed: { Task { await route() } },
                            onDemo: { phase = .main })
            case .onboarding:
                OnboardingView { phase = .main }
            case .main:
                // Root-level call container so an active call (full screen or top mini
                // bar) lives above every screen and survives all navigation.
                CallContainer {
                    MainShell(onSignOut: { Task { await route() } })
                }
            }

            // Screen security: blank the app preview in the app switcher.
            if screenSecurity && scenePhase != .active && !locked {
                Theme.bg(scheme == .dark).ignoresSafeArea()
                    .overlay(Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary))
            }
            // App Lock overlay.
            if locked { LockScreen { authenticate() } }
        }
        .task { await route() }
        // PREVIEW ONLY (Debug builds — Appetize): a fresh preview account is empty, so seed a demo
        // story once we reach the main app, so the Story feature (and the viewers swipe) is testable
        // in the browser. Stripped from TestFlight/App Store (Release), so real users never see it.
        .onChange(of: phase) { _, new in
            #if DEBUG
            if new == .main && !DemoMode.active { Task { await seedPreviewStoryIfNeeded() } }
            #endif
        }
        .onAppear { if lockEnabled { locked = true; authenticate() } }
        .onChange(of: scenePhase) { _, new in
            if new == .background {
                backgroundedAt = Date()
                if lockEnabled, lockDelay == 0 { locked = true }   // immediate lock
            }
            if new == .active {
                // Re-lock only if Kulan was in the background longer than the grace period.
                if lockEnabled, !locked, let t = backgroundedAt,
                   lockDelay > 0, Date().timeIntervalSince(t) >= Double(lockDelay) {
                    locked = true
                }
                backgroundedAt = nil
                if locked { authenticate() }
            }
        }
    }

    private func authenticate() {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            locked = false; return   // no passcode/biometrics set up — don't lock the user out
        }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Kulan") { ok, _ in
            DispatchQueue.main.async { if ok { locked = false } }
        }
    }

    private func route() async {
        phase = .loading
        await AuthService.shared.bootstrap()   // adopts an existing session, creates nothing
        // Signed out (fresh install, or after sign-out) → the account doors. Existing
        // anonymous testers still have their session, so they never see this screen.
        guard AuthService.shared.isSignedIn else {
            phase = .welcome
            return
        }
        // Returning user: boot INSTANTLY from the on-disk cache (the WhatsApp model).
        // Launch must never wait on the network — offline, each awaited server call
        // below stalls ~10s on its timeout (a measured 11s cold start). ensureReady
        // is Keychain-only now, so the whole fast path is local.
        if await ProfileStore.shared.loadCachedMine() {
            try? await Crypto.shared.ensureReady()
            Push.register(); Push.saveVoipToken()
            phase = .main
            Task {   // background refresh + key self-heal, off the boot path
                await ProfileStore.shared.loadMine()
                await Crypto.shared.publishPublicKey()
            }
            return
        }
        // First run (nothing cached yet): the original network path decides
        // onboarding vs main, and publishes the key once the profile doc exists —
        // self-heals accounts that failed to publish on a first launch (otherwise
        // others can never message them: "hasn't set up encryption yet").
        try? await Crypto.shared.ensureReady()
        await ProfileStore.shared.loadMine()
        await Crypto.shared.publishPublicKey()
        let ready = ProfileStore.shared.me?.handle.isEmpty == false
        if ready { Push.register(); Push.saveVoipToken() }   // notifications + VoIP token now that we're signed in
        phase = ready ? .main : .onboarding
    }

    #if DEBUG
    // Seed one demo story on a fresh PREVIEW account (Appetize) so the app isn't empty and the Story
    // viewer / swipe-up can be tried. Debug-only: never compiled into the Release (TestFlight/App Store) build.
    private func seedPreviewStoryIfNeeded() async {
        await StoriesRepository.shared.load(force: true)
        guard StoriesRepository.shared.mine?.stories.isEmpty ?? true else { return }   // seed once
        guard let data = Self.makeDemoStoryImage() else { return }
        StoriesService.shared.postStoryBackground(image: data, caption: "Demo story — swipe up to see viewers")
    }

    private static func makeDemoStoryImage() -> Data? {
        let size = CGSize(width: 1080, height: 1920)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            let cg = ctx.cgContext
            let colors = [UIColor.systemPurple.cgColor, UIColor.systemBlue.cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                cg.drawLinearGradient(g, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            let text = "Demo\nStory" as NSString
            let p = NSMutableParagraphStyle(); p.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: UIColor.white,
                .font: UIFont.systemFont(ofSize: 140, weight: .heavy),
                .paragraphStyle: p,
            ]
            text.draw(in: CGRect(x: 0, y: size.height/2 - 180, width: size.width, height: 400), withAttributes: attrs)
        }
        return img.jpegData(compressionQuality: 0.85)
    }
    #endif
}

// Full-screen lock shown when App Lock is on.
struct LockScreen: View {
    var onUnlock: () -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            Theme.bg(scheme == .dark).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.fill").font(.system(size: 44)).foregroundStyle(.secondary)
                Text("Kulan is locked").font(.headline)
                Button { onUnlock() } label: {
                    Label("Unlock", systemImage: "faceid").font(.body.weight(.semibold))
                        .padding(.horizontal, 24).frame(height: 48)
                        .background(Color.accentColor, in: Capsule()).foregroundStyle(.white)
                }
            }
        }
    }
}

struct OnboardingView: View {
    var onDone: () -> Void
    @State private var name = ""
    @State private var handle = ""
    @State private var saving = false
    @State private var error: String?
    private enum Field { case name, handle }
    @FocusState private var focus: Field?

    // Live username validity (client-side only — the taken/not check runs on Continue).
    private var handleValid: Bool { ChatService.isValidHandle(ChatService.sanitizeHandle(handle)) }
    private var canContinue: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && handleValid && !saving
    }

    var body: some View {
        // Matches the dark sign-up flow this screen follows (the old light Form was a jarring
        // hand-off from the black Welcome/Apple/Google/Email screens).
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    Spacer().frame(height: 24)

                    // Live avatar preview: their initials + hashed color, exactly how they'll appear
                    // to everyone else. Fills in as they type, so the profile feels theirs immediately.
                    AvatarView(name: name.isEmpty ? "?" : name, size: 96)
                        .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                        .animation(.easeOut(duration: 0.2), value: name)

                    Text("Create your profile")
                        .font(.system(size: 27, weight: .heavy)).foregroundStyle(.white)
                        .padding(.top, 18)
                    Text("This is how people will find and know you on Kulan.")
                        .font(.subheadline).foregroundStyle(Color(white: 0.55))
                        .multilineTextAlignment(.center)
                        .padding(.top, 5).padding(.horizontal, 24)

                    VStack(spacing: 14) {
                        field("YOUR NAME") {
                            TextField("", text: $name,
                                      prompt: Text("e.g. Amina Yusuf").foregroundStyle(Color(white: 0.35)))
                                .textInputAutocapitalization(.words)
                                .focused($focus, equals: .name)
                                .submitLabel(.next)
                                .onSubmit { focus = .handle }
                        }

                        field("USERNAME", accessory: {
                            // Inline validity tick, so the rules are felt rather than read.
                            if !handle.isEmpty {
                                Image(systemName: handleValid ? "checkmark.circle.fill" : "circle.dashed")
                                    .foregroundStyle(handleValid ? Color.green : Color(white: 0.45))
                                    .font(.system(size: 17))
                            }
                        }) {
                            HStack(spacing: 2) {
                                Text("@").foregroundStyle(Color(white: 0.45))
                                TextField("", text: $handle,
                                          prompt: Text("username").foregroundStyle(Color(white: 0.35)))
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .focused($focus, equals: .handle)
                                    .submitLabel(.done)
                                    .onChange(of: handle) { _, v in
                                        let clean = ChatService.sanitizeHandle(v)
                                        if clean != v { handle = clean }
                                    }
                            }
                        }

                        Text("Letters, numbers and _ only, 3–30 characters.")   // matches Limits.usernameMaxChars
                            .font(.caption).foregroundStyle(Color(white: 0.4))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.top, 26)

                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.top, 14)
                    }

                    Spacer(minLength: 28)

                    Button {
                        Task { await save() }
                    } label: {
                        Group {
                            if saving {
                                ProgressView().tint(.black)
                            } else {
                                Text("Continue").font(.system(size: 18, weight: .bold)).foregroundStyle(.black)
                            }
                        }
                        .frame(maxWidth: .infinity).frame(height: 54)
                        .background(.white, in: Capsule())
                    }
                    .disabled(!canContinue)
                    .opacity(canContinue ? 1 : 0.5)
                    .animation(.easeOut(duration: 0.15), value: canContinue)

                    // App Store Guideline 1.2: users must agree to the terms (which
                    // include a zero-tolerance policy for objectionable content and
                    // abusive users) before they can post content. Links open in Safari.
                    Text("By tapping Continue you agree to Kulan's [Terms](https://kulan-2ef85.web.app/terms.html) and [Privacy Policy](https://kulan-2ef85.web.app/privacy.html). Kulan has zero tolerance for objectionable content or abusive behavior.")
                        .font(.caption2)
                        .foregroundStyle(Color(white: 0.42))
                        .multilineTextAlignment(.center)
                        .tint(Color(white: 0.75))
                        .padding(.top, 14)
                    #if DEBUG
                    Text("Preview: type **apple** in either field, then Continue, to load a demo account.")
                        .font(.caption2).foregroundStyle(.blue).multilineTextAlignment(.center)
                        .padding(.top, 8)
                    #endif
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            // Apple hands over the person's name exactly once, at first authorization —
            // prefill it so they just pick a username.
            if name.isEmpty, let n = AuthService.shared.pendingDisplayName { name = n }
        }
    }

    // Dark labelled field box, same shape language as the email sign-up screen.
    private func field<C: View, A: View>(_ label: String,
                                         @ViewBuilder accessory: () -> A = { EmptyView() },
                                         @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.caption2.weight(.bold)).foregroundStyle(Color(white: 0.5))
                .tracking(0.6)
            HStack(spacing: 8) {
                content()
                    .font(.system(size: 17))
                    .foregroundStyle(.white)
                accessory()
            }
            .padding(.horizontal, 16).frame(height: 54)
            .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func save() async {
        #if DEBUG
        // Preview demo login (Appetize): "apple" loads a fully-local demo account (stories + chats)
        // with no Firebase, so the app can be tried where Storage uploads don't work. Debug-only.
        // Accept it in EITHER field (name or username), trimmed — so a wrong-field tap still works.
        let nameTrim = name.trimmingCharacters(in: .whitespaces).lowercased()
        if handle.lowercased() == "apple" || nameTrim == "apple" {
            // Firebase-free demo: DemoMode.activate() sets AuthService.shared.uid itself.
            await MainActor.run { DemoMode.activate(); onDone() }
            return
        }
        #endif
        let n = name.trimmingCharacters(in: .whitespaces)
        let h = ChatService.sanitizeHandle(handle)
        guard !n.isEmpty else { error = "Enter your name"; return }
        guard ChatService.isValidHandle(h) else {
            error = "Username: letters, numbers and _ only, 3–30 characters"; return   // matches Limits.usernameMaxChars
        }
        saving = true; error = nil
        do {
            if let existing = await ChatService.findByHandle(h), existing.id != AuthService.shared.uid {
                error = "That username is taken"; saving = false; return
            }
            try await ProfileStore.shared.updateProfile(name: n, handle: h)
            await Crypto.shared.publishPublicKey()   // doc now exists — ensure key is live
            onDone()
        } catch {
            self.error = "Could not save: \(error.localizedDescription)"
        }
        saving = false
    }
}
