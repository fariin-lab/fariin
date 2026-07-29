import SwiftUI
import PhotosUI
import UIKit
import FirebaseAuth
import FirebaseFirestore
import AuthenticationServices   // Sign in with Apple button (connect Apple in Account settings)

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
                    NavigationLink { DevicesView() } label: {
                        SettingsRowLabel("Devices", "ic_linked_devices")
                    }
                }

                Section {
                    NavigationLink { NotificationsSettingsView() } label: {
                        SettingsRowLabel("Notifications", "ic_notifications")
                    }
                    NavigationLink { AppearanceSettingsView() } label: {
                        Label("Appearance", systemImage: "paintbrush")
                    }
                    // App Icon sits at the TOP LEVEL as well as inside Appearance (user request
                    // 2026-07-29). It was only reachable three taps deep, behind Appearance, which is
                    // where people look for wallpapers and themes — not for the icon on their Home
                    // Screen. Both entry points push the same page, so there is no second copy of
                    // anything to keep in step.
                    NavigationLink { AppIconPage() } label: {
                        Label("App Icon", systemImage: "app.badge")
                    }
                    NavigationLink { StorySettingsView() } label: {
                        SettingsRowLabel("Stories", "ic_stories")
                    }
                    NavigationLink { PrivacySettingsView() } label: {
                        SettingsRowLabel("Privacy & Security", "ic_privacy")
                    }
                    NavigationLink { StorageDataView() } label: {
                        Label("Storage and Data", systemImage: "externaldrive")
                    }
                }

                Section {
                    // My QR Code lives in the top-left toolbar button — no duplicate row here.
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
    // Sign-in methods (connect another door to this same account).
    @State private var connecting: AuthService.SignInMethod?
    @State private var connectError: String?
    @State private var connectedTick = 0        // bump to re-read providerData after a link
    @State private var showConnectEmail = false

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

            signInMethodsSection

            Section {
                Button(role: .destructive) { showSignOut = true } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
                Button(role: .destructive) { showDelete = true } label: {
                    Label("Delete Account", systemImage: "trash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
            }
        }
        .listStyle(.insetGrouped)   // clean rounded cards (matches the reference)
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showConnectEmail) {
            ConnectEmailView { email, password in
                try await AuthService.shared.connectEmail(email: email, password: password)
                connectedTick += 1
            }
        }
        .alert("Couldn't connect", isPresented: Binding(get: { connectError != nil },
                                                        set: { if !$0 { connectError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(connectError ?? "") }
        .disabled(working)
        .sheet(item: $exportFile) { f in ActivityView(items: [f.url]) }
        .alert("Sign out?", isPresented: $showSignOut) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) {
                Task {
                    await Push.unregister()   // AWAITED before signOut (needs auth): stop message + CallKit ring pushes to this phone
                    // Same reason it is awaited: dropping our own row in Settings › Devices needs
                    // auth, and leaving it behind would show this phone as still signed in.
                    await DeviceRegistry.shared.removeThisDevice()
                    try? Auth.auth().signOut()
                    SessionWipe.wipeAccountData()   // this account's on-device state must not leak into the next sign-up
                    dismiss(); onSignOut()
                }
            }
        } message: {
            Text("You'll need to sign back in to use Kulan on this device.")
        }
        // Deletion is a PAGE, not a one-tap alert: it names the account, spells out what's lost,
        // and re-verifies you first (an alert can't do the provider re-auth, and skipping it is
        // what used to leave accounts half-deleted).
        .navigationDestination(isPresented: $showDelete) {
            DeleteAccountView { dismiss(); onSignOut() }
        }
    }

    // Gather profile + all chats (decrypted) into a text file, then present the share sheet.
    // MARK: - Sign-in methods

    // Which logins open this account, and a way to add another. Linking keeps the SAME uid, so
    // every chat, key and story survives — and it's how a legacy anonymous session becomes a real
    // account (sign in with Apple/Google later on a new phone instead of losing everything).
    @ViewBuilder private var signInMethodsSection: some View {
        let _ = connectedTick   // re-reads providerData after a successful link
        Section {
            ForEach(AuthService.SignInMethod.allCases) { method in
                signInRow(method)
            }
        } header: {
            Text("Sign-in Methods")
        } footer: {
            Text(AuthService.shared.isAnonymousSession
                 ? "You're signed in as a guest. Connect a login so you can get back into this account on another phone — your chats stay exactly as they are."
                 : "Connect more than one so you can always get back in. They all open this same account.")
        }
    }

    @ViewBuilder private func signInRow(_ method: AuthService.SignInMethod) -> some View {
        let identifier = AuthService.shared.connectedIdentifier(method)
        HStack(spacing: 12) {
            signInIcon(method)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(method.title).foregroundStyle(.primary)
                if let identifier, !identifier.isEmpty {
                    Text(identifier).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if connecting == method {
                ProgressView()
            } else if identifier != nil {
                // Connected: a quiet checkmark, not a button (Firebase needs at least one method,
                // and unlinking the last one would lock the account out — so no disconnect here).
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                connectButton(method)
            }
        }
    }

    @ViewBuilder private func connectButton(_ method: AuthService.SignInMethod) -> some View {
        Button("Connect") { startConnect(method) }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .disabled(connecting != nil)
            // Apple must be triggered by its own button to get the authorization sheet; it's
            // overlaid transparently so the row still reads as a plain "Connect".
            .overlay {
                if method == .apple {
                    SignInWithAppleButton(.continue) { request in
                        AuthService.shared.prepareAppleRequest(request)
                    } onCompletion: { result in
                        switch result {
                        case .success(let auth):
                            connecting = .apple
                            Task {
                                do { try await AuthService.shared.connectApple(authorization: auth); connectedTick += 1 }
                                catch { connectError = error.localizedDescription }
                                connecting = nil
                            }
                        case .failure:
                            break   // cancelled the sheet — not an error worth showing
                        }
                    }
                    .blendMode(.destinationOver)   // invisible, still tappable
                }
            }
    }

    @ViewBuilder private func signInIcon(_ method: AuthService.SignInMethod) -> some View {
        switch method {
        case .apple:  Image(systemName: "apple.logo").font(.system(size: 19)).foregroundStyle(.primary)
        case .google: GoogleGIcon(size: 20)   // the real multi-colour mark, not a letter G
        case .email:  Image(systemName: "envelope.fill").font(.system(size: 16)).foregroundStyle(.primary)
        }
    }

    private func startConnect(_ method: AuthService.SignInMethod) {
        switch method {
        case .apple:
            break                       // handled by the overlaid SignInWithAppleButton
        case .email:
            showConnectEmail = true     // needs an email + password to link
        case .google:
            connecting = .google
            Task {
                do { try await AuthService.shared.connectGoogle(); connectedTick += 1 }
                catch { connectError = error.localizedDescription }
                connecting = nil
            }
        }
    }

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

// Appearance root (user's reference): live preview, quick chat-theme cards, and four
// doors — Chat Wallpaper / Chat Color / App Icon / Night Mode — each its own page
// (AppearancePages.swift). Theme cards and the doors apply to ALL chats.
struct AppearanceSettingsView: View {
    @AppStorage("appearance") private var appearanceRaw = AppAppearance.system.rawValue
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    private var wallStore: WallpaperStore { .shared }
    private var colorStore: ChatColorStore { .shared }

    private var defaultWallpaper: ChatWallpaper {
        ChatWallpaper(stored: UserDefaults.standard.string(forKey: WallpaperStore.defaultKey))
    }
    private var defaultColor: ChatColorSpec? {
        ChatColorSpec(stored: UserDefaults.standard.string(forKey: ChatColorStore.defaultKey))
    }

    var body: some View {
        let _ = wallStore.version
        let _ = colorStore.version
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Chat Theme").font(.footnote).foregroundStyle(.secondary)
                    .textCase(.uppercase).padding(.horizontal, 6)

                VStack(spacing: 0) {
                    preview
                    themeCards
                }
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                VStack(spacing: 0) {
                    doorRow("Chat Wallpaper") { ChatWallpaperPage() }
                    Divider().padding(.leading, 16)
                    doorRow("Chat Color", accessory: AnyView(colorDot)) { ChatColorPage() }
                    Divider().padding(.leading, 16)
                    doorRow("App Icon") { AppIconPage() }
                    Divider().padding(.leading, 16)
                    doorRow("Quick Reaction",
                            accessory: AnyView(Text(QuickReaction.current))) { QuickReactionPage() }
                }
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 24, style: .continuous))

                VStack(spacing: 0) {
                    doorRow("Night Mode",
                            accessory: AnyView(Text(AppAppearance(rawValue: appearanceRaw)?.label ?? "System")
                                .foregroundStyle(.secondary))) { NightModePage() }
                }
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(AppAppearance(rawValue: appearanceRaw)?.colorScheme ?? nil)
    }

    // Live preview drawn on the CURRENT all-chats wallpaper with the CURRENT bubble color.
    private var preview: some View {
        VStack(spacing: 8) {
            Text("Today").font(.caption2.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.regularMaterial, in: Capsule())
            HStack { previewBubble("Here's a preview of the chat color.", mine: false); Spacer(minLength: 36) }
            HStack { Spacer(minLength: 36); previewBubble("The color is visible to only you.", mine: true) }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(previewBackground)
    }

    @ViewBuilder private var previewBackground: some View {
        switch defaultWallpaper {
        case .none:
            Color(.secondarySystemGroupedBackground)
        case .gradient(let id):
            if let g = ChatWallpapers.gradient(id) {
                GradientWallpaperView(g: g, dark: dark)
            } else { Color(.secondarySystemGroupedBackground) }
        case .photo(let id):
            if let img = wallStore.libraryImage(id) {
                Color.clear.overlay { Image(uiImage: img).resizable().scaledToFill() }.clipped()
            } else { Color(.secondarySystemGroupedBackground) }
        case .color(let hex):
            Color(hex: hex)
        case .preset(let id):
            if let img = WallpaperPreset(id: id).image() {
                Color.clear.overlay { Image(uiImage: img).resizable().scaledToFill() }.clipped()
            } else { Color(.secondarySystemGroupedBackground) }
        }
    }

    private func previewBubble(_ text: String, mine: Bool) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(mine ? Color.white : Color.primary)
            .padding(.horizontal, 13).padding(.vertical, 8)
            .background(mine ? (defaultColor.map { AnyShapeStyle($0.fill) } ?? AnyShapeStyle(Theme.defaultBubble(dark)))
                             : AnyShapeStyle(Color(.systemGray5)),
                        in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    // Quick theme cards. A THEME = wallpaper + paired bubble colour (user request): one tap
    // applies BOTH to all chats, and the card previews both so what you see is what you get.
    private var themeCards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(ChatWallpapers.all) { g in
                    let themeColor = ChatColorSpec(colors: [g.bubbleHex])
                    // Selected only when BOTH halves of the theme are the active ones.
                    let isSel = defaultWallpaper == .gradient(g.id)
                        && defaultColor?.stored == themeColor.stored
                    Button {
                        wallStore.applyToAllChats(.gradient(g.id))
                        colorStore.applyToAllChats(themeColor)
                    } label: {
                        VStack(spacing: 6) {
                            Capsule().fill(.white.opacity(0.9)).frame(width: 44, height: 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Capsule().fill(themeColor.solid).frame(width: 44, height: 12)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .padding(10)
                        .frame(width: 92, height: 118)
                        .background(GradientWallpaperView(g: g, dark: dark))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(isSel ? Color.accentColor : .clear, lineWidth: 2.5)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
    }

    private var colorDot: some View {
        Circle()
            .fill(defaultColor.map { AnyShapeStyle($0.fill) } ?? AnyShapeStyle(Theme.defaultBubble(dark)))
            .frame(width: 22, height: 22)
    }

    private func doorRow<D: View>(_ title: String,
                                  accessory: AnyView? = nil,
                                  @ViewBuilder destination: @escaping () -> D) -> some View {
        NavigationLink { destination() } label: {
            HStack(spacing: 12) {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if let accessory { accessory }
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// Privacy & Security, the user's reference structure. Two-Step Verification and
// Passkeys are DELIBERATELY absent: they protect a login, and anonymous accounts have
// none — they arrive with account linking. Everything below is real today.
struct PrivacySettingsView: View {
    private var repo = ConversationsRepository.shared
    private var me: String { AuthService.shared.uid ?? "" }
    private var blockedCount: Int { repo.conversations.filter { $0.blockedBy[me] == true }.count }
    @AppStorage("defaultDisappearSeconds") private var defaultDisappear = 0
    @AppStorage("priv.lastSeen") private var privLastSeen = "everyone"
    @AppStorage("priv.photo") private var privPhoto = "everyone"
    @AppStorage("priv.bio") private var privBio = "everyone"
    @AppStorage("priv.calls") private var privCalls = "everyone"
    @AppStorage("priv.groups") private var privGroups = "everyone"
    @State private var showDefaultDisappear = false

    private func label(_ raw: String) -> String {
        (Audience(rawValue: raw) ?? .everyone).label
    }

    var body: some View {
        List {
            Section {
                NavigationLink { BlockedUsersView() } label: {
                    HStack {
                        Text("Blocked Users")
                        Spacer()
                        Text("\(blockedCount)").foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button { showDefaultDisappear = true } label: {
                    HStack {
                        Text("Disappearing Messages").foregroundStyle(.primary)
                        Spacer()
                        Text(ChatService.disappearLabel(defaultDisappear)).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.tertiary)
                    }
                }
            } footer: {
                Text("Automatically delete messages for everyone after a period of time in all new chats you start.")
            }

            Section {
                NavigationLink { AppLockPage() } label: { Text("App Lock") }
            } footer: {
                Text("Require Face ID to unlock Kulan.")
            }

            Section {
                NavigationLink { PhoneNumberPrivacyView() } label: { Text("Phone Number") }
                audienceRow("Last Seen & Online", key: "lastSeen", value: privLastSeen,
                            footerText: "Who can see when you're online and when you were last active.")
                audienceRow("Profile Picture", key: "photo", value: privPhoto,
                            footerText: "Who can see your profile photo when they find you on Kulan.")
                audienceRow("Bio", key: "bio", value: privBio,
                            footerText: "Who can see the few words about you.")
                audienceRow("Calls", key: "calls", value: privCalls,
                            footerText: "Who can call you. Calls from anyone else are declined automatically.")
                NavigationLink { MessagesPrivacyPage() } label: { Text("Messages") }
                if Flags.groupsEnabled {
                    audienceRow("Groups", key: "groups", value: privGroups,
                                footerText: "Who can add you to groups.")
                }
            }
        }
        .navigationTitle("Privacy & Security")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showDefaultDisappear) {
            DisappearingMessagesView(cid: "", current: defaultDisappear) { defaultDisappear = $0 }
        }
    }

    private func audienceRow(_ title: String, key: String, value: String, footerText: String) -> some View {
        NavigationLink { AudiencePage(title: title, key: key, footer: footerText) } label: {
            HStack {
                Text(title)
                Spacer()
                Text(label(value)).foregroundStyle(.secondary)
            }
        }
    }
}

// Help & About, reference shape: support rows on top, About block below. Storage moved to
// its own Settings page — the old Clear Cache button here also wiped AudioCache, and voice
// notes are ONLY-copies (mailman model), so that button was silent data loss. Gone.
struct AboutView: View {
    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }
    private var buildNumber: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "1"
    }
    var body: some View {
        List {
            Section {
                Link(destination: URL(string: "https://kulan-2ef85.web.app")!) {
                    Text("Support Center").foregroundStyle(.primary)
                }
                Link(destination: URL(string: "mailto:kulanchat@gmail.com")!) {
                    Text("Report a Problem").foregroundStyle(.primary)
                }
            } footer: {
                Text("Kulan has zero tolerance for objectionable content or abusive behavior. Reports are reviewed within 24 hours.")
            }
            Section {
                LabeledContent("Version", value: "\(appVersion) (\(buildNumber))")
                Link(destination: URL(string: "https://kulan-2ef85.web.app/privacy.html")!) {
                    Text("Privacy Policy").foregroundStyle(.primary)
                }
                Link(destination: URL(string: "https://kulan-2ef85.web.app/terms.html")!) {
                    Text("Terms & Conditions").foregroundStyle(.primary)
                }
            } header: {
                Text("About")
            } footer: {
                Text("End-to-end encrypted. Made for Somalia.")
            }
        }
        .navigationTitle("Help & About")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Story Settings

// Stories settings, user's reference layout: View Receipts on top, the red opt-out below.
struct StorySettingsView: View {
    @AppStorage("storyViewReceipts") private var viewReceipts = true
    @AppStorage("storiesOptedOut") private var optedOut = false
    @State private var confirmOff = false

    var body: some View {
        List {
            if !optedOut {
                Section {
                    Toggle("View Receipts", isOn: $viewReceipts).tint(.green)
                } footer: {
                    Text("See and share when stories are viewed. If disabled, you won't see when others view your stories.")
                }
            }
            Section {
                if optedOut {
                    Button("Turn On Stories") {
                        withAnimation { optedOut = false }
                    }
                } else {
                    Button("Turn Off Stories", role: .destructive) { confirmOff = true }
                }
            } footer: {
                Text(optedOut
                     ? "Stories are off. Turn them back on to share and view stories again."
                     : "If you opt out of stories you will no longer be able to share or view stories.")
            }
        }
        .navigationTitle("Stories")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Turn off stories?", isPresented: $confirmOff) {
            Button("Cancel", role: .cancel) {}
            Button("Turn Off", role: .destructive) { withAnimation { optedOut = true } }
        } message: {
            Text("The stories row disappears and you won't share or view stories. Any story you already posted still expires on its own after 24 hours.")
        }
    }
}

// MARK: - Edit Profile

// A picked image awaiting the circular profile cropper (Identifiable for fullScreenCover).
private struct CropItem: Identifiable { let id = UUID(); let image: UIImage }

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
    @State private var localPreview: UIImage?   // picked photo, shown instantly while uploading
    @State private var cropCandidate: CropItem?   // picked image awaiting the circular cropper
    @State private var confirmRemovePhoto = false   // Remove asks first (user request)
    @State private var showEditPhoto = false        // Edit Photo menu (Choose / Remove)
    @State private var showPhotoPicker = false       // programmatic PhotosPicker present
    @State private var saving = false
    @State private var error: String?
    // What the fields held when the sheet opened — closing with UNSAVED text edits asks
    // before discarding (silent loss was the gap; photo changes apply instantly and are
    // never part of Save). Captured in onAppear.
    @State private var origFirst = ""
    @State private var origLast = ""
    @State private var origHandle = ""
    @State private var origAbout = ""
    @State private var confirmDiscard = false
    private var hasUnsavedText: Bool {
        firstName != origFirst || lastName != origLast || handle != origHandle || about != origAbout
    }

    var body: some View {
        NavigationStack {
            Form {
                // Avatar header on the plain grouped background (Contacts / Settings edit style).
                Section {
                    // One "Edit Photo" pill (reference look). Avatar or button opens a menu:
                    // Choose Photo / Remove Photo. Each control is .plain + own contentShape so a
                    // Form-default button can't stretch its tap zone across the whole row.
                    VStack(spacing: 12) {
                        Button { showEditPhoto = true } label: {
                            ZStack {
                                AvatarView(name: firstName, photoUrl: profile.me?.photoUrl, size: 100)
                                if let localPreview {
                                    Image(uiImage: localPreview).resizable().scaledToFill()
                                        .frame(width: 100, height: 100).clipShape(Circle())
                                }
                            }
                            .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        Button { showEditPhoto = true } label: {
                            Text("Edit Photo").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                .padding(.horizontal, 20).frame(height: 36)
                                .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(uploading)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    // Attached HERE, on the avatar section, NOT on the outer view: that chain
                    // already carries a confirmationDialog (discard changes) and an alert (remove
                    // photo), and stacking a second confirmationDialog on the same view made this
                    // one silently never present — tapping "Edit Photo" did nothing.
                    // Bottom sheet, not confirmationDialog (iOS 26 anchors that to the button as a
                    // callout). The picked action runs in the sheet's onDismiss, which is also what
                    // lets the photo picker / remove alert present at all from here.
                    .bottomActionSheet("Profile Photo", isPresented: $showEditPhoto, actions: {
                        var a: [SheetAction] = [SheetAction("Choose Photo") { showPhotoPicker = true }]
                        if profile.me?.photoUrl?.isEmpty == false {
                            a.append(SheetAction("Remove Photo", role: .destructive) { confirmRemovePhoto = true })
                        }
                        return a
                    }())
                    .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
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
                    ToolbarItem(placement: .cancellationAction) {
                        CloseXButton { if hasUnsavedText { confirmDiscard = true } else { dismiss() } }
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        CloseXButton { if hasUnsavedText { confirmDiscard = true } else { dismiss() } }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .fontWeight(.semibold)
                        .disabled(saving || !hasUnsavedText)   // nothing to save → Save sleeps (no ghost tap)
                }
            }
            .onAppear {
                let parts = (profile.me?.name ?? "").split(separator: " ", maxSplits: 1).map(String.init)
                firstName = parts.first ?? ""
                lastName = parts.count > 1 ? parts[1] : ""
                handle = profile.me?.handle ?? ""
                about = profile.me?.about ?? ""
                origFirst = firstName; origLast = lastName
                origHandle = handle; origAbout = about
            }
            // A swipe-down with unsaved text edits must not silently discard them either.
            .interactiveDismissDisabled(hasUnsavedText)
            .confirmationDialog("Discard changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text("Your name, username or bio edits are not saved yet.")
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }   // ignore our own reset in upload() — don't cancel a live upload
                // Picking a photo now opens a CIRCULAR move-and-scale cropper first, so you
                // control exactly how it's framed before it's set (user request).
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let img = UIImage(data: data) else { photoItem = nil; return }
                    await MainActor.run { cropCandidate = CropItem(image: img); photoItem = nil }
                }
            }
            .fullScreenCover(item: $cropCandidate) { c in
                TOCropView(image: c.image, circular: true,
                           onDone: { cropped in
                               cropCandidate = nil
                               uploadTask?.cancel()
                               uploadTask = Task { await uploadCropped(cropped) }
                           },
                           onCancel: { cropCandidate = nil })
                    .ignoresSafeArea()
            }
            .alert("Remove profile photo?", isPresented: $confirmRemovePhoto) {
                Button("Cancel", role: .cancel) {}
                Button("Remove", role: .destructive) {
                    uploadTask?.cancel()
                    uploadTask = Task { await removePhoto() }
                }
            } message: {
                Text("Your photo will be removed and your initials will show instead.")
            }
        }
    }

    // The CROPPED image (from the circular cropper) is what gets uploaded — shown instantly
    // as a local preview, upload runs silently behind it (the seamless WhatsApp feel kept).
    private func uploadCropped(_ image: UIImage) async {
        guard let data = image.jpegData(compressionQuality: 0.92) else { return }
        uploading = true; error = nil
        do {
            if Task.isCancelled { uploading = false; return }
            localPreview = image
            try await profile.uploadPhoto(data)
            localPreview = nil
        } catch {
            localPreview = nil
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

// Connect an email + password login to the CURRENT account (Account > Sign-in Methods).
// Not a sign-up: it attaches another way into the account you're already in.
struct ConnectEmailView: View {
    /// Throws on failure; the sheet shows the message and stays open so the user can fix it.
    var onConnect: (String, String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var canSubmit: Bool {
        email.contains("@") && password.count >= 6 && !busy
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("you@example.com", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                    SecureField("At least 6 characters", text: $password)
                        .textContentType(.newPassword)
                } header: {
                    Text("Email login")
                } footer: {
                    Text("You'll be able to log into this same account with this email and password.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Connect Email")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button("Connect") {
                            busy = true; error = nil
                            Task {
                                do {
                                    try await onConnect(email.trimmingCharacters(in: .whitespaces), password)
                                    dismiss()
                                } catch {
                                    self.error = error.localizedDescription
                                }
                                busy = false
                            }
                        }
                        .fontWeight(.semibold)
                        .disabled(!canSubmit)
                    }
                }
            }
            .onAppear { focused = true }
        }
    }
}
