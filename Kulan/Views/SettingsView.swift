import SwiftUI
import PhotosUI
import UIKit
import FirebaseAuth
import FirebaseFirestore
import AuthenticationServices   // Sign in with Apple button (connect Apple in Account settings)

// Custom-SVG row label (template asset tinted like an SF Symbol, sized to a list row).
// ONE row style for every settings row (the owner's the reference app side-by-side: ours read cramped and
// mixed — some rows had asset icons, some plain SF labels, all at the 44pt List default).
// the reference app's rhythm: ~54pt rows, a steady 26pt icon column, 17pt text.
// Not private: the settings SEARCH results draw their rows with this too. They used to build
// their own Labels from SF Symbols, so searching "Devices" produced a row that looked nothing like
// the Devices row one tap away (owner screenshot). One row style, one icon set, one place to change
// them.
struct SettingsRowLabel: View {
    let title: String
    let image: String
    var system = false
    init(_ title: String, _ image: String) { self.title = title; self.image = image }
    init(_ title: String, system: String) { self.title = title; self.image = system; self.system = true }
    var body: some View {
        Label {
            Text(title).font(.system(size: 17))
                .padding(.vertical, 6)   // lifts the row to the reference app's roomy height
        } icon: {
            Group {
                if system {
                    Image(systemName: image).font(.system(size: 19))
                } else {
                    Image(image).renderingMode(.template).resizable().scaledToFit()
                }
            }
            .frame(width: 26, height: 26)
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
    private var admin = AdminStore.shared   // @Observable: the Official Announcements section appears only for admins
    @AppStorage("appearance") private var appearanceRaw = AppAppearance.system.rawValue
    @State private var showEdit = false
    @State private var showQR = false
    @State private var showPhoto = false          // tap the avatar → full-screen photo morph
    @State private var photoCloseTick = 0         // toolbar X → viewer close (see ProfilePhotoViewer.closeSignal)
    @State private var avatarFrame: CGRect = .zero   // the circle's global rect — the morph's start and end

    private var inviteText: String {
        let h = profile.me?.handle ?? ""
        return h.isEmpty ? "Chat with me on Fariin." : "Chat with me on Fariin, my username is @\(h)"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // THE CIRCLE, restored on the owner's word after seeing the poster here.
                    //
                    // It read badly for a reason worth keeping: a List row cannot bleed, so the
                    // poster arrived as a rounded CARD rather than as the top of the page, and it is
                    // the only place in the app where you look at your own header directly above your
                    // own name — so the name appeared twice, once in the photo's caption and once
                    // under it. A profile page earns the poster because the photo IS the top of the
                    // screen there. Settings does not.
                    //
                    // TWO taps, not one (owner order: "when click profile picture go and open
                    // picture, don't go edit page"): the PICTURE opens the photo full screen, the
                    // way every other avatar in the app does; the name under it still opens Edit,
                    // and the Edit button is always there. No photo = nothing to view, so the
                    // circle falls back to Edit, which is where a photo gets added.
                    profileHeader
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
                        SettingsRowLabel("Appearance", system: "paintbrush")
                    }
                    // NO App Icon row here: it lives inside Appearance, and one door is enough (user
                    // 2026-07-29, after seeing both). Two rows leading to the same page reads as a
                    // duplicate, which is what it was.
                    NavigationLink { ChatsSettingsView() } label: {
                        SettingsRowLabel("Chats", system: "bubble.left.and.bubble.right")
                    }
                    NavigationLink { StorySettingsView() } label: {
                        SettingsRowLabel("Stories", "ic_stories")
                    }
                    NavigationLink { PrivacySettingsView() } label: {
                        SettingsRowLabel("Privacy & Security", "ic_privacy")
                    }
                    NavigationLink { StorageDataView() } label: {
                        SettingsRowLabel("Storage and Data", system: "externaldrive")
                    }
                }

                // THE OFFICIAL CHANNEL'S SENDING SIDE. The whole section is absent unless this
                // account has a row in `admins`, and that is not cosmetic: the Firestore rules refuse
                // every write behind it independently, so a person who found the screen would still
                // be unable to send anything. Hidden here so a normal user never sees a door they
                // cannot open.
                if admin.isAdmin {
                    Section {
                        NavigationLink { AnnouncementAdminView() } label: {
                            SettingsRowLabel("Official Announcements", system: "megaphone")
                        }
                    } footer: {
                        Text(admin.isOwner ? "You are the owner of the Fariin channel."
                                           : "You can send announcements from the Fariin channel.")
                    }
                }

                Section {
                    // My QR Code lives in the top-left toolbar button — no duplicate row here.
                    ShareLink(item: inviteText) { SettingsRowLabel("Invite Friends", "ic_invite_friends") }
                    NavigationLink { AboutView() } label: {
                        SettingsRowLabel("Help & About", system: "questionmark.circle")
                    }
                }
            }
            // The bar titles what you are looking at: the page while it is the page, the picture
            // while the picture is open over it.
            .navigationTitle(showPhoto ? "Profile photo" : "Settings")
            .navigationBarTitleDisplayMode(.inline)
            // Nothing floats over the photo, top or bottom. The tab bar is a safe-area inset on the
            // list, not on the overlay, so hiding it moves no part of the header the morph flies out
            // of — and it comes back only after the close animation has landed.
            .toolbar(showPhoto ? .hidden : .automatic, for: .tabBar)
            .listSectionSpacing(20)   // the reference app's steady card rhythm — .compact left the gaps uneven
            .contentMargins(.top, 4, for: .scrollContent)   // remove the big gap above the avatar
            .preferredColorScheme(AppAppearance(rawValue: appearanceRaw)?.colorScheme ?? nil)
            .toolbar {
                // While the photo viewer is open, the leading slot holds its X — the top strip
                // belongs to the navigation bar, which eats overlay touches (same rule as
                // ContactInfoView) — and QR/Edit/Done step aside so nothing floats over the photo.
                ToolbarItem(placement: .topBarLeading) {
                    if showPhoto {
                        Button { photoCloseTick &+= 1 } label: {
                            Image(systemName: "xmark").font(.system(size: 17, weight: .semibold))
                        }
                        .tint(.primary)
                    } else {
                        Button { showQR = true } label: { Image(systemName: "qrcode") }.tint(.primary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !showPhoto { Button("Edit") { showEdit = true }.tint(.primary) }
                }
                if !asTab {
                    ToolbarItem(placement: .topBarTrailing) {
                        if !showPhoto { Button("Done") { dismiss() } }
                    }
                }
            }
            // The same in-place morph a contact's photo uses: grows out of the circle, drag melts
            // the page away, closes back into it. It LANDS SQUARE (owner order) — a circle is how
            // the avatar is framed in a list, not how you look at your own picture, and the round
            // crop was cutting the photo off on all four sides.
            .overlay {
                if showPhoto {
                    ProfilePhotoViewer(name: profile.me?.name ?? "",
                                       photoUrl: profile.me?.photoUrl ?? "",
                                       sourceFrame: avatarFrame,
                                       landsSquare: true,
                                       closeSignal: photoCloseTick,
                                       isPresented: $showPhoto)
                        .ignoresSafeArea()
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
                // The morph's source rect, and the hidden-while-open swap, same as ContactInfoView's
                // hero: the viewer flies out of this circle and back into it.
                .background(GeometryReader { g in
                    Color.clear.onChange(of: g.frame(in: .global), initial: true) { _, f in avatarFrame = f }
                })
                .opacity(showPhoto ? 0 : 1)
                .contentShape(Circle())
                .onTapGesture {
                    if let url = profile.me?.photoUrl, !url.isEmpty { showPhoto = true }
                    else { showEdit = true }
                }
            VStack(spacing: 8) {
                Text(profile.me?.name ?? "You")
                    .font(.title2.weight(.bold)).foregroundStyle(.primary)
                if let h = profile.me?.handle, !h.isEmpty {
                    Text("@\(h)").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { showEdit = true }
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
    @State private var disconnecting: AuthService.SignInMethod?   // → the verify-then-remove screen
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
            Text("You'll need to sign back in to use Fariin on this device.")
        }
        // Deletion is a PAGE, not a one-tap alert: it names the account, spells out what's lost,
        // and re-verifies you first (an alert can't do the provider re-auth, and skipping it is
        // what used to leave accounts half-deleted).
        .navigationDestination(isPresented: $showDelete) {
            DeleteAccountView { dismiss(); onSignOut() }
        }
        // Removing a login is a page, not an alert, for the same reason deleting the account is:
        // an alert cannot run a provider's re-authentication sheet, and skipping that step is what
        // would turn this feature into a bigger hole than the one it closes.
        .navigationDestination(item: $disconnecting) { method in
            DisconnectSignInView(method: method) { connectedTick += 1 }
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
                 ? "You're signed in as a guest. Connect a login so you can get back into this account on another phone, and your chats stay exactly as they are."
                 : "Connect more than one so you can always get back in. They all open this same account. You can remove one as long as another is left, and we'll ask you to prove it's you first.")
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
                // CONNECTED. This used to be a checkmark and nothing else, on the reasoning that
                // Firebase needs at least one method and unlinking the last one would lock the
                // account out. That reasoning was wrong: the answer to "removing the last one is
                // dangerous" is to refuse the LAST one, not to refuse all of them. Leaving it out
                // meant somebody who attached their own Google to your account could never be
                // removed by anybody.
                //
                // So: Remove appears only when another door is connected, and it goes through a
                // verification screen. The checkmark stays when this is the only way in, because
                // then there is genuinely nothing to offer.
                if AuthService.shared.connectedMethods.count > 1 {
                    Button("Remove") { disconnecting = method }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
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
                                catch { connectError = AuthService.plainMessage(error) }
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
                catch { connectError = AuthService.plainMessage(error) }
                connecting = nil
            }
        }
    }

    private func exportData() async {
        exporting = true
        let me = AuthService.shared.uid ?? ""
        var out = "Fariin, data export\n\n"
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

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Fariin-Data-Export.txt")
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
    // Calls default to My Friends — see PrivacyPrefs.defaultAudience. The @AppStorage default
    // has to match it or this row shows "Everyone" while the gate behaves as "My Friends".
    @AppStorage("priv.calls") private var privCalls = "contacts"
    @AppStorage("priv.messages") private var privMessages = "everyone"
    @AppStorage("priv.groups") private var privGroups = "everyone"
    // Default "modern", and any value this build does not recognise falls back to modern too — the
    // new header is the app's layout, the circle is the opt-out.
    @AppStorage(ProfileLayoutStyle.storageKey) private var profileLayout = ProfileLayoutStyle.modern.rawValue
    @State private var showDefaultDisappear = false

    private var profileLayoutStyle: ProfileLayoutStyle {
        ProfileLayoutStyle.resolved(profileLayout)
    }

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
                Text("Require Face ID to unlock Fariin.")
            }

            // HIDDEN, not removed (owner, 2026-08-02: "Dont delete just hide… i need Modern Header
            // defuilt user make cant change it"). The page and the classic header stay wired and
            // working; this is the only door to them, and it is off the wall. Nobody who already
            // chose Classic is left on it — ProfileLayoutStyle.resolved answers modern for everyone
            // while the flag is off, whatever their device has stored.
            if Flags.profileLayoutChoice {
                Section {
                    NavigationLink { ProfileLayoutPage() } label: {
                        HStack {
                            Text("Profile Layout")
                            Spacer()
                            Text(profileLayoutStyle.label).foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("How profiles are shown. The modern header fills the top of the page with the profile photo.")
                }
            }

            Section {
                // NO PHONE NUMBER ROW. Fariin does not use phone numbers — accounts are Apple/Google/
                // email and people are found by @handle — so a privacy control for who can see a
                // number nobody has was answering a question the app never asks.
                audienceRow("Last Seen & Online", key: "lastSeen", value: privLastSeen,
                            footerText: "Who can see when you're online and when you were last active.")
                audienceRow("Profile Picture", key: "photo", value: privPhoto,
                            footerText: "Who can see your profile photo when they find you on Fariin.")
                audienceRow("Bio", key: "bio", value: privBio,
                            footerText: "Who can see the few words about you.")
                audienceRow("Calls", key: "calls", value: privCalls,
                            footerText: "Who can call you. Calls from anyone else are declined automatically.")
                // Shows its value like every other row here. It was the one row with a bare title, so
                // it read as broken next to five rows that each state their setting (user: "messages
                // when i select everyone or same one i am not seeing").
                NavigationLink { MessagesPrivacyPage() } label: {
                    HStack {
                        Text("Messages")
                        Spacer()
                        Text(label(privMessages)).foregroundStyle(.secondary)
                    }
                }
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
                Link(destination: URL(string: "https://fariin.com")!) {
                    Text("Support Center").foregroundStyle(.primary)
                }
                Link(destination: URL(string: "mailto:support@fariin.com")!) {
                    Text("Report a Problem").foregroundStyle(.primary)
                }
            } footer: {
                Text("Fariin has zero tolerance for objectionable content or abusive behavior. Reports are reviewed within 24 hours.")
            }
            Section {
                LabeledContent("Version", value: "\(appVersion) (\(buildNumber))")
                Link(destination: URL(string: "https://fariin.com/privacy")!) {
                    Text("Privacy Policy").foregroundStyle(.primary)
                }
                Link(destination: URL(string: "https://fariin.com/terms")!) {
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

/// The saved profile photo, for the Large preview card. Plain url, not E2EE, from the same store
/// every avatar in the app is filled from — so it is already in hand and the card opens holding the
/// picture instead of flashing a grey rectangle first.
private struct PosterPreviewImage: View {
    let url: String
    @State private var image: UIImage?

    init(url: String) {
        self.url = url
        // MEMORY only. `smallImageSync` would also read the disk, but its own documentation bars
        // full-size photos from the main thread and a poster is one — the task below fetches it.
        _image = State(initialValue: DiskImageCache.shared.memoryImage(for: url))
    }

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Color(uiColor: .secondarySystemGroupedBackground) }
        }
        .task(id: url) {
            if image != nil { return }
            if let cached = await DiskImageCache.shared.image(for: url) { image = cached; return }
            guard let u = URL(string: url),
                  let (data, _) = try? await MediaSession.shared.data(from: u),
                  let ui = UIImage(data: data) else { return }
            DiskImageCache.shared.store(ui, data: data, for: url)
            image = ui
        }
    }
}

struct EditProfileView: View {
    @Environment(\.dismiss) private var dismiss
    private var profile = ProfileStore.shared
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var handle = ""
    @State private var about = ""
    @State private var photoItem: PhotosPickerItem?
    /// TWO framings of the picked photo, waiting for Save, plus a request to remove. NOTHING is
    /// written to the server until Save — pressing X must genuinely undo (owner: "dont Update profile
    /// image without save").
    ///
    /// Two, not one: the circle people see in every list and the tall one on the profile header are
    /// framed separately, because a face centred for a full-width header is not centred for a 40pt
    /// circle.
    @State private var pendingPhoto: UIImage?     // the circle — every avatar in the app
    @State private var pendingPoster: UIImage?    // the tall one — the profile header
    @State private var pendingRemove = false
    @State private var cropCandidate: CropItem?   // picked image awaiting the circular cropper
    @State private var confirmRemovePhoto = false   // Remove asks first (user request)
    @State private var showEditPhoto = false        // the Edit Photo sheet
    /// What that sheet was asked for. Read and cleared in its onDismiss, never acted on inline.
    @State private var photoAction: ProfilePhotoAction?
    @State private var showPhotoPicker = false       // programmatic PhotosPicker present
    @State private var showCamera = false            // Apple's camera, for Take photo
    /// Is there a picture to remove: one you just picked, or a saved one you have not already asked
    /// to drop. Without the second half the X kept offering to remove a photo that was already gone.
    private var hasPictureToRemove: Bool {
        pendingPhoto != nil || (!pendingRemove && profile.me?.photoUrl?.isEmpty == false)
    }
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
    @FocusState private var bioFocused: Bool
    private static let bioAnchor = "bio.field"   // the row the scroller pulls above the keyboard
    private var hasUnsavedText: Bool {
        firstName != origFirst || lastName != origLast || handle != origHandle || about != origAbout
    }
    /// Anything Save would write. The photo counts now that it is no longer applied the instant it
    /// is cropped, which is what makes X a real cancel rather than a late goodbye.
    private var hasUnsavedChanges: Bool { hasUnsavedText || pendingPhoto != nil || pendingRemove }

    enum EditTab: String, CaseIterable, Identifiable {
        // The raw value is the stored/AppStorage-free tab identity only; the LABEL is what he reads.
        // "Large" named a layout; this tab shows what other people see, so it says Preview (his
        // word, 2026-08-03).
        case circle, large
        var id: String { rawValue }
        var label: String { self == .circle ? "Circle" : "Preview" }
    }
    @State private var tab: EditTab = .circle

    /// PREVIEW ONLY — your picture at the shape the Large layout crops it to, your name, your
    /// handle. Nothing else and nothing to press (owner, 2026-08-03: "minimalist and clear").
    ///
    /// A CARD, deliberately not `ProfilePosterHeader` itself. That header is the real profile PAGE:
    /// it bleeds to both screen edges, runs up under the bars and melts into the page below it.
    /// Those are the right instincts on a page you scroll and the wrong ones inside a sheet, where
    /// the same drawing reads as a photograph that ran out rather than as a preview of anything —
    /// and the five round actions belong to a person you can call, which on your own profile is
    /// nobody. **THE REAL PROFILE PAGE IS NOT TOUCHED BY ANY OF THIS** (his order, in as many
    /// words): the redesign lives on this tab alone.
    ///
    /// The GeometryReader is what makes the card the right height on the first frame. A ratio would
    /// have nothing to divide: scrolling content is proposed an unspecified height, the same trap
    /// `ProfilePosterHeader.photoSpacer` states outright and works around.
    private var largePreview: some View {
        GeometryReader { g in
            // Narrower than the page, because the cards behind it need somewhere to be seen. His
            // drawing puts the front card at roughly three quarters of the width.
            let cardW = max(0, g.size.width * 0.74)
            ScrollView {
                previewDeck(width: cardW)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 34)
                    .padding(.bottom, 44)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
    }

    /// A DECK: the card you are previewing, with the same card peeking from both screen edges,
    /// smaller and tilted (owner's drawing, 2026-08-03 — asked whether the edge pieces were real he
    /// answered "a card deck, decorative"). The two behind are scenery: no gesture, no paging, and
    /// nothing to press.
    @ViewBuilder private func previewDeck(width: CGFloat) -> some View {
        if let art = previewArt {
            ZStack {
                deckSide(art, width: width, side: -1)
                deckSide(art, width: width, side: 1)
                frontCard(art, width: width)
            }
            // Reserve exactly the front card's height. The tilted neighbours are drawn from the
            // same box and must not lengthen the page or the whole deck drifts up as they lean.
            .frame(height: width * PosterGeometry.aspect)
        } else {
            // No photo, no deck: a stack of empty rectangles would be inventing a layout you will
            // never have. A profile with no picture shows the circle, so the preview shows one.
            AvatarView(name: previewName, photoUrl: nil, size: 140)
                .padding(.vertical, 28)
        }
    }

    /// The card in front: the 4:5 crop the big header takes, at `PosterGeometry.aspect` so the
    /// preview and the thing it previews can never disagree about the shape — with the name and
    /// handle INSIDE it, on a dark plate near the bottom, exactly as he drew it.
    private func frontCard(_ art: PreviewArt, width: CGFloat) -> some View {
        cardArtwork(art, width: width, corner: 32)
            .overlay(alignment: .bottom) {
                VStack(spacing: 2) {
                    Text(previewName)
                        .font(.title3.weight(.bold)).foregroundStyle(.white)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    // A blank line rather than no line, so the plate keeps its height while a
                    // handle is being typed.
                    Text(handle.isEmpty ? " " : "@\(handle)")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 22).padding(.vertical, 10)
                .background(Color.black.opacity(0.38),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.bottom, 26)
            }
            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
    }

    /// One of the two behind. Scaled down, pushed almost all the way off its own edge, and leaned
    /// away from the middle, so what is left on screen is the sliver in his drawing.
    private func deckSide(_ art: PreviewArt, width: CGFloat, side: CGFloat) -> some View {
        cardArtwork(art, width: width, corner: 26)
            .scaleEffect(0.84)
            .rotationEffect(.degrees(side * 5))
            .offset(x: side * width * 0.82)
            .allowsHitTesting(false)
    }

    /// The picture itself at the card's size. One place, so the front card and the two behind can
    /// never end up showing different crops of the same photograph.
    private func cardArtwork(_ art: PreviewArt, width: CGFloat, corner: CGFloat) -> some View {
        Group {
            switch art {
            case .local(let img): Image(uiImage: img).resizable().scaledToFill()
            case .remote(let url): PosterPreviewImage(url: url)
            }
        }
        .frame(width: width, height: width * PosterGeometry.aspect)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }

    /// Which picture the preview is of. The unsaved crop wins over anything already stored — the
    /// whole point of a preview is to show the photo before it exists anywhere — and the poster crop
    /// wins over the circle one.
    private enum PreviewArt {
        case local(UIImage)
        case remote(String)
    }
    private var previewArt: PreviewArt? {
        if pendingRemove { return nil }
        if let img = pendingPoster ?? pendingPhoto { return .local(img) }
        // `hasPicture`, not "is the string empty" — the same last question every profile header
        // asks, so your own preview cannot claim a photo the app cannot draw.
        if let p = profile.me?.posterUrl, ProfilePhotoIndex.hasPicture(p) { return .remote(p) }
        if let p = profile.me?.photoUrl, ProfilePhotoIndex.hasPicture(p) { return .remote(p) }
        return nil
    }

    private var previewName: String {
        let n = "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? (profile.me?.name ?? "You") : n
    }

    var body: some View {
        NavigationStack {
            // TWO TABS, ONE SCREEN. Circle is where you edit; Large is only ever a look at the
            // result. Tabs of the same screen rather than a pushed page, so Save and X stay put and
            // one set of pending changes feeds both — a preview on its own page would need the
            // unsaved photo threaded into it and could drift out of step with the form.
            Group {
                if tab == .large { largePreview } else { editForm }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Hide the toolbar's own glass so CloseXButton's circle isn't double-wrapped (iOS 26).
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .cancellationAction) {
                        CloseXButton { if hasUnsavedChanges { confirmDiscard = true } else { dismiss() } }
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        CloseXButton { if hasUnsavedChanges { confirmDiscard = true } else { dismiss() } }
                    }
                }
                ToolbarItem(placement: .principal) {
                    Picker("", selection: $tab) {
                        ForEach(EditTab.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 190)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .fontWeight(.semibold)
                        .disabled(saving || !hasUnsavedChanges)
                }
            }
            // On the SCREEN, with the X that raises it, so it works from either tab.
            .interactiveDismissDisabled(hasUnsavedChanges)
            .confirmationDialog("Discard changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text("Your changes are not saved yet.")
            }
        }
    }

    private var editForm: some View {
        Group {
            // A ScrollViewReader so the BIO can pull itself back above the keyboard as it grows
            // (owner 2026-08-04: the second line disappears behind the keys). A Form scrolls a field
            // into view when it FIRST gains focus and then considers the job done — but this field
            // grows downward as you type, so every new line pushed the cursor further under the
            // keyboard while the scroll position stayed where it was.
            ScrollViewReader { scroller in
            Form {
                // Avatar header on the plain grouped background (Contacts / Settings edit style).
                Section {
                    // One "Edit Photo" pill (reference look). Avatar or button opens a menu:
                    // Choose Photo / Remove Photo. Each control is .plain + own contentShape so a
                    // Form-default button can't stretch its tap zone across the whole row.
                    VStack(spacing: 12) {
                        Button { showEditPhoto = true } label: {
                            ZStack {
                                // `pendingRemove` blanks the url so you see the letter you are about
                                // to end up with, rather than the photo you just asked to delete.
                                AvatarView(name: firstName,
                                           photoUrl: pendingRemove ? nil : profile.me?.photoUrl,
                                           size: 100)
                                if let pendingPhoto {
                                    Image(uiImage: pendingPhoto).resizable().scaledToFill()
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
                        // Was `.disabled(uploading)`, guarding an upload that started the moment you
                        // cropped. Nothing uploads here any more, so there is nothing to guard: you
                        // can pick a different photo as many times as you like before pressing Save.
                        .disabled(saving)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    // Attached HERE, on the avatar section, NOT on the outer view: that chain
                    // already carries a confirmationDialog (discard changes) and an alert (remove
                    // photo), and stacking a second confirmationDialog on the same view made this
                    // one silently never present — tapping "Edit Photo" did nothing.
                    // Bottom sheet, not confirmationDialog (iOS 26 anchors that to the button as a
                    // callout). The picked action runs in the sheet's onDismiss, which is also what
                    // lets the camera / photo picker / remove alert present at all from here.
                    //
                    // The three words it used to list are now the owner's drawing: the picture
                    // itself, an X on it for remove, Take photo and Choose photo underneath.
                    .sheet(isPresented: $showEditPhoto, onDismiss: {
                        guard let a = photoAction else { return }
                        photoAction = nil
                        switch a {
                        case .camera:  showCamera = true
                        case .library: showPhotoPicker = true
                        case .remove:  confirmRemovePhoto = true
                        }
                    }) {
                        ProfilePhotoSheet(name: firstName,
                                          photoUrl: pendingRemove ? nil : profile.me?.photoUrl,
                                          pendingImage: pendingPhoto,
                                          canRemove: hasPictureToRemove,
                                          action: $photoAction)
                    }
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
                        .focused($bioFocused)
                        .id(Self.bioAnchor)
                        .onChange(of: about) { _, v in
                            if v.count > 140 { about = String(v.prefix(140)) }
                            // Follow the cursor DOWN: anchor .bottom keeps the newest line just
                            // above the keyboard rather than centring the whole field.
                            if bioFocused { withAnimation(.easeOut(duration: 0.2)) { scroller.scrollTo(Self.bioAnchor, anchor: .bottom) } }
                        }
                        .onChange(of: bioFocused) { _, focused in
                            // On focus too: the field can already be several lines tall when you
                            // come back to edit it, and that lands under the keyboard immediately.
                            guard focused else { return }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                withAnimation(.easeOut(duration: 0.2)) { scroller.scrollTo(Self.bioAnchor, anchor: .bottom) }
                            }
                        }
                } header: {
                    Text("Bio")
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }
            }
            }
            // X and Save moved OUT to the screen (see `body`). They belong to the whole screen, not
            // to the form: attached here they vanished the moment you switched to the Large tab,
            // leaving a preview with no way to save it and no way out.
            .onAppear {
                let parts = (profile.me?.name ?? "").split(separator: " ", maxSplits: 1).map(String.init)
                firstName = parts.first ?? ""
                lastName = parts.count > 1 ? parts[1] : ""
                handle = profile.me?.handle ?? ""
                about = profile.me?.about ?? ""
                origFirst = firstName; origLast = lastName
                origHandle = handle; origAbout = about
            }
            // The discard prompt moved OUT to the screen with the X that raises it — left here it
            // did not exist on the Large tab, so X would set the flag and nothing would appear.
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
            // Apple's camera, for Take photo. A captured picture goes to the SAME two-stage cropper
            // a chosen one does, so both are framed the same way and only one path can be wrong.
            //
            // Deliberately a sibling of the cropper's own cover on THIS chain, which is ThreadView's
            // proven camera-to-editor shape (ThreadView.swift:686). Left on the avatar row it would
            // have been one presentation asking a different view to start another while it closes,
            // which is the shape of every "nothing happens" bug this screen has had.
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { data in
                    if let ui = UIImage(data: data) { cropCandidate = CropItem(image: ui) }
                }
                .ignoresSafeArea()
            }
            .fullScreenCover(item: $cropCandidate) { c in
                // Our own move-and-scale rather than the general-purpose cropper: a profile photo is
                // now shown as TWO shapes (the round avatar and the poster header), and the one
                // thing this screen has to do is let you check both before you commit. The library
                // cropper can only show one, and its rotation dial and ratio presets are noise here.
                ProfilePhotoCropper(image: c.image,
                                    onDone: { avatar, poster in
                                        cropCandidate = nil
                                        // HELD, NOT UPLOADED. Nothing reaches the server until Save,
                                        // so X genuinely cancels. The avatar below updates straight
                                        // away, so it still feels immediate.
                                        pendingPhoto = avatar
                                        pendingPoster = poster
                                        pendingRemove = false
                                    },
                                    onCancel: { cropCandidate = nil })
                    .ignoresSafeArea()
            }
            .alert("Remove profile photo?", isPresented: $confirmRemovePhoto) {
                Button("Cancel", role: .cancel) {}
                Button("Remove", role: .destructive) {
                    // Also held for Save, for the same reason a picked photo is.
                    pendingRemove = true
                    pendingPhoto = nil
                    pendingPoster = nil
                }
            } message: {
                Text("Your initials will show instead. Nothing changes until you press Save.")
            }
        }
    }

    /// Writes the held photo change. Called ONLY from `save()` — the whole point is that nothing
    /// reaches the server before then. Returns false if it failed, so Save can stop and leave the
    /// screen open with the error rather than closing over a photo that never landed.
    private func applyPendingPhoto() async -> Bool {
        if pendingRemove {
            do { try await profile.removePhoto(); pendingRemove = false; return true }
            catch { self.error = "Could not remove photo: \(error.localizedDescription)"; return false }
        }
        guard let img = pendingPhoto, let data = img.jpegData(compressionQuality: 0.92) else { return true }
        do {
            // ONE pass: both crops upload in parallel, one user-doc write, one conversation
            // sweep. This used to be uploadPhoto then uploadPoster in sequence — two uploads,
            // three conversation sweeps, three profile re-fetches — which is the "Save takes too
            // long" the owner reported.
            try await profile.uploadProfileImages(circle: data,
                                                  poster: pendingPoster?.jpegData(compressionQuality: 0.92))
            pendingPhoto = nil
            pendingPoster = nil
            return true
        } catch {
            self.error = "Photo upload failed: \(error.localizedDescription)"
            return false
        }
    }

    private func save() async {
        // Validate the TEXT before writing anything at all, so a rejected username cannot leave the
        // photo already changed. Everything this screen does is now one action.
        let n = "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces)
        let h = ChatService.sanitizeHandle(handle)
        guard !n.isEmpty else { error = "Enter your name"; return }
        guard ChatService.isValidHandle(h) else {
            error = "Username: letters, numbers and _ only, 3–30 characters"; return
        }
        saving = true; error = nil
        do {
            // NO PRE-CHECK. `updateProfile` claims the name in one server transaction when it has
            // changed, which is the only test that can actually settle who gets it — a query here
            // could only ever report what was true a round trip ago.
            // The photo goes first, and a failure stops here: closing over a photo that never landed
            // would tell you it saved when it did not.
            guard await applyPendingPhoto() else { saving = false; return }
            if hasUnsavedText { try await profile.updateProfile(name: n, handle: h, about: about) }
            dismiss()
        } catch {
            let msg = error.localizedDescription
            self.error = msg.contains("username") || msg.contains("Username") ? msg : "Could not save: \(msg)"
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

    /// What the line under the field is saying. One value, so the three states cannot overlap and the
    /// animation has something single to cross-fade between.
    private enum Status: Equatable {
        case quiet                    // too short to judge, or unchanged from what you already have
        case checking
        case available(String)
        case taken
        case problem(String)          // shape is wrong, or the server refused for its own reason
    }

    @State private var status: Status = .quiet
    /// The value the LAST check was fired for. Stops the same name being asked about twice — a
    /// re-render, a keyboard autocorrect that lands on the same text, or coming back to a name you
    /// already tried.
    @State private var lastAsked = ""
    /// Bumped on every keystroke. A reply whose token is stale is DROPPED: a slow answer for "viize"
    /// must never overwrite a fresh answer for "viizethh", which is the classic way these fields end
    /// up lying to people.
    @State private var token = 0
    @State private var claiming = false

    private var clean: String { ChatService.sanitizeHandle(draft) }
    private var unchanged: Bool { clean.lowercased() == handle.lowercased() }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 2) {
                    Text("@").foregroundStyle(.secondary)
                    TextField("username", text: $draft)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().focused($focused)
                        .onChange(of: draft) { _, v in
                            let c = ChatService.sanitizeHandle(v)
                            if c != v { draft = c }
                            schedule(c)
                        }
                    // Clear, inside the field, only while there is something to clear.
                    if !draft.isEmpty {
                        Button { draft = ""; status = .quiet; lastAsked = ""; focused = true } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 17))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    }
                }
            } footer: {
                // The one line that changes. Fixed height so the form does not twitch as it swaps.
                statusLine
                    .animation(.smooth(duration: 0.22), value: status)
            }
        }
        .navigationTitle("Username")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { Task { await done() } }
                    .fontWeight(.semibold)
                    // An EMPTY (or too-short) draft was accepted here and only rejected later by
                    // Save, which then failed with a validation message for a field the user was no
                    // longer looking at — and name and bio edits could not be saved at all until a
                    // username was retyped. There is no "remove username" outcome, so block it here
                    // where the field is still on screen (audit).
                    .disabled(claiming || clean.count < Limits.usernameMinChars || status == .taken)
            }
        }
        .onAppear { draft = handle; focused = true }
    }

    /// THE RULES STAY PUT (owner 2026-08-04: they vanished the moment the checker answered).
    ///
    /// They used to be one of the STATES, so the first reply from the server took them off the
    /// screen — exactly while you are typing a name and most likely to need them. They are not a
    /// state, they are the caption for the field; the checker's answer goes underneath.
    @ViewBuilder private var statusLine: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Letters, numbers and _ only. \(Limits.usernameMinChars)–\(Limits.usernameMaxChars) characters.")
            switch status {
            case .quiet:
                EmptyView()
            case .checking:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Checking username…")
                }
                .transition(.opacity)
            case .available(let name):
                Text("\(name) is available.").foregroundStyle(.green)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            case .taken:
                Text("Sorry, this username is already taken.").foregroundStyle(.red)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            case .problem(let why):
                Text(why).foregroundStyle(.red)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Debounced availability check. Everything that makes this feel instant instead of chattery is
    /// here: nothing is asked until the name could actually be valid, the same name is never asked
    /// about twice, a newer keystroke cancels the wait, and a stale reply is dropped on arrival.
    private func schedule(_ value: String) {
        token += 1
        let mine = token

        guard !unchanged else { status = .quiet; return }
        if let problem = ChatService.handleShapeProblem(value) {
            withAnimation { status = .problem(problem) }
            return
        }
        guard value.count >= Limits.usernameMinChars else { withAnimation { status = .quiet }; return }
        guard value != lastAsked else { return }

        withAnimation { status = .checking }
        Task {
            // The pause IS the debounce: a newer keystroke bumps the token, and this reply is then
            // thrown away rather than raced against.
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard mine == token else { return }
            lastAsked = value
            do {
                let r = try await ChatService.checkHandleAvailable(value)
                guard mine == token else { return }
                withAnimation {
                    if r.available { status = .available(value) }
                    else if r.reason == "taken" || r.reason == nil { status = .taken }
                    else { status = .problem(r.reason ?? "") }
                }
            } catch {
                guard mine == token else { return }
                // A failed CHECK is not a failed name: say nothing rather than accuse it of being
                // taken. Done still asks the server, which is the answer that counts.
                withAnimation { status = .quiet }
                lastAsked = ""
            }
        }
    }

    /// Done CLAIMS it on the server. The check above is a courtesy; this is the decision, and it is
    /// the only thing that can actually make the name yours.
    private func done() async {
        let value = clean
        guard value.count >= Limits.usernameMinChars else { return }
        if unchanged { dismiss(); return }
        claiming = true
        do {
            try await ChatService.claimHandle(value)
            handle = value
            // THE CLAIM CHANGED THE SERVER; NOTHING TOLD THE APP (owner 2026-08-04: "when i click
            // done save is not working… new name never appearing").
            //
            // It saved every time. `claimUsername` writes handle and handleLower on the user
            // document inside its transaction, and the logs show it returning clean. But this screen
            // claimed the name DIRECTLY and then only wrote the binding, so `ProfileStore.me` still
            // held the profile it read when the app started — and every place that shows your
            // @name reads that. Save worked; the app just went on displaying the old answer, which
            // is indistinguishable from it not having worked.
            await ProfileStore.shared.refreshMe()
            claiming = false
            dismiss()
        } catch {
            claiming = false
            let msg = (error as NSError).localizedDescription
            withAnimation { status = msg.lowercased().contains("taken") ? .taken : .problem(msg) }
        }
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
                                    self.error = AuthService.plainMessage(error)
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
