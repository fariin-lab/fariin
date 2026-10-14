import SwiftUI
import FirebaseAuth

// ⛔ SECURITY CHECKUP — owner, 2026-10-14, from the Devices page: "check passkey, chat key, where
// you're logged in and password; green tick only when it is really set up; tap a missing one and go
// straight to the page that sets it up; when you come back the tick updates by itself".
//
// The model, from the reference messenger's reminders (PIN, backup key, inactive and new linked
// devices): each check asks the SOURCE OF TRUTH every time rather than a remembered flag, each item
// opens the one screen that fixes it, and coming back from that screen asks again. Four rules hold
// here because getting them wrong is worse than having no checkup:
//   1. A tick is only ever drawn from a server answer that said "yes".
//   2. A check that could not be answered is "Couldn't check", never a tick and never "missing".
//   3. Checks run side by side; one slow answer does not hold up the other three.
//   4. A refresh keeps the last answer on screen until the new one lands, so rows never flash.

@MainActor @Observable
final class SecurityCheckup {
    enum Status: Equatable {
        case checking
        case done(String)       // verified; the line under the title
        case missing            // verified absent
        case failed             // the question could not be answered
    }

    var passkey: Status = .checking
    var chatKey: Status = .checking
    var password: Status = .checking
    var devices: Status = .checking
    /// Other devices signed in since the last review, for the "missing" line.
    private(set) var unreviewedCount = 0
    private var running = false

    func run() async {
        guard !running else { return }
        running = true
        defer { running = false }
        async let a = Self.checkPasskey()
        async let b = Self.checkChatKey()
        async let c = Self.checkPassword()
        async let d = Self.checkDevices()
        passkey = await a
        chatKey = await b
        password = await c
        let (status, count) = await d
        devices = status
        unreviewedCount = count
    }

    private static func date(_ d: Date) -> String {
        d.formatted(.dateTime.day().month(.abbreviated).year())
    }

    /// `listPasskeys` is the same server call the Passkeys page draws from.
    private static func checkPasskey() async -> Status {
        guard let d = try? await AccountCall.run("listPasskeys") else { return .failed }
        let list = d["passkeys"] as? [[String: Any]] ?? []
        guard !list.isEmpty else { return .missing }
        let newest = list.compactMap { $0["createdAt"] as? Double }.max()
            .map { Date(timeIntervalSince1970: $0 / 1000) }
        let count = list.count == 1 ? "1 passkey" : "\(list.count) passkeys"
        return .done(newest.map { "\(count) · added \(date($0))" } ?? count)
    }

    /// `chatPinStatus` on the server; nil from `refreshStatus` means it did not answer in time.
    private static func checkChatKey() async -> Status {
        guard let set = await ChatPin.refreshStatus() else { return .failed }
        guard set else { return .missing }
        return .done(ChatPin.lastSetAt.map { "Updated \(date($0))" } ?? "Set")
    }

    /// The account's sign-in methods, reloaded from the server first: a cached user can still list
    /// a password that was removed on another device. Firebase does not tell an app when a password
    /// was last changed, so there is no date to show and none is invented.
    private static func checkPassword() async -> Status {
        guard let user = Auth.auth().currentUser else { return .failed }
        do { try await user.reload() } catch { return .failed }
        let auth = AuthService.shared
        return auth.isConnected(.email) && !auth.passwordIsOnRelay ? .done("Set") : .missing
    }

    /// The device list straight from the server (`fetchOnce` reads with `source: .server`). Every
    /// other device signed in after the last review counts as unreviewed.
    private static func checkDevices() async -> (Status, Int) {
        guard let list = try? await DeviceRegistry.shared.fetchOnce() else { return (.failed, 0) }
        let others = list.filter { !$0.isThisDevice }
        let reviewed = reviewedAt()
        let unreviewed = others.filter { s in
            guard let reviewed else { return true }
            return (s.createdAt ?? .distantFuture) > reviewed
        }
        if !unreviewed.isEmpty { return (.missing, unreviewed.count) }
        let total = list.count == 1 ? "Only this device" : "\(list.count) devices"
        guard let reviewed else { return (.done(total), 0) }
        return (.done("\(total) · reviewed \(reviewed.formatted(.relative(presentation: .named)))"), 0)
    }

    // MARK: Device review

    private static func reviewKey() -> String? {
        Auth.auth().currentUser.map { "security.devicesReviewedAt.\($0.uid)" }
    }
    static func reviewedAt() -> Date? {
        guard let k = reviewKey() else { return nil }
        return UserDefaults.standard.object(forKey: k) as? Date
    }
    /// Looking at the device list is the review: called when the checkup sends you to it.
    static func markDevicesReviewed() {
        guard let k = reviewKey() else { return }
        UserDefaults.standard.set(Date(), forKey: k)
    }
}

struct SecurityCheckupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var check = SecurityCheckup()
    @State private var path: [Item] = []
    private var profile = ProfileStore.shared

    enum Item: Hashable { case passkey, chatKey, password }

    private struct Entry: Identifiable {
        let id: String
        let title: String
        let missingTitle: String
        let why: String
        let status: SecurityCheckup.Status
        let open: () -> Void
    }

    private var entries: [Entry] {
        let passwordSet = check.password != .missing
        return [
            Entry(id: "passkey", title: "Passkey", missingTitle: "Create a passkey",
                  why: "Sign in with Face ID. There is no password for anyone to steal.",
                  status: check.passkey, open: { path.append(.passkey) }),
            Entry(id: "password", title: "Password",
                  missingTitle: passwordSet ? "Password" : "Set a password",
                  why: "A password lets you sign in again if you lose this phone.",
                  status: check.password, open: { path.append(.password) }),
            Entry(id: "devices", title: "Where you're signed in",
                  missingTitle: check.unreviewedCount == 1 ? "Review 1 new device"
                                                           : "Review \(check.unreviewedCount) new devices",
                  why: "Make sure you recognise every device signed in to your account.",
                  status: check.devices, open: {
                      // The list is on the page behind this sheet; going there IS the review.
                      SecurityCheckup.markDevicesReviewed()
                      dismiss()
                  }),
            Entry(id: "chatKey", title: "Chat Key", missingTitle: "Set a Chat Key",
                  why: "People who know your Chat Key can start a chat with you.",
                  status: check.chatKey, open: { path.append(.chatKey) }),
        ]
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    let missing = entries.filter { $0.status == .missing }
                    let failed = entries.filter { $0.status == .failed }
                    let rest = entries.filter { $0.status != .missing && $0.status != .failed }

                    if !missing.isEmpty {
                        section(nil, footer: "Set these up to keep your account safe if your phone is lost or someone learns your password.") {
                            ForEach(missing) { e in
                                row(icon: "exclamationmark.circle", tint: .blue,
                                    title: e.missingTitle, subtitle: e.why, action: e.open)
                                if e.id != missing.last?.id { divider }
                            }
                        }
                    }
                    if !failed.isEmpty {
                        section("Couldn't check", footer: nil) {
                            ForEach(failed) { e in
                                row(icon: "exclamationmark.triangle", tint: .orange,
                                    title: e.title, subtitle: "Check your connection and try again.",
                                    action: { Task { await check.run() } })
                                if e.id != failed.last?.id { divider }
                            }
                        }
                    }
                    if !rest.isEmpty {
                        section(missing.isEmpty && failed.isEmpty ? "Everything is set up" : "Set up",
                                footer: nil) {
                            ForEach(rest) { e in
                                if case .done(let line) = e.status {
                                    row(icon: "checkmark.circle", tint: .green,
                                        title: e.title, subtitle: line, action: e.open)
                                } else {
                                    row(icon: nil, tint: .secondary,
                                        title: e.title, subtitle: "Checking…", action: nil)
                                }
                                if e.id != rest.last?.id { divider }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 28)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom) {
                Button { dismiss() } label: {
                    Text("Continue")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Color.blue, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .background(Color(.systemGroupedBackground))
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Item.self) { item in
                switch item {
                case .passkey: PasskeysView()
                case .chatKey: ChatPinPage()
                case .password:
                    PasswordView(address: AuthService.shared.passwordAddress ?? "",
                                 isFirstPassword: check.password == .missing)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task { await check.run() }
        // Back from a setup page: ask again, so the tick follows what was just done.
        .onChange(of: path) { _, now in
            if now.isEmpty { Task { await check.run() } }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await check.run() } }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            AvatarView(name: profile.me?.name ?? "", photoUrl: profile.me?.photoUrl, size: 96)
            Text("Security Checkup").font(.title2.weight(.bold))
            Text("We checked your account against the server just now.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Divider().padding(.leading, 54)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String?, footer: String?,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.title3.weight(.bold)).padding(.horizontal, 4)
            }
            VStack(spacing: 0) { content() }
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            if let footer {
                Text(footer).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 16)
            }
        }
    }

    private func row(icon: String?, tint: Color, title: String, subtitle: String,
                     action: (() -> Void)?) -> some View {
        Button { action?() } label: {
            HStack(spacing: 14) {
                Group {
                    if let icon {
                        Image(systemName: icon).font(.system(size: 22, weight: .regular)).foregroundStyle(tint)
                    } else {
                        ProgressView()
                    }
                }
                .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body).foregroundStyle(.primary)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }
}
