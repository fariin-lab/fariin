import SwiftUI
import UIKit

// Settings subviews. Real where the backend exists (Blocked Users, push toggle);
// honest placeholders where it doesn't yet (Devices sessions, Phone Number) — no
// fabricated data, built so they can be wired up when the infra lands.

private var appVersion: String {
    (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
}

// MARK: - Notifications

// The user's reference layout, every row REAL: Show Notifications = push registration;
// Message Preview = whether the push shows the sender (server reads users.notifPreview);
// Sound = bundled tones the push and in-app banner actually play (users.notifSound);
// the in-app block drives InAppNotify. Only "New Contacts" is absent — there is no
// contact-book sync, so that event cannot exist yet.
struct NotificationsSettingsView: View {
    @AppStorage("notif.push") private var pushOn = true
    @AppStorage("notif.preview") private var messagePreview = true
    @AppStorage("notif.sound") private var soundName = "rebound"
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
            }

            Section {
                Toggle("Message Preview", isOn: $messagePreview)
                    .tint(.green)
                    .onChange(of: messagePreview) { _, on in
                        // The push server reads this per recipient — OFF sends a nameless
                        // "New message" instead of the sender's name.
                        Task { try? await ProfileStore.shared.setNotifPrefs(preview: on) }
                    }
                NavigationLink { NotificationSoundView() } label: {
                    HStack {
                        Text("Sound")
                        Spacer()
                        Text(soundName == "default" ? "Default" : soundName.capitalized)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Options")
            }

            Section {
                Toggle("In-App Sounds", isOn: $inAppSound).tint(.green)
                Toggle("In-App Vibrate", isOn: $inAppVibrate).tint(.green)
                Toggle("In-App Preview", isOn: $inAppPreview).tint(.green)
            } header: {
                Text("In-App Notifications")
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
                Text("Undo all custom notification settings for your chats.")
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

// Sound picker: bundled tones, tap = hear it + choose it. The choice drives BOTH the
// lock-screen push (server reads users.notifSound) and the in-app banner tone.
struct NotificationSoundView: View {
    @AppStorage("notif.sound") private var soundName = "rebound"
    private let sounds = ["default", "rebound", "chime", "pop", "pulse", "marimba"]

    var body: some View {
        List {
            Section {
                ForEach(sounds, id: \.self) { s in
                    Button {
                        soundName = s
                        InAppNotify.shared.playTone(s)   // instant preview
                        Task { try? await ProfileStore.shared.setNotifPrefs(sound: s) }
                    } label: {
                        HStack {
                            Text(s == "default" ? "Default" : s.capitalized).foregroundStyle(.primary)
                            Spacer()
                            if soundName == s {
                                Image(systemName: "checkmark").fontWeight(.semibold)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                }
            } footer: {
                Text("Plays for new messages, on the lock screen and inside the app.")
            }
        }
        .navigationTitle("Sound")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Devices (restored 2026-07-24 on user request)

struct DevicesView: View {
    @State private var showAddInfo = false

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 26) {
                    // Hero card: illustration + caption + Link button.
                    VStack(spacing: 16) {
                        Image(systemName: "laptopcomputer.and.iphone")
                            .font(.system(size: 60))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.blue)
                            .padding(.top, 10)
                        (Text("Use Kulan on desktop or iPad. ").foregroundStyle(.secondary)
                            + Text("Learn More").foregroundStyle(.blue))
                            .font(.subheadline).multilineTextAlignment(.center)
                        Button { showAddInfo = true } label: {
                            Text("Link a New Device").font(.headline).foregroundStyle(.white)
                                .frame(maxWidth: .infinity).frame(height: 50)
                                .background(.blue, in: Capsule())
                        }
                    }
                    .padding(20)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                    // Linked devices list (none — single-device today).
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Linked Devices").font(.title3.weight(.bold)).padding(.horizontal, 4)
                        Text("No linked devices")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).frame(height: 84)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }

                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "lock.fill").font(.caption)
                        Text("Messages and chat info are protected by end-to-end encryption on all devices")
                    }
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                }
                .padding(16)
            }
        }
        .navigationTitle("Linked Devices")
        .navigationBarTitleDisplayMode(.inline)
        // Honest: there's no companion app to link yet, so the button explains instead of faking.
        .alert("Coming soon", isPresented: $showAddInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Kulan on desktop and iPad is coming soon. Right now each account runs on a single device.")
        }
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
