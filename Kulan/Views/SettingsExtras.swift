import SwiftUI
import UIKit
import FirebaseFirestore

// Settings subviews. Real where the backend exists (Blocked Users, push toggle, Devices);
// honest placeholders where it doesn't yet (Phone Number) â€” no fabricated data, built so
// they can be wired up when the infra lands.

private var appVersion: String {
    (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
}

// MARK: - Notifications

// The user's reference layout, every row REAL: Show Notifications = push registration;
// Message Preview = whether the push shows the sender (server reads users.notifPreview);
// Sound = bundled tones the push and in-app banner actually play (users.notifSound);
// the in-app block drives InAppNotify. Only "New Contacts" is absent â€” there is no
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
                        // The push server reads this per recipient â€” OFF sends a nameless
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
                // Enabled when ANY customization exists, not just a mute (audit): a chat with a
                // custom tone and nothing muted left this greyed out, in exactly the case it is for.
                .disabled(resetting || (mutedCount == 0 && !SoundStore.hasAnyCustom))
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
            Text("Every muted chat goes back to normal notifications, and custom chat sounds return to the default.")
        }
    }

    private func resetAll() async {
        resetting = true
        let now = Date().timeIntervalSince1970 * 1000
        for c in ConversationsRepository.shared.conversations where c.isMuted(me, now: now) {
            await ChatService.setMute(c.id, until: 0)
        }
        SoundStore.clearAllCustom()   // per-chat message/call tones — "ALL custom settings"
        resetting = false
    }
}

// Sound picker: bundled tones, tap = hear it + choose it. The choice drives BOTH the
// lock-screen push (server reads users.notifSound) and the in-app banner tone.
struct NotificationSoundView: View {
    @AppStorage("notif.sound") private var soundName = "rebound"
    // Our own tones only. "default" was Apple's Note (iMessage's sound) and is gone; a stored
    // "default" from before now resolves to Rebound wherever it is read.
    private let sounds = ["rebound", "chime", "pop", "pulse", "marimba"]

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
                            Text(s == "rebound" ? "Rebound (default)" : s.capitalized)
                                .foregroundStyle(.primary)
                            Spacer()
                            if soundName == s || (soundName == "default" && s == "rebound") {
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

// MARK: - Devices
//
// Rewritten 2026-07-27. It used to be a "Linked Devices" page whose hero was a Link a New
// Device button for a desktop app that does not exist â€” the user's word for it was "ghost".
// It is now what Discord's Devices screen is: every phone signed in to this account, which
// one you are holding, and a way to throw the others off. Every field on it is real.

struct DevicesView: View {
    @State private var sessions: [DeviceSession] = []
    @State private var listener: ListenerRegistration?
    @State private var loaded = false
    @State private var confirmSignOutAll = false
    @State private var pendingSignOut: DeviceSession?
    @State private var error: String?
    @State private var working = false

    private var others: [DeviceSession] { sessions.filter { !$0.isThisDevice } }

    var body: some View {
        List {
            Section {
                if let this = sessions.first(where: { $0.isThisDevice }) {
                    row(this)
                } else if loaded {
                    // Registration failed or has not landed yet: say so rather than draw a
                    // device card out of thin air.
                    Text("This device is not registered yet. Check your connection.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } header: {
                Text("This device")
            }

            Section {
                if others.isEmpty {
                    if loaded {
                        // A reassuring empty state, not a bare strip of grey text (user feedback).
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.shield.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("No other devices").font(.subheadline.weight(.semibold))
                                Text("Only this device is signed in to your account.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        Text("Loadingâ€¦").foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(others) { s in
                        row(s)
                            .swipeActions(edge: .trailing) {
                                Button("Sign out", role: .destructive) { pendingSignOut = s }
                            }
                    }
                }
            } header: {
                Text("Other devices")
            } footer: {
                Text("If you do not recognise a device, sign it out. A device that is switched off is signed out the next time it opens, but it stops receiving messages and calls straight away.")
            }

            if !others.isEmpty {
                Section {
                    Button("Sign out all other devices", role: .destructive) {
                        confirmSignOutAll = true
                    }
                    .disabled(working)
                }
            }

            if let error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }

            Section {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lock.fill").font(.caption)
                    Text("Messages are end-to-end encrypted and stored on each device. Signing a device out stops it receiving anything new, but the messages already on it stay there.")
                }
                .font(.footnote).foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard listener == nil else { return }
            listener = DeviceRegistry.shared.listen { list in
                sessions = list
                loaded = true
            }
            if listener == nil { loaded = true }   // signed out; nothing to watch
        }
        .onDisappear { listener?.remove(); listener = nil }
        .confirmationDialog("Sign out this device?",
                            isPresented: Binding(get: { pendingSignOut != nil },
                                                 set: { if !$0 { pendingSignOut = nil } }),
                            titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                if let s = pendingSignOut { run { try await DeviceRegistry.shared.signOut(deviceId: s.id) } }
                pendingSignOut = nil
            }
            Button("Cancel", role: .cancel) { pendingSignOut = nil }
        } message: {
            Text("It will stop receiving messages and calls, and will be signed out the next time it is opened.")
        }
        .confirmationDialog("Sign out all other devices?", isPresented: $confirmSignOutAll,
                            titleVisibility: .visible) {
            Button("Sign out all", role: .destructive) {
                let list = others
                run { try await DeviceRegistry.shared.signOutAllOthers(list) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This device stays signed in.")
        }
    }

    private func row(_ s: DeviceSession) -> some View {
        HStack(spacing: 14) {
            // A colored device tile â€” the flat grey glyph read as unfinished (user feedback,
            // Telegram's device tiles as the reference; our green, our glyph).
            Image(systemName: "iphone")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(
                    LinearGradient(colors: [Color.green.opacity(0.95), Color.green.opacity(0.65)],
                                   startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(s.model).font(.body.weight(.semibold))
                    if s.isThisDevice {
                        Text("This device")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text([s.os, s.appVersion.isEmpty ? nil : "Kulan \(s.appVersion)"]
                        .compactMap { $0 }.joined(separator: " Â· "))
                    .font(.caption).foregroundStyle(.secondary)
                statusLine(s)
            }
        }
        .padding(.vertical, 4)
    }

    // "Active now" is the one piece of good news on this page â€” it gets the live green dot.
    @ViewBuilder private func statusLine(_ s: DeviceSession) -> some View {
        let text = subtitle(s)
        if text == "Active now" {
            HStack(spacing: 5) {
                Circle().fill(Color.green).frame(width: 7, height: 7)
                Text(text).font(.caption.weight(.medium)).foregroundStyle(.green)
            }
        } else {
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// "Active now" for this phone (it is, you are looking at it), a relative time for the rest.
    private func subtitle(_ s: DeviceSession) -> String {
        if s.isThisDevice { return "Active now" }
        let last = s.lastSeenAt.formatted(.relative(presentation: .named))
        guard let created = s.createdAt else { return "Last active \(last)" }
        return "Last active \(last) Â· signed in \(created.formatted(.dateTime.day().month(.abbreviated).year()))"
    }

    private func run(_ op: @escaping () async throws -> Void) {
        working = true; error = nil
        Task {
            do { try await op() }
            catch { let m = error.localizedDescription; await MainActor.run { self.error = m } }
            await MainActor.run { working = false }
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
                                .buttonStyle(.borderless)   // explicit â€” a default Button in a List row fires on ANY row tap
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
        // Confirm before unblocking â€” an accidental row tap must not silently unblock someone.
        .alert("Unblock \(toUnblock.map { $0.name(for: me) } ?? "")?",
               isPresented: Binding(get: { toUnblock != nil }, set: { if !$0 { toUnblock = nil } })) {
            Button("Cancel", role: .cancel) {}
            Button("Unblock", role: .destructive) {
                if let conv = toUnblock { Task { await ChatService.setBlocked(conv.id, false) } }
            }
        }
    }
}

// DELETED HERE: PhoneNumberPrivacyView. Kulan has no phone numbers - accounts are Apple/Google/email
// and people are found by @handle - so a page choosing who may see your number was storing a
// preference about a field that does not exist. Its own footer admitted as much. Removed 2026-07-29
// along with its Privacy row and its entry in settings search.
