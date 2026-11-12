import SwiftUI
import FirebaseAuth

// ⛔ CHAT BACKUP SCREENS (owner 2026-11-12, device-storage plan phase 3, both apps alike).
// Settings > Chats > Chat Backup: last backup, Back Up Now, daily automatic backup on Wi-Fi, and the
// optional backup password (the only way a backup opens on Android, or after the iCloud Keychain
// copy of the key is gone). Everything here stays hidden while `ChatBackup.enabled` is false.

/// This phone's backup choices, per account. The password lives in this phone's Keychain only
/// (never synced, never sent): the daily backup needs it to lock each new backup the same way.
enum ChatBackupPrefs {
    private static func uid() -> String { Auth.auth().currentUser?.uid ?? "" }
    private static func autoKey(_ u: String) -> String { "chatBackup.auto.\(u)" }
    private static func pwKey(_ u: String) -> String { "fariin_backup_password_v1.\(u)" }
    private static func lastKey(_ u: String) -> String { "chatBackup.lastMade.\(u)" }

    static var autoOn: Bool {
        get { UserDefaults.standard.bool(forKey: autoKey(uid())) }
        set { UserDefaults.standard.set(newValue, forKey: autoKey(uid())) }
    }
    static var password: String? {
        get { Keychain.get(pwKey(uid())) }
        set {
            if let newValue, !newValue.isEmpty { Keychain.set(pwKey(uid()), newValue) } else { Keychain.delete(pwKey(uid())) }
        }
    }
    static var lastMade: Date? {
        get {
            let v = UserDefaults.standard.double(forKey: lastKey(uid()))
            return v > 0 ? Date(timeIntervalSince1970: v) : nil
        }
        set { UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0, forKey: lastKey(uid())) }
    }
}

/// The daily backup: once a day, on Wi-Fi, while the app is open (asked at launch and on return to
/// the app). Quiet: a failure waits for the next chance.
@MainActor enum ChatBackupScheduler {
    private static var running = false

    static func runIfDue() {
        guard ChatBackup.enabled, ChatBackupPrefs.autoOn, !running,
              NetworkState.shared.isWifi, NetworkState.shared.isOnline,
              let uid = Auth.auth().currentUser?.uid else { return }
        if let last = ChatBackupPrefs.lastMade, Date().timeIntervalSince(last) < 24 * 3600 { return }
        running = true
        let password = ChatBackupPrefs.password
        Task {
            if let info = try? await ICloudBackup.shared.backupNow(uid: uid, password: password) {
                ChatBackupPrefs.lastMade = info.made
            }
            running = false
        }
    }
}

struct ChatBackupPage: View {
    @State private var latest: ICloudBackup.Info?
    @State private var loading = true
    @State private var working = false
    @State private var problem: String?
    @State private var autoOn = ChatBackupPrefs.autoOn
    @State private var hasPassword = ChatBackupPrefs.password != nil
    @State private var editPassword = false

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Last Backup")
                    Spacer()
                    if loading { ProgressView() } else {
                        Text(latest.map { "\($0.made.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: $0.size, countStyle: .file))" } ?? "Never")
                            .foregroundStyle(.secondary)
                    }
                }
                Button { backUpNow() } label: {
                    HStack {
                        Text("Back Up Now")
                        if working { Spacer(); ProgressView() }
                    }
                }
                .disabled(working)
                Toggle("Back Up Automatically", isOn: $autoOn).tint(.green)
                    .onChange(of: autoOn) { _, on in ChatBackupPrefs.autoOn = on; if on { ChatBackupScheduler.runIfDue() } }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if let problem { Text(problem).foregroundStyle(.red) }
                    Text("Your chats are saved to your own iCloud, locked so only you can open them. Fariin can't read them. Automatic backups run once a day on Wi-Fi. Photos and videos are not included yet.")
                }
            }
            Section {
                Button(hasPassword ? "Change Backup Password" : "Add Backup Password") { editPassword = true }
                if hasPassword {
                    Button("Remove Backup Password", role: .destructive) {
                        ChatBackupPrefs.password = nil
                        hasPassword = false
                    }
                }
            } footer: {
                Text("Add a password so you can restore even without your iCloud Keychain, or on an Android phone. Fariin can't reset it.")
            }
        }
        .navigationTitle("Chat Backup")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $editPassword) {
            NavigationStack {
                BackupPasswordPage { pw in
                    ChatBackupPrefs.password = pw
                    hasPassword = true
                    editPassword = false
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        latest = try? await ICloudBackup.shared.latestBackup()
        loading = false
    }

    private func backUpNow() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        working = true
        problem = nil
        let password = ChatBackupPrefs.password
        Task {
            do {
                let info = try await ICloudBackup.shared.backupNow(uid: uid, password: password)
                ChatBackupPrefs.lastMade = info.made
                latest = info
                Haptics.notify(.success)
            } catch {
                problem = error.localizedDescription
                Haptics.notify(.error)
            }
            working = false
        }
    }
}

/// Backup password: twice, 8 characters or more, any characters. Kept on this phone only.
struct BackupPasswordPage: View {
    var onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pw = ""
    @State private var confirm = ""
    @State private var problem: String?

    var body: some View {
        List {
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
        }
        .navigationTitle("Backup Password")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    guard pw.count >= BackupArchive.minPasswordLength else {
                        problem = "Use at least \(BackupArchive.minPasswordLength) characters."; return
                    }
                    guard pw == confirm else { problem = "The passwords don't match."; return }
                    onSave(pw)
                }
                .disabled(pw.isEmpty || confirm.isEmpty)
            }
        }
    }
}
