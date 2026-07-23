import SwiftUI
import UIKit

// Settings subviews. Real where the backend exists (Blocked Users, push toggle);
// honest placeholders where it doesn't yet (Devices sessions, Phone Number) — no
// fabricated data, built so they can be wired up when the infra lands.

private var appVersion: String {
    (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
}

// MARK: - Notifications

// Layout follows the user's reference (master switch → in-app block → red reset at the
// bottom), REAL rows only: no Sound picker until bundled tones + the server payload
// exist, no Message Preview (lock-screen pushes can't show E2EE text anyway), no New
// Contacts (no contact sync). Reset = unmute every chat you custom-muted.
struct NotificationsSettingsView: View {
    @AppStorage("notif.push") private var pushOn = true
    @AppStorage("notif.inAppSound") private var inAppSound = true
    @AppStorage("notif.inAppVibrate") private var inAppVibrate = true
    @AppStorage("notif.inAppPreview") private var inAppPreview = true
    @State private var confirmReset = false
    @State private var resetting = false

    private var me: String { AuthService.shared.uid ?? "" }
    private var mutedCount: Int {
        let now = Date().timeIntervalSince1970 * 1000
        return ConversationsRepository.shared.conversations.filter { $0.isMuted(me, now: now) }.count
    }

    var body: some View {
        List {
            Section {
                Toggle("Show Notifications", isOn: $pushOn)
                    .tint(.green)
                    .onChange(of: pushOn) { _, on in
                        if on { Push.register() } else { Task { await Push.unregister() } }   // unregister is now async
                    }
            } footer: {
                Text("Get notified of new messages and calls when Kulan is closed. (Message text never appears in the lock-screen notification — it stays end-to-end encrypted.)")
            }

            Section {
                Toggle("In-App Sounds", isOn: $inAppSound).tint(.green)
                Toggle("In-App Vibrate", isOn: $inAppVibrate).tint(.green)
                Toggle("In-App Preview", isOn: $inAppPreview).tint(.green)
            } header: {
                Text("In-App Notifications")
            } footer: {
                Text("Controls alerts while Kulan is open.")
            }

            Section {
                Button(role: .destructive) { confirmReset = true } label: {
                    HStack {
                        Text("Reset All Notifications")
                        if resetting { Spacer(); ProgressView() }
                    }
                }
                .disabled(resetting || mutedCount == 0)
            } footer: {
                Text(mutedCount == 0
                     ? "No chats have custom notification settings."
                     : "Unmutes the \(mutedCount) chat\(mutedCount == 1 ? "" : "s") you muted.")
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Reset all notifications?", isPresented: $confirmReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) { Task { await resetAll() } }
        } message: {
            Text("Every muted chat goes back to normal notifications.")
        }
    }

    private func resetAll() async {
        resetting = true
        let now = Date().timeIntervalSince1970 * 1000
        for c in ConversationsRepository.shared.conversations where c.isMuted(me, now: now) {
            await ChatService.setMute(c.id, until: 0)
        }
        resetting = false
    }
}

// MARK: - Blocked Users (real)

struct BlockedUsersView: View {
    private var repo = ConversationsRepository.shared
    @Environment(\.colorScheme) private var scheme
    @State private var toUnblock: Conversation?   // row awaiting the "Unblock?" confirm
    private var me: String { AuthService.shared.uid ?? "" }
    private var blocked: [Conversation] {
        repo.conversations.filter { $0.blockedBy[me] == true }
            .sorted { $0.updatedAtMillis > $1.updatedAtMillis }
    }

    var body: some View {
        Group {
            if blocked.isEmpty {
                ContentUnavailableView("No blocked users", systemImage: "hand.raised",
                                       description: Text("People you block will appear here."))
            } else {
                List {
                    ForEach(blocked) { conv in
                        HStack(spacing: 12) {
                            AvatarView(name: conv.name(for: me), photoUrl: conv.photoUrl(for: me), size: 40)
                            Text(conv.name(for: me)).font(.body)
                            Spacer()
                            Button("Unblock") { toUnblock = conv }
                                .buttonStyle(.borderless)   // explicit — a default Button in a List row fires on ANY row tap
                                .font(.subheadline.weight(.semibold))
                                .tint(.red)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Blocked Users")
        .navigationBarTitleDisplayMode(.inline)
        // Confirm before unblocking — an accidental row tap must not silently unblock someone.
        .alert("Unblock \(toUnblock.map { $0.name(for: me) } ?? "")?",
               isPresented: Binding(get: { toUnblock != nil }, set: { if !$0 { toUnblock = nil } })) {
            Button("Cancel", role: .cancel) {}
            Button("Unblock", role: .destructive) {
                if let conv = toUnblock { Task { await ChatService.setBlocked(conv.id, false) } }
            }
        }
    }
}

// MARK: - Phone Number privacy

struct PhoneNumberPrivacyView: View {
    enum Audience: String, CaseIterable, Identifiable {
        case everybody, contacts, nobody
        var id: String { rawValue }
        var label: String {
            switch self {
            case .everybody: return "Everybody"
            case .contacts:  return "My Contacts"
            case .nobody:    return "Nobody"
            }
        }
    }
    @AppStorage("privacy.phone") private var raw = Audience.nobody.rawValue

    var body: some View {
        List {
            Section {
                ForEach(Audience.allCases) { option in
                    Button { raw = option.rawValue } label: {
                        HStack {
                            Text(option.label).foregroundStyle(.primary)
                            Spacer()
                            if raw == option.rawValue {
                                Image(systemName: "checkmark").foregroundStyle(.primary)
                            }
                        }
                    }
                }
            } header: {
                Text("WHO CAN SEE MY PHONE NUMBER")
            } footer: {
                Text("Kulan doesn't use phone numbers yet (sign-in is by username). This preference is saved for when phone numbers are added.")
            }
        }
        .navigationTitle("Phone Number")
        .navigationBarTitleDisplayMode(.inline)
    }
}
