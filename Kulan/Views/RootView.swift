import SwiftUI
import LocalAuthentication
import UIKit

struct RootView: View {
    enum Phase { case loading, onboarding, main }
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
        await AuthService.shared.bootstrap()
        try? await Crypto.shared.ensureReady()
        await ProfileStore.shared.loadMine()
        // Re-publish the public key now that the profile doc exists — self-heals
        // accounts that failed to publish on a first launch (otherwise others can
        // never message them: "hasn't set up encryption yet").
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

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Your name", text: $name)
                        .textInputAutocapitalization(.words)
                    HStack(spacing: 1) {
                        Text("@").foregroundStyle(.secondary)
                        TextField("Username", text: $handle)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .onChange(of: handle) { _, v in
                                let clean = ChatService.sanitizeHandle(v)
                                if clean != v { handle = clean }
                            }
                    }
                } header: {
                    Text("Create your profile")
                } footer: {
                    Text("Username: letters, numbers and _ only, 3–24 characters.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Welcome to Kulan")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    Button {
                        Task { await save() }
                    } label: {
                        if saving {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Continue").fontWeight(.semibold).frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(saving)

                    // App Store Guideline 1.2: users must agree to the terms (which
                    // include a zero-tolerance policy for objectionable content and
                    // abusive users) before they can post content. Links open in Safari.
                    Text("By tapping Continue you agree to Kulan's [Terms](https://kulan-2ef85.web.app/terms.html) and [Privacy Policy](https://kulan-2ef85.web.app/privacy.html). Kulan has zero tolerance for objectionable content or abusive behavior.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .tint(.primary)
                    #if DEBUG
                    Text("Preview: type **apple** in either field, then Continue, to load a demo account.")
                        .font(.caption2).foregroundStyle(.blue).multilineTextAlignment(.center)
                    #endif
                }
                .padding()
            }
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
            error = "Username: letters, numbers and _ only, 3–24 characters"; return
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
