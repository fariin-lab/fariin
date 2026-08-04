import SwiftUI
import LocalAuthentication
import UIKit

struct RootView: View {
    // Equatable must be DECLARED now: Swift synthesises it automatically only for enums with no
    // associated values, and `.restore` added two. onChange(of: phase) depends on it.
    enum Phase: Equatable { case loading, welcome, onboarding, main, restore(handle: String, due: Date) }
    @State private var phase: Phase = .loading
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appLockEnabled") private var lockEnabled = false
    @AppStorage("appLockDelay") private var lockDelay = 0   // grace period (seconds) before re-locking
    @AppStorage("screenSecurity") private var screenSecurity = false
    @State private var locked = false
    @State private var backgroundedAt: Date?
    // Someone signed this phone out from Settings › Devices on another phone.
    @ObservedObject private var devices = DeviceRegistry.shared
    @State private var showRevokedNotice = false

    var body: some View {
        ZStack {
            Theme.bg(scheme == .dark).ignoresSafeArea()
            switch phase {
            case .loading:
                // Static branded launch screen (no spinner) — matches the native iOS launch
                // screen so boot feels instant, like other chat apps. No "loading" UI.
                Text("Fariin").font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
            case .welcome:
                // Signed out → the front door (Apple / Google / email). After any door
                // succeeds, route() decides onboarding (new account) vs main (returning).
                WelcomeView(onAuthed: { Task { await route() } },
                            onDemo: { phase = .main })
            case .onboarding:
                OnboardingView { phase = .main }
            case .restore(let handle, let due):
                // A scheduled-for-deletion account cannot enter the app: it is hidden from everyone
                // else, so being half-inside it would be worse than either choice. Restore or finish.
                RestoreAccountView(handle: handle, scheduledFor: due,
                                   onRestored: { Task { await route() } },
                                   onDeletedNow: { Task { await route() } })
            case .main:
                // Root-level call container so an active call (full screen or top mini
                // bar) lives above every screen and survives all navigation.
                CallContainer {
                    MainShell(onSignOut: { Task { await route() } })
                }
                // Our own message banner, mounted once here so it rides above every screen. It sits
                // UNDER the call screen on purpose: a call already owns the whole display.
                .inAppBanner()
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
        // Remote sign-out: our own device record was deleted from another phone. Same teardown
        // as tapping Sign Out here, then back to the front door with a word about why.
        .onChange(of: devices.revoked) { _, revoked in
            guard revoked else { return }
            Task {
                await DeviceRegistry.shared.performRevokedSignOut()
                await route()
                showRevokedNotice = true
            }
        }
        .alert("Signed out", isPresented: $showRevokedNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This device was signed out from another device.")
        }
        .onChange(of: scenePhase) { _, new in
            if new == .background {
                backgroundedAt = Date()
                if lockEnabled, lockDelay == 0 { locked = true }   // immediate lock
            }
            if new == .active {
                // Re-lock only if Fariin was in the background longer than the grace period.
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
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Fariin") { ok, _ in
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
        // Returning user: boot INSTANTLY from the on-disk cache (the the reference app model).
        // Launch must never wait on the network — offline, each awaited server call
        // below stalls ~10s on its timeout (a measured 11s cold start). ensureReady
        // is Keychain-only now, so the whole fast path is local.
        if await ProfileStore.shared.loadCachedMine() {
            // Deliberately re-checked from the SERVER before using the cache: the deletion may have
            // been scheduled on another device, and the cached copy would happily let them in.
            if let due = await ProfileStore.shared.scheduledDeletionDate() {
                phase = .restore(handle: ProfileStore.shared.me?.handle ?? "", due: due)
                return
            }
            try? await Crypto.shared.ensureReady()
            Push.register(); Push.saveVoipToken()
            DeviceRegistry.shared.start()   // record this phone in Settings › Devices, and watch for a remote sign-out
            phase = .main
            Task {   // background refresh + key self-heal, off the boot path
                await ProfileStore.shared.loadMine()
                await Crypto.shared.publishPublicKey()
                // Send anything an app kill left queued, whatever chat it belongs to — the queue's
                // own contract. Until now it only re-drove when that exact chat was reopened.
                await SendQueue.drainAll()
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
        if let due = ProfileStore.shared.me?.deletionScheduledFor, due > Date() {
            phase = .restore(handle: ProfileStore.shared.me?.handle ?? "", due: due)
            return
        }
        let ready = ProfileStore.shared.me?.handle.isEmpty == false
        if ready {
            Push.register(); Push.saveVoipToken()   // notifications + VoIP token now that we're signed in
            DeviceRegistry.shared.start()
            Task { await SendQueue.drainAll() }   // queued sends from a previous run (see drainAll)
        }
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
                Text("Fariin is locked").font(.headline)
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

    /// WHAT THE TICK MEANS. It used to mean "the format is legal", and it was drawn green, so a
    /// username somebody else already owns showed a confident green tick — and only after tapping
    /// Continue did the screen say "That username is taken". The tick promised something it had
    /// never checked.
    ///
    /// ON THE PRIVACY OF ASKING. Checking live means asking the server "does @x exist" as somebody
    /// types, which is an enumeration oracle if handle existence is a secret. Here it is not, and
    /// that was verified rather than assumed: ChatService.findByHandle already lets any signed-in
    /// person resolve any handle, which is how @search, the QR scanner and invite links work, and
    /// the users document carries no email and no phone — name, handle, about, photo, public key,
    /// privacy settings. So resolving a handle reveals a profile and nothing behind it, exactly as
    /// on the reference app, X or the reference app where usernames are public by design. This adds no new door.
    /// It does make scraping the namespace easier, and that exposure already exists via @search;
    /// real rate limiting would mean routing every lookup through a Cloud Function and paying a
    /// round trip on all of them. Worth writing down, not worth doing before launch.
    enum HandleState: Equatable { case empty, invalid, checking, free, taken }

    @State private var handleState: HandleState = .empty
    @State private var checkTask: Task<Void, Never>?

    private var canContinue: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && handleState == .free && !saving
    }

    /// Debounced so it is one read per PAUSE rather than one per keystroke. The previous task is
    /// cancelled on every change, so a fast typist produces exactly one query, not eight.
    private func scheduleHandleCheck() {
        checkTask?.cancel()
        let h = ChatService.sanitizeHandle(handle)
        guard !h.isEmpty else { handleState = .empty; return }
        guard ChatService.isValidHandle(h) else { handleState = .invalid; return }

        handleState = .checking
        checkTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            let found = await ChatService.findByHandle(h)
            guard !Task.isCancelled else { return }
            // Still typing? A late answer about an older string must not overwrite a newer one.
            guard ChatService.sanitizeHandle(handle) == h else { return }
            // Your own handle is not "taken" from your point of view.
            let mine = found?.id == AuthService.shared.uid
            await MainActor.run { handleState = (found == nil || mine) ? .free : .taken }
        }
    }

    var body: some View {
        // Last step of the sign-up flow, so it wears the flow's skin: pinned light, same
        // palette and pills as Welcome/Apple/Google/Email (see AuthFlowViews).
        ZStack {
            AuthPalette.page.ignoresSafeArea()
                .dismissesKeyboardOnTap()
            ScrollView {
                VStack(spacing: 0) {
                    Spacer().frame(height: 24)

                    // Live avatar preview: their initials + hashed color, exactly how they'll appear
                    // to everyone else. Fills in as they type, so the profile feels theirs immediately.
                    AvatarView(name: name.isEmpty ? "?" : name, size: 84)
                        .overlay(Circle().strokeBorder(AuthPalette.hairline, lineWidth: 1))
                        .animation(.easeOut(duration: 0.2), value: name)

                    Text("Create your profile")
                        .font(.system(size: 23, weight: .bold)).foregroundStyle(.primary)
                        .padding(.top, 16)
                    Text("This is how people will find and know you on Fariin.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 5).padding(.horizontal, 24)

                    VStack(spacing: 14) {
                        field("YOUR NAME") {
                            TextField("", text: $name,
                                      prompt: Text("e.g. Amina Yusuf").foregroundStyle(.tertiary))
                                .textInputAutocapitalization(.words)
                                .focused($focus, equals: .name)
                                .submitLabel(.next)
                                .onSubmit { focus = .handle }
                        }

                        field("USERNAME", accessory: {
                            // The tick now means AVAILABLE, which is what everybody already thought
                            // it meant. Monochrome: this flow has no colour in it but the avatar,
                            // and the shapes carry the meaning without needing any.
                            switch handleState {
                            case .empty:
                                EmptyView()
                            case .invalid:
                                Image(systemName: "circle.dashed")
                                    .foregroundStyle(.secondary).font(.system(size: 17))
                            case .checking:
                                ProgressView().controlSize(.small)
                            case .free:
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.primary).font(.system(size: 17))
                            case .taken:
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red).font(.system(size: 17))
                            }
                        }) {
                            HStack(spacing: 2) {
                                Text("@").foregroundStyle(.secondary)
                                TextField("", text: $handle,
                                          prompt: Text("username").foregroundStyle(.tertiary))
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .focused($focus, equals: .handle)
                                    .submitLabel(.done)
                                    .onChange(of: handle) { _, v in
                                        let clean = ChatService.sanitizeHandle(v)
                                        if clean != v { handle = clean }
                                        scheduleHandleCheck()
                                    }
                            }
                        }

                        // ONE line that answers whatever the current question is, rather than a
                        // fixed rule plus a separate error appearing somewhere else after a tap.
                        Group {
                            switch handleState {
                            case .taken:
                                Text("@\(ChatService.sanitizeHandle(handle)) is taken. Try adding a number.")
                                    .foregroundStyle(.red)
                            case .free:
                                Text("@\(ChatService.sanitizeHandle(handle)) is available.")
                                    .foregroundStyle(.primary)
                            case .checking:
                                Text("Checking…").foregroundStyle(.secondary)
                            case .empty, .invalid:
                                Text("Letters, numbers and _ only, 3–30 characters.")   // matches Limits.usernameMaxChars
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .animation(.easeInOut(duration: 0.15), value: handleState)
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
                                ProgressView().tint(AuthPalette.page)   // spinner reads on the filled pill
                            } else {
                                Text("Continue")
                            }
                        }
                        .authPrimaryPill()
                    }
                    .disabled(!canContinue)
                    .opacity(canContinue ? 1 : 0.5)
                    .animation(.easeOut(duration: 0.15), value: canContinue)

                    // App Store Guideline 1.2: users must agree to the terms (which
                    // include a zero-tolerance policy for objectionable content and
                    // abusive users) before they can post content. Links open in Safari.
                    Text("By tapping Continue you agree to Fariin's [Terms](https://fariin.com/terms) and [Privacy Policy](https://fariin.com/privacy). Fariin has zero tolerance for objectionable content or abusive behavior.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .tint(.primary)
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
        .onAppear {
            // Apple hands over the person's name exactly once, at first authorization —
            // prefill it so they just pick a username.
            if name.isEmpty, let n = AuthService.shared.pendingDisplayName { name = n }
        }
    }

    // Labelled field box, same shape language as the email sign-up screen.
    private func field<C: View, A: View>(_ label: String,
                                         @ViewBuilder accessory: () -> A = { EmptyView() },
                                         @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                .tracking(0.6)
            HStack(spacing: 8) {
                content()
                    .font(.system(size: 17))
                    .foregroundStyle(.primary)
                accessory()
            }
            .padding(.horizontal, 16).frame(height: 50)
            .background(AuthPalette.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
            // NO PRE-CHECK ANY MORE. There used to be a findByHandle query here to catch somebody
            // claiming the name in the seconds between the tick appearing and Continue being
            // pressed — a real race, but a query can never close it, because two clients can both
            // read "free" in the same millisecond. `claimUsername` settles it in ONE transaction on
            // the server, so the query was buying a nicer sentence at the cost of a round trip and
            // a false sense that it was the thing deciding.
            try await ProfileStore.shared.updateProfile(name: n, handle: h)
            await Crypto.shared.publishPublicKey()   // doc now exists — ensure key is live
            onDone()
        } catch {
            // The server's own words when it has any — "Sorry, this username is already taken." reads
            // as an answer; "Could not save: ..." reads as the app breaking.
            let msg = error.localizedDescription
            self.error = msg.contains("username") || msg.contains("Username") ? msg : "Could not save: \(msg)"
        }
        saving = false
    }
}
