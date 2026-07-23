import SwiftUI
import PhotosUI
import UIKit
import FirebaseAuth
import FirebaseFirestore

// Custom-SVG row label (template asset tinted like an SF Symbol, sized to a list row).
private struct SettingsRowLabel: View {
    let title: String
    let image: String
    init(_ title: String, _ image: String) { self.title = title; self.image = image }
    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(image).renderingMode(.template).resizable().scaledToFit().frame(width: 22, height: 22)
        }
    }
}

// Parent settings — profile cell on top, then grouped rows that push to dedicated
// sub-screens (the standard settings structure), built our way with native List.
struct SettingsView: View {
    var onSignOut: () -> Void
    var asTab = false   // true when shown as a bottom tab (no "Done" — nothing to dismiss)
    init(onSignOut: @escaping () -> Void, asTab: Bool = false) {
        self.onSignOut = onSignOut
        self.asTab = asTab
    }

    @Environment(\.dismiss) private var dismiss
    private var profile = ProfileStore.shared
    @AppStorage("appearance") private var appearanceRaw = AppAppearance.system.rawValue
    @State private var showEdit = false
    @State private var showQR = false

    private var inviteText: String {
        let h = profile.me?.handle ?? ""
        return h.isEmpty ? "Chat with me on Kulan." : "Chat with me on Kulan — my username is @\(h)"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { showEdit = true } label: { profileHeader }
                        .buttonStyle(.plain)
                }
                .listRowBackground(Color.clear)

                Section {
                    NavigationLink { AccountSettingsView(onSignOut: onSignOut) } label: {
                        SettingsRowLabel("Account", "ic_account")
                    }
                }

                Section {
                    NavigationLink { NotificationsSettingsView() } label: {
                        SettingsRowLabel("Notifications", "ic_notifications")
                    }
                    NavigationLink { AppearanceSettingsView() } label: {
                        Label("Appearance", systemImage: "paintbrush")
                    }
                    NavigationLink { StorySettingsView() } label: {
                        SettingsRowLabel("Stories", "ic_stories")
                    }
                    NavigationLink { PrivacySettingsView() } label: {
                        SettingsRowLabel("Privacy & Security", "ic_privacy")
                    }
                }

                Section {
                    Button { showQR = true } label: { SettingsRowLabel("My QR Code", "ic_qr") }
                    ShareLink(item: inviteText) { Label("Invite Friends", systemImage: "person.badge.plus") }
                    NavigationLink { AboutView() } label: {
                        Label("Help & About", systemImage: "questionmark.circle")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .listSectionSpacing(.compact)   // tighten the dead space between blocks
            .contentMargins(.top, 4, for: .scrollContent)   // remove the big gap above the avatar
            .preferredColorScheme(AppAppearance(rawValue: appearanceRaw)?.colorScheme ?? nil)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showQR = true } label: { Image(systemName: "qrcode") }.tint(.primary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit") { showEdit = true }.tint(.primary)
                }
                if !asTab {
                    ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
                }
            }
            .sheet(isPresented: $showEdit) { EditProfileView() }
            .sheet(isPresented: $showQR) { MyQRView() }
        }
    }

    // Centered profile header (mockup style): big avatar, name, @handle. Tap to edit.
    private var profileHeader: some View {
        VStack(spacing: 8) {
            AvatarView(name: profile.me?.name ?? "", photoUrl: profile.me?.photoUrl, size: 96)
            Text(profile.me?.name ?? "You")
                .font(.title2.weight(.bold)).foregroundStyle(.primary)
            if let h = profile.me?.handle, !h.isEmpty {
                Text("@\(h)").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
    }
}

// MARK: - My Profile

// Your own profile, shown the way other people see it (hero avatar, name, @handle, bio),
// with your own Stories section below. Edit lives in the top-right (opens EditProfileView).
struct MyProfileView: View {
    private var profile = ProfileStore.shared
    @State private var stories = StoriesRepository.shared
    @State private var viewerGroup: StoryGroup?
    @State private var showEdit = false
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }
    private var cardColor: Color { dark ? Color(hex: 0x1C1C1E) : Color(hex: 0xF2F2F7) }
    private var title: String {
        if let h = profile.me?.handle, !h.isEmpty { return "@\(h)" }
        return profile.me?.name ?? "My Profile"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                hero
                if let about = profile.me?.about, !about.isEmpty { bioCard(about) }
                storiesSection
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("Edit") { showEdit = true }.tint(.primary) }
        }
        .sheet(isPresented: $showEdit) { EditProfileView() }
        .task { await stories.load() }
        .fullScreenCover(item: $viewerGroup) { g in
            StoryViewer(group: g, ownSwipeDismiss: true) { viewerGroup = nil; Task { await stories.load(force: true) } }
        }
    }

    private var hero: some View {
        VStack(spacing: 6) {
            AvatarView(name: profile.me?.name ?? "", photoUrl: profile.me?.photoUrl, size: 96)
            Text(profile.me?.name ?? "You").font(.title.weight(.bold))
            if let h = profile.me?.handle, !h.isEmpty {
                Text("@\(h)").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private func bioCard(_ about: String) -> some View {
        Text(about).font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(cardColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder private var storiesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("My Stories").font(.headline)
            if let mine = stories.mine, !mine.stories.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(mine.stories) { s in
                            AsyncImage(url: URL(string: s.previewUrl)) { p in
                                if let img = p.image { img.resizable().scaledToFill() }
                                else { Color.secondary.opacity(0.2) }
                            }
                            .frame(width: 92, height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .contentShape(Rectangle())
                            .onTapGesture { viewerGroup = mine }
                        }
                    }
                }
            } else {
                Text("You have no active stories.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(cardColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Sub-pages

struct AccountSettingsView: View {
    var onSignOut: () -> Void
    init(onSignOut: @escaping () -> Void) { self.onSignOut = onSignOut }

    @Environment(\.dismiss) private var dismiss
    private var profile = ProfileStore.shared
    @State private var showDelete = false
    @State private var showSignOut = false
    @State private var working = false
    @State private var deleteError: String?
    @State private var exporting = false
    @State private var exportFile: ExportFile?

    var body: some View {
        List {
            // No avatar header and no profile fields here (username/name/bio/photo all live in
            // Edit Profile, reached from the Settings header). Account is ONLY data + session
            // actions — a settings page, not profile management (user direction 2026-07-22).
            Section {
                Button { Task { await exportData() } } label: {
                    HStack {
                        Label("Export My Data", systemImage: "square.and.arrow.up")
                        Spacer()
                        if exporting { ProgressView() }
                    }
                }
                .tint(.primary)
                .disabled(exporting)
            } footer: {
                Text("Saves your profile and all chats to a text file you can share or keep.")
            }

            Section {
                Button(role: .destructive) { showSignOut = true } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
                Button(role: .destructive) { showDelete = true } label: {
                    Label("Delete Account", systemImage: "trash")
                }
            }
        }
        .listStyle(.insetGrouped)   // clean rounded cards (matches the reference)
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(working)
        .sheet(item: $exportFile) { f in ActivityView(items: [f.url]) }
        .alert("Sign out?", isPresented: $showSignOut) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) {
                Task {
                    await Push.unregister()   // AWAITED before signOut (needs auth): stop message + CallKit ring pushes to this phone
                    try? Auth.auth().signOut()
                    SessionWipe.wipeAccountData()   // this account's on-device state must not leak into the next sign-up
                    dismiss(); onSignOut()
                }
            }
        } message: {
            Text("You'll need to sign back in to use Kulan on this device.")
        }
        .alert("Delete account?", isPresented: $showDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task {
                    working = true
                    do {
                        try await profile.deleteAccount()
                        SessionWipe.wipeAccountData()   // server data is gone; clear the device copy too
                        working = false; dismiss(); onSignOut()   // only sign out if the server delete SUCCEEDED
                    } catch {
                        working = false
                        deleteError = error.localizedDescription   // failed delete must NOT look like success
                    }
                }
            }
        } message: {
            Text("This permanently deletes your account and profile. This can't be undone.")
        }
        .alert("Couldn't delete account", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteError ?? "Please try again.")
        }
    }

    // Gather profile + all chats (decrypted) into a text file, then present the share sheet.
    private func exportData() async {
        exporting = true
        let me = AuthService.shared.uid ?? ""
        var out = "Kulan — Data Export\n\n"
        out += "Name: \(profile.me?.name ?? "")\n"
        out += "Username: @\(profile.me?.handle ?? "")\n"
        if let about = profile.me?.about, !about.isEmpty { out += "Bio: \(about)\n" }
        out += "Account ID: \(me)\n\n"

        let convs = await MainActor.run {
            ConversationsRepository.shared.conversations
                .filter { !$0.isCleared(me) }
                .filter { Flags.groupsEnabled || !$0.isGroup }
        }
        let db = Firestore.firestore()
        for c in convs {
            _ = await Crypto.shared.preloadKey(c.otherUid(me))
            out += "===== Chat with \(c.name(for: me)) =====\n"
            if let snap = try? await db.collection("conversations").document(c.id)
                .collection("messages").order(by: "createdAt").getDocuments() {
                for d in snap.documents {
                    let m = Message(id: d.documentID, data: d.data(), cid: c.id, crypto: Crypto.shared)
                    let who = m.authorId == me ? "You" : c.name(for: me)
                    let when = m.createdAt.formatted(date: .abbreviated, time: .shortened)
                    let body = m.isImage ? "[Photo]" : (m.isAudio ? "[Voice message]"
                              : (m.isCall ? "[Call]" : m.text))
                    out += "[\(when)] \(who): \(body)\n"
                }
            }
            out += "\n"
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Kulan-Data-Export.txt")
        try? out.write(to: url, atomically: true, encoding: .utf8)
        await MainActor.run { exportFile = ExportFile(url: url); exporting = false }
    }
}

// Wraps a file URL so it can drive a .sheet(item:).
struct ExportFile: Identifiable { let id = UUID(); let url: URL }

// Native share sheet.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct AppearanceSettingsView: View {
    @AppStorage("appearance") private var appearanceRaw = AppAppearance.system.rawValue
    var body: some View {
        List {
            Section {
                Picker("Theme", selection: $appearanceRaw) {
                    ForEach(AppAppearance.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                Text("Choose how Kulan looks. System follows your device setting.")
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(AppAppearance(rawValue: appearanceRaw)?.colorScheme ?? nil)
    }
}

struct PrivacySettingsView: View {
    private var repo = ConversationsRepository.shared
    private var me: String { AuthService.shared.uid ?? "" }
    private var blockedCount: Int { repo.conversations.filter { $0.blockedBy[me] == true }.count }
    @AppStorage("appLockEnabled") private var appLock = false
    @AppStorage("appLockDelay") private var lockDelay = 0   // grace period (seconds) before re-locking
    @AppStorage("screenSecurity") private var screenSecurity = false
    @AppStorage("readReceipts") private var readReceipts = true
    @AppStorage("typingIndicators") private var typingIndicators = true
    @AppStorage("shareLastSeen") private var shareLastSeen = true
    @AppStorage("telegramMediaOpen") private var telegramMediaOpen = false
    var body: some View {
        List {
            // (The standard message list is now THE list — the experimental toggle and the old
            // SwiftUI fallback were removed 2026-07-11 per user decision. The 2026-07-14
            // Telegram-engine test toggle was likewise removed after the comparison.)
            Section {
                Toggle(isOn: $telegramMediaOpen) { Label("Telegram Media Open", systemImage: "photo.on.rectangle.angled") }.tint(.green)
            } footer: {
                Text("Experimental test: photos and videos open from the message bubble with Telegram's animation (the image itself springs to full screen and flies back on close) instead of the system zoom. Applies to single photo/video taps in chats. Turn off to compare.")
            }

            Section {
                Toggle(isOn: $readReceipts) { Label("Read Receipts", systemImage: "checkmark.circle") }.tint(.green)
                Toggle(isOn: $typingIndicators) { Label("Typing Indicators", systemImage: "ellipsis.bubble") }.tint(.green)
                Toggle(isOn: $shareLastSeen) { Label("Last Seen & Online", systemImage: "clock") }.tint(.green)
            } footer: {
                Text("These are reciprocal — if you turn one off, you won't see it from others either.")
            }

            Section {
                NavigationLink { BlockedUsersView() } label: {
                    HStack {
                        Label("Blocked Users", systemImage: "hand.raised")
                        Spacer()
                        Text("\(blockedCount)").foregroundStyle(.secondary)
                    }
                }
                NavigationLink { PhoneNumberPrivacyView() } label: {
                    Label("Phone Number", systemImage: "phone")
                }
            }

            Section {
                Toggle(isOn: $appLock) { Label("App Lock", systemImage: "faceid") }.tint(.green)
                if appLock {
                    Picker(selection: $lockDelay) {
                        Text("Immediately").tag(0)
                        Text("After 1 minute").tag(60)
                        Text("After 5 minutes").tag(300)
                        Text("After 1 hour").tag(3600)
                    } label: { Label("Auto-Lock", systemImage: "clock.arrow.circlepath") }
                }
                Toggle(isOn: $screenSecurity) { Label("Screen Security", systemImage: "eye.slash") }.tint(.green)
            } footer: {
                Text("App Lock requires Face ID / passcode to open Kulan. Auto-Lock sets how long Kulan can be in the background before it locks again. Screen Security hides the app preview in the multitasking switcher.")
            }

            Section {
                Label("End-to-end encrypted", systemImage: "lock.fill")
            } footer: {
                Text("Every message is end-to-end encrypted. The private key lives only on your device — the server can never read your messages.")
            }
        }
        .navigationTitle("Privacy & Security")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AboutView: View {
    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }
    @State private var storageText = "Calculating…"
    @State private var clearing = false
    var body: some View {
        List {
            Section {
                LabeledContent("Version", value: appVersion)
                Label("End-to-end encrypted", systemImage: "lock.fill")
            } footer: {
                Text("Kulan — a Somali messenger. Made for Somalia.")
            }
            Section {
                LabeledContent("Cached media", value: storageText)
                Button {
                    clearing = true
                    Task { await clearCache(); storageText = await computeStorage(); clearing = false }
                } label: {
                    HStack { Label("Clear Cache", systemImage: "trash"); Spacer(); if clearing { ProgressView() } }
                }
                .disabled(clearing)
            } footer: {
                Text("Frees photos and voice notes downloaded to this device. Your messages are never deleted.")
            }
            Section {
                Link(destination: URL(string: "https://kulan-2ef85.web.app/privacy.html")!) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
                Link(destination: URL(string: "https://kulan-2ef85.web.app/terms.html")!) {
                    Label("Terms & Conditions", systemImage: "doc.text")
                }
                Link(destination: URL(string: "mailto:kulanchat@gmail.com")!) {
                    Label("Report a Problem", systemImage: "envelope")
                }
            } footer: {
                Text("Kulan has zero tolerance for objectionable content or abusive behavior. Reports are reviewed within 24 hours.")
            }
        }
        .navigationTitle("Help & About")
        .navigationBarTitleDisplayMode(.inline)
        .task { storageText = await computeStorage() }
    }

    // Measure downloaded media (temp files + URL cache) off the main thread.
    private func computeStorage() async -> String {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            var total = Int64(URLCache.shared.currentDiskUsage)
            total += Int64(DiskImageCache.shared.diskBytes())   // persistent image/story cache
            total += Int64(AudioCache.diskBytes())              // persistent voice notes
            if let en = fm.enumerator(at: fm.temporaryDirectory, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let url as URL in en {
                    total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
            }
            let f = ByteCountFormatter(); f.allowedUnits = [.useMB, .useKB]; f.countStyle = .file
            return f.string(fromByteCount: total)
        }.value
    }

    // Remove cached/downloaded media only — never touches messages or keys.
    private func clearCache() async {
        DiskImageCache.shared.clear()   // persistent image/story disk cache (memory + disk)
        AudioCache.clear()              // persistent voice notes (re-download on next play)
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            if let items = try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil) {
                for url in items { try? fm.removeItem(at: url) }
            }
            URLCache.shared.removeAllCachedResponses()
        }.value
    }
}

// MARK: - Story Settings

struct StorySettingsView: View {
    @AppStorage("storyViewReceipts") private var viewReceipts = true

    var body: some View {
        List {
            Section {
                Toggle("Share View Receipts", isOn: $viewReceipts)
            } footer: {
                Text("If on, people see when you've viewed their status, and you can see who viewed yours. If off, neither is shared.")
            }
            Section {
                LabeledContent("Who can see my status", value: "Your chats")
            } footer: {
                Text("Your status is visible for 24 hours to everyone you've chatted with, then it's deleted automatically.")
            }
        }
        .navigationTitle("Stories")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Edit Profile

struct EditProfileView: View {
    @Environment(\.dismiss) private var dismiss
    private var profile = ProfileStore.shared
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var handle = ""
    @State private var about = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var uploadTask: Task<Void, Never>?
    @State private var uploading = false
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                // Avatar header on the plain grouped background (Contacts / Settings edit style).
                Section {
                    VStack(spacing: 10) {
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            AvatarView(name: firstName, photoUrl: profile.me?.photoUrl, size: 100)
                                .overlay { if uploading { ZStack { Circle().fill(.black.opacity(0.3)); ProgressView().tint(.white) } } }
                        }
                        .buttonStyle(.plain)
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            Text("Change Photo").font(.subheadline)
                        }
                        if profile.me?.photoUrl?.isEmpty == false {
                            Button(role: .destructive) {
                                uploadTask?.cancel()
                                uploadTask = Task { await removePhoto() }
                            } label: {
                                Text("Remove Photo").font(.subheadline)
                            }
                            .disabled(uploading)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }

                Section {
                    TextField("First name", text: $firstName)
                        .textInputAutocapitalization(.words)
                        .onChange(of: firstName) { _, v in if v.count > 40 { firstName = String(v.prefix(40)) } }
                    TextField("Last name", text: $lastName)
                        .textInputAutocapitalization(.words)
                        .onChange(of: lastName) { _, v in if v.count > 40 { lastName = String(v.prefix(40)) } }
                }

                Section {
                    NavigationLink {
                        UsernameEditView(handle: $handle)
                    } label: {
                        HStack {
                            Text("Username")
                            Spacer()
                            Text(handle.isEmpty ? "Set" : "@\(handle)").foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    TextField("A few words about you", text: $about, axis: .vertical)
                        .lineLimit(1...5)
                        .onChange(of: about) { _, v in if v.count > 140 { about = String(v.prefix(140)) } }
                } header: {
                    Text("Bio")
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Hide the toolbar's own glass so CloseXButton's circle isn't double-wrapped (iOS 26).
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .cancellationAction) { CloseXButton { dismiss() } }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .cancellationAction) { CloseXButton { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.fontWeight(.semibold).disabled(saving)
                }
            }
            .onAppear {
                let parts = (profile.me?.name ?? "").split(separator: " ", maxSplits: 1).map(String.init)
                firstName = parts.first ?? ""
                lastName = parts.count > 1 ? parts[1] : ""
                handle = profile.me?.handle ?? ""
                about = profile.me?.about ?? ""
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }   // ignore our own reset in upload() — don't cancel a live upload
                uploadTask?.cancel()
                uploadTask = Task { await upload(item) }
            }
        }
    }

    private func upload(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        // Reset on every exit so re-picking (even the same photo) fires onChange again
        // (WallpaperPickerSheet pattern). onChange guards nil, so this never cancels a newer pick.
        defer { photoItem = nil }
        uploading = true; error = nil
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { uploading = false; return }
            if Task.isCancelled { uploading = false; return }   // a newer pick superseded this one
            try await profile.uploadPhoto(data)
        } catch {
            self.error = "Photo upload failed: \(error.localizedDescription)"
        }
        uploading = false
    }

    private func removePhoto() async {
        uploading = true; error = nil
        do { try await profile.removePhoto() }
        catch { self.error = "Could not remove photo: \(error.localizedDescription)" }
        uploading = false
    }

    private func save() async {
        let n = "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces)
        let h = ChatService.sanitizeHandle(handle)
        guard !n.isEmpty else { error = "Enter your name"; return }
        guard ChatService.isValidHandle(h) else {
            error = "Username: letters, numbers and _ only, 3–30 characters"; return
        }
        saving = true; error = nil
        do {
            if let existing = await ChatService.findByHandle(h), existing.id != AuthService.shared.uid {
                error = "That username is taken"; saving = false; return
            }
            try await profile.updateProfile(name: n, handle: h, about: about)
            dismiss()
        } catch {
            self.error = "Could not save: \(error.localizedDescription)"
        }
        saving = false
    }
}

// Dedicated username editor — pushed from Edit Profile (Apple pattern: a sub-screen with a back
// button + Done), one @field in a grouped section with a footer of rules.
struct UsernameEditView: View {
    @Binding var handle: String
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                HStack(spacing: 2) {
                    Text("@").foregroundStyle(.secondary)
                    TextField("username", text: $draft)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().focused($focused)
                        .onChange(of: draft) { _, v in let c = ChatService.sanitizeHandle(v); if c != v { draft = c } }
                }
            } footer: {
                Text("Letters, numbers and _ only. 3–30 characters.")
            }
        }
        .navigationTitle("Username")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { handle = ChatService.sanitizeHandle(draft); dismiss() }.fontWeight(.semibold)
            }
        }
        .onAppear { draft = handle; focused = true }
    }
}
