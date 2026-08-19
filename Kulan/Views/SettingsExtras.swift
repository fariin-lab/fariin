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

    /// Anything on this page off its default, or any per-chat customisation anywhere.
    private var hasAnythingToReset: Bool {
        if !pushOn || !messagePreview || soundName != "rebound"
            || !inAppSound || !inAppVibrate || !inAppPreview { return true }
        if SoundStore.hasAnyCustom { return true }
        let now = Date().timeIntervalSince1970 * 1000
        return ConversationsRepository.shared.conversations.contains { $0.isMuted(me, now: now) }
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
                        // This comment used to say the push server read the preference. It did not.
                        // The value was written here and never looked at, so the switch did nothing
                        // for as long as it has existed. `onNewMessage` honours it as of 2026-08-05:
                        // OFF sends "Fariin / New message" with no sender name, no group name and no
                        // mention hint — which matters beyond the lock screen, because every field in
                        // a push travels through Apple's servers in the clear.
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
            } footer: {
                // The section had no footer at all, and "In-App Preview" says nothing on its own —
                // it is the only one of the three whose name does not describe what it does. All
                // three are real: `InAppNotify` and `PushManager` both read them.
                Text("How a message announces itself while you already have Fariin open. Preview shows the sender and the message in the banner; with it off the banner says only that something arrived.")
            }

            Section {
                Button(role: .destructive) { confirmReset = true } label: {
                    HStack {
                        Text("Reset All Notifications")
                        if resetting { Spacer(); ProgressView() }
                    }
                }
                // RED ONLY WHEN THERE IS SOMETHING TO RESET (owner 2026-08-05: "the Reset text is
                // always red, even when all settings are already at their default values"). The
                // page's own values are live @AppStorage, so the gate follows every switch as it
                // flips; the muted-chats and per-chat-tone halves are read at render, which is the
                // best a page that does not own them can do — at worst the row is red with only
                // those to undo, never grey while a visible switch is off.
                .disabled(resetting || !hasAnythingToReset)
            } footer: {
                Text("Undo all custom notification settings, including per-chat sounds and muted chats.")
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
        // THE PAGE'S OWN SETTINGS TOO (the reference app's Reset does the same): the global tone,
        // the preview switch and the in-app block go back to their defaults, on the device and on
        // the server where the server reads them. Show Notifications INCLUDED, on the owner's
        // direct order (2026-08-05: "if notifications are turned OFF, they stay OFF even after I
        // tap Reset — fix this so Reset restores the default settings"); its onChange re-registers
        // push, so flipping the value here is the whole job.
        pushOn = true
        messagePreview = true
        soundName = "rebound"
        inAppSound = true
        inAppVibrate = true
        inAppPreview = true
        try? await ProfileStore.shared.setNotifPrefs(preview: true, sound: "rebound")
        resetting = false
    }
}

// Sound picker: bundled tones, tap = hear it + choose it. The choice drives BOTH the
// lock-screen push (server reads users.notifSound) and the in-app banner tone.
struct NotificationSoundView: View {
    @AppStorage("notif.sound") private var soundName = "rebound"
    // Our own tones only. "default" was Apple's Note (the reference app's sound) and is gone; a stored
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
// It is now what the reference app's Devices screen is: every phone signed in to this account, which
// one you are holding, and a way to throw the others off. Every field on it is real.

struct DevicesView: View {
    @State private var sessions: [DeviceSession] = []
    @State private var listener: ListenerRegistration?
    @State private var loaded = false
    @State private var confirmSignOutAll = false
    @State private var pendingSignOut: DeviceSession?
    @State private var error: String?
    @State private var working = false
    @State private var autoDays = DeviceRegistry.autoSignOutDefaultDays
    @State private var autoLoaded = false

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
                                // `.tint(.red)` explicitly. `role: .destructive` only colours a
                                // swipe action while the app has not tinted itself, and this one
                                // tints `.primary`, so the button took white at night and drew
                                // white text on it. Same trap as the archive list's Delete.
                                Button("Sign out", role: .destructive) { pendingSignOut = s }
                                    .tint(.red)
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
                Picker("Sign out inactive devices", selection: $autoDays) {
                    ForEach(DeviceRegistry.autoSignOutOptions, id: \.self) { d in
                        Text(Self.autoLabel(d)).tag(d)
                    }
                }
                .disabled(!autoLoaded)
            } header: {
                Text("Automatic sign-out")
            } footer: {
                Text("A device that is not opened for this long is signed out on its own. The device you are using stays signed in as long as you keep using it.")
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
        .task {
            autoDays = await DeviceRegistry.shared.autoSignOutDays()
            autoLoaded = true
        }
        // `autoLoaded` gates the write: the first change of this value is the loaded answer
        // arriving, not a choice anybody made.
        .onChange(of: autoDays) { _, days in
            guard autoLoaded else { return }
            run { try await DeviceRegistry.shared.setAutoSignOutDays(days) }
        }
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
            // the reference app's device tiles as the reference; our green, our glyph).
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
                Text([s.os, s.appVersion.isEmpty ? nil : "Fariin \(s.appVersion)"]
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

    /// The interval the heartbeat writes on, plus a minute of slack. A device in use has written
    /// inside this window by definition, and one that has not is genuinely not in front of anybody.
    private static let activeWindow: TimeInterval = 360

    static func autoLabel(_ days: Int) -> String {
        switch days {
        case 0:   return "Never"
        case 30:  return "After 1 month"
        case 90:  return "After 3 months"
        case 180: return "After 6 months"
        case 365: return "After 1 year"
        default:  return "After \(days) days"
        }
    }

    /// "Active now" for this phone (it is, you are looking at it) AND for any other device that
    /// reported in within the heartbeat window — a second phone in your other hand is active, and
    /// saying "last active 2 minutes ago" about it was only ever true because nothing was writing.
    private func subtitle(_ s: DeviceSession) -> String {
        if s.isThisDevice { return "Active now" }
        if s.lastSeenAt > Date().addingTimeInterval(-Self.activeWindow) { return "Active now" }
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
    @State private var search = ""
    @State private var showPicker = false
    /// uid → @handle, filled once per person. A conversation carries a name and a photo but not a
    /// username, and the username is what tells two people with the same display name apart — which
    /// on a BLOCK list is the difference that matters most.
    @State private var handles: [String: String] = [:]

    private var me: String { AuthService.shared.uid ?? "" }
    private var blocked: [Conversation] {
        let all = repo.conversations.filter { $0.blockedBy[me] == true }
            .sorted { $0.updatedAtMillis > $1.updatedAtMillis }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.name(for: me).lowercased().contains(q)
                || (handles[$0.otherUid(me)] ?? "").lowercased().contains(q)
        }
    }

    private func blockedRow(_ conv: Conversation) -> some View {
        HStack(spacing: 12) {
            AvatarView(name: conv.name(for: me), photoUrl: conv.photoUrl(for: me), size: 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(conv.name(for: me)).font(.body)
                    VerifiedMark(uid: conv.otherUid(me), size: 13)
                }
                if let h = handles[conv.otherUid(me)], !h.isEmpty {
                    Text("@\(h)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    /// One fetch per blocked person, once. Anyone already known is skipped, so re-entering the page
    /// or a conversations refresh costs nothing.
    private func loadHandles() async {
        for conv in repo.conversations where conv.blockedBy[me] == true {
            let uid = conv.otherUid(me)
            guard !uid.isEmpty, handles[uid] == nil else { continue }
            if let p = await ProfileStore.shared.fetch(uid) {
                await MainActor.run { handles[uid] = p.handle }
            }
        }
    }

    var body: some View {
        List {
            Section {
                Button { showPicker = true } label: {
                    Label { Text("Block User…") } icon: { Image(systemName: "hand.raised.fill") }
                        .foregroundStyle(Color.red)
                }
            }
            Section {
                if blocked.isEmpty {
                    // Inside the List rather than replacing it, so the Block User row above stays
                    // reachable when nobody is blocked yet — which is exactly when you want it.
                    Text(search.isEmpty ? "People you block will appear here." : "No match.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    ForEach(blocked) { conv in
                        blockedRow(conv)
                            // SWIPE LEFT TO UNBLOCK, per his reference. The permanent inline Unblock
                            // button is gone: an undo-the-block action sitting in every row is one
                            // mis-tap from undoing something somebody chose deliberately, and it made
                            // each row read as a button.
                            // FULL SWIPE ALLOWED, like every other list in the app. It was off, so a
                            // swipe that kept going hit an invisible wall and did nothing — the
                            // gesture behaved differently here than in the chat list for no reason
                            // the finger can see. The confirm still stands behind it: a full swipe
                            // opens the same "Unblock?" dialog the button does, so nothing is undone
                            // by accident, which is what turning it off was trying to protect.
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button { toUnblock = conv } label: {
                                    Label("Unblock", systemImage: "hand.raised.slash")
                                }
                                .tint(.red)
                            }
                    }
                }
            } header: {
                if !blocked.isEmpty { Text("Blocked") }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
        .sheet(isPresented: $showPicker) { BlockPickerView() }
        .task(id: repo.conversations.count) { await loadHandles() }
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

/// Pick somebody to block, from the people you already have a chat with.
///
/// DELIBERATELY NOT A SEARCH OF EVERY ACCOUNT, and this is the one decision in this screen worth
/// defending. Blocking a stranger you have never met protects you from nothing: they cannot reach you
/// until they message you, and the moment they do the chat is here to be blocked from. Meanwhile a
/// directory search would turn this page into a way to test whether any given @handle exists, which
/// is a question a block list has no business answering.
private struct BlockPickerView: View {
    @Environment(\.dismiss) private var dismiss
    private var repo = ConversationsRepository.shared
    @State private var query = ""
    private var me: String { AuthService.shared.uid ?? "" }

    private var candidates: [Conversation] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return repo.conversations
            .filter { !$0.isGroup && $0.blockedBy[me] != true && !$0.otherUid(me).isEmpty }
            .filter { q.isEmpty || $0.name(for: me).lowercased().contains(q) }
            .sorted { $0.updatedAtMillis > $1.updatedAtMillis }
    }

    var body: some View {
        NavigationStack {
            List {
                if candidates.isEmpty {
                    Text(query.isEmpty ? "You have no chats to block." : "No match.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(candidates) { conv in
                        Button {
                            Task { await ChatService.setBlocked(conv.id, true) }
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(name: conv.name(for: me), photoUrl: conv.photoUrl(for: me), size: 40)
                                Text(conv.name(for: me)).foregroundStyle(.primary)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: "Search")
            .navigationTitle("Block User")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() }.tint(.primary) }
            }
        }
    }
}

// DELETED HERE: PhoneNumberPrivacyView. Fariin has no phone numbers - accounts are Apple/Google/email
// and people are found by @handle - so a page choosing who may see your number was storing a
// preference about a field that does not exist. Its own footer admitted as much. Removed 2026-07-29
// along with its Privacy row and its entry in settings search.
