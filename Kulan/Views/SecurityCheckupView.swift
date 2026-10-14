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
    var unreviewedCount: Int { unreviewed.count }
    /// Those devices themselves, for the "Is this you?" page.
    private(set) var unreviewed: [DeviceSession] = []
    private var running = false

    func run() async {
        guard !running else { return }
        running = true
        rerun = false
        async let a = Self.checkPasskey()
        async let b = Self.checkChatKey()
        async let c = Self.checkPassword()
        async let d = Self.checkDevices()
        passkey = await a
        chatKey = await b
        password = await c
        let (status, list) = await d
        // A Yes that landed while this was in flight wins over this older answer; ask again.
        if !rerun {
            devices = status
            unreviewed = list
        }
        running = false
        if rerun { await run() }
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
    ///
    /// ⛔ BY DEVICE, NOT BY CLOCK — owner 2026-10-14: "I tap Yes, these are mine and it is still not
    /// verified". A record written by an older build has no `createdAt`, which counted as signed in
    /// in the future, so no review time could ever cover it. A device is reviewed once its id has
    /// been confirmed; the review time only answers for ids from before this list existed.
    private static func checkDevices() async -> (Status, [DeviceSession]) {
        guard let list = try? await DeviceRegistry.shared.fetchOnce() else { return (.failed, []) }
        let others = list.filter { !$0.isThisDevice }
        let reviewed = reviewedAt()
        let confirmed = reviewedIds()
        let unreviewed = others.filter { s in
            if confirmed.contains(s.id) { return false }
            guard let reviewed, let created = s.createdAt else { return true }
            return created > reviewed
        }
        if !unreviewed.isEmpty { return (.missing, unreviewed) }
        let total = list.count == 1 ? "Only this device" : "\(list.count) devices"
        guard let reviewed else { return (.done(total), []) }
        return (.done("\(total) · reviewed \(reviewed.formatted(.relative(presentation: .named)))"), [])
    }

    // MARK: Device review

    private static func reviewKey() -> String? {
        Auth.auth().currentUser.map { "security.devicesReviewedAt.\($0.uid)" }
    }
    static func reviewedAt() -> Date? {
        guard let k = reviewKey() else { return nil }
        return UserDefaults.standard.object(forKey: k) as? Date
    }
    private static func idsKey() -> String? {
        Auth.auth().currentUser.map { "security.devicesReviewedIds.\($0.uid)" }
    }
    private static func reviewedIds() -> Set<String> {
        guard let k = idsKey() else { return [] }
        return Set(UserDefaults.standard.stringArray(forKey: k) ?? [])
    }

    /// The owner answered "Yes, these are mine": those devices are confirmed by id, and the row turns
    /// green NOW rather than after the next server answer (a check already in flight would otherwise
    /// land with the list from before the Yes). `run()` then asks the server again.
    func confirmDevices() {
        guard let k = Self.idsKey(), let t = Self.reviewKey() else { return }
        let ids = Self.reviewedIds().union(unreviewed.map(\.id))
        UserDefaults.standard.set(Array(ids), forKey: k)
        UserDefaults.standard.set(Date(), forKey: t)
        unreviewed = []
        devices = .done("Reviewed just now")
        rerun = true
    }
    private var rerun = false
}

struct SecurityCheckupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var check: SecurityCheckup
    @State private var open: Item?
    /// ⛔ ONE SHEET, ALREADY ANSWERED — owner 2026-10-14: "it has two sheets, the loading one and the
    /// first one". It opened on four "Checking…" rows and then re-laid itself out (and resized) when
    /// the answers came. The Devices page now runs the check BEFORE presenting and hands it in here.
    init(check: SecurityCheckup) { _check = State(initialValue: check) }
    @State private var detent: PresentationDetent = .height(SecurityCheckupSheet.lastContentH + 68)
    @State private var contentH: CGFloat = 0
    /// Content + the Continue bar (8 + 52 + 8). A sheet height leaves out the bottom safe area, so
    /// it is not added. 0.8 of the screen until the content has been measured once.
    /// The last measured content height on this phone, so the sheet PRESENTS at nearly its final
    /// height: presenting at 0.8 of the screen and switching to the measured height a frame later
    /// changed the detents mid-slide and cut the slide-up short (owner 2026-10-14: "the sheet is not
    /// coming from the bottom, make it Apple style"). 640 until measured once.
    private static var lastContentH: CGFloat = 640
    private var fitDetent: PresentationDetent {
        .height((contentH > 0 ? contentH : Self.lastContentH) + 68)
    }
    private var profile = ProfileStore.shared

    enum Item: Hashable, Identifiable {
        case passkey, chatKey, password, devices
        var id: Self { self }
    }

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
                  status: check.passkey, open: { open = .passkey }),
            Entry(id: "password", title: "Password",
                  missingTitle: passwordSet ? "Password" : "Set a password",
                  why: "A password lets you sign in again if you lose this phone.",
                  status: check.password, open: { open = .password }),
            Entry(id: "devices", title: "Where you're signed in",
                  missingTitle: check.unreviewedCount == 1 ? "Review 1 new device"
                                                           : "Review \(check.unreviewedCount) new devices",
                  why: "Make sure you recognise every device signed in to your account.",
                  status: check.devices, open: {
                      // ⛔ THE OWNER SAYS YES — owner 2026-10-14: "how does a user say I am sure".
                      // New devices open an "Is this you?" page (the reference app's new-login
                      // question); only its Yes marks them reviewed. A tick row has nothing new to
                      // confirm, so it goes to the full list behind this sheet.
                      if check.unreviewed.isEmpty { dismiss() } else { open = .devices }
                  }),
            Entry(id: "chatKey", title: "Chat Key", missingTitle: "Set a Chat Key",
                  why: "People who know your Chat Key can start a chat with you.",
                  status: check.chatKey, open: { open = .chatKey }),
        ]
    }

    var body: some View {
        NavigationStack {
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
                        // "Everything is set up" only once nothing is still being checked.
                        section(rest.contains { $0.status == .checking } ? "Checking your account…"
                                : missing.isEmpty && failed.isEmpty ? "Everything is set up" : "Set up",
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
                // The sheet is sized to this (see `fitDetent`), so it shows everything without a scroll.
                .background(
                    GeometryReader { g in
                        Color.clear
                            .onAppear { contentH = g.size.height; Self.lastContentH = g.size.height }
                            .onChange(of: g.size.height) { _, h in contentH = h; Self.lastContentH = h }
                    }
                )
            }
            .scrollBounceBehavior(.basedOnSize)   // it fits, so it does not wobble or show a scroll bar
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
        }
        // ⛔ FROM THE BOTTOM, NOT THE RIGHT — owner 2026-10-14: "page is coming right side, make it
        // coming bottom". Each setup page is its own sheet over the checkup (it used to be pushed
        // inside it), with its own bar and an X, and its own dismiss() closes just that sheet.
        .sheet(item: $open, onDismiss: { Task { await check.run() } }) { item in
            NavigationStack {
                Group {
                    switch item {
                    case .passkey: PasskeysView()
                    case .chatKey: ChatPinPage()
                    case .password:
                        PasswordView(address: AuthService.shared.passwordAddress ?? "",
                                     isFirstPassword: check.password == .missing)
                    case .devices:
                        DeviceReviewPage(devices: check.unreviewed,
                                         onYes: {
                                             check.confirmDevices()
                                             open = nil   // back to the checkup, which asks again
                                         },
                                         onNo: {
                                             // The Devices page is behind the checkup: close both.
                                             open = nil
                                             dismiss()
                                         })
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        // A plain button: the bar draws the glass circle itself. `CloseXButton`
                        // brought a second circle of its own, so the X wore two rings (owner
                        // 2026-10-14, "two duplicate X buttons").
                        Button { open = nil } label: {
                            Image(systemName: "xmark").font(.system(size: 17, weight: .semibold))
                        }
                    }
                }
            }
            .presentationDragIndicator(.visible)
        }
        // ⛔ TALL ENOUGH FOR EVERYTHING — owner 2026-10-14: at 70% the last rows needed a scroll;
        // "always show all of it". The sheet is the content's own height (rows + Continue), never
        // taller than the screen allows. ONE height: with a second, taller stop the sheet could be
        // dragged up and the Continue bar was left floating mid-sheet (owner's screenshot).
        // ⛔ FROM THE VERY BOTTOM — owner 2026-10-14, twice: "it comes from the centre, make it come
        // from the bottom". On iOS 26 a sheet shorter than the screen floats, inset from the bottom
        // and sides, so it rises from mid-screen. Only the full-height detent is joined to the bottom
        // edge. One fixed height also means the sheet can never resize under the reader.
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task { await check.run() }
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

/// "Is this you?" for devices that signed in since the last review: the reference app's new-login
/// question. Yes marks them reviewed; No goes to the Devices page, where any of them can be signed out.
private struct DeviceReviewPage: View {
    let devices: [DeviceSession]
    let onYes: () -> Void
    let onNo: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Text(devices.count == 1 ? "Is this you?" : "Are these you?")
                        .font(.title2.weight(.bold))
                    Text(devices.count == 1
                         ? "This device signed in to your account. Check that you recognise it."
                         : "These devices signed in to your account. Check that you recognise each one.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                VStack(spacing: 0) {
                    ForEach(devices) { d in
                        HStack(spacing: 14) {
                            DeviceTile(session: d, size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.displayName).font(.body.weight(.semibold))
                                Text(detail(d)).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        if d.id != devices.last?.id { Divider().padding(.leading, 70) }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            }
            .padding(.horizontal, 16)
            .padding(.top, 28)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 4) {
                Button(action: onYes) {
                    Text(devices.count == 1 ? "Yes, it's me" : "Yes, these are mine")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Color.blue, in: Capsule())
                }
                .buttonStyle(.plain)
                Button(action: onNo) {
                    Text("No, it's not me")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .background(Color(.systemGroupedBackground))
        }
    }

    /// "Kampala, Uganda · signed in 3 days ago"; the place is left out until the server has one.
    private func detail(_ d: DeviceSession) -> String {
        let when = d.createdAt.map { "signed in \($0.formatted(.relative(presentation: .named)))" } ?? "signed in"
        return d.location.isEmpty ? when.prefix(1).uppercased() + when.dropFirst() : "\(d.location) · \(when)"
    }
}
