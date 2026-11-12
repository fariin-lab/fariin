import SwiftUI
import UIKit
import Observation
import UniformTypeIdentifiers
import FirebaseAuth

// ⛔ CHAT BACKUP SCREENS (owner 2026-11-12, device-storage plan phase 3, both apps alike; flow agreed
// with Android in fariin-plans/backup-flow-study.md "Our flow" A-D). On iPhone the cloud is the
// phone's own iCloud, so there is no account row.
//   A. once after sign-in, when no backup exists: "Keep a copy of your chats" (Turn On / Not Now);
//      Not Now is asked once more 7 days later from a Back Up circle in Things you can do.
//   B. Settings > Chats > Chat Backup: status + Back Up Now (Cancel while running), How often,
//      Use Mobile Data, Backup Password (a password or a 64-digit key).
//   C. restore at sign-in, only when this phone has no history for the account; Skip leaves a
//      Restore circle in Things you can do until a newer backup replaces it or a restore succeeds.
//   D. errors in plain words.
// Everything here stays hidden while `ChatBackup.enabled` is false.

// MARK: - Choices

/// This phone's backup choices, per account. The password lives in this phone's Keychain only
/// (never synced, never sent): each new backup is locked with it the same way.
enum ChatBackupPrefs {
    enum Frequency: String, CaseIterable, Identifiable {
        case daily, weekly, off
        var id: String { rawValue }
        var title: String {
            switch self {
            case .daily: "Daily"
            case .weekly: "Weekly"
            case .off: "Off"
            }
        }
        var interval: TimeInterval? {
            switch self {
            case .daily: 24 * 3600
            case .weekly: 7 * 24 * 3600
            case .off: nil
            }
        }
    }

    private static func uid() -> String { Auth.auth().currentUser?.uid ?? "" }
    private static func key(_ name: String) -> String { "chatBackup.\(name).\(uid())" }
    private static func pwKey(_ u: String) -> String { "fariin_backup_password_v1.\(u)" }
    private static var d: UserDefaults { .standard }

    /// Nil until the person chose (setup card or the page). The scheduler treats nil as Off.
    static var frequencyChoice: Frequency? {
        get { d.string(forKey: key("frequency")).flatMap(Frequency.init(rawValue:)) }
        set { d.set(newValue?.rawValue, forKey: key("frequency")) }
    }
    static var frequency: Frequency { frequencyChoice ?? .off }

    /// Off by default: backups wait for Wi-Fi.
    static var useMobileData: Bool {
        get { d.bool(forKey: key("mobileData")) }
        set { d.set(newValue, forKey: key("mobileData")) }
    }
    static var password: String? {
        get { Keychain.get(pwKey(uid())) }
        set {
            if let newValue, !newValue.isEmpty { Keychain.set(pwKey(uid()), newValue) } else { Keychain.delete(pwKey(uid())) }
        }
    }
    static var lastMade: Date? {
        get {
            let v = d.double(forKey: key("lastMade"))
            return v > 0 ? Date(timeIntervalSince1970: v) : nil
        }
        set { d.set(newValue?.timeIntervalSince1970 ?? 0, forKey: key("lastMade")) }
    }
    /// When the setup card (A) was shown; nil = not yet.
    static var setupAskedAt: Date? {
        get {
            let v = d.double(forKey: key("setupAsked"))
            return v > 0 ? Date(timeIntervalSince1970: v) : nil
        }
        set { d.set(newValue?.timeIntervalSince1970 ?? 0, forKey: key("setupAsked")) }
    }
    /// The 7-day Back Up circle was used or hidden: never again.
    static var setupCircleDone: Bool {
        get { d.bool(forKey: key("setupCircleDone")) }
        set { d.set(newValue, forKey: key("setupCircleDone")) }
    }
    /// `made` (ms) of the backup whose restore was skipped: the Restore circle shows while the
    /// newest backup in iCloud is still this one. 0 = none.
    static var restoreSkippedMade: Int64 {
        get { Int64(d.double(forKey: key("restoreSkipped"))) }
        set { d.set(Double(newValue), forKey: key("restoreSkipped")) }
    }
}

/// Error text in plain words (flow D).
enum ChatBackupText {
    static let waitingForWifi = "Waiting for Wi-Fi"
    static let waitingForConnection = "Waiting for a connection"
    static let wrongPassword = "That password doesn't open this backup"

    /// Nil for a cancel, which needs no words.
    static func plain(_ error: Error) -> String? {
        if error is CancellationError { return nil }
        if let f = error as? BackupArchive.Failure, f == .wrongPassword { return wrongPassword }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    /// "Today, 3:40 AM", "Yesterday, 9:02 PM", else "Nov 3, 2026, 8:15 AM".
    static func when(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return "Today, \(time)" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday, \(time)" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    static func describe(_ info: ICloudBackup.Info) -> String { "\(when(info.made)) · \(size(info.size))" }
}

// MARK: - Running a backup

/// The one backup that can run at a time, shared by the page, the setup card and the schedule, so
/// the page shows (and can cancel) a backup it did not start.
@MainActor @Observable
final class ChatBackupRunner {
    static let shared = ChatBackupRunner()
    private init() {}

    private(set) var running = false
    /// Set while a backup waits for Wi-Fi (or any connection): the words to show.
    private(set) var waiting: String?
    var problem: String?
    /// The backup now in iCloud, as last read or made.
    var latest: ICloudBackup.Info?

    private var task: Task<Void, Never>?
    private var waitTask: Task<Void, Never>?

    var busy: Bool { running || waiting != nil }

    private var networkWords: String? {
        let net = NetworkState.shared
        if !net.isOnline { return ChatBackupPrefs.useMobileData ? ChatBackupText.waitingForConnection : ChatBackupText.waitingForWifi }
        if !net.isWifi && !ChatBackupPrefs.useMobileData { return ChatBackupText.waitingForWifi }
        return nil
    }

    /// The schedule, asked at launch and on return to the app. Quiet: a failure waits for the next
    /// chance. Never runs while an older backup waits to be restored (it would replace it), nor on
    /// a phone with no history yet (an empty backup would replace a full one).
    func runIfDue() {
        guard ChatBackup.enabled, !busy, Auth.auth().currentUser != nil,
              let every = ChatBackupPrefs.frequency.interval, networkWords == nil else { return }
        if let last = ChatBackupPrefs.lastMade, Date().timeIntervalSince(last) < every { return }
        let offer = ChatRestoreOffer.shared
        guard offer.screen == nil, offer.circle == nil else { return }
        run(quiet: true, needsHistory: true)
    }

    /// Back Up Now (the page, the setup card, a new password). Waits for Wi-Fi when it must.
    func start() {
        guard ChatBackup.enabled, !busy else { return }
        problem = nil
        if let words = networkWords {
            waiting = words
            waitTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    guard let self, !Task.isCancelled else { return }
                    if let words = self.networkWords { self.waiting = words; continue }
                    self.waiting = nil
                    self.run(quiet: false, needsHistory: false)
                    return
                }
            }
            return
        }
        run(quiet: false, needsHistory: false)
    }

    func cancel() {
        waitTask?.cancel(); waitTask = nil
        waiting = nil
        task?.cancel()
    }

    private func run(quiet: Bool, needsHistory: Bool) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        running = true
        let password = ChatBackupPrefs.password
        task = Task { [weak self] in
            defer { self?.running = false; self?.task = nil }
            if needsHistory {
                // safety review 2026-11-12: an automatic backup only from a phone with synced marks.
                let has = await Task.detached(priority: .utility) { LocalMessageDB.shared.hasSyncedMarks(uid: uid) }.value
                guard has else { return }
            }
            do {
                let info = try await ICloudBackup.shared.backupNow(uid: uid, password: password)
                ChatBackupPrefs.lastMade = info.made
                self?.latest = info
                ChatRestoreOffer.shared.replacedBy(info)
                if !quiet { Haptics.notify(.success) }
            } catch {
                guard let words = ChatBackupText.plain(error) else { return }   // cancelled
                self?.problem = words
                if !quiet { Haptics.notify(.error) }
            }
        }
    }
}

/// The daily / weekly backup, as RootView asks for it on return to the app.
@MainActor enum ChatBackupScheduler {
    static func runIfDue() { ChatBackupRunner.shared.runIfDue() }
}

// MARK: - Sign-in: restore (C), then the setup card (A)

/// What the app offers about chat backup right now. Its own object: the old Backup PIN offer
/// (KeyBackupOffer) stays hidden and untouched (owner 2026-11-12).
@MainActor @Observable
final class ChatRestoreOffer {
    static let shared = ChatRestoreOffer()
    private init() {}

    /// The full "Restore your chats?" screen.
    var screen: ICloudBackup.Info?
    /// After Skip: the Restore circle in Things you can do.
    var circle: ICloudBackup.Info?
    /// Not Now on the setup card, 7 days on: the Back Up circle (asked once more).
    var backUpCircle = false

    func reopen() { if let c = circle { screen = c } }

    func skipped(_ info: ICloudBackup.Info, uid: String) {
        LocalMessageDB.shared.setMeta(uid: uid, key: "restore.checked", String(ChatBackupText.ms(info.made)))
        ChatBackupPrefs.restoreSkippedMade = ChatBackupText.ms(info.made)
        screen = nil
        circle = info
    }

    /// `complete`: every row of the backup was filed (safety review 2026-11-12); only then "restored".
    func restored(_ info: ICloudBackup.Info, uid: String, complete: Bool) {
        let made = String(ChatBackupText.ms(info.made))
        LocalMessageDB.shared.setMeta(uid: uid, key: "restore.checked", made)
        if complete { LocalMessageDB.shared.setMeta(uid: uid, key: "restored", made) }
        ChatBackupPrefs.restoreSkippedMade = 0
        circle = nil
        // `screen` stays: the restore screen shows the count, its Continue closes it (RootView).
    }

    func hideCircle() {
        ChatBackupPrefs.restoreSkippedMade = 0
        circle = nil
    }

    /// A new backup was made from this phone: the skipped one is gone from iCloud.
    func replacedBy(_ info: ICloudBackup.Info) {
        ChatBackupPrefs.restoreSkippedMade = 0
        circle = nil
    }

    func hideBackUpCircle() {
        ChatBackupPrefs.setupCircleDone = true
        backUpCircle = false
    }

    /// The circles this offer adds to the front of Things you can do (MainShell getStartedLayer).
    var leads: [GetStartedLead] {
        guard ChatBackup.enabled else { return [] }
        var out: [GetStartedLead] = []
        if circle != nil {
            out.append(GetStartedLead(id: "chatRestore", icon: "icloud.and.arrow.down.fill", label: "Restore",
                                      accessibility: "Restore your chats",
                                      action: { [weak self] in self?.reopen() },
                                      hide: { [weak self] in self?.hideCircle() }))
        }
        if backUpCircle {
            out.append(GetStartedLead(id: "chatBackUp", icon: "icloud.fill", label: "Back Up",
                                      accessibility: "Back up your chats",
                                      action: { [weak self] in
                                          self?.hideBackUpCircle()
                                          ChatBackupFlow.askSetup()
                                      },
                                      hide: { [weak self] in self?.hideBackUpCircle() }))
        }
        return out
    }

    func hideAll() {
        if circle != nil { hideCircle() }
        if backUpCircle { hideBackUpCircle() }
    }
}

/// ⛔ NOTHING IS FILED BEFORE THE RESTORE QUESTION (safety review 2026-11-12). InboxSync and
/// HistoryPull wait until the sign-in restore check (transfer, then iCloud) has decided; what they
/// file would otherwise change the answer. Opened once per launch by `ChatBackupFlow.atSignIn`,
/// which then kicks InboxSync.
@MainActor enum SignInRestoreGate {
    static var done = false

    static func open() {
        guard !done else { return }
        done = true
        InboxSync.shared.kick()
    }
}

@MainActor enum ChatBackupFlow {
    /// After sign-in (RootView, once per launch on the main screen). Restore first, then the setup
    /// card, never both on screen. All quiet: an iCloud problem here just asks nothing.
    static func atSignIn() async {
        // safety review 2026-11-12: InboxSync / HistoryPull start once the restore check is over,
        // however it ends.
        defer { SignInRestoreGate.open() }
        // Owner 2026-11-12: no "Moving from another phone?" screen at launch (it showed to an
        // existing account right after an update). Transfer lives in Settings > Chats only.
        guard ChatBackup.enabled, let uid = Auth.auth().currentUser?.uid else { return }
        let offer = ChatRestoreOffer.shared
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        // C. Rule agreed with Android 2026-11-12: look for a backup only when this phone holds no
        // history for the account; a backup is offered once (meta "restore.checked" = its made),
        // a newer one once more.
        // "restore.checked" is compared below (a newer backup is offered once more), so not here.
        let hasHistory = await Task.detached(priority: .utility) {
            LocalMessageDB.shared.hasHistory(uid: uid, includingChecked: false)
        }.value
        let latest: ICloudBackup.Info?
        do { latest = try await ICloudBackup.shared.latestBackup() } catch { return }
        ChatBackupRunner.shared.latest = latest
        if let latest {
            let made = ChatBackupText.ms(latest.made)
            if !hasHistory {
                let checked = await withCheckedContinuation { (c: CheckedContinuation<Int64, Never>) in
                    LocalMessageDB.shared.meta(uid: uid, prefix: "restore.checked") { m in
                        c.resume(returning: Int64(m["restore.checked"] ?? "") ?? 0)
                    }
                }
                if made > checked { offer.screen = latest }
            }
            let skipped = ChatBackupPrefs.restoreSkippedMade
            if offer.screen == nil, skipped != 0 {
                if skipped == made { offer.circle = latest } else { ChatBackupPrefs.restoreSkippedMade = 0 }
            }
        }
        while offer.screen != nil {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return }
        }
        SignInRestoreGate.open()   // decided: the setup card below does not hold the filing back

        // A. The setup card: once per account, only when nothing was chosen and no backup exists.
        guard ChatBackupPrefs.frequencyChoice == nil, latest == nil else { return }
        if let asked = ChatBackupPrefs.setupAskedAt {
            if !ChatBackupPrefs.setupCircleDone, Date().timeIntervalSince(asked) >= 7 * 24 * 3600 {
                offer.backUpCircle = true
            }
            return
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        while RootView.somethingPresented {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Task.isCancelled { return }
        }
        guard ChatBackupPrefs.frequencyChoice == nil, offer.screen == nil else { return }
        askSetup()
    }

    /// "Keep a copy of your chats". Turn On = Daily + a first backup in the background. Not Now
    /// needs no answer: it was asked (`setupAskedAt`), and the circle asks once more after 7 days.
    static func askSetup() {
        ChatBackupPrefs.setupAskedAt = ChatBackupPrefs.setupAskedAt ?? Date()
        GlassConfirmDoor.show(
            title: "Keep a copy of your chats",
            message: "Saved to your iCloud, locked so only you can open it.",
            confirm: "Turn On", cancel: "Not Now", confirmColor: .primary) {
                ChatBackupPrefs.frequencyChoice = .daily
                ChatRestoreOffer.shared.backUpCircle = false
                ChatBackupRunner.shared.start()
            }
    }
}

// MARK: - B. Settings > Chats > Chat Backup

struct ChatBackupPage: View {
    @State private var runner = ChatBackupRunner.shared
    @State private var loading = true
    @State private var frequency = ChatBackupPrefs.frequency
    @State private var mobileData = ChatBackupPrefs.useMobileData
    @State private var hasPassword = ChatBackupPrefs.password != nil
    @State private var editLock = false

    var body: some View {
        List {
            // Status first, one action under it, settings below (redesign 2026-11-12).
            Section {
                hero
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            }

            Section {
                Picker("Automatic Backup", selection: $frequency) {
                    ForEach(ChatBackupPrefs.Frequency.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .onChange(of: frequency) { _, f in
                    ChatBackupPrefs.frequencyChoice = f
                    ChatBackupScheduler.runIfDue()
                }
                Toggle("Use Mobile Data", isOn: $mobileData).tint(.green)
                    .onChange(of: mobileData) { _, on in ChatBackupPrefs.useMobileData = on }
            } footer: {
                Text(mobileData ? "Backups run on Wi-Fi or mobile data." : "Backups wait for Wi-Fi.")
            }

            Section {
                Toggle("Backup Password", isOn: Binding(get: { hasPassword }, set: { on in
                    if on { editLock = true } else { askTurnOff() }
                }))
                .tint(.green)
                if hasPassword {
                    Button("Change Password") { editLock = true }
                }
            } footer: {
                Text(hasPassword
                     ? "You need this password to restore on a new phone."
                     : "Add a password to restore on a phone without your iCloud Keychain.")
            }
        }
        .navigationTitle("Chat Backup")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $editLock) {
            NavigationStack {
                BackupLockPage { secret in
                    ChatBackupPrefs.password = secret
                    hasPassword = true
                    editLock = false
                    relock()
                }
            }
        }
        .task { await load() }
    }

    private var hero: some View {
        VStack(spacing: 14) {
            Image(systemName: "icloud.fill")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(Color.fariinAction)
                .frame(width: 76, height: 76)
                .background(Circle().fill(Color.fariinAction.opacity(0.12)))
                .padding(.top, 4)

            VStack(spacing: 4) {
                if loading && runner.latest == nil {
                    ProgressView().frame(height: 44)
                } else if let latest = runner.latest {
                    Text("Last backup")
                        .font(.title3.weight(.semibold))
                    Text(ChatBackupText.describe(latest))
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text("No backup yet")
                        .font(.title3.weight(.semibold))
                    Text("Keep your chats safe if you lose this phone.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)

            if runner.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(runner.waiting ?? "Backing up...")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .transition(.opacity)
            } else if let problem = runner.problem {
                Text(problem)
                    .font(.footnote).foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }

            backUpPill.padding(.top, 4)

            Text("Locked so only you can open it. Fariin can't read your backup. Photos and videos are not included yet.")
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
        .animation(.easeOut(duration: 0.2), value: runner.busy)
    }

    private var backUpPill: some View {
        Button {
            if runner.busy { runner.cancel() } else { backUpNow() }
        } label: {
            Text(runner.busy ? "Cancel" : "Back Up Now")
                .font(.body.weight(.semibold))
                .foregroundStyle(runner.busy ? Color.primary : Color.onFariinAction)
                .frame(maxWidth: .infinity).frame(height: 50)
                .background(Capsule().fill(runner.busy ? Color(.tertiarySystemFill) : Color.fariinAction))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        loading = true
        do {
            runner.latest = try await ICloudBackup.shared.latestBackup()
        } catch {
            if !runner.busy { runner.problem = ChatBackupText.plain(error) }
        }
        loading = false
    }

    private func backUpNow() {
        // A skipped restore is still waiting: backing up now replaces that older backup.
        if ChatRestoreOffer.shared.circle != nil {
            GlassConfirmDoor.show(title: "Replace your older backup?",
                                  message: "It has chats that are not on this phone. Back up now and it is replaced.",
                                  confirm: "Back Up") { startFirstBackup() }
            return
        }
        startFirstBackup()
    }

    private func startFirstBackup() {
        // A first backup by hand keeps itself fresh: How often becomes Daily unless chosen.
        if ChatBackupPrefs.frequencyChoice == nil {
            ChatBackupPrefs.frequencyChoice = .daily
            frequency = .daily
        }
        runner.start()
    }

    private func askTurnOff() {
        GlassConfirmDoor.show(title: "Turn off backup password?",
                              message: "Your next backup opens only with this iCloud account.",
                              confirm: "Turn Off") {
            ChatBackupPrefs.password = nil
            hasPassword = false
            relock()
        }
    }

    /// The backup in iCloud is locked the old way until the next one: make it now when there is one.
    private func relock() {
        guard runner.latest != nil, !runner.busy, ChatRestoreOffer.shared.circle == nil else { return }
        runner.start()
    }
}

// MARK: - Backup password or 64-digit key

/// Turning the backup password on: a password (8 or more characters) or a 64-digit key made here.
/// The key is just a digits-only password to the archive (format v1), so both apps open it.
struct BackupLockPage: View {
    enum Kind: Hashable { case password, key }
    var onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind = Kind.password
    @State private var pw = ""
    @State private var confirm = ""
    @State private var problem: String?
    @State private var key = BackupLockPage.newKey()
    @State private var copied = false

    /// 64 random digits (the system generator is the secure one on Apple platforms).
    static func newKey() -> String {
        var g = SystemRandomNumberGenerator()
        return String((0..<64).map { _ in Character(String(Int.random(in: 0...9, using: &g))) })
    }

    private var groups: [String] {
        stride(from: 0, to: key.count, by: 4).map { i in
            let a = key.index(key.startIndex, offsetBy: i)
            return String(key[a..<key.index(a, offsetBy: 4)])
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Lock With", selection: $kind) {
                    Text("Password").tag(Kind.password)
                    Text("64-Digit Key").tag(Kind.key)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if kind == .password {
                Section {
                    SecureField("Password", text: $pw).textContentType(.newPassword)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    SecureField("Confirm Password", text: $confirm).textContentType(.newPassword)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        if let problem { Text(problem).foregroundStyle(.red) }
                        Text("At least \(BackupArchive.minPasswordLength) characters. Fariin can't reset it, so pick one you will remember.")
                    }
                }
            } else {
                Section {
                    keyCard
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                } footer: {
                    Text("Write this key down and keep it somewhere safe. It opens your backup on any phone, and Fariin can't show it again.")
                }
                Section {
                    Button { save(key) } label: {
                        Text("I Saved It")
                            .font(.body.weight(.semibold)).foregroundStyle(Color.onFariinAction)
                            .frame(maxWidth: .infinity).frame(height: 50)
                            .background(Capsule().fill(Color.fariinAction))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
        }
        .navigationTitle("Backup Password")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(kind == .key)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close")
            }
            if kind == .password {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard pw.count >= BackupArchive.minPasswordLength else {
                            problem = "Use at least \(BackupArchive.minPasswordLength) characters."; return
                        }
                        guard pw == confirm else { problem = "The passwords don't match."; return }
                        save(pw)
                    }
                    .disabled(pw.isEmpty || confirm.isEmpty)
                }
            }
        }
    }

    /// 16 groups of 4 in a glass card, with Copy.
    private var keyCard: some View {
        VStack(spacing: 16) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 12) {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, g in
                    Text(g).font(.system(.title3, design: .monospaced).weight(.medium))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(groups.joined(separator: ", "))
            Button {
                // Kept on this phone only and wiped after two minutes.
                UIPasteboard.general.setItems([[UTType.plainText.identifier: key]],
                                              options: [.localOnly: true,
                                                        .expirationDate: Date().addingTimeInterval(120)])
                copied = true
                Haptics.notify(.success)
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .liquidGlass(Capsule(), interactive: true)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 20).padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .liquidGlass(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func save(_ secret: String) {
        Haptics.notify(.success)
        onSave(secret)
    }
}

// MARK: - C. Restore at sign-in

/// "Restore your chats?" with the backup's date and size. Asks for the password or 64-digit key
/// only when this phone's iCloud Keychain key can't open the backup.
struct ChatRestoreView: View {
    let info: ICloudBackup.Info
    var onDone: () -> Void

    enum Stage: Equatable {
        case ask, secret, working, done(Int), blocked
        var isDone: Bool { if case .done = self { return true } else { return false } }
    }
    @State private var stage = Stage.ask
    @State private var secret = ""
    @State private var useKey = false
    @State private var needsSecret = false
    @State private var problem: String?
    @FocusState private var focused: Bool

    private var uid: String { Auth.auth().currentUser?.uid ?? "" }
    private var secretReady: Bool {
        useKey ? secret.count == 64 : secret.count >= BackupArchive.minPasswordLength
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 40)
            Image(systemName: stage.isDone ? "checkmark.icloud.fill" : "icloud.and.arrow.down.fill")
                .font(.system(size: 46, weight: .regular))
                .foregroundStyle(Color.fariinAction)
                .frame(width: 96, height: 96)
                .liquidGlass(Circle())
            Text(stage.isDone ? "Your chats are back" : "Restore your chats?")
                .font(.title2.weight(.bold)).multilineTextAlignment(.center)
            Text(subtitle)
                .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if stage == .secret || (needsSecret && stage == .working) { secretField }
            if let problem {
                Text(problem).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            Spacer()
            primaryButton
            if !stage.isDone {
                Button("Skip") { skip() }
                    .font(.body.weight(.semibold)).foregroundStyle(.secondary)
                    .disabled(stage == .working)
                    .padding(.bottom, 8)
            }
        }
        .padding(.horizontal, 24)
        // No keyboard by itself (owner 2026-11-12, as the old restore screen): a tap outside closes it.
        .background(Color(.systemBackground).ignoresSafeArea().onTapGesture { focused = false })
        .interactiveDismissDisabled()
    }

    private var subtitle: String {
        switch stage {
        case .done(let n): return n == 1 ? "1 message restored." : "\(n.formatted()) messages restored."
        case .working: return "Restoring..."
        case .blocked: return "Backup from \(ChatBackupText.describe(info))"
        default:
            return needsSecret
                ? "This backup is locked with a password. Enter it to bring back your chats."
                : "Found a backup in your iCloud from \(ChatBackupText.describe(info))."
        }
    }

    private var secretField: some View {
        VStack(spacing: 10) {
            SecureField(useKey ? "64-digit key" : "Backup password", text: $secret)
                .keyboardType(useKey ? .numberPad : .default)
                .textContentType(.password)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .multilineTextAlignment(.center).font(.title3)
                .padding(.vertical, 14).padding(.horizontal, 16)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemFill)))
                .focused($focused)
                .id(useKey)
                .onChange(of: secret) { _, v in if useKey { secret = String(v.filter(\.isNumber).prefix(64)) } }
                .disabled(stage == .working)
            Button(useKey ? "Use a password instead" : "Use a 64-digit key instead") {
                useKey.toggle(); secret = ""; problem = nil
            }
            .font(.footnote.weight(.semibold))
            .disabled(stage == .working)
        }
    }

    @ViewBuilder private var primaryButton: some View {
        let title: String = switch stage {
        case .done, .blocked: "Continue"
        default: "Restore"
        }
        Button { primary() } label: {
            ZStack {
                Text(title).opacity(stage == .working ? 0 : 1)
                if stage == .working { ProgressView().tint(Color.onFariinAction) }
            }
            .font(.body.weight(.semibold)).foregroundStyle(Color.onFariinAction)
            .frame(maxWidth: .infinity).frame(height: 52)
            .background(Capsule().fill(Color.fariinAction))
        }
        .disabled(stage == .working || (stage == .secret && !secretReady))
    }

    private func primary() {
        switch stage {
        case .done: onDone()
        case .blocked: skip()
        default: restore()
        }
    }

    private func restore() {
        problem = nil
        focused = false
        let password: String? = needsSecret ? secret : nil
        stage = .working
        let me = uid
        Task {
            do {
                let got = try await ICloudBackup.shared.restore(uid: me, password: password)
                let n = got.filed
                ChatRestoreOffer.shared.restored(info, uid: me, complete: got.complete)
                Haptics.notify(.success)
                stage = .done(n)
            } catch BackupArchive.Failure.needsPassword {
                needsSecret = true
                stage = .secret
            } catch BackupArchive.Failure.wrongPassword {
                secret = ""
                problem = ChatBackupText.wrongPassword   // no try limit: the backup is in their own iCloud
                Haptics.notify(.error)
                stage = .secret
            } catch let f as BackupArchive.Failure where f == .noKey || f == .otherAccount || f == .newerVersion {
                problem = ChatBackupText.plain(f)
                Haptics.notify(.error)
                stage = .blocked
            } catch {
                problem = ChatBackupText.plain(error)
                Haptics.notify(.error)
                stage = needsSecret ? .secret : .ask
            }
        }
    }

    private func skip() {
        ChatRestoreOffer.shared.skipped(info, uid: uid)
        onDone()
    }
}
