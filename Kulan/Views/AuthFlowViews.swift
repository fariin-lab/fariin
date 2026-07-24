import SwiftUI
import AuthenticationServices

// The front door (user decision 2026-07-24: DARK, Discord skeleton, our skin).
// Welcome → Create Account / Log In → Apple / Google / Email → onboarding (name,
// @username) for new accounts, straight in for returning ones. Always dark: the
// chrome logo was born on black.
struct WelcomeView: View {
    var onAuthed: () -> Void
    var onDemo: () -> Void = {}   // Appetize preview: straight to main, no routing

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                greetingWall
                VStack(spacing: 0) {
                    Spacer()
                    ShiningLogo()
                        .frame(width: 140, height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                    Text("Welcome to Kulan")
                        .font(.system(size: 32, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.top, 28)
                    Text("Private chats, calls and stories.\nMade for Somalis everywhere.")
                        .font(.system(size: 16))
                        .foregroundStyle(Color(white: 0.62))
                        .multilineTextAlignment(.center)
                        .padding(.top, 10)
                    Spacer()
                    Spacer()
                    VStack(spacing: 12) {
                        NavigationLink { AuthMethodView(mode: .create, onAuthed: onAuthed) } label: {
                            Text("Create Account")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity).frame(height: 54)
                                .background(.white, in: Capsule())
                        }
                        NavigationLink { AuthMethodView(mode: .login, onAuthed: onAuthed) } label: {
                            Text("Log In")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity).frame(height: 54)
                                .background(Color(white: 0.14), in: Capsule())
                        }
                        #if DEBUG
                        // Appetize preview: a Firebase-free local demo account. Debug-only.
                        Button("Preview demo") {
                            DemoMode.activate()
                            onDemo()
                        }
                        .font(.caption)
                        .foregroundStyle(Color(white: 0.4))
                        .padding(.top, 2)
                        #endif
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    // Our personality move: faint Somali greetings drifting in the dark, ours alone.
    private var greetingWall: some View {
        VStack(spacing: 44) {
            ForEach(Array(["Salaam", "Nabad", "Iska warran", "Maalin wanaagsan", "Soo dhawoow"].enumerated()),
                    id: \.offset) { i, word in
                Text(word)
                    .font(.system(size: 34, weight: .heavy))
                    .foregroundStyle(Color(white: 0.10))
                    .frame(maxWidth: .infinity, alignment: i.isMultiple(of: 2) ? .leading : .trailing)
                    .padding(.horizontal, 20)
            }
        }
        .rotationEffect(.degrees(-8))
        .allowsHitTesting(false)
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

    @State private var busy = false
    @State private var error: String?

    private var title: String { mode == .create ? "Create Account" : "Log In" }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 14) {
                Spacer()
                Text(title)
                    .font(.system(size: 28, weight: .heavy)).foregroundStyle(.white)
                Text(mode == .create ? "Pick a door. Takes less than a minute."
                                     : "Welcome back.")
                    .font(.subheadline).foregroundStyle(Color(white: 0.6))
                Spacer()

                SignInWithAppleButton(mode == .create ? .signUp : .signIn) { request in
                    AuthService.shared.prepareAppleRequest(request)
                } onCompletion: { result in
                    switch result {
                    case .success(let auth):
                        run { try await AuthService.shared.completeApple(authorization: auth) }
                    case .failure:
                        break   // user cancelled the sheet — not an error worth showing
                    }
                }
                .signInWithAppleButtonStyle(.white)
                .frame(height: 54)
                .clipShape(Capsule())

                Button {
                    run { try await AuthService.shared.signInWithGoogle() }
                } label: {
                    HStack(spacing: 8) {
                        Text("G").font(.system(size: 20, weight: .bold))
                        Text("Continue with Google").font(.system(size: 18, weight: .semibold))
                    }
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity).frame(height: 54)
                    .background(.white, in: Capsule())
                }
                .disabled(busy)

                NavigationLink { EmailAuthView(mode: mode, onAuthed: onAuthed) } label: {
                    Text(mode == .create ? "Sign up with Email" : "Log in with Email")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 54)
                        .background(Color(white: 0.14), in: Capsule())
                }

                if busy { ProgressView().tint(.white).padding(.top, 6) }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                        .multilineTextAlignment(.center).padding(.top, 4)
                }

                if mode == .create {
                    Text("By continuing you agree to Kulan's [Terms](https://kulan-2ef85.web.app/terms.html) and [Privacy Policy](https://kulan-2ef85.web.app/privacy.html).")
                        .font(.caption2).foregroundStyle(Color(white: 0.5))
                        .multilineTextAlignment(.center).tint(Color(white: 0.75))
                        .padding(.top, 10)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
        }
        .preferredColorScheme(.dark)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func run(_ op: @escaping () async throws -> Void) {
        busy = true; error = nil
        Task {
            do {
                try await op()
                await MainActor.run { onAuthed() }
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
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
            Color.black.ignoresSafeArea()
            VStack(spacing: 14) {
                Spacer().frame(height: 40)
                Text(mode == .create ? "Sign up with Email" : "Log in with Email")
                    .font(.system(size: 26, weight: .heavy)).foregroundStyle(.white)

                field("Email") {
                    TextField("", text: $email, prompt: Text("you@example.com").foregroundStyle(Color(white: 0.4)))
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus)
                }
                field("Password") {
                    SecureField("", text: $password, prompt: Text(mode == .create ? "At least 6 characters" : "Your password").foregroundStyle(Color(white: 0.4)))
                        .textContentType(mode == .create ? .newPassword : .password)
                }

                Button {
                    submit()
                } label: {
                    if busy {
                        ProgressView().tint(.black).frame(maxWidth: .infinity).frame(height: 54)
                            .background(.white, in: Capsule())
                    } else {
                        Text(mode == .create ? "Create Account" : "Log In")
                            .font(.system(size: 18, weight: .bold)).foregroundStyle(.black)
                            .frame(maxWidth: .infinity).frame(height: 54)
                            .background(.white, in: Capsule())
                    }
                }
                .disabled(busy || email.isEmpty || password.isEmpty)
                .opacity(email.isEmpty || password.isEmpty ? 0.55 : 1)

                if mode == .login {
                    Button(resetSent ? "Reset email sent — check your inbox" : "Forgot password?") {
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
                    .foregroundStyle(resetSent ? Color.green : Color(white: 0.6))
                    .disabled(resetSent)
                }

                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
        }
        .preferredColorScheme(.dark)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focus = true }
    }

    private func field<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(Color(white: 0.55))
            content()
                .font(.system(size: 17))
                .foregroundStyle(.white)
                .padding(.horizontal, 16).frame(height: 52)
                .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func submit() {
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
        case 17007: return "That email already has an account. Try logging in."
        case 17020: return "No internet connection. Try again."
        default: return error.localizedDescription
        }
    }
}
