import SwiftUI
import FirebaseFirestore
import Photos

// ⛔ GROUP INFO, IN THE PERSON PROFILE'S DESIGN — owner 2026-10-18: "make it exactly the design the
// user profile is using". The 1:1 page's own pieces (`ProfileInfoRow`, `ProfileMediaCard`,
// `profileSurface`) on the same grey page: the ROUND photo always (never the big photo header; that
// is a person's), name and member count, the actions, the description as an About card (the Fariin
// official chat's), the members, the media, one settings card, and the red card. Who-can-do-what,
// admins, the member list and invites live on Group Settings (`GroupSettingsView`), not here. Edit
// changes the name and the photo (`EditGroupView`).
//
// owner 2026-10-18 (upgrade): labelled tiles in place of the round actions (Call, Video, Share or
// Add, Search), the ••• menu in the top bar with the QR of the invite link beside it, a pinned
// Members · Media · Settings switcher, Member Changes, Media and Storage rows, Save to Photos per
// chat, Encryption, Export Chat and Create a Similar Group. No empty description card any more:
// an "Add group description" link under the count instead. The new pieces are in GroupInfoExtras.
//
// ⛔ owner's mockup 2026-10-19 REPLACES THE LAYOUT ABOVE: a photo group gets the person profile's
// big photo header and its colour; no photo, a glass disc of three faces. Then five glass circles
// (Add, Video, Mute, Search, More), one card (Disappearing, Sounds, Invite link), Group Settings,
// All Members as a cloud of faces, All Media. Nothing else on the page: every other item is in the
// ••• menu (`moreMenuItems`). Glass cards here (`profileGlassSurface`); a person's stay flat.
struct GroupInfoView: View {
    let cid: String
    /// The chat's search, opened from the Search tile (the profile's own wiring).
    let onSearch: (() -> Void)?
    init(cid: String, onSearch: (() -> Void)? = nil) { self.cid = cid; self.onSearch = onSearch }
    @Environment(\.dismiss) private var dismiss
    private var repo = ConversationsRepository.shared
    private var me: String { AuthService.shared.uid ?? "" }

    @State private var showDescEdit = false
    @State private var descText = ""
    @State private var showDisappear = false
    @State private var pendingDisappear: Int?   // chosen timer awaiting the "for all members" confirm
    @State private var showAdd = false
    @State private var memberAction: MemberAction?
    @State private var notice = ""
    @State private var noticeShown = false
    @State private var profileOf: MemberAction?   // Info on a member's sheet (owner 2026-10-19)
    @State private var confirmLeave = false
    @State private var confirmClear = false
    @State private var confirmReport = false
    @State private var confirmDelete = false
    /// A refused Leave / Delete Group. Both used to close the page on `try?` whatever happened.
    @State private var actionError: String?
    @State private var media: [Message] = []
    @State private var showAllMedia = false
    @State private var viewerImage: Message?
    @State private var viewerVideo: Message?
    @State private var showCall = false
    @State private var showInvite = false
    /// The invite link being shared through the app's Send To sheet (Share Group).
    @State private var shareGroupText: String?
    @State private var showMemberLink = false
    @State private var showAllMembers = false   // the members header's search, and See All under the first five
    @State private var showSounds = false
    @State private var showSettings = false
    @State private var showEdit = false
    @State private var showGroupPhoto = false    // tap the photo → the same morph a person's photo uses
    @State private var photoCloseTick = 0        // toolbar X → viewer close (see ProfilePhotoViewer.closeSignal)
    /// Where the header's photo is drawn, for the viewer's flight. A plain box, not observed: the
    /// header reports it while scrolling and a re-render per frame is the scroll lag of 2026-10-18.
    @State private var artRect = GroupArtRect()
    /// The colour read out of the group's photo (the person profile's own reading, `ProfilePalette`).
    // 2026-10-18 upgrade.
    @State private var showMemberChanges = false
    @State private var showEncryption = false
    @State private var showQR = false
    @State private var showSimilar = false
    @State private var saveChoice: AutoSaveToPhotos.ChatChoice = .standard
    @State private var photosDenied = false
    /// Media, links and files in this chat (the gallery's own count), nil until known.
    @State private var galleryCount: Int?
    /// The messages the storage figure was summed from, so Clear removes exactly those files.
    @State private var storageMessages: [Message] = []
    @State private var storage: ChatMediaStorage.Usage?
    @State private var confirmClearStorage = false
    @State private var showStorage = false
    @State private var exportFile: ExportFile?
    @State private var exportError: String?
    @State private var exporting = false

    struct MemberAction: Identifiable, Hashable { let id: String; let name: String; let isAdmin: Bool }

    private var conv: Conversation? { repo.conversations.first { $0.id == cid } }
    private var iAmAdmin: Bool { conv?.isAdmin(me) ?? false }
    private var iAmOwner: Bool { conv?.createdBy == me && !(conv?.createdBy.isEmpty ?? true) }
    // Per-flag admin right check (owner = all; legacy admin with no adminRights entry = all).
    private func can(_ r: Conversation.Right) -> Bool { conv?.adminCan(me, r) ?? false }
    // An admin with the matching right can; members can too when the group's permission is on.
    private var canEditInfo: Bool { can(.changeInfo) || (conv?.membersCanEditInfo ?? false) }
    private var canAdd: Bool { can(.inviteUsers) || (conv?.membersCanAdd ?? false) }
    private var title: String { conv?.title ?? "Group" }
    private var muted: Bool { conv?.isMuted(me, now: Date().timeIntervalSince1970 * 1000) ?? false }
    private var pageBackground: Color { Color(uiColor: .systemGroupedBackground) }
    /// The group's photo, only when there is a real one: it decides the big header and the colour.
    private var groupPhoto: String? {
        let u = conv?.avatarUrl
        return ProfilePhotoIndex.hasPicture(u) ? u : nil
    }
    private var hasGroupPhoto: Bool { groupPhoto != nil }
    /// ⛔ A GROUP PAGE TAKES NO COLOUR FROM ITS PHOTO (owner 2026-10-19, after seeing it on device):
    /// always the plain grouped background.
    private var palette: ProfilePalette? { nil }
    /// ContactInfoView's bar rule: iOS 26 is handed light for the glass, iOS 27 reads its backdrop.
    private var barScheme: ColorScheme? {
        guard palette != nil else { return nil }
        if #available(iOS 27.0, *) { return .dark }
        return .light
    }
    /// The group's invite link, only while it has one (2026-10-18: a private group shows no Share/QR).
    /// Admins share the link; members only when "Share the group link" is on (owner 2026-10-19,
    /// a course group whose admins keep the door to themselves).
    private var mayShareLink: Bool {
        guard let c = conv else { return false }
        return c.isAdmin(me) || c.isOwner(me) || c.membersCanShareLink
    }
    private var inviteLink: String? {
        guard mayShareLink, let code = conv?.inviteCode, !code.isEmpty,
              let link = URL(string: KulanApp.groupLink(code: code)) else { return nil }
        return link.absoluteString
    }

    /// The same capsule the profile page raises: up on a spring, gone after a second and a half.
    private func flashNotice(_ text: String) {
        Haptics.notify(.warning)
        notice = text
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { noticeShown = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeOut(duration: 0.25)) { noticeShown = false }
        }
    }

    var body: some View {
        AnyView(core)
            .overlay(alignment: .bottom) {
                if noticeShown {
                    Text(notice)
                        .font(.subheadline.weight(.medium)).foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(.black.opacity(0.75), in: Capsule())
                        .padding(.horizontal, 24)
                        .padding(.bottom, 40)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .navigationDestination(isPresented: $showMemberChanges) { GroupMemberChangesView(cid: cid) }
            .navigationDestination(isPresented: $showMemberLink) {
                if let link = inviteLink { GroupLinkShareView(title: title, photo: conv?.avatarUrl, link: link) }
            }
            .navigationDestination(item: $profileOf) { m in
                ContactInfoView(cid: ChatService.convId(me, m.id), name: m.name,
                                photoUrl: conv?.photos[m.id], source: .calls)
            }
            .sheet(isPresented: $showAllMembers) { GroupMembersSheet(cid: cid) }
            .sheet(isPresented: $showEncryption) { ChatEncryptionSheet() }
            .sheet(isPresented: $showQR) {
                if let link = inviteLink { GroupLinkQRSheet(title: title, link: link) }
            }
            .sheet(isPresented: $showSimilar) {
                NewGroupView(initial: similarPeople) { t in openCreatedGroup(t) }
            }
            // Export Chat: the decrypted text is deleted the moment the share sheet closes.
            .sheet(item: $exportFile, onDismiss: { DataExport.cleanup() }) { f in ActivityView(items: [f.url]) }
            .modifier(GroupInfoUpgradeDialogs(
                photosDenied: $photosDenied, exportError: $exportError,
                storage: storage, confirmClearStorage: $confirmClearStorage, onClearStorage: clearStorage))
    }

    private var core: some View {
        page
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .navigationBarBackButtonHidden(showGroupPhoto)
            // The person profile's bar over a photo (ContactInfoView `coreScrollWithBars`): no
            // material over the picture, the glass scheme for this OS, and the chevron held white
            // by the tint so it stays white through the iOS 26 flip.
            .toolbarColorScheme(barScheme, for: .navigationBar)
            .tint(palette != nil ? Color.white : nil)
            .overlay {
                if showGroupPhoto {
                    // Out of the round photo, landing on the whole picture square, as my own photo
                    // does in Settings (owner 2026-10-19: "now is a circle, make it like Settings").
                    ProfilePhotoViewer(name: title, photoUrl: groupPhoto ?? "",
                                       sourceFrame: artRect.rect, landsSquare: true,
                                       closeSignal: photoCloseTick,
                                       isPresented: $showGroupPhoto)
                        .ignoresSafeArea()
                }
            }
            .modifier(GroupInfoDialogs(cid: cid, current: conv?.disappearSeconds ?? 0,
                                       showDescEdit: $showDescEdit, descText: $descText,
                                       showDisappear: $showDisappear, pendingDisappear: $pendingDisappear))
            .modifier(GroupInfoExits(cid: cid, conv: conv, me: me,
                                     confirmLeave: $confirmLeave, confirmClear: $confirmClear,
                                     confirmReport: $confirmReport, confirmDelete: $confirmDelete,
                                     actionError: $actionError, onGone: { dismiss() }))
            // A full page, pushed (owner 2026-10-18), not a half sheet.
            .sheet(item: Binding(get: { shareGroupText.map { ShareText(id: $0) } },
                                 set: { shareGroupText = $0?.id })) { t in
                ForwardPicker(shareText: t.id)
            }
            .navigationDestination(isPresented: $showInvite) {
                InviteLinkSheet(cid: cid, groupTitle: title, groupPhoto: conv?.avatarUrl,
                                initialCode: conv?.inviteCode ?? "", embedded: true)
            }
            .sheet(item: $memberAction) { m in memberSheet(m) }
            .sheet(isPresented: $showAdd) { AddMembersSheet(cid: cid, existing: Set(conv?.users ?? [])) }
            .sheet(isPresented: $showEdit) {
                EditGroupView(cid: cid, title: title, photoUrl: conv?.avatarUrl,
                              description: conv?.groupDescription ?? "")
            }
            .fullScreenCover(item: $viewerImage) { msg in
                ImageViewerView(message: msg, cid: cid, rectScope: .profile)
            }
            .fullScreenCover(item: $viewerVideo) { msg in
                VideoPlayerScreen(message: msg, cid: cid, clipProvider: { nil }, rectScope: .profile)
            }
            .navigationDestination(isPresented: $showStorage) {
                ChatStorageView(cid: cid, title: title, messages: storageMessages) {
                    Task { await loadMediaFigures() }
                }
            }
            .navigationDestination(isPresented: $showAllMedia) {
                MediaGalleryView(cid: cid, title: title, photoUrl: conv?.avatarUrl)
            }
            .navigationDestination(isPresented: $showSounds) { SoundsNotificationsView(cid: cid) }
            .navigationDestination(isPresented: $showSettings) { GroupSettingsView(cid: cid) }
            .fullScreenCover(isPresented: $showCall) { GroupCallView() }
            // Local first (offline + instant), then the server; a failed load leaves what we have.
            .task {
                saveChoice = AutoSaveToPhotos.choice(for: cid)
                if let local = ThreadMessageCache.shared.messages(for: cid) {
                    let localMedia = local
                        .filter { $0.isImage || $0.isVideo || $0.isAlbum }
                        .reversed()
                        .flatMap { $0.expandedGalleryItems(cid: cid) }
                    if !localMedia.isEmpty { media = Array(localMedia) }
                }
                if let fresh = await ChatService.sharedMedia(cid) { media = fresh }
            }
            // The gallery count and the storage figure, again on every return (the gallery or a
            // clear may have changed them).
            .onAppear { Task { await loadMediaFigures() } }
    }

    // ⛔ THE OWNER'S MOCKUP, AND ONLY WHAT IS IN IT (2026-10-19): the header, five round glass
    // actions, one card of three rows, Group Settings, All Members as a cloud of faces, All Media.
    // Everything else the page used to carry (About, the member rows, storage, export, QR,
    // encryption, a similar group, leave / report / delete) is in the ••• action's menu.
    private var page: some View {
        ScrollView {
            VStack(spacing: 20) {
                AnyView(header)
                AnyView(cards)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        // Named so the big header can read its own offset and stretch on a pull.
        .coordinateSpace(name: Self.scrollSpace)
        // The person profile's page: one flat colour off the photo, washing in when it is read;
        // the plain grouped background for a group with no photo.
        .background { ProfileAdaptiveBackdrop(palette: palette, fallback: pageBackground) }
        .environment(\.profilePalette, palette)
        // A coloured page is always the dark family (the profile's rule, owner 2026-08-19).
        .environment(\.colorScheme, palette != nil ? .dark : scheme)
    }
    @Environment(\.colorScheme) private var scheme
    private static let scrollSpace = "groupInfoScroll"

    @ViewBuilder private var cards: some View {
        settingsCard
        if iAmAdmin { groupSettingsCard }
        // The bubble cloud is the admin panel's call (config/features memberCloud), live.
        if Flags.memberCloud(for: cid) { memberCloudCard }
        if !media.isEmpty {
            ProfileMediaCard(cid: cid, media: media, cardColor: cardColor,
                             onOpen: { m in if m.isVideo { viewerVideo = m } else { viewerImage = m } },
                             onSeeAll: { showAllMedia = true })
        }
        // Members between All Media and the red rows (owner's mockup 2026-10-19).
        membersSection
        exitCard
    }

    // MARK: Header

    /// ⛔ NO BIG PHOTO HEADER FOR A GROUP (owner 2026-10-19, on device): a group with a photo shows
    /// it as a round picture; without one, a glass disc of three members' faces. Either way the
    /// name, the count and the description, then the actions.
    private var header: some View {
        VStack(spacing: 16) {
            if let groupPhoto {
                AvatarView(name: title, photoUrl: groupPhoto, size: Self.photoSide)
                    .opacity(showGroupPhoto ? 0 : 1)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { artRect.rect = $0 }
                    .onTapGesture { showGroupPhoto = true }
            } else {
                GroupFaceCluster(conv: conv, me: me)
                    // No photo yet: whoever may change it goes straight to Edit Group.
                    .onTapGesture { if canEditInfo { showEdit = true } }
            }
            headerCaption(.primary)
            actionsRow.padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }
    /// The person profile's no-photo slot (ContactInfoView, 132pt).
    private static let photoSide: CGFloat = 132

    /// Name, "N Members" and the description line, centred.
    private func headerCaption(_ ink: Color) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.title.weight(.bold)).foregroundStyle(ink)
                .lineLimit(2).multilineTextAlignment(.center)
            Text(memberCountText).font(.body).foregroundStyle(ink.opacity(0.7))
            if !desc.isEmpty {
                Text(desc).font(.subheadline).foregroundStyle(ink.opacity(0.7))
                    .lineLimit(3).multilineTextAlignment(.center)
                    .padding(.top, 2)
            } else if canEditInfo {
                // No description yet: whoever may edit is offered one, the reference app's line
                // (owner 2026-10-19). It opens Edit Group, as the Edit button does.
                Button { showEdit = true } label: {
                    // Blue, not `.tint`: the app's tint is `.primary`, which drew it black.
                    Text("Add Group Description").font(.subheadline).foregroundStyle(Color.blue)
                        .multilineTextAlignment(.center)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
    }

    private var memberCountText: String {
        let n = conv?.users.count ?? 0
        return "\(Self.compactCount(n)) Member\(n == 1 ? "" : "s")"
    }

    /// 950, 1.2k, 168k, 1.5M.
    static func compactCount(_ n: Int) -> String {
        func short(_ v: Double, _ unit: String) -> String {
            if v >= 10 { return "\(Int(v))\(unit)" }
            let tenths = Int((v * 10).rounded(.down))
            return tenths % 10 == 0 ? "\(tenths / 10)\(unit)" : "\(tenths / 10).\(tenths % 10)\(unit)"
        }
        if n < 1000 { return "\(n)" }
        if n < 1_000_000 { return short(Double(n) / 1000, "k") }
        return short(Double(n) / 1_000_000, "M")
    }

    // MARK: Actions

    /// Five equal glass circles, no labels: Add, Video, Mute, Search, More. The person profile's
    /// own circle (`PosterActionIcon`). What I may not do stays on the row, greyed, and a tap says
    /// why (owner 2026-10-19), instead of a hole in the row.
    private var actionsRow: some View {
        HStack(spacing: 0) {
            Button { addTapped() } label: { actionIcon("person.fill.badge.plus") }
                .tint(.primary)
                .opacity(canAdd ? 1 : 0.45)
                .accessibilityLabel("Add Members")
            Button { callTapped(video: true) } label: { actionIcon("video.fill") }
                .tint(.primary)
                .opacity(callReady ? 1 : 0.45)
                .accessibilityLabel("Video Call")
            Menu { muteMenuItems } label: { actionIcon(muted ? "bell.fill" : "bell.slash.fill") }
                .tint(.primary)
                .accessibilityLabel(muted ? "Unmute" : "Mute")
            Button { onSearch?() } label: { actionIcon("magnifyingglass") }
                .tint(.primary)
                .disabled(onSearch == nil)
                .opacity(onSearch == nil ? 0.45 : 1)
                .accessibilityLabel("Search")
            Menu { moreMenuItems } label: { actionIcon("ellipsis") }
                .tint(.primary)
                .accessibilityLabel("More")
        }
    }

    /// The person profile's circle at its own size (owner 2026-10-19: "exactly match the User
    /// Profile").
    private func actionIcon(_ name: String) -> some View {
        PosterActionIcon(icon: name, onPhoto: false)
    }

    private func addTapped() {
        if canAdd { showAdd = true } else { flashNotice("Only admins can add members") }
    }

    private var mayCall: Bool { CallFeatures.groupCalls && (conv?.canStartCall(me) ?? false) }
    private var callReady: Bool { mayCall && !busyElsewhere }

    /// On a 1:1 call, or on another group's call. This group's own running call is not "busy":
    /// the tile joins it.
    private var busyElsewhere: Bool {
        let s = CallService.shared.state
        if s == .outgoing || s == .incoming || s == .active || s == .reconnecting { return true }
        if let other = GroupCallService.shared.activeCid, other != cid { return true }
        return false
    }

    // ⛔ THE CALL BUTTON STAYS, GREYED, WHEN I CANNOT START ONE (owner 2026-10-19): already on
    // another call, or the group leaves calls to admins. A tap says which.
    private func callTapped(video: Bool) {
        if !CallFeatures.groupCalls { flashNotice("Group calls are not available yet"); return }
        if busyElsewhere { flashNotice("You're already on a call"); return }
        if !mayCall { flashNotice("Only admins can start a call"); return }
        startCall(video: video)
    }

    @ViewBuilder private var muteMenuItems: some View {
        if muted {
            Section(muteUntilLabel) {
                Button("Unmute") { Task { await ChatService.setMute(cid, until: 0) } }
            }
        } else {
            Section("Mute this chat for…") {
                Button("1 hour") { setMuted(ChatService.muteUntil(1)) }
                Button("8 hours") { setMuted(ChatService.muteUntil(8)) }
                Button("1 day") { setMuted(ChatService.muteUntil(24)) }
                Button("1 week") { setMuted(ChatService.muteUntil(168)) }
                Button("Always") { setMuted(ChatService.muteUntil(nil)) }
            }
        }
    }

    private func setMuted(_ until: Double) { Task { await ChatService.setMute(cid, until: until) } }

    private var muteUntilLabel: String {
        let secs = (conv?.mutedBy[me] ?? 0) / 1000
        if secs > Date().addingTimeInterval(3600 * 24 * 365 * 5).timeIntervalSince1970 { return "Muted always" }
        let date = Date(timeIntervalSince1970: secs)
        let t = Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
        return "Muted until \(t)"
    }

    // MARK: The ••• menu

    /// Everything the mockup leaves off the page, in the system menu: the group, its members, its
    /// media and data, then Clear and the red exits last. Each piece is its own small builder so
    /// the menu never becomes one long expression for the type checker.
    @ViewBuilder private var moreMenuItems: some View {
        menuGroupItems
        menuMemberItems
        menuMediaItems
        menuChatItems
    }

    @ViewBuilder private var menuGroupItems: some View {
        Section {
            // Edit Group is the bar's Edit button now (owner 2026-10-19).
            if canEditInfo {
                // The description is edited on Edit Group with the bio's rules (2026-10-18).
                Button { showEdit = true } label: {
                    Label(desc.isEmpty ? "Add Group Description" : "Edit Description", systemImage: "text.alignleft")
                }
                // The group's wallpaper is everyone's, so only someone who may change group info
                // (owner 2026-10-18; firestore.rules says the same).
                Button { changeWallpaper() } label: {
                    Label { Text("Change Wallpaper") } icon: { MenuIcon("ic_wallpaper") }
                }
            }
            if CallFeatures.groupCalls {
                Button { callTapped(video: false) } label: { Label("Voice Call", systemImage: "phone") }
            }
            // Admins send the link straight away; a member gets the link's own page (owner 2026-10-19).
            if let link = inviteLink {
                Button {
                    if can(.inviteUsers) { shareGroupText = link } else { showMemberLink = true }
                } label: { Label("Share Group", systemImage: "square.and.arrow.up") }
                Button { showQR = true } label: {
                    Label { Text("QR Code") } icon: { MenuIcon("ic_qr") }
                }
            }
        }
    }

    @ViewBuilder private var menuMemberItems: some View {
        Section {
            if canAdd {
                Button { showAdd = true } label: { Label("Add Members", systemImage: "person.badge.plus") }
            }
            // Member Labels show on the rows of this list (`GroupMemberRow`).
            Button { showAllMembers = true } label: { Label("Members", systemImage: "person.2") }
            // Who joined, left, was removed or changed admin, newest first (owner 2026-10-18).
            Button { showMemberChanges = true } label: {
                Label("View Member Changes", systemImage: "clock.arrow.circlepath")
            }
        }
    }

    @ViewBuilder private var menuMediaItems: some View {
        Section {
            Button { showAllMedia = true } label: {
                Label(galleryCount.map { "Media, Links and Files (\($0))" } ?? "Media, Links and Files",
                      systemImage: "photo.on.rectangle")
            }
            // The chat's storage item by item (owner 2026-10-19), not one clear-all.
            Button { showStorage = true } label: {
                Label(storage.map { "Storage Used (\(Self.bytes($0.total)))" } ?? "Storage Used",
                      systemImage: "internaldrive")
            }
            // This phone only (2026-10-18): follows Settings > Chats, or overrides it for this chat.
            Menu {
                Picker("Save to Photos", selection: Binding(get: { saveChoice }, set: { pickSaveChoice($0) })) {
                    ForEach(AutoSaveToPhotos.ChatChoice.allCases, id: \.self) { c in Text(c.label).tag(c) }
                }
            } label: {
                Label("Save to Photos: \(saveChoice.label)", systemImage: "square.and.arrow.down")
            }
            Button { showEncryption = true } label: {
                Label { Text("Encryption") } icon: { MenuIcon("ic_privacy") }
            }
        }
    }

    @ViewBuilder private var menuChatItems: some View {
        Section {
            Button { exportChat() } label: { Label("Export Chat", systemImage: "square.and.arrow.up.on.square") }
                .disabled(exporting)
            Button { showSimilar = true } label: { Label("Create a Similar Group", systemImage: "person.3") }
            Button { confirmClear = true } label: { Label("Clear Chat", systemImage: "eraser") }
        }
    }

    /// Report, Leave and Delete as red rows at the foot of the page, out of the ••• menu (owner
    /// 2026-10-19).
    private var exitCard: some View {
        VStack(spacing: 0) {
            ProfileInfoRow(title: "Report Group", icon: "ic_report", tint: .red, chevron: false) { confirmReport = true }
            rowDivider
            ProfileInfoRow(title: "Leave Group", icon: "rectangle.portrait.and.arrow.right",
                           tint: .red, chevron: false) { confirmLeave = true }
            // Only the owner can permanently delete the whole group (for everyone).
            if iAmOwner {
                rowDivider
                ProfileInfoRow(title: "Delete Group", icon: "trash", tint: .red, chevron: false) { confirmDelete = true }
            }
        }
        .profileSurface(plain: cardColor)
    }

    private func startCall(video: Bool) {
        Task { await GroupCallService.shared.start(cid: cid, title: title, video: video) }
        InstantCover.run { showCall = true }   // a cut, not a slide (owner, 2026-10-06)
    }

    /// Back to the chat, then its wallpaper picker (the profile's own route).
    private func changeWallpaper() {
        let target = cid
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NotificationCenter.default.post(name: .openChatWallpaper, object: target)
        }
    }

    // MARK: Export, Create Similar

    private func exportChat() {
        exporting = true
        let t = title
        Task {
            defer { exporting = false }
            do { exportFile = ExportFile(url: try await DataExport.groupChatExport(cid: cid, title: t)) }
            catch { exportError = error.localizedDescription }
        }
    }

    /// The group's members, me left out, in the page's order, for New Group's ticks.
    private var similarPeople: [NewGroupView.Person] {
        GroupMembers.sorted(conv, me: me).filter { $0 != me }.map {
            NewGroupView.Person(id: $0, name: conv?.names[$0] ?? "User", photo: conv?.photos[$0])
        }
    }

    /// The new group opens the way a notification's chat does, once the sheet has gone.
    private func openCreatedGroup(_ t: ChatTarget) {
        showSimilar = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            let router = AppRouter.shared
            router.pendingChatName = t.name
            router.pendingChatPhoto = t.photo
            router.pendingChatId = t.id
        }
    }

    // MARK: Cards

    private var desc: String { conv?.groupDescription ?? "" }

    /// The mockup's three rows. Each keeps its old gate: a member's tap on what only an admin may
    /// change says so instead of doing nothing (owner 2026-10-19).
    private var settingsCard: some View {
        VStack(spacing: 0) {
            ProfileInfoRow(title: "Disappearing Messages", icon: "ic_disappearing", value: disappearLabel) {
                if can(.changeInfo) { showDisappear = true } else { flashNotice("Only admins can change this") }
            }
            rowDivider
            ProfileInfoRow(title: "Sounds & Notifications", icon: "ic_notifications",
                           value: muted ? "Off" : "On") { showSounds = true }
            rowDivider
            ProfileInfoRow(title: "Group invite link", icon: "link",
                           value: (conv?.inviteCode ?? "").isEmpty ? "Off" : "On") { inviteRowTapped() }
        }
        .profileSurface(plain: cardColor)
    }

    /// Invite links are an admin right (fix-all #226): that admin manages them; a member who may
    /// share gets the link's own page; anyone else is told why.
    private func inviteRowTapped() {
        if can(.inviteUsers) { showInvite = true }
        else if inviteLink != nil { showMemberLink = true }
        else { flashNotice("Only admins can manage the invite link") }
    }

    private var groupSettingsCard: some View {
        ProfileInfoRow(title: "Group Settings", icon: "gearshape") { showSettings = true }
            .profileSurface(plain: cardColor)
    }

    /// The person profile's flat card colour and separator (ContactInfoView `cardColor`,
    /// `rowDivider`): on a tinted page the palette's own line, else the system one.
    private var cardColor: Color { Color(uiColor: .secondarySystemGroupedBackground) }
    @ViewBuilder private var rowDivider: some View {
        if let palette {
            Color(uiColor: palette.separator).frame(height: 0.5).padding(.leading, 56)
        } else {
            Divider().padding(.leading, 56)
        }
    }

    private var disappearLabel: String {
        let s = conv?.disappearSeconds ?? 0
        return s == 0 ? "Off" : ChatService.disappearShortLabel(s)
    }

    // MARK: Members

    /// The reference app's members section (owner's mockup 2026-10-19): "N Members" over the card
    /// with a search button, then Add Members, then the members. The search and See All open the
    /// full list; a row is that member's card.
    private var membersSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            membersHeader
            membersCard
        }
    }

    /// The reference's section header: headline, secondary grey, 16pt in, the search glyph in the
    /// same grey at the trailing edge.
    private var membersHeader: some View {
        HStack(spacing: 0) {
            Text(membersTitle).font(.headline).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button { showAllMembers = true } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 19))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search members")
        }
        .padding(.leading, 16)
    }

    private var membersTitle: String {
        let n = conv?.users.count ?? 0
        return "\(n) Member\(n == 1 ? "" : "s")"
    }

    /// The reference shows six members; past six, the first five and See All.
    private static let membersShown = 6
    private var hasMoreMembers: Bool { (conv?.users.count ?? 0) > Self.membersShown }
    private var shownMembers: [String] {
        let all = GroupMembers.sorted(conv, me: me)
        return hasMoreMembers ? Array(all.prefix(Self.membersShown - 1)) : all
    }

    private var membersCard: some View {
        VStack(spacing: 0) {
            if canAdd {
                MemberCircleRow(icon: "plus", title: "Add Members") { showAdd = true }
                memberDivider
            }
            ForEach(Array(shownMembers.enumerated()), id: \.element) { i, uid in
                if i > 0 { memberDivider }
                GroupInfoMemberRow(conv: conv, uid: uid, me: me) { openMember(uid) }
            }
            if hasMoreMembers {
                memberDivider
                MemberCircleRow(icon: "chevron.down", title: "See All") { showAllMembers = true }
            }
        }
        .profileSurface(plain: cardColor)
    }

    /// The reference's separator starts at the text: 16 in + the 36pt photo + 12.
    private var memberDivider: some View { Divider().padding(.leading, 64) }

    private func openMember(_ uid: String) {
        memberAction = MemberAction(id: uid, name: conv?.names[uid] ?? "User",
                                    isAdmin: conv?.isAdmin(uid) ?? false)
    }

    /// "All Members" and See All over a loose cloud of up to eleven faces, the biggest in the
    /// middle. The whole card is one button to the full, searchable list (owner 2026-10-19: a face
    /// does NOT open that member's card). Shown only where the admin panel turns it on
    /// (`Flags.memberCloud`).
    private var memberCloudCard: some View {
        Button { showAllMembers = true } label: {
            VStack(alignment: .leading, spacing: 4) {
                memberCloudHeader
                MemberBubbleCloud(conv: conv, ids: Array(GroupMembers.sorted(conv, me: me).prefix(MemberBubbleCloud.capacity)))
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .profileSurface(plain: cardColor)
        .accessibilityLabel("All Members, See All")
    }

    private var memberCloudHeader: some View {
        HStack(spacing: 8) {
            Text("All Members").font(.headline).foregroundStyle(.primary)
            Spacer(minLength: 8)
            HStack(spacing: 3) {
                Text("See All").font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, ProfileMediaCard.inset)
        .padding(.top, ProfileMediaCard.inset)
    }

    private func memberSheet(_ m: MemberAction) -> some View {
        GroupMemberSheet.make(cid: cid, conv: conv, me: me, uid: m.id,
                              onInfo: { uid in profileOf = MemberAction(id: uid, name: conv?.names[uid] ?? "User", isAdmin: false) })
            .presentationDetents([.large])
    }

    // MARK: Media figures

    static func bytes(_ n: Int) -> String {
        n == 0 ? "None" : ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    /// The gallery's own list (memory, then its disk copy, else one read that also warms the gallery)
    /// gives the count; that list plus the open chat's cached messages give the storage.
    @MainActor private func loadMediaFigures() async {
        var all = GalleryCache.seed(cid)
        if all == nil, let fetched = await ChatService.galleryContent(cid) {
            let shown = fetched.filter { !HiddenMessages.isHidden($0.id) }
            GalleryCache.store[cid] = shown
            all = shown
        }
        if let all { galleryCount = MediaGalleryView.itemCount(all, cid: cid) }
        var byId: [String: Message] = [:]
        for m in (all ?? []) + (ThreadMessageCache.shared.messages(for: cid) ?? []) { byId[m.id] = m }
        let msgs = Array(byId.values)
        storageMessages = msgs
        storage = await Task.detached(priority: .utility) { ChatMediaStorage.measure(msgs) }.value
    }

    private func clearStorage() {
        let msgs = storageMessages
        ChatMediaStorage.clearCache(msgs)
        // The cache deletes are queued on its own disk queue; measure after they have run.
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            storage = await Task.detached(priority: .utility) { ChatMediaStorage.measure(msgs) }.value
        }
    }

    // MARK: Save to Photos

    /// Always asks for Photos access on the tap, as the Settings switch does (a refusal from a
    /// background save would otherwise leave "Always" showing while nothing is saved).
    private func pickSaveChoice(_ c: AutoSaveToPhotos.ChatChoice) {
        AutoSaveToPhotos.setChoice(c, for: cid)
        saveChoice = c
        guard c == .always else { return }
        Task { @MainActor in
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status != .authorized, status != .limited else { return }
            AutoSaveToPhotos.setChoice(.standard, for: cid)
            saveChoice = .standard
            photosDenied = true
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        // The bar sits above the viewer overlay and eats its touches, so the viewer's X is a bar
        // item, wired through closeSignal (ContactInfoView's rule). Otherwise the system's own
        // glass back button is the only thing up there (the mockup).
        if showGroupPhoto {
            ToolbarItem(placement: .topBarLeading) {
                Button { photoCloseTick &+= 1 } label: {
                    Image(systemName: "xmark").font(.system(size: 17, weight: .semibold))
                }
                .tint(.primary)
            }
        } else if canEditInfo {
            // Edit Group, top right (owner 2026-10-19).
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { showEdit = true }
            }
        }
    }
}

/// The header photo's drawn rect, held outside SwiftUI's observation (see `artRect`).
final class GroupArtRect { var rect: CGRect = .zero }

// MARK: - Faces

/// One member's face: their photo, or their initial on their own colour pair
/// (`AvatarPalette.gradient(for:)`, the person profile's letter colours).
struct GroupFace: View {
    let name: String
    let photo: String?
    let size: CGFloat

    var body: some View {
        if ProfilePhotoIndex.hasPicture(photo) {
            AvatarView(name: name, photoUrl: photo, size: size)
        } else {
            Circle()
                .fill(LinearGradient(colors: AvatarPalette.gradient(for: name),
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: size, height: size)
                .overlay {
                    Text(initial).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white)
                }
        }
    }

    private var initial: String {
        name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
    }
}

/// A group with no photo (owner's mockup 2026-10-19): a ~200pt glass disc, a little lighter than
/// the page, holding three members of different sizes that overlap: a large face top-left, a
/// medium one bottom-right, a small one bottom-centre. Faces with photos take the big places.
private struct GroupFaceCluster: View {
    let conv: Conversation?
    let me: String

    /// The round group photo's size (`GroupInfoView.photoSide`), so a group with no photo and one
    /// with a photo show the same circle (owner 2026-10-19; it was 200).
    static let side: CGFloat = 132
    /// Offset from the disc's centre and diameter, largest first: the 200pt layout, scaled.
    private static let slots: [(x: CGFloat, y: CGFloat, d: CGFloat)] = {
        let k: CGFloat = side / 200
        let base: [(CGFloat, CGFloat, CGFloat)] = [(-26, -26, 104), (40, 30, 72), (-6, 56, 50)]
        return base.map { (x: $0.0 * k, y: $0.1 * k, d: $0.2 * k) }
    }()

    private var picks: [String] {
        let everyone = GroupMembers.sorted(conv, me: me)
        let others = everyone.filter { $0 != me }
        let pool = others.isEmpty ? everyone : others
        let withPhoto = pool.filter { ProfilePhotoIndex.hasPicture(conv?.photos[$0]) }
        let without = pool.filter { !ProfilePhotoIndex.hasPicture(conv?.photos[$0]) }
        return Array((withPhoto + without).prefix(Self.slots.count))
    }

    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.06))
                .liquidGlass(Circle())
            ForEach(Array(picks.enumerated()), id: \.element) { i, uid in
                face(i, uid)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .contentShape(Circle())
    }

    /// The smaller faces carry a thin ring of the page so an overlap reads as one face in front.
    private func face(_ i: Int, _ uid: String) -> some View {
        let s = Self.slots[i]
        return GroupFace(name: conv?.names[uid] ?? "User", photo: conv?.photos[uid], size: s.d)
            .overlay { Circle().stroke(Color(uiColor: .systemGroupedBackground), lineWidth: i == 0 ? 0 : 3) }
            .offset(x: s.x, y: s.y)
    }
}

/// All Members as a loose cloud (owner's mockup 2026-10-19): two rows of faces of different sizes,
/// the biggest in the middle, smaller ones toward the edges. Fixed spots as shares of the card's
/// width, so it reads organic on every phone and never overlaps. Faces are not buttons: the card
/// around the cloud is.
private struct MemberBubbleCloud: View {
    let conv: Conversation?
    let ids: [String]

    static let height: CGFloat = 160
    /// x as a share of the width, y as a share of the height, diameter; the first member (me, then
    /// the admins) takes the middle.
    private static let slots: [(x: CGFloat, y: CGFloat, d: CGFloat)] = [
        (0.50, 0.50, 70), (0.30, 0.33, 54), (0.70, 0.35, 56), (0.32, 0.75, 46),
        (0.68, 0.74, 48), (0.12, 0.30, 40), (0.88, 0.30, 42), (0.14, 0.72, 36),
        (0.86, 0.72, 38), (0.50, 0.09, 28), (0.50, 0.91, 28),
    ]
    static var capacity: Int { slots.count }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(Array(ids.prefix(Self.slots.count).enumerated()), id: \.element) { i, uid in
                    bubble(i, uid, width: geo.size.width)
                }
            }
            .frame(width: geo.size.width, height: Self.height)
        }
        .frame(height: Self.height)
    }

    private func bubble(_ i: Int, _ uid: String, width: CGFloat) -> some View {
        let s = Self.slots[i]
        return GroupFace(name: conv?.names[uid] ?? "User", photo: conv?.photos[uid], size: s.d)
            .position(x: s.x * width, y: s.y * Self.height)
            .accessibilityHidden(true)
    }
}

/// One member on the group page, the reference app's contact cell (owner's mockup 2026-10-19):
/// 36pt photo, 12 to the text, the name in the body style with their Role under it as a tinted
/// pill, Owner / Admin in grey at the end, 7 above and below. The trailing word stays beside a
/// Role here: that is the reference look the owner asked for.
private struct GroupInfoMemberRow: View {
    let conv: Conversation?
    let uid: String
    let me: String
    let onTap: () -> Void

    private var name: String { uid == me ? "You" : (conv?.names[uid] ?? "User") }
    private var rank: String? {
        if let c = conv, !c.createdBy.isEmpty, c.createdBy == uid { return "Owner" }
        return (conv?.isAdmin(uid) ?? false) ? "Admin" : nil
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                AvatarView(name: name, photoUrl: conv?.photos[uid], size: 36)
                nameStack
                Spacer(minLength: 8)
                if let rank {
                    Text(rank).font(.subheadline).foregroundStyle(MemberCircleRow.accessoryGrey)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var nameStack: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(name).font(.body).foregroundStyle(.primary).lineLimit(1)
                VerifiedMark(uid: uid, size: 13)
            }
            if let role = conv?.roles[uid] { MemberLabelPill(role: role, uid: uid) }
        }
    }
}

/// A member's Role as the reference draws its member label off a bubble: caption text in the
/// member's name colour (the chat's sender colour), on a capsule of that colour at 14% (32% at
/// night), 8 either side and 1 above and below.
private struct MemberLabelPill: View {
    let role: GroupRole
    let uid: String
    @Environment(\.colorScheme) private var scheme

    private var tint: Color { Color(uiColor: BubblePalette.senderColor(uid)) }

    var body: some View {
        Text(role.display)
            .font(.caption)
            .lineLimit(1)
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 1)
            .background(Capsule().fill(tint.opacity(scheme == .dark ? 0.32 : 0.14)))
    }
}

/// Add Members and See All: a glyph in a pale circle the size of a member's photo, then the title.
private struct MemberCircleRow: View {
    let icon: String
    let title: String
    let onTap: () -> Void

    /// The reference's circle fill (its gray02 by day, gray65 at night).
    static let circleFill = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark ? UIColor(white: 0x4A / 255.0, alpha: 1) : UIColor(white: 0xF6 / 255.0, alpha: 1)
    })
    /// The reference's trailing-label grey (gray45 by day, gray25 at night).
    static let accessoryGrey = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark ? UIColor(white: 0xB9 / 255.0, alpha: 1) : UIColor(white: 0x84 / 255.0, alpha: 1)
    })

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                glyph
                Text(title).font(.body).foregroundStyle(.primary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A bold glyph in the reference's 20pt box, centred in the 36pt circle.
    private var glyph: some View {
        Image(systemName: icon)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.primary)
            .frame(width: 20, height: 20)
            .frame(width: 36, height: 36)
            .background(Circle().fill(Self.circleFill))
    }
}

/// The upgrade's questions (2026-10-18): Photos access refused for Save to Photos, an export that
/// failed, and clearing this chat's cached media.
private struct GroupInfoUpgradeDialogs: ViewModifier {
    @Binding var photosDenied: Bool
    @Binding var exportError: String?
    let storage: ChatMediaStorage.Usage?
    @Binding var confirmClearStorage: Bool
    let onClearStorage: () -> Void

    func body(content: Content) -> some View {
        content
            .alert("Photos access is off", isPresented: $photosDenied) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Allow Fariin to add to your Photos in the iPhone Settings app, then choose Always again.")
            }
            .alert("Could not export this chat", isPresented: Binding(
                get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(exportError ?? "") }
            .alert("Clear cached media?", isPresented: $confirmClearStorage) {
                Button("Cancel", role: .cancel) {}
                Button("Clear", role: .destructive) { onClearStorage() }
            } message: {
                Text("This frees \(GroupInfoView.bytes(storage?.clearable ?? 0)) of copies that download again when you open them. No messages are deleted, and photos, videos and voice messages kept only on this phone stay.")
            }
    }
}

/// The group's members in the order every list shows them: me, then admins, then by name.
enum GroupMembers {
    static func sorted(_ conv: Conversation?, me: String) -> [String] {
        (conv?.users ?? []).sorted { a, b in
            if a == me { return true }
            if b == me { return false }
            let aAdmin = conv?.isAdmin(a) ?? false, bAdmin = conv?.isAdmin(b) ?? false
            if aAdmin != bAdmin { return aAdmin }
            return (conv?.names[a] ?? "").lowercased() < (conv?.names[b] ?? "").lowercased()
        }
    }
}

/// One member: photo, name, their Role under it, and Owner / Admin on the right.
struct GroupMemberRow: View {
    let conv: Conversation?
    let uid: String
    let me: String
    let onTap: () -> Void

    private var name: String { uid == me ? "You" : (conv?.names[uid] ?? "User") }
    private var rank: String? {
        if let c = conv, !c.createdBy.isEmpty, c.createdBy == uid { return "Owner" }
        return (conv?.isAdmin(uid) ?? false) ? "Admin" : nil
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                AvatarView(name: name, photoUrl: conv?.photos[uid], size: 40)
                // The Role sits on the name's line, right of it (owner 2026-10-18: "not under the
                // name"). The name gives way first, so a long one truncates before the chip does.
                HStack(spacing: 6) {
                    Text(name).foregroundStyle(.primary).lineLimit(1)
                    VerifiedMark(uid: uid, size: 13)
                    if let role = conv?.roles[uid] { RoleChip(role: role).layoutPriority(1) }
                }
                Spacer(minLength: 8)
                // Owner / Admin at the reference app's size for this label (owner 2026-10-18): the
                // subheadline style (15pt), secondary grey, not the 17pt the name uses.
                // One label only (owner 2026-10-19): a Role stands in for Owner / Admin.
                if let rank, conv?.roles[uid] == nil { Text(rank).font(.subheadline).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A member's Role (owner 2026-10-18): one line in the accent colour on a pale capsule, the emoji
/// in front when there is one.
struct RoleChip: View {
    let role: GroupRole
    var body: some View {
        Text(role.display)
            .font(.subheadline)
            .lineLimit(1)
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
    }
}

/// The description editor and the disappearing timer, as the page always asked them.
private struct GroupInfoDialogs: ViewModifier {
    let cid: String
    /// The group's timer now, for the page's tick.
    let current: Int
    @Binding var showDescEdit: Bool
    @Binding var descText: String
    @Binding var showDisappear: Bool
    @Binding var pendingDisappear: Int?

    func body(content: Content) -> some View {
        content
            .alert("Group description", isPresented: $showDescEdit) {
                TextField("Description", text: $descText)
                Button("Save") { let t = descText; Task { try? await ChatService.setGroupDescription(cid: cid, text: t) } }
                Button("Cancel", role: .cancel) {}
            }
            // ⛔ THE ONE-TO-ONE CHAT'S PAGE (owner 2026-10-18: "open the page exactly like a normal user's,
            // with all its features"): every preset and Custom, not a three-line menu. Off applies at
            // once; turning it ON still asks first, because in a group it deletes for every member.
            .sheet(isPresented: $showDisappear) {
                DisappearingMessagesView(cid: cid, current: current) { s in
                    if s == 0 { Task { await ChatService.setDisappear(cid, seconds: 0) } }
                    else if s != current {
                        // After the page has gone, so the question is not asked under a closing sheet.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { pendingDisappear = s }
                    }
                }
            }
            .alert("Turn on disappearing messages?", isPresented: Binding(
                get: { pendingDisappear != nil },
                set: { if !$0 { pendingDisappear = nil } }
            )) {
                Button("Cancel", role: .cancel) { pendingDisappear = nil }
                Button("Turn On") {
                    if let s = pendingDisappear { Task { await ChatService.setDisappear(cid, seconds: s) } }
                    pendingDisappear = nil
                }
            } message: {
                Text("New messages in this group will be deleted for ALL members after \(ChatService.disappearLabel(pendingDisappear ?? 86_400)). Everyone will see that you turned this on.")
            }
    }
}

/// Clear, Leave, Report and Delete, each asked first, as the page always asked them.
private struct GroupInfoExits: ViewModifier {
    let cid: String
    let conv: Conversation?
    let me: String
    @Binding var confirmLeave: Bool
    @Binding var confirmClear: Bool
    @Binding var confirmReport: Bool
    @Binding var confirmDelete: Bool
    @Binding var actionError: String?
    let onGone: () -> Void

    /// Close only on success (audit, 2026-09-24): a refused leave or delete was swallowed by `try?`
    /// and the page closed anyway.
    private func run(_ op: @escaping () async throws -> Void) {
        Task {
            do {
                try await op()
                await MainActor.run { onGone() }
            } catch {
                let msg = error.localizedDescription
                await MainActor.run { actionError = msg }
            }
        }
    }

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Clear this chat?", isPresented: $confirmClear, titleVisibility: .visible) {
                // Local clear (hides history for ME only) — NOT a global delete of my messages.
                Button("Clear Chat", role: .destructive) { Task { await ChatService.deleteForMe(cid) } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This clears the chat from your device only.") }
            // owner 2026-10-18: Leave, Report and Delete ask in Apple's centred alert, not a sheet.
            .alert("Leave Group?", isPresented: $confirmLeave) {
                Button("Cancel", role: .cancel) {}
                Button("Leave", role: .destructive) { run { try await ChatService.leaveGroup(cid: cid) } }
            } message: { Text("You won't get messages from this group any more.") }
            .alert("Report Group?", isPresented: $confirmReport) {
                Button("Report", role: .destructive) {
                    // admins.first can be ME (self-report) — pick another admin, else the creator, else any other member.
                    let creator = conv?.createdBy
                    let target = conv?.admins.first(where: { $0 != me })
                        ?? ((creator?.isEmpty == false && creator != me) ? creator : nil)
                        ?? conv?.users.first(where: { $0 != me })
                        ?? ""
                    Task { await ChatService.report(reportedUid: target, cid: cid, reason: "group") }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("The group will be reported to moderators for review.") }
            .alert("Delete Group?", isPresented: $confirmDelete) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { run { try await GroupInviteService.deleteGroup(cid: cid) } }
            } message: { Text("This permanently deletes the group and all its messages for everyone. This cannot be undone.") }
            .alert("Could not do that", isPresented: Binding(get: { actionError != nil },
                                                              set: { if !$0 { actionError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(actionError ?? "") }
    }
}

// Multi-select sheet to add 1:1 contacts who aren't already in the group.
struct AddMembersSheet: View {
    let cid: String
    let existing: Set<String>
    init(cid: String, existing: Set<String>) { self.cid = cid; self.existing = existing }
    @Environment(\.dismiss) private var dismiss
    private var convRepo = ConversationsRepository.shared
    private var me: String { AuthService.shared.uid ?? "" }
    @State private var selected = Set<String>()
    @State private var query = ""
    @State private var results: [UserProfile] = []
    @State private var adding = false
    @State private var errorText: String?
    @State private var noticeText: String?

    private var candidates: [(id: String, name: String, photo: String?)] {
        convRepo.conversations
            // No demo chats (audit, 2026-09-24): same leak as New Group, a made-up person added
            // into a real group's `users`.
            .filter { !$0.isGroup && !$0.isCleared(me) && !DemoMode.isDemoConversation($0.id) }
            .compactMap { c in
                let u = c.otherUid(me)
                guard !u.isEmpty, !existing.contains(u) else { return nil }
                return (u, c.name(for: me), c.photoUrl(for: me))
            }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Everyone this sheet has shown, for the chips of those picked (a search result stays named
    /// after the search changes).
    @State private var known: [String: (name: String, photo: String?)] = [:]

    /// Your chats, A to Z, as Select Members groups them.
    private var lettered: [(letter: String, people: [(id: String, name: String, photo: String?)])] {
        let groups = Dictionary(grouping: candidates) { p -> String in
            let f = p.name.trimmingCharacters(in: .whitespaces).uppercased().first
            return f.map { $0.isLetter ? String($0) : "#" } ?? "#"
        }
        return groups.keys.sorted { $0 == "#" ? false : ($1 == "#" ? true : $0 < $1) }
            .map { ($0, groups[$0] ?? []) }
    }

    /// ⛔ SELECT MEMBERS' PAGE, EXACTLY (owner 2026-10-18: "make it look exactly like the select members
    /// page"): the picked people as chips on top, A to Z under it, results while searching, the
    /// Forward page's rows, X on the left and a blue Add with its spinner inside.
    var body: some View {
        NavigationStack {
            List {
                if !selected.isEmpty {
                    Section("Adding · \(selected.count)") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(Array(selected).sorted(), id: \.self) { id in
                                    let p = known[id]
                                    Button { toggle(id) } label: {
                                        VStack(spacing: 4) {
                                            ZStack(alignment: .topTrailing) {
                                                AvatarView(name: p?.name ?? "", photoUrl: p?.photo, size: 52)
                                                Image(systemName: "xmark.circle.fill")
                                                    .font(.system(size: 18))
                                                    .symbolRenderingMode(.palette)
                                                    .foregroundStyle(.white, .gray)
                                                    .offset(x: 4, y: -4)
                                            }
                                            Text(p?.name ?? "").font(.caption2).lineLimit(1).frame(width: 56)
                                                .foregroundStyle(.primary)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                if query.isEmpty {
                    if candidates.isEmpty {
                        Section {
                            Text("Search by name or username to add anyone.").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(lettered, id: \.letter) { group in
                        Section(group.letter) {
                            ForEach(group.people, id: \.id) { p in memberPickRow(p.id, p.name, p.photo) }
                        }
                    }
                } else {
                    Section("Results") {
                        let found = results.filter { $0.id != me && !existing.contains($0.id) }
                        if found.isEmpty { Text("No one found").foregroundStyle(.secondary) }
                        ForEach(found) { p in
                            memberPickRow(p.id, p.name.isEmpty ? p.handle : p.name, p.photoUrl)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: "Name or username")
            .onChange(of: query) { _, q in search(q) }
            .navigationTitle("Add Members")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Couldn't add members", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
            .alert("Members added", isPresented: Binding(get: { noticeText != nil }, set: { if !$0 { noticeText = nil } })) {
                Button("OK") { dismiss() }
            } message: { Text(noticeText ?? "") }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { add() } label: {
                        if adding { ProgressView().tint(.white) } else { Text("Add").fontWeight(.semibold) }
                    }
                    .disabled(selected.isEmpty || adding)
                    .buttonStyle(.borderedProminent).tint(.blue)
                }
            }
        }
    }

    private func add() {
        let ids = Array(selected)
        adding = true
        Task {
            do {
                let keyless = try await ChatService.addGroupMembers(cid: cid, add: ids)
                await MainActor.run {
                    if keyless.isEmpty { dismiss() }
                    else {
                        noticeText = "\(keyless.joined(separator: ", ")) hasn't opened Fariin yet. They'll see messages once they do."
                        adding = false
                    }
                }
            } catch {
                let msg = error.localizedDescription
                await MainActor.run { errorText = msg; adding = false }
            }
        }
    }

    /// Select Members' row (`NewGroupView.memberRow`): the Forward page's spacing and circle.
    @ViewBuilder private func memberPickRow(_ id: String, _ name: String, _ photo: String?) -> some View {
        Button { known[id] = (name, photo); toggle(id) } label: {
            HStack(spacing: 12) {
                AvatarView(name: name, photoUrl: photo, size: 40)
                HStack(spacing: 4) {
                    Text(name).font(.system(size: 17)).foregroundStyle(.primary)
                    VerifiedMark(uid: id, size: 13)
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: selected.contains(id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(selected.contains(id) ? Color.accentColor : Color.secondary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
        .alignmentGuide(.listRowSeparatorLeading) { _ in 52 }
    }

    private func search(_ q: String) {
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { results = []; return }
        Task {
            var r = await ChatService.searchUsers(prefix: trimmed)
            if r.isEmpty, let exact = await ChatService.findByHandle(trimmed) { r = [exact] }
            await MainActor.run { results = r }
        }
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
}

// Tap a group member → see their profile (avatar, name, @handle, about) + admin actions.
struct GroupMemberSheet: View {
    let cid: String
    let member: GroupInfoView.MemberAction
    let iAmAdmin: Bool
    let ownerUid: String
    var canManageAdmins: Bool = false      // Conversation.canManageAdmin: promote/demote + set their rights
    var canRestrict: Bool = false          // I hold the Restrict-members right → can remove/mute
    var currentRights: [String]? = nil      // this admin's granted rights (nil = the defaults/legacy)
    var grantable: [String] = []            // owner 2026-10-18: the rights I may hand out (all, for the owner)
    @State private var confirmTransfer = false
    var mutedUntil: Double = 0              // ms; > now = currently restricted
    var role: GroupRole? = nil              // their Role (owner 2026-10-18), nil = none
    var canEditRole: Bool = false           // Conversation.canSetRole: admins only, never the owner's by an admin
    @Environment(\.dismiss) private var dismiss
    @State private var profile: UserProfile?
    @State private var confirmRemove = false
    @State private var rights: Set<String> = []
    @State private var rightsLoaded = false
    private var me: String { AuthService.shared.uid ?? "" }
    private var isOwner: Bool { member.id == ownerUid }
    private var iAmOwner: Bool { ownerUid == me }
    private var isMuted: Bool { mutedUntil > Date().timeIntervalSince1970 * 1000 }

    @State private var busy = false
    @State private var actionError: String?
    // 2026-09-24 fix-all #124
    @State private var showBlock = false
    @State private var showReport = false
    @State private var memberBlocked = false
    @State private var showProfileHere = false
    // ⛔ ONE PAGE (owner 2026-10-19): rights, Make Admin and the role are edited here and written
    // together by Save Changes, instead of on their own pushed pages.
    @State private var baseRights: Set<String> = []
    @State private var makeAdmin = false
    @State private var roleText = ""
    @State private var confirmDismissAdmin = false
    var onInfo: ((String) -> Void)? = nil   // push their profile on the opener's stack

    /// Every member action goes through here (audit, 2026-09-24). Each one was `try?` then dismiss:
    /// a refused Make Admin / Remove closed the sheet as if it had worked, and a second tap while the
    /// first was still waiting on the server wrote the change, and its "is now an admin" line, twice.
    private func run(_ op: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            do {
                try await op()
                await MainActor.run { busy = false; dismiss() }
            } catch {
                let msg = error.localizedDescription
                await MainActor.run { busy = false; actionError = msg }
            }
        }
    }

    private func mute(_ seconds: Double) {
        run { try await ChatService.muteMember(cid: cid, uid: member.id, name: member.name, seconds: seconds) }
    }

    /// Their audience map, applied the same way ContactInfoView applies it. Sharing a group is not
    /// the same as being a contact, so the "My Friends" test is the real message-history one.
    private var gatedMemberPhoto: String? {
        guard let p = profile else { return nil }
        return PrivacyPrefs.allows(p.privacy, "photo",
                                   contactOfMine: PrivacyPrefs.mayViewPhotoOf(member.id)) ? p.photoUrl : nil
    }
    private var gatedMemberAbout: String? {
        guard let p = profile else { return nil }
        return PrivacyPrefs.allows(p.privacy, "bio",
                                   contactOfMine: PrivacyPrefs.isContact(member.id)) ? p.about : nil
    }

    // ⛔ EVERYTHING ON ONE PAGE (owner 2026-10-19, after the reference app's admin page): the info
    // card, the rights switches (or Make Admin), Dismiss Admin, then one card of what else I may do
    // to them, and Save Changes at the foot. Nothing here pushes but Info, which opens their regular
    // profile on the group page's own stack, so Back lands on the group again. Block and Report
    // live on that profile, as for anyone else.
    private var card: Color { Color(uiColor: .secondarySystemGroupedBackground) }
    private var rowDivider: some View { Divider().padding(.leading, 56) }

    // MARK: One-page editing (owner 2026-10-19)

    /// Someone else, and not the owner: the only people this page may change.
    private var isOther: Bool { member.id != me && !isOwner }
    private var firstName: String {
        member.name.split(separator: " ").first.map(String.init) ?? member.name
    }
    /// The rights I may hand out, in the model's order (the Edit Admin Rights page's own list).
    private var shownRights: [Conversation.Right] {
        Conversation.Right.allCases.filter { grantable.contains($0.rawValue) }
    }
    /// What goes out: only rights I may grant, as AdminRightsView.save sends them.
    private var rightsList: [String] {
        Conversation.Right.allCases.map(\.rawValue).filter { rights.contains($0) && grantable.contains($0) }
    }
    private var mayEditRights: Bool { isOther && canManageAdmins }
    private var rightsChanged: Bool { mayEditRights && member.isAdmin && rights != baseRights }
    private var promoting: Bool { mayEditRights && !member.isAdmin && makeAdmin }
    private var cleanedRole: String { GroupRole.clean(roleText) }
    private var roleChanged: Bool { canEditRole && cleanedRole != (role?.text ?? "") }
    private var hasChanges: Bool { rightsChanged || promoting || roleChanged }
    /// The Save Changes button only on a page with something it could save.
    private var showsSave: Bool { mayEditRights || canEditRole }

    /// Everything changed on the page in one go: promote (with the switched-on rights) or the new
    /// rights, then the role. Same calls the old pushed pages made.
    private func saveChanges() {
        guard hasChanges else { return }
        let cid = cid, uid = member.id, name = member.name
        let list = rightsList
        let promote = promoting, newRights = rightsChanged
        let writeRole = roleChanged, roleWords = cleanedRole, roleEmoji = role?.emoji
        run {
            if promote {
                try await ChatService.promoteGroupAdmin(cid: cid, uid: uid, name: name, rights: list)
            } else if newRights {
                try await ChatService.setAdminRights(cid: cid, uid: uid, rights: list)
            }
            if writeRole {
                try await ChatService.setRole(cid: cid, uid: uid, text: roleWords, emoji: roleEmoji)
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    rightsSection
                    dismissAdminCard
                    actionsCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .safeAreaInset(edge: .bottom) { saveBar }
            .navigationTitle(isOwner || member.isAdmin ? "Admin" : "Member")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showProfileHere) {
                ContactInfoView(cid: ChatService.convId(me, member.id), name: member.name,
                                photoUrl: gatedMemberPhoto, source: .calls)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close")
                }
            }
            .task { profile = await ProfileStore.shared.fetch(member.id) }
            .onAppear {
                guard !rightsLoaded else { return }
                rightsLoaded = true
                rights = currentRights.map(Set.init) ?? Set(Conversation.Right.defaults.map(\.rawValue))
                baseRights = rights
                roleText = role?.text ?? ""
            }
            .onChange(of: roleText) { _, new in
                // Typing or pasting past the limit keeps the first 24, as RoleEditorView does.
                if new.utf16.count > GroupRole.maxText { roleText = GroupRole.fit(new, max: GroupRole.maxText) }
            }
            .confirmationDialog("Dismiss \(member.name) as admin?",
                                isPresented: $confirmDismissAdmin, titleVisibility: .visible) {
                Button("Dismiss Admin", role: .destructive) {
                    run { try await ChatService.demoteGroupAdmin(cid: cid, uid: member.id, name: member.name) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Make \(member.name) the owner?",
                                isPresented: $confirmTransfer, titleVisibility: .visible) {
                Button("Transfer Ownership", role: .destructive) {
                    run { try await ChatService.transferGroupOwnership(cid: cid, to: member.id, name: member.name) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(member.name) will have full control of this group, including over you. You will stay an admin.")
            }
            .confirmationDialog("Remove \(member.name) from the group?",
                                isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    run { try await ChatService.removeGroupMember(cid: cid, uid: member.id, name: member.name) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Could not do that", isPresented: Binding(get: { actionError != nil },
                                                              set: { if !$0 { actionError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(actionError ?? "") }
            // 2026-09-24 fix-all #124: ContactInfoView's two confirms, word for word.
            .darkAlert("Block \(member.name)?",
                       message: "Blocked users will not be able to call you or send you messages.",
                       isPresented: $showBlock,
                       actions: [
                        .cancel(),
                        .destructive("Block") { blockMember(report: false) },
                        .destructive("Block and Report") { blockMember(report: true) },
                       ])
            .darkAlert("Report \(member.name)?",
                       message: "Reported accounts are reviewed by our team. They are not told.",
                       isPresented: $showReport,
                       actions: [
                        .cancel(),
                        .destructive("Report") {
                            let other = member.id, group = cid
                            Task { await ChatService.report(reportedUid: other, cid: group, reason: "user") }
                        },
                        .destructive("Report and Block") { blockMember(report: true) },
                       ])
            .onAppear { memberBlocked = BlockList.shared.contains(member.id) }
        }
    }

    /// The info card: photo, name with a grey Owner/Admin chip, @handle and role under.
    private var header: some View {
        HStack(spacing: 14) {
            // Honor THEIR audience settings, like the 1:1 profile does (audit).
            AvatarView(name: member.name, photoUrl: gatedMemberPhoto, size: 60)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(member.name).font(.headline).lineLimit(1)
                    VerifiedMark(uid: member.id, size: 15, explains: true)
                    // One chip only (owner 2026-10-19): their role, when they have one, stands in
                    // for Owner/Admin.
                    if let role { RoleChip(role: role) } else if isOwner || member.isAdmin { adminChip }
                }
                if let h = profile?.handle, !h.isEmpty {
                    Text("@\(h)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .profileSurface(plain: card)
    }

    private var adminChip: some View {
        Text(isOwner ? "Owner" : "Admin").font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color(.systemGray5), in: Capsule())
            .foregroundStyle(.secondary)
    }

    /// A grouped-list section heading / footnote, drawn by hand over the plain cards.
    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased()).font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
    }
    private func sectionFooter(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
    }

    /// One switch per right I may hand out, the Edit Admin Rights page's list. For an admin they
    /// edit the rights; for a member they come up under Make Admin with the promote defaults.
    @ViewBuilder private var rightsSection: some View {
        if mayEditRights {
            VStack(spacing: 8) {
                if !member.isAdmin { makeAdminCard }
                if member.isAdmin || makeAdmin {
                    sectionHeader("What \(firstName) can do")
                    rightsCard
                    sectionFooter("\(firstName) can only do what is switched on here. Nobody but the owner can remove or change the owner.")
                }
            }
            .animation(.snappy(duration: 0.25), value: makeAdmin)
        }
    }

    private var makeAdminCard: some View {
        Toggle("Make Admin", isOn: $makeAdmin)
            .disabled(busy)
            .padding(.horizontal, 16).padding(.vertical, 11)
            .profileSurface(plain: card)
    }

    private var rightsCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(shownRights.enumerated()), id: \.element.id) { i, r in
                if i > 0 { Divider().padding(.leading, 16) }
                rightToggle(r)
            }
        }
        .profileSurface(plain: card)
    }

    private func rightToggle(_ r: Conversation.Right) -> some View {
        Toggle(r.label, isOn: Binding(
            get: { rights.contains(r.rawValue) },
            set: { on in if on { rights.insert(r.rawValue) } else { rights.remove(r.rawValue) } }))
            .disabled(busy)
            .padding(.horizontal, 16).padding(.vertical, 11)
    }

    /// Red Dismiss Admin on its own, as the reference app draws it.
    @ViewBuilder private var dismissAdminCard: some View {
        if mayEditRights && member.isAdmin {
            Button { confirmDismissAdmin = true } label: {
                Text("Dismiss Admin").foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .profileSurface(plain: card)
        }
    }

    /// Save Changes, pinned to the foot: the app's blue glass pill, live only once something changed.
    @ViewBuilder private var saveBar: some View {
        if showsSave {
            Button { saveChanges() } label: {
                Group {
                    if busy { ProgressView().tint(.white) } else { Text("Save Changes") }
                }
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 50)
                .liquidGlass(Capsule(), interactive: true, tint: Color(.systemBlue))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!hasChanges || busy)
            .opacity(hasChanges || busy ? 1 : 0.45)
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 8)
        }
    }

    /// The role, typed straight into the card (RoleEditorView's limits); saved by Save Changes.
    /// Their emoji, when they have one, is kept as it is.
    private var roleRow: some View {
        let left = GroupRole.maxText - roleText.utf16.count
        return HStack(spacing: 14) {
            Group {
                if let e = role?.emoji { Text(e).font(.system(size: 18)) }
                else { Image(systemName: "tag").font(.system(size: 17)) }
            }
            .frame(width: 26)
            TextField("Role, like Designer", text: $roleText)
                .submitLabel(.done)
                .disabled(busy)
            if left <= 9 {
                Text("\(left)").font(.footnote.monospacedDigit())
                    .foregroundStyle(left <= 5 ? Color.red : Color.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 18)
    }

    private var tiles: some View {
        HStack(spacing: 10) {
            GroupActionTile(icon: "message", title: "Message", cardColor: card) { openChat() }
            GroupActionTile(icon: "ic_call_voice", title: "Voice", cardColor: card) {
                CallService.shared.startCall(to: member.id, name: member.name, photo: gatedMemberPhoto,
                                             video: false, fromProfile: true)
            }
            GroupActionTile(icon: "ic_call_video", title: "Video", cardColor: card) {
                CallService.shared.startCall(to: member.id, name: member.name, photo: gatedMemberPhoto,
                                             video: true, fromProfile: true)
            }
        }
    }

    /// What I may do to them in this group, then Info, then the red one last. The owner is protected:
    /// no admin demotes or removes them. Promote/demote/rights is `canManageAdmins`; removing needs
    /// the Restrict-members right, and removing an ADMIN is the owner's alone (firestore.rules
    /// nonOwnerAdminWriteOK).
    @ViewBuilder private var actionsCard: some View {
        // Admin rights, Make Admin and Dismiss Admin sit above in their own cards (owner 2026-10-19).
        // Myself with no role to set: no card at all, not an empty one.
        if canEditRole || member.id != me { actionRows }
    }

    private var actionRows: some View {
        let other = isOther
        let canRemove = other && canRestrict && (iAmOwner || !member.isAdmin)
        let canMute = other && canRestrict && !member.isAdmin
        return VStack(spacing: 0) {
            // ⛔ ROLE — owner 2026-10-18. Given by admins only (Conversation.canSetRole).
            if canEditRole {
                roleRow
                if member.id != me { rowDivider }
            }
            if canMute {
                if isMuted {
                    ProfileInfoRow(title: "Lift Restrictions", icon: "speaker.wave.2", chevron: false) {
                        run { try await ChatService.unmuteMember(cid: cid, uid: member.id, name: member.name) }
                    }
                } else {
                    Menu {
                        Button("1 hour")  { mute(3600) }
                        Button("1 day")   { mute(86400) }
                        Button("1 week")  { mute(604800) }
                        Button("Until I lift it") { mute(0) }
                    } label: {
                        ProfileInfoRow(title: "Mute in This Group", icon: "speaker.slash", chevron: false) {}
                            .allowsHitTesting(false)
                    }
                }
                rowDivider
            }
            if other && iAmOwner {
                ProfileInfoRow(title: "Transfer Ownership", icon: "crown", chevron: false) { confirmTransfer = true }
                rowDivider
            }
            if member.id != me {
                ProfileInfoRow(title: "Info", icon: "info.circle") { openProfile() }
            }
            if canRemove {
                rowDivider
                ProfileInfoRow(title: "Remove from Group", icon: "minus.circle", tint: .red, chevron: false) {
                    confirmRemove = true
                }
            }
        }
        .profileSurface(plain: card)
    }

    private func openChat() {
        AppRouter.shared.pendingChatName = member.name
        AppRouter.shared.pendingChatPhoto = profile?.photoUrl
        AppRouter.shared.pendingChatId = ChatService.convId(me, member.id)
        // 2026-09-24 audit: create the chat the way every other entry point does.
        let other = member.id
        Task { await ChatService.openConversation(uid: other) }
        dismiss()
    }

    /// On the group page's stack when it handed us `onInfo` (Back returns to the group), else here.
    private func openProfile() {
        if let onInfo {
            let uid = member.id
            dismiss()
            onInfo(uid)
        } else {
            showProfileHere = true
        }
    }

    /// 2026-09-24 fix-all #124: flipped first, as on the profile, so an offline tap does not read dead.
    private func blockMember(report: Bool) {
        memberBlocked = true
        let other = member.id, group = cid, mine = me
        Task {
            await ChatService.setBlocked(ChatService.convId(mine, other), true)
            if report { await ChatService.report(reportedUid: other, cid: group, reason: "user") }
        }
    }
}

/// The text handed to Share Group's sheet, as an `Identifiable` for `.sheet(item:)`.
private struct ShareText: Identifiable { let id: String }

// MARK: - Members sheet (search / See All)

/// ⛔ THE MEMBERS SHEET — owner 2026-10-18, with the reference app's own: X, "Members", a sort
/// button; the members under A–Z headers with the letter index down the side; one card with Add
/// Members and Invite Via Group Link; the search bar at the bottom with the keys already up.
/// Opened by the members search button and by See All on the group page.
struct GroupMembersSheet: View {
    let cid: String
    init(cid: String) { self.cid = cid }
    @Environment(\.dismiss) private var dismiss
    private var repo = ConversationsRepository.shared
    private var me: String { AuthService.shared.uid ?? "" }
    @State private var query = ""
    /// Off at open: the keyboard comes up only when the field is tapped (owner 2026-10-19).
    @State private var searching = false
    @State private var adminsFirst = false
    @State private var opened: OpenedMember?
    @State private var showAdd = false
    @State private var showInvite = false

    private struct OpenedMember: Identifiable { let id: String }
    private var conv: Conversation? { repo.conversations.first { $0.id == cid } }
    private var canAdd: Bool { (conv?.adminCan(me, .inviteUsers) ?? false) || (conv?.membersCanAdd ?? false) }
    private var canInvite: Bool { conv?.adminCan(me, .inviteUsers) ?? false }

    private func name(_ uid: String) -> String { uid == me ? "You" : (conv?.names[uid] ?? "User") }

    /// Members matching the search, sorted by name (or admins first, then by name).
    private var members: [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = (conv?.users ?? []).filter {
            q.isEmpty || name($0).lowercased().contains(q) || (conv?.roles[$0]?.display.lowercased().contains(q) ?? false)
        }
        return all.sorted { a, b in
            if adminsFirst {
                let ra = rank(a), rb = rank(b)
                if ra != rb { return ra < rb }
            }
            return name(a).localizedCaseInsensitiveCompare(name(b)) == .orderedAscending
        }
    }
    private func rank(_ uid: String) -> Int {
        if conv?.createdBy == uid { return 0 }
        return (conv?.isAdmin(uid) ?? false) ? 1 : 2
    }
    /// The letter a name files under: A–Z, everything else "#".
    private func letter(_ uid: String) -> String {
        guard let c = name(uid).folding(options: .diacriticInsensitive, locale: .current).first,
              c.isLetter, c.isASCII else { return "#" }
        return String(c).uppercased()
    }
    private var sections: [(String, [String])] {
        if adminsFirst { return [("", members)] }
        var out: [(String, [String])] = []
        for uid in members {
            let l = letter(uid)
            if let i = out.firstIndex(where: { $0.0 == l }) { out[i].1.append(uid) } else { out.append((l, [uid])) }
        }
        return out.sorted { a, b in a.0 == "#" ? false : (b.0 == "#" ? true : a.0 < b.0) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(sections, id: \.0) { sec in
                    Section {
                        ForEach(sec.1, id: \.self) { uid in
                            GroupMemberRow(conv: conv, uid: uid, me: me) { opened = OpenedMember(id: uid) }
                                .listRowInsets(EdgeInsets())
                        }
                    } header: {
                        if !sec.0.isEmpty { Text(sec.0) }
                    }
                    .sectionIndexLabel(sec.0.isEmpty ? nil : Text(sec.0))
                }
                if query.isEmpty && (canAdd || canInvite) {
                    Section {
                        if canAdd {
                            Button { showAdd = true } label: { actionRow("plus", "Add Members") }
                        }
                        if canInvite {
                            Button { showInvite = true } label: { actionRow("link", "Invite Via Group Link") }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionIndexVisibility(.visible)
            .searchable(text: $query, isPresented: $searching, prompt: "Search")
            .navigationTitle("Members")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort", selection: $adminsFirst) {
                            Text("By Name").tag(false)
                            Text("Admins First").tag(true)
                        }
                    } label: { Image(systemName: "line.3.horizontal.decrease") }
                    .accessibilityLabel("Sort")
                }
            }
            .sheet(item: $opened) { o in
                GroupMemberSheet.make(cid: cid, conv: conv, me: me, uid: o.id)
                    .presentationDetents([.large])
            }
            .sheet(isPresented: $showAdd) { AddMembersSheet(cid: cid, existing: Set(conv?.users ?? [])) }
            .navigationDestination(isPresented: $showInvite) {
                InviteLinkSheet(cid: cid, groupTitle: conv?.title ?? "Group", groupPhoto: conv?.avatarUrl,
                                initialCode: conv?.inviteCode ?? "", embedded: true)
            }
        }
    }

    private func actionRow(_ icon: String, _ title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium)).foregroundStyle(.primary)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color(.systemGray5)))
            Text(title).foregroundStyle(.primary)
            Spacer()
        }
    }
}
