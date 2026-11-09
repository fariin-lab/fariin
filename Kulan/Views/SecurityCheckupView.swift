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

//
// ⛔ ONE CHECK, KEPT READY — owner 2026-10-15: "scan in the background whenever the user changes a
// setting; when I tap Security Checkup show the latest results at once, no new scan, no spinner".
// Before, every visit to Devices built a fresh, empty check and the sheet ran a second one on open,
// so the rows could start on "Checking…". Now there is one per app run (`shared`); a change to a
// passkey, password, Chat Key or device marks it stale (`settingChanged()`) and one scan runs a
// moment later, however many changes came in that moment. An answer is only shown when its scan
// was not overtaken by a newer change, and nothing runs while the app is in the background (the
// calls would fail there and read as "Couldn't check"); it runs when the app is back.
@MainActor @Observable
final class SecurityCheckup {
    static let shared = SecurityCheckup()

    /// A finished, clean scan younger than this is shown as it is; opening the sheet asks nothing.
    private static let freshFor: TimeInterval = 5 * 60
    /// When the last scan finished with every answer in, and for which account.
    private(set) var lastCompleted: Date?
    private var scannedUid: String?
    /// Bumped by every setting change; an answer from a scan started before it is not shown.
    private var generation = 0
    private var stale = false
    private var debounce: Task<Void, Never>?
    private var waitingForActive = false

    private init() {
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let c = SecurityCheckup.shared
                if c.waitingForActive { c.waitingForActive = false; c.start() }
            }
        }
    }

    /// Something the checkup reads just changed (called from the places that change it). Callable
    /// from anywhere; the scan itself starts after a short pause so a burst of changes costs one.
    nonisolated static func settingChanged() {
        Task { @MainActor in shared.markStale() }
    }

    private func markStale() {
        generation &+= 1
        stale = true
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            start()
        }
    }

    /// Scan only when there is no recent clean answer: never scanned, a setting changed, a check
    /// failed, another account signed in, or the answer is older than `freshFor`.
    func refreshIfStale() {
        if scannedUid != Auth.auth().currentUser?.uid { resetForNewAccount() }
        let failed = [passkey, chatKey, password, devices].contains(.failed)
        let old = lastCompleted.map { Date().timeIntervalSince($0) > Self.freshFor } ?? true
        guard stale || failed || old else { return }
        debounce?.cancel()
        start()
    }

    private func resetForNewAccount() {
        scannedUid = Auth.auth().currentUser?.uid
        passkey = .checking; chatKey = .checking; password = .checking; devices = .checking
        unreviewed = []
        lastCompleted = nil
        generation &+= 1
    }

    /// Background-safe start: in the background the scan waits for the app to come back.
    private func start() {
        guard UIApplication.shared.applicationState == .active else { waitingForActive = true; return }
        Task { await run() }
    }
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
    /// When each check's answer last landed ("passkey", "password", "devices", "chatKey"). The
    /// sheet's scan (owner 2026-11-09) turns a row only once ITS answer from this scan is in.
    private(set) var answered: [String: Date] = [:]

    /// A real scan now, for the sheet's live check: waits for one already running, then asks again.
    func scanNow() async {
        if scannedUid != Auth.auth().currentUser?.uid { resetForNewAccount() }
        while running { try? await Task.sleep(for: .milliseconds(60)) }
        await run()
    }

    func run() async {
        guard !running else { return }
        if scannedUid != Auth.auth().currentUser?.uid { resetForNewAccount() }
        running = true
        rerun = false
        stale = false
        let gen = generation
        // An answer is shown only if no setting changed since this scan began (it would describe
        // the account before the change) and the app is still in front (a call cut off by the
        // background fails, and that failure says nothing about the account).
        var allLanded = true
        let usable = { (s: Status) -> Bool in
            let ok = gen == self.generation
                && (s != .failed || UIApplication.shared.applicationState == .active)
            if !ok { allLanded = false }
            return ok
        }
        async let a = Self.checkPasskey()
        async let b = Self.checkChatKey()
        async let c = Self.checkPassword()
        async let d = Self.checkDevices()
        let pa = await a; if usable(pa) { passkey = pa; answered["passkey"] = Date() }
        let ck = await b; if usable(ck) { chatKey = ck; answered["chatKey"] = Date() }
        let pw = await c; if usable(pw) { password = pw; answered["password"] = Date() }
        let (status, list) = await d
        // A Yes that landed while this was in flight wins over this older answer; ask again.
        if usable(status), !rerun {
            devices = status
            unreviewed = list
            answered["devices"] = Date()
        }
        // "Checked just now" only for a scan where every answer landed and was shown.
        let clean = allLanded && !rerun
            && ![passkey, chatKey, password, devices].contains { $0 == .checking || $0 == .failed }
        if clean { lastCompleted = Date() }
        running = false
        if UIApplication.shared.applicationState != .active { waitingForActive = true; return }
        if rerun || gen != generation { await run() }
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
        stale = true
    }
    private var rerun = false
}

struct SecurityCheckupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var check: SecurityCheckup
    @State private var open: Item?
    // ⛔ THE LIVE SCAN — owner 2026-11-09 ("make it like banks: tap, it scans, then shows what you
    // did well or what is missing"), approved on the Pixel first. This REVERSES 2026-10-15's "show
    // the latest results at once, no spinner". Every open asks the server again (`scanNow`); a row
    // turns only when its own answer from this scan has landed. The only addition is pacing: rows
    // at least 280 ms apart, the first at 450 ms, the whole scan at least 1.5 s.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed: [String] = []     // rows on screen during the scan, in order
    @State private var resolved: Set<String> = []  // rows whose fresh answer is in
    @State private var finishing = false           // the ring is closing
    @State private var ringClose: CGFloat = 0
    @State private var ringShown = true
    @State private var badge = false
    @State private var settled = false             // the final grouped layout is up
    @State private var scanned = false             // one scan per presentation
    /// ⛔ ONE SHEET, ALREADY ANSWERED — owner 2026-10-14: "it has two sheets, the loading one and the
    /// first one". It opened on four "Checking…" rows and then re-laid itself out (and resized) when
    /// the answers came. The Devices page now runs the check BEFORE presenting and hands it in here.
    init(check: SecurityCheckup) { _check = State(initialValue: check) }
    private func close() { dismiss() }
    /// ⛔ ONE HEIGHT FOR THE WHOLE PRESENTATION — owner 2026-10-15: "a small sheet appears in the
    /// centre, a second later another, long one; make it come like the device sheet". The device sheet
    /// has one fixed detent and slides up once. This one opened at a guess and then replaced its detent
    /// set with the measured height; a detent set that changes while the sheet is presenting makes iOS
    /// fall back to full height for a moment. Now the height is fixed when the sheet is made, from the
    /// last measurement kept on this phone, and a new measurement only serves the NEXT open.
    private let openHeight: CGFloat = SecurityCheckupSheet.lastContentH + 68
    /// Content + the Continue bar (8 + 52 + 8). A sheet height leaves out the bottom safe area, so
    /// it is not added. 0.8 of the screen until the content has been measured once.
    /// The last measured content height on this phone, so the sheet PRESENTS at nearly its final
    /// height: presenting at 0.8 of the screen and switching to the measured height a frame later
    /// changed the detents mid-slide and cut the slide-up short (owner 2026-10-14: "the sheet is not
    /// coming from the bottom, make it Apple style"). 640 until measured once.
    /// Kept across launches, so even the first open after a relaunch presents at its real height.
    private static var lastContentH: CGFloat {
        get { let v = UserDefaults.standard.double(forKey: "securityCheckup.contentH"); return v > 0 ? v : 640 }
        set { UserDefaults.standard.set(Double(newValue), forKey: "securityCheckup.contentH") }
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
                      if check.unreviewed.isEmpty { close() } else { open = .devices }
                  }),
            Entry(id: "chatKey", title: "Chat Key", missingTitle: "Set a Chat Key",
                  why: "People who know your Chat Key can start a chat with you.",
                  status: check.chatKey, open: { open = .chatKey }),
        ]
        // owner 2026-10-18: no Chat Key row while the admin panel hides the Chat Key (MsgPolicy).
        .filter { $0.id != "chatKey" || MsgPolicy.shared.chatKeyVisible }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    // ⛔ ONE CARD, ONE ORDER, BEFORE AND AFTER (owner 2026-11-09, second Pixel video):
                    // regrouping at the end read as the whole list jumping, crossfade or not. The list
                    // the scan builds IS the result; a blue "!" marks what is missing. At the end only
                    // the note, the safety link and Continue fade in below it.
                    scanCard
                    if settled { settledTail.transition(.opacity) }
                }
                .padding(.horizontal, 16)
                .padding(.top, 28)
                .padding(.bottom, 24)
                // Measured for the NEXT open (see `openHeight`): an open sheet never changes height.
                // Only the settled layout is measured: it is the height the sheet must hold.
                .background(
                    GeometryReader { g in
                        Color.clear
                            .onChange(of: g.size.height) { _, h in if settled { Self.lastContentH = h } }
                            .onChange(of: settled) { _, s in if s { Self.lastContentH = g.size.height } }
                    }
                )
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)   // it fits, so it does not wobble or show a scroll bar
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom) {
                Button { close() } label: {
                    Text("Done")   // owner 2026-11-09: it closes back to Devices, nothing continues
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.onFariinAction)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Color.fariinAction, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!settled)
                .opacity(settled ? 1 : 0.4)
                .animation(.easeOut(duration: 0.2), value: settled)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .background(Color(.systemGroupedBackground))
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .modifier(SubSheets(open: $open, check: check, close: close))
        .presentationDetents([.height(openHeight)])
        .presentationDragIndicator(.visible)
        .task {
            guard !scanned else { check.refreshIfStale(); return }
            scanned = true
            await runScan()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, settled { check.refreshIfStale() }
        }
    }

    // MARK: The scan

    /// During the scan: one card, the rows in a fixed order, each sliding in and turning when its
    /// answer lands.
    private var scanCard: some View {
        VStack(spacing: 0) {
            ForEach(entries.filter { revealed.contains($0.id) }) { e in
                scanRow(e)
                    .transition(.offset(y: 8).combined(with: .opacity))
                if e.id != revealed.last { divider }
            }
        }
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .opacity(revealed.isEmpty ? 0 : 1)
    }

    @ViewBuilder private func scanRow(_ e: Entry) -> some View {
        if resolved.contains(e.id) {
            switch e.status {
            case .done(let line):
                row(icon: "checkmark.circle", tint: .green, title: e.title, subtitle: line, action: settled ? e.open : nil, popIn: true)
            case .missing:
                row(icon: "exclamationmark.circle", tint: .blue, title: e.missingTitle, subtitle: e.why, action: settled ? e.open : nil, popIn: true)
            case .failed:
                row(icon: "exclamationmark.triangle", tint: .orange, title: e.title, subtitle: "Couldn't check",
                    action: settled ? { Task { await check.run() } } : nil, popIn: true)
            case .checking:
                row(icon: nil, tint: .secondary, title: e.title, subtitle: "Checking…", action: nil)
            }
        } else {
            row(icon: nil, tint: .secondary, title: e.title, subtitle: "Checking…", action: nil)
        }
    }

    private var allGood: Bool { !entries.contains { $0.status == .missing || $0.status == .failed } }

    private var resultLine: String {
        let n = entries.filter { $0.status == .missing }.count
        if n == 0 { return entries.contains { $0.status == .failed } ? "Couldn't check everything" : "Everything is set up" }
        return n == 1 ? "1 thing to set up" : "\(n) things to set up"
    }

    private func sleep(until t: Date) async {
        let s = t.timeIntervalSinceNow
        if s > 0 { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }
    }

    @MainActor private func runScan() async {
        let order = entries.map(\.id)
        if reduceMotion {
            await check.scanNow()
            revealed = order; resolved = Set(order)
            UINotificationFeedbackGenerator().notificationOccurred(allGood ? .success : .warning)
            ringShown = false; badge = allGood; finishing = true; settled = true
            return
        }
        let start = Date()
        Task { await check.scanNow() }
        var last = start
        for (i, id) in order.enumerated() {
            await sleep(until: (i == 0 ? start.addingTimeInterval(0.45) : last.addingTimeInterval(0.28)))
            withAnimation(.easeOut(duration: 0.22)) { revealed.append(id) }
            // Its own answer from THIS scan (12 s at most; then the row shows what the check holds).
            while (check.answered[id] ?? .distantPast) < start, Date().timeIntervalSince(start) < 12 {
                try? await Task.sleep(for: .milliseconds(50))
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { _ = resolved.insert(id) }
            switch entries.first(where: { $0.id == id })?.status {
            case .done?: UISelectionFeedbackGenerator().selectionChanged()          // a light tick
            case .missing?: UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.55)
            default: UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            last = Date()
        }
        await sleep(until: start.addingTimeInterval(1.5))
        finishing = true
        withAnimation(.easeInOut(duration: 0.25)) { ringClose = 1 }
        UINotificationFeedbackGenerator().notificationOccurred(allGood ? .success : .warning)
        try? await Task.sleep(for: .milliseconds(250))
        withAnimation(.easeOut(duration: 0.2)) { ringShown = false }
        if allGood { withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { badge = true } }
        try? await Task.sleep(for: .milliseconds(300))
        withAnimation(.easeOut(duration: 0.25)) { settled = true }
    }

    // MARK: Settled

    /// Under the card once the scan has settled: the note (only when something is missing) and the
    /// link to fariin.com/safety. People reading this sheet are already thinking about their account;
    /// that page shows everything else (requests, block, report, scams).
    @ViewBuilder private var settledTail: some View {
        VStack(spacing: 16) {
            if entries.contains(where: { $0.status == .missing }) {
                Text("Set these up to keep your account safe if your phone is lost or someone learns your password.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
            }
            Button { if let u = URL(string: "https://fariin.com/safety") { WebLink.open(u) } } label: {
                Text("How Fariin keeps you safe")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.fariinAction)
            }
            .buttonStyle(.plain)
        }
    }

    /// The photo with the scan ring: an arc running round it while the checks run, closing into a
    /// full ring at the end and fading; a small tick badge when everything is fine.
    private var header: some View {
        VStack(spacing: 10) {
            ZStack {
                AvatarView(name: profile.me?.name ?? "", photoUrl: profile.me?.photoUrl, size: 96)
                if ringShown && !reduceMotion {
                    if finishing {
                        Circle().trim(from: 0, to: 0.28 + 0.72 * ringClose)
                            .stroke(Color.fariinAction, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 106, height: 106)
                    } else {
                        SpinningArc(color: UIColor(Color.fariinAction), lineWidth: 3, fraction: 0.28, period: 0.9)
                            .frame(width: 106, height: 106)
                    }
                }
            }
            .frame(width: 108, height: 108)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.onFariinAction, Color.fariinAction)
                    .background(Circle().fill(Color(.systemGroupedBackground)).padding(-2))
                    .scaleEffect(badge ? 1 : 0.6)
                    .opacity(badge ? 1 : 0)
                    .offset(x: -4, y: -4)
            }
            Text("Security Checkup").font(.title2.weight(.bold))
            Text(finishing ? resultLine : "Checking your account…")
                .font(.subheadline.weight(finishing ? .semibold : .regular))
                .foregroundStyle(finishing ? Color.primary : Color.secondary)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: finishing)
            if finishing {
                Text(checkedLine)
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Says when the shown answers were checked; never "just now" for answers that are not.
    private var checkedLine: String {
        guard let t = check.lastCompleted else { return "Checking your account against the server…" }
        if Date().timeIntervalSince(t) < 60 { return "We checked your account against the server just now." }
        return "We checked your account against the server \(t.formatted(.relative(presentation: .named)))."
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
                     action: (() -> Void)?, popIn: Bool = false) -> some View {
        Button { action?() } label: {
            HStack(spacing: 14) {
                Group {
                    if let icon {
                        Image(systemName: icon).font(.system(size: 22, weight: .regular)).foregroundStyle(tint)
                            // The scan's spinner turning into the answer (owner 2026-11-09).
                            .transition(popIn ? .scale(scale: 0.6).combined(with: .opacity) : .identity)
                    } else {
                        ProgressView().transition(.opacity)
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

/// Each setup page as its own sheet over the checkup, with an X (owner 2026-10-14: "make it coming
/// bottom"). Moved out of the checkup's body unchanged when the live scan arrived (2026-11-09).
private struct SubSheets: ViewModifier {
    @Binding var open: SecurityCheckupSheet.Item?
    let check: SecurityCheckup
    let close: () -> Void

    func body(content: Content) -> some View {
        content.sheet(item: $open, onDismiss: { check.refreshIfStale() }) { item in
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
                                             close()
                                         })
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        // A plain button: the bar draws the glass circle itself (one ring, not two).
                        Button { open = nil } label: {
                            Image(systemName: "xmark").font(.system(size: 17, weight: .semibold))
                        }
                    }
                }
            }
            .presentationDragIndicator(.visible)
        }
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
                        .foregroundStyle(Color.onFariinAction)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Color.fariinAction, in: Capsule())
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
