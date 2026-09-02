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
    /// Six local chats for taking the website screenshots. Read back into `DemoMode.chatsInjected`
    /// at launch, so the switch survives a restart the way every other setting does. The row that
    /// shows it is gated on `DemoMode.isAvailable` — debug or TestFlight, never the App Store.
    @AppStorage("demoChats") private var demoChats = false
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
                    // ⛔ MY PROFILE — his ask, 2026-09-02: "add My profile card in between account
                    // and Devices". It opens `GlowProfileView` on his OWN uid, which is the page
                    // that already exists for this: photo, name, handle, bio, the Glow stats card
                    // and Posted stories. A second "my profile" screen would be a second place for
                    // those to drift.
                    NavigationLink {
                        GlowProfileView(uid: AuthService.shared.uid ?? "",
                                        initialName: profile.me?.name ?? "",
                                        initialPhoto: profile.me?.photoUrl)
                    } label: {
                        SettingsRowLabel("My Profile", "ic_account")
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
                        // ITS OWN OUTLINED DRAWING, not the tab bar's. `ic_chat` is a SOLID bubble
                        // because a tab bar icon has to read at 24pt against a selected pill; dropped
                        // into this list it was a black blob beside Account, Devices, Notifications
                        // and Privacy, which are all outlines. Same family, different weight — and a
                        // settings row wants the outline.
                        SettingsRowLabel("Chats", "ic_settings_chats")
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

                    // VERIFICATION, on its own capability. An admin who can send announcements is not
                    // thereby somebody who can put the app's name behind a stranger's identity, so
                    // this section appears only for `.verify` and the rules check the same thing
                    // again before any write lands.
                    if Flags.verificationConsole, admin.can(.verify) {
                        Section {
                            NavigationLink { VerificationAdminView() } label: {
                                SettingsRowLabel("Verification", system: "checkmark.seal")
                            }
                        } footer: {
                            Text("Give, change or withdraw a verified badge. Every decision is recorded permanently.")
                        }
                    }
                }

                Section {
                    // My QR Code lives in the top-left toolbar button — no duplicate row here.
                    ShareLink(item: inviteText) { SettingsRowLabel("Invite Friends", "ic_invite_friends") }
                    NavigationLink { AboutView() } label: {
                        SettingsRowLabel("Help & About", system: "questionmark.circle")
                    }
                }

                // TESTFLIGHT AND DEBUG, NEVER THE APP STORE — the same gate as "Demo story people"
                // in Story settings, and for the same reason.
                //
                // Six chats that live only in this phone's memory, added to the list above your
                // real ones so the website screenshots can be taken without signing out of your own
                // account. Nothing is written, nothing is uploaded, and nobody else can see them.
                // They are gone the moment the switch goes off or the app restarts.
                //
                // This is here rather than behind a demo LOGIN because that screen only appears
                // after a real sign-in succeeds, so reaching it meant making a second Apple or
                // Google account first. A switch in your own settings is one tap.
                if DemoMode.isAvailable {
                    Section {
                        Toggle("Demo chats", isOn: $demoChats).tint(.orange)
                            .onChange(of: demoChats) { _, on in
                                DemoMode.setChats(on)
                                ConversationsRepository.shared.refreshForDemo()
                                // The story row is built by its own repository and would not have
                                // noticed until the next launch, so the switch would have looked
                                // half-broken: chats appear at once, stories only tomorrow.
                                StoriesRepository.shared.refreshForDemo()
                            }
                    } footer: {
                        Text("Testers only. Adds seven local chats to your list and two people to the story row, for taking screenshots. They are made on this device, never uploaded, and nobody else can see them. Your own chats and your own story are not touched.")
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
            // ⚠️ THE HONEST HALF OF AN OPTIMISTIC PHOTO, and it belongs on THIS screen rather than in
            // the sheet: the sheet has already closed by the time an upload can fail. The old picture
            // is back before this appears, which is why it says what happened rather than asking for
            // anything.
            .alert("Photo wasn't changed",
                   isPresented: Binding(get: { profile.photoError != nil },
                                        set: { if !$0 { profile.photoError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(profile.photoError ?? "") }
        }
    }

    // Centered profile header (mockup style): big avatar, name, @handle. Tap to edit.
    private var profileHeader: some View {
        VStack(spacing: 8) {
            // 120, up from 96 on his 2026-08-08 report that it reads small. This is the first thing
            // on the screen and the only picture on it, and at 96 it was smaller than the app icon
            // in the tab bar below it. The reference app's own settings avatar is 100; the extra goes to the
            // same place his screenshot points, which is the gap between the circle and the name.
            AvatarView(name: profile.me?.name ?? "", photoUrl: profile.me?.photoUrl, size: 120)
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
                // ⚠️ THE BADGE WAS NEVER DRAWN ON MY OWN NAME (owner 2026-08-11: "iam not seeing
                // verify mark in my profile setting"). His account really is verified — active and
                // official in the data, read back live — and every screen that draws OTHER people
                // (the chat list, contact info, calls, groups, the announcement console) has carried
                // `VerifiedMark` all along. This screen and the story header simply never asked.
                //
                // Same component as everywhere else, deliberately: a screen that draws its own tick
                // is a screen that can disagree with the app about who is verified.
                HStack(spacing: 6) {
                    Text(profile.me?.name ?? "You")
                        .font(.title2.weight(.bold)).foregroundStyle(.primary)
                    if let uid = profile.me?.id { VerifiedMark(uid: uid, size: 18, explains: true) }
                }
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
                // Tidied here too, and for the same reason as `ContactInfoView.gatedAbout`: my own
                // bio written before the rule is still stored with its blank lines until the day I
                // next press Save, and this page should not be waiting on that to look right.
                // Trimmed as well, so a bio that is nothing but blanks draws no card at all.
                if let raw = profile.me?.about {
                    let about = Limits.oneParagraph(raw, max: Limits.bioChars)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !about.isEmpty { bioCard(about) }
                }
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
        // (No story cover here any more. This screen ran `ownSwipeDismiss: true`, which handed the
        // close to the story library's own pan — a different gesture with different physics from
        // the one the chat list uses, on the same app. It opens through `StoryDoor` now.)
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
                            // The flight's source, at the radius this tile is actually drawn with —
                            // 16, not the row's 24, so the story lands on the shape that is there.
                            // Keyed per STORY: each tile is its own rectangle and the close has to
                            // fly back to the one that was tapped.
                            .modifier(MediaRectReporter(id: "mine-\(s.id)", scope: .storyRow,
                                                        cornerRadius: 16))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                StoryDoor.open(mine, from: "mine-\(s.id)",
                                               onClosed: { Task { await stories.load(force: true) } })
                            }
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
    /// Setting a FIRST password on the address the account already has. Distinct from
    /// `showConnectEmail`, which asks for an address as well — see `reallyConnect`.
    @State private var showSetPassword = false

    var body: some View {
        List {
            // No avatar header and no profile fields here (username/name/bio/photo all live in
            // Edit Profile, reached from the Settings header). Account is ONLY data + session
            // actions — a settings page, not profile management (user direction 2026-07-22).
            // ⚠️ EXPORT MY DATA USED TO BE THE FIRST THING ON THIS PAGE. It is now below Sign-in
            // Methods, because both references put it there and they are right: one mainstream messenger's
            // account settings screen lists "Request account data" second from LAST, immediately
            // before Delete, and another mainstream messenger files "Request account info" in the same low position. It is
            // a button most people press once in their life or never, and it was standing in front of
            // everything they actually opened this page for.

            // ABOVE Sign-in Methods, and filed under the word people actually look for.
            //
            // A password could already be added before this row existed, but only through Sign-in
            // Methods › Email › Connect, which asks for an address we already know and is named
            // after a thing nobody searching for "password" would open. Owner's instruction: put it
            // where they look.
            //
            // The row hides itself for an account that cannot have a password at all — one signed
            // in with no email address anywhere on it. Offering a screen that can only fail is
            // worse than not offering it.
            //
            // ⚠️ AND FOR APPLE'S HIDDEN ADDRESS, for the same reason one step further on. Hide My
            // Email leaves the account on `…@privaterelay.appleid.com`; a password there is real,
            // and unusable, because the sign-in screen asks for an address the person has never
            // seen. `hasTypableAddress` is that test. Connecting Google gives the account an
            // address they know and this row comes back on its own.
            //
            // Someone who set a password BEFORE this rule still sees Change Password, or they could
            // never alter or remove the one they have.
            // ⚠️ CHANGE ONLY. SETTING A PASSWORD LIVES UNDER SIGN-IN METHODS, AND ONLY THERE.
            //
            // This row used to read "Set a Password" when there wasn't one, three lines above a
            // "Password — Connect" row doing the same job. His 2026-08-10 screenshot has both circled
            // with "same thing why?". They were: two entry points to one outcome, side by side, and
            // the app looked confused about its own account model.
            //
            // A password is a way to sign in, so it belongs in the list of ways to sign in, beside
            // Apple and Google, where you can also see whether it is set. What does NOT belong there
            // is CHANGING one, because that list only offers Connect and Remove. So this section
            // survives for exactly that job and appears only once a password exists.
            if let address = AuthService.shared.passwordAddress,
               AuthService.shared.isConnected(.email) {
                Section {
                    NavigationLink {
                        PasswordView(address: address, isFirstPassword: false)
                    } label: {
                        Label("Change Password", systemImage: "key.fill")
                    }
                } footer: {
                    // NO ADDRESS HERE EITHER, same instruction, same reasoning as the footer inside
                    // PasswordView. This row went through two wordings the owner rejected on a real
                    // phone, both of which recited his own email back at him mid-sentence. The
                    // caption's job is to say what the row does, not to read out data he can see two
                    // rows below under Sign-in Methods.
                    // One branch now: the section itself only exists when a password is set.
                    Text("Change the password you sign in with.")
                }
            }

            signInMethodsSection

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

            // ⚠️ SIGN OUT IS NOT DESTRUCTIVE AND MUST NOT BE PAINTED AS THOUGH IT WERE.
            //
            // It carried `role: .destructive`, so it drew red, in the SAME card as Delete Account and
            // one row above it. Signing out is completely reversible — you sign back in and everything
            // is there. Red is the app promising that something cannot be undone, and spending it on a
            // routine action teaches people to stop reading red, which is the last habit anyone should
            // have directly above a button that ends their account.
            //
            // One of those two does not even put sign out on this screen, and in both references Delete sits
            // ALONE at the bottom of its own group. Two sections now, so there is real space between
            // the reversible thing and the permanent one.
            Section {
                Button { showSignOut = true } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .tint(.primary)
            }

            Section {
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
        // Adding a FIRST password to the address the account already has. The same screen the old
        // "Set a Password" row pushed, reached from the one place a password now lives.
        //
        // In its own NavigationStack because `PasswordView` sets a `navigationTitle`, and pushed from
        // a NavigationLink it inherited the settings stack's bar to draw it in. Presented bare in a
        // sheet there is no bar, so the screen would arrive untitled.
        //
        // `onDismiss` bumps the tick because the Sign-in Methods list reads the account's providers
        // directly, and nothing tells SwiftUI they changed while a sheet was up. Without it you would
        // set a password and the row would still say Connect until something else redrew the page.
        .sheet(isPresented: $showSetPassword, onDismiss: { connectedTick += 1 }) {
            NavigationStack {
                PasswordView(address: AuthService.shared.passwordAddress ?? "", isFirstPassword: true)
            }
        }
        .alert("Couldn't connect", isPresented: Binding(get: { connectError != nil },
                                                        set: { if !$0 { connectError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(connectError ?? "") }
        .disabled(working)
        // Sign-out is one-way and has network work behind it, so it gets the treatment every other
        // messenger gives it: the page stops answering and says why. Same idiom as
        // DisconnectSignInView, with the scrim and the word added because this one ends the session
        // and a bare spinner over a still-bright list does not read as "stop tapping".
        .overlay {
            if working {
                ZStack {
                    Color.black.opacity(0.12).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Signing out").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
        .sheet(item: $exportFile) { f in ActivityView(items: [f.url]) }
        .alert("Sign out?", isPresented: $showSignOut) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) {
                // Set BEFORE the Task, so the page locks on this run loop rather than after the
                // first await. The two cleanups below are network writes: on a weak signal they
                // took seconds, and this page sat there fully live the whole time. The tap read as
                // if nothing had happened, Sign Out could be tapped again, and Delete Account was
                // still reachable with a sign-out already in flight (owner report).
                working = true
                Task {
                    await Push.unregister()   // AWAITED before signOut (needs auth): stop message + CallKit ring pushes to this phone
                    // Same reason it is awaited: dropping our own row in Settings › Devices needs
                    // auth, and leaving it behind would show this phone as still signed in.
                    await DeviceRegistry.shared.removeThisDevice()
                    // Deliberately NOT bounded by a timeout. Leaving early to feel faster would put
                    // back the bug `Push.unregister`'s retry exists to fix: tokens left under the
                    // signed-out account keep ringing this phone and showing its notifications.
                    // Waiting visibly is better than leaking a signed-out account's messages.
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
                // A PASSWORD IS NOT OFFERED WHEN THERE IS NO ADDRESS TO TYPE IT AGAINST.
                //
                // Apple's Hide My Email leaves the account on an unguessable relay address, and a
                // password there is a credential that cannot be used at the sign-in screen. Offering
                // it would hand somebody a backup that fails on the day they need it. Connecting
                // Google gives the account a real address and the row appears by itself.
                //
                // Still shown when it is already SET, or an account that set one before this rule
                // would have no way to see it or take it off.
                if method != .email
                    || AuthService.shared.isConnected(.email)
                    || AuthService.shared.hasTypableAddress {
                    signInRow(method)
                }
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
                // THE ADDRESS BELONGS TO THE DOOR THAT IDENTIFIES AN ACCOUNT, and the password row
                // is not one. Its address is always the account's own, so printing it here repeated
                // the line above and made one account look like two. The other two rows keep it:
                // "Google · you@gmail.com" answers WHICH Google account opens this.
                if method != .email, let identifier, !identifier.isEmpty {
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
                // ⚠️ NOT a count. Removing this must leave a door the person can actually open —
                // an Apple-with-Hide-My-Email account that also set a password has two methods and
                // only one of them can be used. See AuthService.removalLeavesAWayIn.
                if AuthService.shared.removalLeavesAWayIn(method) {
                    // The other half of the takeover, gated for the same reason. The removal screen
                    // already re-verifies with a provider, and that step is exactly what the attack
                    // walks through: the credential it accepts can be one added a minute earlier on
                    // the same unlocked phone. The device lock is the part that cannot be
                    // manufactured on the spot.
                    Button("Remove") {
                        Task {
                            switch await DeviceLock.prove(reason: "Remove a way to sign in to Fariin") {
                            case .refused:
                                connectError = "Not verified. Unlock with Face ID, Touch ID or your passcode to remove a way in."
                            case .noLock:
                                connectError = DeviceLock.noLockAdvice
                            case .proved:
                                connectError = nil
                                disconnecting = method
                            }
                        }
                    }
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
                            // GATED HERE, NOT BEFORE, and the order is forced rather than chosen.
                            // Apple's sheet only appears if its own button receives the tap
                            // directly, so there is nowhere earlier to stand. The sheet therefore
                            // runs first and the device lock second, which looks back to front and
                            // is not: nothing is linked until both have passed, and the link is the
                            // only thing that matters. Same takeover as startConnect, same defence.
                            connecting = .apple
                            Task {
                                switch await DeviceLock.prove(reason: "Add a way to sign in to Fariin") {
                                case .refused:
                                    connectError = "Not verified. Unlock with Face ID, Touch ID or your passcode to add a way in."
                                    connecting = nil
                                    return
                                case .noLock:
                                    connectError = DeviceLock.noLockAdvice
                                    connecting = nil
                                    return
                                case .proved:
                                    break
                                }
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

    /// ⚠️ THE DEVICE LOCK GATE HERE IS A FIX FOR A CONFIRMED ACCOUNT TAKEOVER. Do not remove it,
    /// and do not "simplify" it away because connecting a login feels harmless.
    ///
    /// The attack, sixty seconds with an unlocked phone, no jailbreak, stock build:
    ///   1. Settings › Sign-in Methods › Email › Connect. This used to open the sheet with nothing
    ///      asked. Type any address and any password. Firebase links it and MOVES `user.email` to
    ///      the attacker's address.
    ///   2. Tap Remove on the victim's Google. That screen asks you to prove yourself with "any of
    ///      your sign-in methods" — and `reauthEmail` builds its credential from
    ///      `currentUser.email`, which is now the attacker's. So they prove themselves with the
    ///      password they set twenty seconds earlier.
    ///   3. The account now has exactly one door and they hold the key. The victim's own Forgot
    ///      Password finds nothing, because their address is no longer on the account.
    ///
    /// AuthService's own comment claimed the reauth requirement closed this. It did not: a
    /// credential added a moment ago is still an accepted proof of ownership, so step 2 proves
    /// itself with step 1.
    ///
    /// The removal alert does not save them either. It is addressed from post-change state, and by
    /// then the victim's address is off the account, so the "a login was removed" mail goes to the
    /// attacker.
    ///
    /// An emailed code cannot fix this — the attacker chooses the address, and the victim's inbox is
    /// on the phone in their hand anyway. Only the device lock stops somebody standing there,
    /// because their face is not yours. See DeviceLock for the two-attacker reasoning in full.
    private func startConnect(_ method: AuthService.SignInMethod) {
        Task {
            switch await DeviceLock.prove(reason: "Add a way to sign in to Fariin") {
            case .refused:
                connectError = "Not verified. Unlock with Face ID, Touch ID or your passcode to add a way in."
                return
            case .noLock:
                connectError = DeviceLock.noLockAdvice
                return
            case .proved:
                break
            }
            await MainActor.run { connectError = nil; reallyConnect(method) }
        }
    }

    private func reallyConnect(_ method: AuthService.SignInMethod) {
        switch method {
        case .apple:
            break                       // handled by the overlaid SignInWithAppleButton
        case .email:
            // ⚠️ ONLY ASK FOR AN ADDRESS WHEN WE DO NOT ALREADY HAVE ONE.
            //
            // His 2026-08-10 screenshot circled "Set a Password" and the Password row together and
            // asked why they are the same thing. They were not even the same thing, which was worse:
            // this Connect opened `ConnectEmailView`, which asks for an email AND a password, on an
            // account whose address was already sitting two rows above it under Google. It asked him
            // to type an address the app had.
            //
            // An account with a typable address needs a PASSWORD, not an identity — that is the whole
            // point of the rename from "Email" to "Password". Only an account with no usable address
            // has to supply one.
            if AuthService.shared.passwordAddress != nil, AuthService.shared.hasTypableAddress {
                showSetPassword = true
            } else {
                showConnectEmail = true     // no address on file: needs an email + password to link
            }
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
            if let g = WallpaperPreset(id: id).theme {
                GradientWallpaperView(g: g, dark: dark)
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
                    // CAROUSEL, WITH APPLE'S OWN API. The row was flat: every card the same size
                    // right up to the edge, so it read as a list that happens to scroll sideways
                    // rather than something you turn through. `scrollTransition` hands each card
                    // its position in the container as a number running -1 (leading edge) → 0
                    // (settled in view) → 1 (trailing edge), and the card scales, fades and tilts
                    // off that. No package: this has been in SwiftUI since iOS 17 and we ship 26.
                    .scrollTransition(axis: .horizontal) { content, phase in
                        content
                            .scaleEffect(1 - abs(phase.value) * 0.14)
                            .opacity(1 - abs(phase.value) * 0.45)
                            // Around Y, so a card on its way out turns its face away and the ones
                            // in the middle face you square. Negative because `phase.value` is
                            // already negative on the leading side, and the tilt has to follow the
                            // direction of travel or the whole row looks bent the wrong way.
                            .rotation3DEffect(.degrees(phase.value * -14), axis: (x: 0, y: 1, z: 0))
                    }
                }
            }
            .scrollTargetLayout()
        }
        // Come to rest ON a card, never between two. Without this the scroll stops wherever the
        // finger left it and the tilt settles at some random angle, which reads as broken rather
        // than as a carousel.
        .scrollTargetBehavior(.viewAligned)
        // `contentMargins`, not `.padding` on the HStack: padding inside a viewAligned scroll view
        // is measured as part of the first and last targets, so the row snaps 12pt off.
        .contentMargins(12, for: .scrollContent)
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
    // The adaptive profile background used to be a switch here (2026-08-08). It is not a setting any
    // more: a profile takes its colour from that person's photograph for everyone, always, and there
    // is no second design left to choose between (owner, 2026-08-19).
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
                // Face ID is not the whole answer and this page and the App Lock page disagreed
                // about it. `RootView` evaluates `.deviceOwnerAuthentication`, which accepts Face
                // ID, Touch ID OR the passcode — and on a Touch ID phone the old line named a
                // sensor that device does not have. Both pages say the same thing now.
                Text("Require Face ID, Touch ID or your passcode to unlock Fariin.")
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
    /// ⚠️ TEMPORARY — the re-entry scroll jump. Goes with the "Copy scroll log" row below.
    @State private var jumpLogCopied = false
    @State private var jumpLogCleared = false
    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }
    private var buildNumber: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "1"
    }
    /// The build number is the first thing support has to ask for and the last thing anybody can
    /// read off their own phone, so it travels in the subject line instead.
    private var reportURL: URL {
        let subject = "Fariin \(appVersion) (\(buildNumber)) problem report"
        guard let encoded = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "mailto:support@fariin.com?subject=\(encoded)") else {
            return URL(string: "mailto:support@fariin.com")!
        }
        return url
    }

    /// A row that LEAVES THE APP, and says so.
    ///
    /// Every one of these was a bare `Link`, which draws nothing at all: four rows that hand you to
    /// Safari or to Mail looked exactly like the Version row, which does nothing. A chevron would be
    /// the wrong fix — that promises another screen inside the app and this is a door out of it.
    private func outLink(_ title: String, _ url: URL) -> some View {
        Link(destination: url) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
    }

    var body: some View {
        List {
            Section {
                // /support, NOT the site root. The root has been a holding page since the landing
                // page was pulled, so "Support Center" opened a page reading "Working on it." — the
                // one link somebody taps when they are already stuck. The real page exists and has
                // for a while.
                outLink("Support Center", URL(string: "https://fariin.com/support")!)
                outLink("Report a Problem", reportURL)
            } header: {
                Text("Help")
            } footer: {
                Text("Fariin has zero tolerance for objectionable content or abusive behavior. Reports are reviewed within 24 hours.")
            }
            Section {
                // Selectable so it can be copied into a support mail. It is the one value on this
                // screen somebody else will ask them to read out.
                LabeledContent("Version", value: "\(appVersion) (\(buildNumber))")
                    .textSelection(.enabled)
                // ⚠️ TEMPORARY, 2026-08-29 — the re-entry scroll jump. Delete this row, `JumpLog`
                // and the `jlog` calls in `NativeMessageList` once the cause is written down.
                //
                // A VISIBLE ROW RATHER THAN A LONG-PRESS ON THE VERSION ABOVE, deliberately: that
                // row is `.textSelection(.enabled)`, so a long press there belongs to UIKit's text
                // selection and a gesture competing with it is a coin toss. The reproduction has
                // already been paid for twice; the way to read the result must not be the part that
                // fails.
                Button {
                    UIPasteboard.general.string = JumpLog.shared.text
                    jumpLogCopied = true
                    jumpLogCleared = false
                } label: {
                    LabeledContent("Copy scroll log",
                                   value: jumpLogCopied ? "Copied" : "\(JumpLog.shared.count) lines")
                }
                .foregroundStyle(.primary)
                // ⛔ AND A WAY TO EMPTY IT. His report, 2026-08-30: "I tried to clear it and make
                // another log but it keeps stuck". Putting the log on disk so it would survive a
                // relaunch also made it survive everything else, and a log you cannot reset is one
                // reproduction long — every run after the first arrives buried under the one before
                // it. Clearing is half of the tool.
                Button(role: .destructive) {
                    JumpLog.shared.clear()
                    jumpLogCleared = true
                    jumpLogCopied = false
                } label: {
                    LabeledContent("Clear scroll log", value: jumpLogCleared ? "Cleared" : "")
                }
                outLink("Privacy Policy", URL(string: "https://fariin.com/privacy")!)
                outLink("Terms & Conditions", URL(string: "https://fariin.com/terms")!)
            } header: {
                Text("About")
            } footer: {
                // THE SAME OVERCLAIM THE WEBSITE ALREADY HAD CORRECTED. Messages and calls are end
                // to end encrypted; stories are NOT yet (see the 2026-08-05 privacy sweep — removing
                // the public audience unblocked it, but it is not built). fariin.com's meta
                // description was fixed for exactly this on `fariin-web 6101adf`, and this line was
                // left saying the broader thing. It should not outrun the app twice.
                Text("Messages and calls are end-to-end encrypted. Made for Somalia.")
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
    /// Demo people in the story row. Read by `StoriesRepository.injectDemoStories`. The row that
    /// shows this switch is gated on `DemoStoryMedia.isAvailable` (debug or TestFlight, never the
    /// App Store) — it cannot be `#if DEBUG`, because TestFlight is a Release build and that is the
    /// only kind of build he can run.
    @AppStorage("demoStoryUsers") private var demoStoryUsers = false
    // DELETED HERE: the "3D Cube Transition" toggle and the `story.personTransition` defaults key it
    // wrote. Both transitions were kept switchable on his 2026-08-11 instruction so he could compare
    // them; on 2026-08-12 he compared them and ruled — the cube is the only one, and the flat slide
    // "should no longer exist anywhere in the person-to-person story transition". A setting whose
    // off position no longer exists is not a setting.
    @State private var confirmOff = false
    @State private var audiences = StoryAudienceStore.shared
    @State private var contacts: [StoryContact] = []
    @State private var creating = false

    var body: some View {
        List {
            // THE SAME LIST THE SHARE SHEET SHOWS, and deliberately the same rows: an audience you
            // made while posting has to be findable afterwards, and one you make here has to be
            // there the next time you post. One store, two doors.
            if !optedOut {
                Section {
                    ForEach(audiences.all) { a in
                        Group {
                            if a.kind == .everyone {
                                // ⚠️ IT OPENS NOW. The audience is still fixed — "Everyone cannot be
                                // edited" was his own rule and stands — but the page behind it edits
                                // the SEPARATE hidden list, which is not a property of any audience
                                // and applies to all of them. See `EveryonePrivacyView`.
                                NavigationLink { EveryonePrivacyView() } label: {
                                    StoryAudienceRow(audience: a, contacts: StoryContact.ids(contacts)) { EmptyView() }
                                }
                            } else if a.kind == .myFriends {
                                NavigationLink { MyFriendsPrivacyView() } label: {
                                    StoryAudienceRow(audience: a, contacts: StoryContact.ids(contacts)) { EmptyView() }
                                }
                            } else if a.kind == .glowers {
                                // ⛔ ITS OWN PAGE — owner, 2026-09-02. It used to fall through to
                                // `CustomStoryDetailView`, which looks up `store.custom` by id and
                                // finds nothing for a built-in, so the row opened an empty screen.
                                NavigationLink { GlowersPrivacyView() } label: {
                                    StoryAudienceRow(audience: a, contacts: StoryContact.ids(contacts)) { EmptyView() }
                                }
                            } else {
                                NavigationLink { CustomStoryDetailView(audienceId: a.id) } label: {
                                    StoryAudienceRow(audience: a, contacts: StoryContact.ids(contacts)) { EmptyView() }
                                }
                            }
                        }
                        // The share sheet's row height, from the row itself so the two lists cannot
                        // drift — see `StoryAudienceRow.insets`.
                        .listRowInsets(StoryAudienceRow<EmptyView>.insets)
                    }
                } header: {
                    HStack {
                        Text("Stories")
                        Spacer()
                        NewAudienceButton(onCustom: { creating = true }, canAddCustom: audiences.canAddCustom)
                    }
                    .textCase(nil)
                } footer: {
                    Text("Story updates automatically disappear after 24 hours. Choose who can view your story, or make a new one with specific viewers.")
                }
            }
            // TESTFLIGHT AND DEBUG, NEVER THE APP STORE — see `DemoStoryMedia.isAvailable`.
            //
            // Four people whose stories are drawn and encoded on this phone (see `demoGroups`).
            // Nothing about them touches Firebase and nobody else can ever see them. They exist
            // because the story bugs worth testing are video bugs, and testing those needs a friend
            // with video stories, which a real account does not reliably have.
            if DemoStoryMedia.isAvailable {
                Section {
                    Toggle("Demo story people", isOn: $demoStoryUsers).tint(.orange)
                        .onChange(of: demoStoryUsers) { _, _ in
                            StoriesRepository.shared.refreshForDemo()
                        }
                } footer: {
                    Text("Testers only. Adds four local people with video and photo stories to the story row, for checking the story viewer. They are drawn on this device, never uploaded, and nobody else can see them.")
                }
            }
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
        .onAppear { contacts = StoryContact.all() }   // recomputed, so a fresh block counts
        .sheet(isPresented: $creating) {
            CreateCustomStoryFlow(onCreated: { _ in creating = false },
                                  onCancel: { creating = false })
        }
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
    /// The username editor, presented from the bottom rather than pushed — see the row below.
    @State private var editingUsername = false
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
    /// The gap the bio card keeps above the keys (owner 2026-08-22: "there's no space between card
    /// and keyboard"). `scrollTo(anchor: .bottom)` lands the card's bottom edge on the bottom of the
    /// visible area, so the only way to buy a gap is to make the visible area end higher — which is
    /// what the matching `safeAreaInset` on the Form does, and only while the bio is being edited.
    private static let bioKeyboardGap: CGFloat = 14
    /// Same rule as the username counter: show it only once this many characters remain.
    private static let bioCounterAppearsAt = 20
    private var bioRemaining: Int { max(0, Limits.bioChars - about.count) }
    private var hasUnsavedText: Bool {
        firstName != origFirst || lastName != origLast || handle != origHandle || about != origAbout
    }

    /// A BIO IS ONE PARAGRAPH — the rule and the whole reason for it live in `Limits.oneParagraph`,
    /// which a contact's private Note shares. This is the bio's ceiling applied to it.
    static func tidyBio(_ raw: String) -> String {
        Limits.oneParagraph(raw, max: Limits.bioChars)
    }

    /// ⚠️ THE WHOLE NAME, BECAUSE THE LETTER AVATAR'S COLOUR IS HASHED FROM IT. The two pictures of
    /// the same account disagreed: the page behind this sheet draws `me.name` ("adnan abdi") and this
    /// sheet drew `firstName` alone ("adnan"), so `AvatarPalette.gradient(for:)` was hashing two
    /// different strings and answering two different colours — teal on the page, blue in the sheet,
    /// same person, same letter. This is the SAME composition `save` writes, so it follows the
    /// fields while they are edited and equals `me.name` the moment it lands.
    private var editingName: String {
        "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces)
    }
    /// Anything Save would write. The photo counts now that it is no longer applied the instant it
    /// is cropped, which is what makes X a real cancel rather than a late goodbye.
    private var hasUnsavedChanges: Bool { hasUnsavedText || pendingPhoto != nil || pendingRemove }

    var body: some View {
        NavigationStack {
            // ONE SCREEN, and only ever the form. A Circle/Preview segmented control used to sit in
            // the top bar with a card-deck rendering of the big profile header behind it (owner
            // 2026-08-03). Owner 2026-08-19, looking at it: "it doesn't make sense, remove it" — you
            // edit your profile here and you look at it on the profile page, so a second drawing of
            // the same thing inside the editor was a tab that needed explaining rather than using.
            editForm
            .navigationTitle("Edit Profile")
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
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .fontWeight(.semibold)
                        .disabled(saving || !hasUnsavedChanges)
                }
            }
            // On the SCREEN, with the X that raises it, so it works from either tab.
            .interactiveDismissDisabled(hasUnsavedChanges)
            // ALERT, for the reason ChatsSettingsView spells out over "Delete Everything": on iOS 26
            // a confirmationDialog attached to a plain view renders as an anchored popover and drops
            // its cancel button. Here that would leave "Discard Changes" as the only thing on
            // screen, on the one prompt whose entire purpose is offering the way back. The rest of
            // the guard is already right — interactiveDismissDisabled stops the swipe — so losing
            // "Keep Editing" would be the only hole left in it.
            .alert("Discard changes?", isPresented: $confirmDiscard) {
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
                                AvatarView(name: editingName,
                                           photoUrl: pendingRemove ? nil : profile.me?.photoUrl,
                                           // 120, matching the Settings header's own circle. At 100
                                           // it was the smallest picture on a page whose entire
                                           // subject is that picture, with the pill under it nearly
                                           // as wide as the photo itself (owner, 2026-08-20).
                                           size: 120)
                                if let pendingPhoto {
                                    Image(uiImage: pendingPhoto).resizable().scaledToFill()
                                        .frame(width: 120, height: 120).clipShape(Circle())
                                }
                            }
                            .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        HStack(spacing: 10) {
                            Button { showEditPhoto = true } label: {
                                Text("Edit Photo").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                    .padding(.horizontal, 20).frame(height: 36)
                                    .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            // ⛔ DELETED HERE: the preview button — owner, 2026-09-02: "in edit
                            // profile the preview button, remove it, I don't need it".
                            //
                            // It was added 2026-08-20 on the reasoning that everything on this
                            // screen is a field and none of it shows the result. That reasoning is
                            // weaker now than it was: the profile has its own Edit button in the top
                            // right, so the page you are editing is one tap behind this sheet rather
                            // than somewhere you have to go and find. Preview from a preview is a
                            // second door to the room you just left.
                        }
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
                        // A Recents pick goes to the SAME cropper a chosen photo does — one framing
                        // path, so only one of them can be wrong.
                        case .image(let img): cropCandidate = CropItem(image: img)
                        // An emoji disc is already square and already centred. Held for Save like
                        // every other change on this screen, and the poster is the same square:
                        // there is no second framing of a circle.
                        case .emoji(let img):
                            pendingPhoto = img
                            pendingPoster = img
                            pendingRemove = false
                        }
                    }) {
                        ProfilePhotoSheet(name: editingName,
                                          photoUrl: pendingRemove ? nil : profile.me?.photoUrl,
                                          pendingImage: pendingPhoto,
                                          canRemove: hasPictureToRemove,
                                          action: $photoAction)
                    }
                    .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
                    // ⛔ DELETED HERE with its button: the profile PREVIEW sheet, on his word,
                    // 2026-09-02. It presented `ContactInfoView` in preview mode — the real screen a
                    // stranger gets, not a mock-up, driven by `previewUid`. That mode still exists
                    // and still works; nothing on this page opens it any more.
                    //
                    // Recorded rather than silently dropped because it took two goes to get right
                    // (full page, then back to a sheet on his word, then `presentationBackground`
                    // for the white corners), and none of that history is worth rediscovering if it
                    // is ever wanted again.
                    // Its own stack, because it carries a title and a Done and is no longer inside
                    // this screen's navigation.
                    .sheet(isPresented: $editingUsername) {
                        NavigationStack { UsernameEditView(handle: $handle) }
                    }
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
                    // ⛔ A SHEET, NOT A PUSH (owner, 2026-08-20: "that page and keyboard is coming
                    // right side… it must come bottom"). A push arrives from the trailing edge, and
                    // because the field takes focus as it arrives, iOS carries the KEYBOARD in on
                    // that same horizontal transition — so the keys slid in from the right corner
                    // instead of rising. Presenting from the bottom makes both move the one way.
                    //
                    // The row keeps its own chevron: it is a `Button` now, and `NavigationLink` was
                    // what used to draw that for free.
                    Button { editingUsername = true } label: {
                        HStack {
                            Text("Username").foregroundStyle(.primary)
                            Spacer()
                            Text(handle.isEmpty ? "Set" : "@\(handle)").foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                }

                Section {
                    // ⛔ THE COUNTER LIVES IN THE CARD (owner 2026-08-22: "count characters bio put
                    // inside the card"). It was the Section's FOOTER, which draws below the white
                    // shape, so the number floated on the grey with nothing to belong to. Inside the
                    // row it is part of the field it is counting.
                    VStack(alignment: .trailing, spacing: 4) {
                        // ⛔ TIDIED IN THE SETTER, NOT IN `onChange`, AND THAT IS THE WHOLE OF HIS
                        // "click the arrow, page is doing scroll down then scroll up".
                        //
                        // `onChange` runs AFTER the binding has been written and the view laid out.
                        // So Return really did insert a newline: the field grew a line, the form
                        // scrolled to keep the caret above the keyboard, and only then did the tidy
                        // replace the newline with a space, shrinking the field and scrolling back.
                        // Down, then up, every time — and the 0.2s animation on the scroll made sure
                        // both halves were visible.
                        //
                        // A filtering binding closes the gap: the newline is gone before `about` ever
                        // holds it, so there is no taller layout to lay out and nothing to undo.
                        TextField("A few words about you",
                                  text: Binding(get: { about },
                                                set: { about = Self.tidyBio($0) }),
                                  axis: .vertical)
                            .lineLimit(1...5)
                            .focused($bioFocused)
                            .onChange(of: about) { _, _ in
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
                        // The same counter rule the username field already uses: nothing at all until
                        // you are near the ceiling, then a number counting DOWN. A counter that is
                        // always on screen is a number that means nothing for the hundred characters
                        // nobody is near the limit.
                        if bioRemaining <= Self.bioCounterAppearsAt {
                            Text("\(bioRemaining)")
                                .font(.footnote)
                                .monospacedDigit()      // so the row does not jog as 10 becomes 9
                                .foregroundStyle(bioRemaining == 0 ? .red : .secondary)
                                .transition(.opacity)
                                .accessibilityLabel("\(bioRemaining) characters left")
                        }
                    }
                    // ⚠️ THE ANCHOR MOVED OUT TO THE WHOLE ROW. It was on the field alone, and the
                    // counter now sits under it inside the same card — scrolling the field to the
                    // bottom of the visible area would have parked the counter behind the keyboard.
                    .id(Self.bioAnchor)
                } header: {
                    Text("Bio")
                }
                .animation(.smooth(duration: 0.22), value: bioRemaining <= Self.bioCounterAppearsAt)

                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }
            }
            // THE GAP ABOVE THE KEYS. Raising the bottom of the scrollable area is the only lever
            // that works here: the scroller lands the bio card's bottom edge on that boundary, so
            // with no inset the card sits flush against the keyboard. Zero when the bio is not being
            // edited, so nothing else on the form gains a mystery margin.
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: bioFocused ? Self.bioKeyboardGap : 0)
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
    /// ⛔ THE PHOTO NO LONGER HOLDS THE SHEET OPEN, and that is the whole of "make it fast".
    ///
    /// This used to await the two uploads, the download-url round trips and the user-document write
    /// before Save would close — several seconds on a phone connection, watching a spinner. The
    /// reference app does not wait for any of that: the picture you cropped is on screen at once and
    /// the upload runs behind you.
    ///
    /// `setPhotoLocallyThenUpload` publishes the new picture under a local url seeded into the image
    /// cache, so every avatar in the app has it on the next frame, and swaps to the real url when it
    /// lands. Nothing here can fail any more, so nothing here returns false: a failed upload puts the
    /// old picture back and reports itself through `profile.photoError`, which this screen watches.
    private func applyPendingPhoto() {
        if pendingRemove {
            profile.removePhotoLocallyThenSync()
            pendingRemove = false
            return
        }
        guard let img = pendingPhoto else { return }
        profile.setPhotoLocallyThenUpload(circle: img, poster: pendingPoster)
        pendingPhoto = nil
        pendingPoster = nil
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
            // ⚠️ THE ORDER IS REVERSED, AND ON PURPOSE. The TEXT is what can be refused — a username
            // is claimed by one server transaction and somebody else may hold it — so it is awaited
            // first and its failure keeps the sheet open with the reason. The photo cannot fail here
            // at all any more: it is applied locally and uploaded behind, so it is started last and
            // the sheet closes on top of it.
            // Tidied again on the way out, not only as you type: a bio saved before this rule
            // existed still holds its blank lines, and this is the pass that cleans it.
            if hasUnsavedText { try await profile.updateProfile(name: n, handle: h, about: Self.tidyBio(about)) }
            applyPendingPhoto()
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

    /// Letters still available. Never negative: `sanitizeHandle` truncates at the maximum.
    private var remaining: Int { max(0, Limits.usernameMaxChars - clean.count) }
    /// The counter stays hidden until this many or fewer are left. The reference app's threshold: theirs
    /// appears at 21 of 30, which is 9 remaining.
    private static let counterAppearsAt = 9

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
                    // HOW MANY LETTERS ARE LEFT, and only once that is a real question.
                    //
                    // The reference app's counter, from the owner's screenshot: nothing at all until you are
                    // near the ceiling, then a number that counts DOWN as you type. Theirs appears
                    // at 21 of 30, which is the same rule as "show it when 9 or fewer remain", so
                    // that is what this is — expressed as the remainder rather than the length, or
                    // it would silently stop matching if the maximum ever moved.
                    //
                    // A counter that is always on screen is worse than none: for the twenty
                    // characters nobody is anywhere near the limit it is a number that means
                    // nothing, sitting in the one place the eye goes to check the name.
                    //
                    // It cannot go negative — sanitizeHandle truncates at the maximum, so the field
                    // simply stops accepting letters and this reads 0.
                    if remaining <= Self.counterAppearsAt {
                        Text("\(remaining)")
                            .font(.subheadline)
                            .monospacedDigit()          // so the field does not jog as 10 becomes 9
                            .foregroundStyle(remaining == 0 ? .red : .secondary)
                            .transition(.opacity)
                            .accessibilityLabel("\(remaining) characters left")
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
                // Drives BOTH transitions in this row: the counter appearing at nine left, and the
                // clear button appearing on the first letter. A `.transition` with nothing animating
                // the change behind it does nothing at all, so without this the counter would pop in
                // rather than fade. Keyed to the two things that actually change, not to `draft`,
                // which would re-run the animation on every keystroke.
                .animation(.smooth(duration: 0.18), value: remaining <= Self.counterAppearsAt)
                .animation(.smooth(duration: 0.18), value: draft.isEmpty)
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
        // ⚠️ THE FOCUS WAITS FOR THE PRESENTATION TO LAND. Asking for it in `onAppear` means asking
        // while the screen is still arriving, and iOS then animates the keyboard along whatever
        // transition is running rather than raising it from the bottom — which is exactly what the
        // owner photographed. One runloop turn after the sheet has settled, the keyboard rises the
        // ordinary way.
        .onAppear { draft = handle }
        .task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            focused = true
        }
    }

    /// THE RULES STAY PUT (owner 2026-08-04: they vanished the moment the checker answered).
    ///
    /// They used to be one of the STATES, so the first reply from the server took them off the
    /// screen — exactly while you are typing a name and most likely to need them. They are not a
    /// state, they are the caption for the field.
    ///
    /// ⚠️ THE VERDICT GOES ON TOP, THE RULES UNDER IT (owner 2026-08-22: "plz check available
    /// usernam always make first"). The rules are the same sentence on every screen and every
    /// visit, so once the checker has an answer the answer is the only new thing here — burying it
    /// on the second line makes you read a line you already know before the one you are waiting
    /// for. The rules keep their place as the field's caption; they just stop going first.
    @ViewBuilder private var statusLine: some View {
        VStack(alignment: .leading, spacing: 4) {
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
            Text("Letters, numbers and _ only. \(Limits.usernameMinChars)–\(Limits.usernameMaxChars) characters.")

            // THE LINK, BUILT AS YOU TYPE. The reference app shows a similar line — "This link opens
            // a chat with you:" followed by its own address — which is the thing that makes a username feel like it is worth
            // choosing: it stops being a setting and becomes an address you can hand to somebody.
            //
            // Shown at EVERY state, including while the name is invalid or taken — the reference app does the
            // same, because the line's job is to show what the link WOULD be, not to be a second
            // verdict. The status line at the top of this block is the verdict, and two of them
            // disagreeing on one screen is worse than none.
            //
            // The format is the one the app actually opens: KulanApp routes both
            // https://fariin.com/u/<handle> and kulan://u/<handle>, and fariin.com is in the
            // entitlements. It is written here rather than hardcoded twice — if the path ever moves,
            // it moves in one place.
            //
            // Selectable, not tappable. Copying it is the whole point; opening a chat with yourself
            // is not.
            VStack(alignment: .leading, spacing: 2) {
                Text("This link opens a chat with you:")
                Text(Self.profileLink(for: clean))
                    .foregroundStyle(.tint)
                    .textSelection(.enabled)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The public address for a handle. Empty draft shows the bare domain, the way the reference app shows a
    /// bare address before you have typed anything — the shape of the thing you are about to
    /// own, rather than a blank.
    static func profileLink(for handle: String) -> String {
        "https://fariin.com/u/\(handle)"
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
                    // "Email", not "you@example.com". Unlike the two auth screens this row has no
                    // label above it, so the placeholder IS the label here and cannot just be
                    // emptied — that would leave a blank row with nothing saying what goes in it.
                    // The word does the labelling job the fake address was pretending to do.
                    TextField("Email", text: $email)
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
