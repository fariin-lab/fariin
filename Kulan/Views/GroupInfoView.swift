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
    @State private var showAllMembers = false   // See All, under the first ten members
    @State private var showSounds = false
    @State private var showSettings = false
    @State private var showEdit = false
    @State private var showGroupPhoto = false    // tap the photo → the same morph a person's photo uses
    @State private var photoCloseTick = 0        // toolbar X → viewer close (see ProfilePhotoViewer.closeSignal)
    @State private var avatarFrame: CGRect = .zero
    @State private var memberQuery = ""
    @State private var searchingMembers = false
    // 2026-10-18 upgrade.
    @State private var marks = GroupInfoScrollMarks()
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
    private var cardColor: Color { Color(uiColor: .secondarySystemGroupedBackground) }
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
            .overlay {
                if showGroupPhoto {
                    ProfilePhotoViewer(name: title, photoUrl: conv?.avatarUrl ?? "",
                                       sourceFrame: avatarFrame, poster: false,
                                       // Whole photo, square (owner 2026-10-18), not the circle.
                                       landsSquare: true,
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

    private var page: some View {
        ScrollView {
            // ⛔ NO MEMBERS / MEDIA / SETTINGS BAR (owner 2026-10-19: "remove this, it doesn't make
            // sense"). The three sections follow each other with their own headings; a bar that
            // only scrolled to them added a row and explained nothing.
            LazyVStack(spacing: 20) {
                AnyView(topSections)
                VStack(spacing: 20) { AnyView(lowerSections) }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
    }

    @ViewBuilder private var topSections: some View {
        hero
        actionsRow
        if !desc.isEmpty { aboutCard.padding(.top, 8) }
    }

    @ViewBuilder private var lowerSections: some View {
        // Each anchor rides on top of its section with no gap of its own (the stack's spacing would
        // otherwise add one per anchor).
        VStack(spacing: 0) { GroupSectionAnchor(section: .members, marks: marks); membersBlock }
        VStack(spacing: 0) { GroupSectionAnchor(section: .media, marks: marks); mediaBlock }
        VStack(spacing: 0) { GroupSectionAnchor(section: .settings, marks: marks); settingsCard }
        dangerCard.padding(.top, 8)
        if let label = createdByLabel {
            Text(label).font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).multilineTextAlignment(.center)
        }
    }

    // MARK: Header

    /// The profile's round header (`ContactInfoView.hero`'s numbers): the 120pt circle, the name,
    /// and the member count where a person's @handle sits.
    private var hero: some View {
        VStack(spacing: 6) {
            AvatarView(name: title, photoUrl: conv?.avatarUrl, size: 120)
                .opacity(showGroupPhoto ? 0 : 1)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { avatarFrame = $0 }
                .contentShape(Circle())
                .onTapGesture {
                    if ProfilePhotoIndex.hasPicture(conv?.avatarUrl) { showGroupPhoto = true }
                }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.title.weight(.bold))
                    .lineLimit(2).multilineTextAlignment(.center)
                // owner 2026-10-18: a small pencil beside the name for whoever may change it.
                if canEditInfo {
                    Button { showEdit = true } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Edit name and picture")
                }
            }
            Text(conv?.memberCountLabel ?? " ")
                .font(.body).foregroundStyle(.secondary)
                .frame(minHeight: 22)
            // No empty About card any more (owner 2026-10-18): a small link here, only for whoever
            // may write the description.
            if desc.isEmpty && canEditInfo {
                Button { showEdit = true } label: {
                    Text("Add group description").font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    /// The labelled tiles (owner 2026-10-18): Call and Video when group calls are on and I may start
    /// one, Share while the group has a link (else Add for whoever may add), Search. Mute and the
    /// rest are in the ••• menu of the top bar.
    private var actionsRow: some View {
        HStack(spacing: 10) {
            if mayCall {
                GroupActionTile(icon: "ic_call_voice", title: "Call", cardColor: cardColor) { startCall(video: false) }
                GroupActionTile(icon: "ic_call_video", title: "Video", cardColor: cardColor) { startCall(video: true) }
            }
            // The app's own Send To sheet (owner 2026-10-18), not the system one: the link goes to
            // chats here as a plain message of mine.
            if let link = inviteLink {
                GroupActionTile(icon: "square.and.arrow.up", title: "Share", cardColor: cardColor) { shareGroupText = link }
            } else if canAdd {
                GroupActionTile(icon: "ic_add_member", title: "Add", cardColor: cardColor) { showAdd = true }
            } else if !(conv?.inviteCode ?? "").isEmpty {
                // The group has a link, but its admins share it themselves: the tile stays, greyed.
                GroupActionTile(icon: "square.and.arrow.up", title: "Share", cardColor: cardColor) {}
                    .disabled(true).opacity(0.45)
            }
            if let onSearch {
                GroupActionTile(icon: "magnifyingglass", title: "Search", cardColor: cardColor) { onSearch() }
            }
        }
    }

    private var mayCall: Bool { CallFeatures.groupCalls && (conv?.canStartCall(me) ?? false) }

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

    /// The ••• menu. Leave / Report / Delete stay on the red card. Whoever may change group info gets
    /// the edit items and the wallpaper first; everyone gets Mute, Export, Create Similar and Clear.
    @ViewBuilder private var moreMenuItems: some View {
        if canEditInfo {
            Section {
                Button { showEdit = true } label: { Label("Edit Name and Picture", systemImage: "pencil") }
                // The description is edited on Edit Group with the bio's rules (2026-10-18).
                Button { showEdit = true } label: { Label("Edit Description", systemImage: "text.alignleft") }
                // owner 2026-10-18: the group's wallpaper is everyone's, so only someone who may change
                // group info sees this (same test as the name and photo; firestore.rules says the same).
                Button { changeWallpaper() } label: {
                    Label { Text("Change Wallpaper") } icon: { MenuIcon("ic_wallpaper") }
                }
            }
        }
        Section {
            // No Mute here (owner 2026-10-19): Sounds & Notifications on the page already holds it.
            Button { exportChat() } label: { Label("Export Chat", systemImage: "square.and.arrow.down") }
                .disabled(exporting)
            Button { showSimilar = true } label: { Label("Create a Similar Group", systemImage: "person.2") }
        }
        Button { confirmClear = true } label: { Label("Clear Chat", systemImage: "trash") }
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

    /// The description, as the Fariin official chat's About card (links and @usernames tappable).
    /// Shown only when there IS one (owner 2026-10-18); tap to edit, for whoever may.
    private var aboutCard: some View {
        ProfileAboutContent(text: desc, linked: true)
            .profileSurface(plain: cardColor)
            .contentShape(Rectangle())
            // 2026-10-18 (owner): no small pop-up for this any more; the description is edited on the
            // Edit Group page with the bio's rules, so the card opens that page.
            .onTapGesture { if canEditInfo { showEdit = true } }
    }

    private var settingsCard: some View {
        VStack(spacing: 0) {
            // A group-wide setting: the change-info right edits it, everyone else reads it.
            ProfileInfoRow(title: "Disappearing Messages", icon: "ic_disappearing", value: disappearLabel,
                           chevron: can(.changeInfo)) {
                // A tap that did nothing read as broken (owner 2026-10-19): say why instead.
                if can(.changeInfo) { showDisappear = true } else { flashNotice("Only admins can change this") }
            }
            rowDivider
            ProfileInfoRow(title: "Sounds & Notifications", icon: "ic_notifications",
                           value: muted ? "Muted" : "On") { showSounds = true }
            // This phone only (2026-10-18): follows Settings > Chats, or overrides it for this chat.
            rowDivider
            saveToPhotosRow
            rowDivider
            encryptionRow
            // Invite links are an admin right (fix-all #226), so only that admin sees the row.
            if can(.inviteUsers) {
                rowDivider
                ProfileInfoRow(title: "Group invite link", icon: "link",
                               value: (conv?.inviteCode ?? "").isEmpty ? "Off" : "On") { showInvite = true }
            }
            if iAmAdmin {
                rowDivider
                ProfileInfoRow(title: "Group Settings", icon: "gearshape") { showSettings = true }
            }
        }
        .profileSurface(plain: cardColor)
    }

    /// Default / Always / Never as the system's own menu with its tick, on the row's look.
    private var saveToPhotosRow: some View {
        Menu {
            Picker("Save to Photos", selection: Binding(get: { saveChoice }, set: { pickSaveChoice($0) })) {
                ForEach(AutoSaveToPhotos.ChatChoice.allCases, id: \.self) { c in Text(c.label).tag(c) }
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "square.and.arrow.down").font(.system(size: 17)).frame(width: 26)
                Text("Save to Photos")
                Spacer()
                Text(saveChoice.label).foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down").font(.footnote.weight(.bold)).foregroundStyle(.tertiary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 16).padding(.vertical, 18)
            .contentShape(Rectangle())
        }
        .tint(.primary)
    }

    /// Encryption, with its one-line promise under the title (the row's two-line form).
    private var encryptionRow: some View {
        Button { showEncryption = true } label: {
            HStack(spacing: 14) {
                Image("ic_privacy").renderingMode(.template).resizable().scaledToFit()
                    .frame(width: 21, height: 21)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Encryption")
                    Text("Messages are end-to-end encrypted. Tap to learn more.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.tertiary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 16).padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var rowDivider: some View { Divider().padding(.leading, 56) }

    private var disappearLabel: String {
        let s = conv?.disappearSeconds ?? 0
        return s == 0 ? "Off" : ChatService.disappearShortLabel(s)
    }

    // MARK: Media

    /// The All Media strip when there is any, then Media, Links and Files (opens the gallery) and
    /// this chat's storage on this phone.
    private var mediaBlock: some View {
        VStack(spacing: 12) {
            if !media.isEmpty {
                ProfileMediaCard(cid: cid, media: media, cardColor: cardColor,
                                 onOpen: { m in if m.isVideo { viewerVideo = m } else { viewerImage = m } },
                                 onSeeAll: { showAllMedia = true })
            }
            VStack(spacing: 0) {
                ProfileInfoRow(title: "Media, Links and Files", icon: "photo.on.rectangle",
                               value: galleryCount.map { "\($0)" } ?? " ") { showAllMedia = true }
                rowDivider
                ProfileInfoRow(title: "Storage Used", icon: "internaldrive",
                               value: storage.map { Self.bytes($0.total) } ?? " ",
                               chevron: (storage?.clearable ?? 0) > 0) {
                    if (storage?.clearable ?? 0) > 0 { confirmClearStorage = true }
                }
            }
            .profileSurface(plain: cardColor)
        }
    }

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

    // MARK: Members

    private var membersBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(conv?.memberCountLabel.capitalized ?? "Members").font(.headline)
                Spacer()
                // owner 2026-10-18: the search opens the members sheet (its own list with its search
                // bar, as the reference app does), not a field squeezed into this page.
                Button {
                    showAllMembers = true
                } label: {
                    Image(systemName: searchingMembers ? "xmark" : "magnifyingglass")
                        .font(.system(size: 17, weight: .medium)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(searchingMembers ? "Close search" : "Search members")
            }
            .padding(.horizontal, 8)
            if searchingMembers {
                TextField("Search members", text: $memberQuery)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .profileSurface(plain: cardColor, radius: 14)
            }
            membersCard
        }
    }

    private var membersCard: some View {
        VStack(spacing: 0) {
            if canAdd && memberQuery.isEmpty {
                Button { showAdd = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .medium)).foregroundStyle(.secondary)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color(.systemGray5)))
                        Text("Add Members").foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            // ⛔ TEN ON THE PAGE (owner 2026-10-18): a big group listed every member here. The first
            // ten, then See All opens the full, searchable members list in a sheet. A search shows
            // every match, as before.
            let all = shownMembers
            let capped = memberQuery.isEmpty && all.count > Self.membersShown
            ForEach(Array((capped ? Array(all.prefix(Self.membersShown)) : all).enumerated()), id: \.element) { i, uid in
                if i > 0 || (canAdd && memberQuery.isEmpty) { rowDivider }
                GroupMemberRow(conv: conv, uid: uid, me: me) {
                    memberAction = MemberAction(id: uid, name: conv?.names[uid] ?? "User",
                                                isAdmin: conv?.isAdmin(uid) ?? false)
                }
            }
            if capped {
                rowDivider
                Button { showAllMembers = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary)
                            .frame(width: 40, height: 40)
                        Text("See All").foregroundStyle(.primary)
                        Spacer()
                        Text("\(all.count)").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            // owner 2026-10-18: who joined, left, was removed or changed admin, newest first.
            if memberQuery.isEmpty {
                rowDivider
                Button { showMemberChanges = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 17, weight: .medium)).foregroundStyle(.secondary)
                            .frame(width: 40, height: 40)
                        Text("View Member Changes").foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .profileSurface(plain: cardColor)
    }
    private static let membersShown = 10

    private var shownMembers: [String] {
        let all = GroupMembers.sorted(conv, me: me)
        let q = memberQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { (conv?.names[$0] ?? "").lowercased().contains(q) }
    }

    private func memberSheet(_ m: MemberAction) -> some View {
        GroupMemberSheet.make(cid: cid, conv: conv, me: me, uid: m.id,
                              onInfo: { uid in profileOf = MemberAction(id: uid, name: conv?.names[uid] ?? "User", isAdmin: false) })
            .presentationDetents([.medium, .large])
    }

    // MARK: Exits

    /// The profile's red card, for a group: Leave, Report, and Delete for the owner.
    private var dangerCard: some View {
        VStack(spacing: 0) {
            ProfileInfoRow(title: "Leave Group", icon: "rectangle.portrait.and.arrow.right",
                           tint: .red, chevron: false) { confirmLeave = true }
            rowDivider
            ProfileInfoRow(title: "Report Group", icon: "ic_report", tint: .red, chevron: false) { confirmReport = true }
            // Only the owner can permanently delete the whole group (for everyone).
            if iAmOwner {
                rowDivider
                ProfileInfoRow(title: "Delete Group", icon: "trash", tint: .red, chevron: false) { confirmDelete = true }
            }
        }
        .profileSurface(plain: cardColor)
    }

    // "Created by you · 26 Jun 2026", like the reference group screens.
    // 2026-10-18 (owner): taken off the bottom of the page; nil hides the line wherever it is used.
    private var createdByLabel: String? {
        return nil
        guard let conv, conv.isGroup, !conv.createdBy.isEmpty else { return nil }
        let who = conv.createdBy == me ? "you" : (conv.names[conv.createdBy] ?? "someone")
        guard let d = conv.createdAt else { return "Created by \(who)" }
        let f = DateFormatter(); f.dateStyle = .medium
        return "Created by \(who) · \(f.string(from: d))"
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if showGroupPhoto {
            // The bar sits above the viewer overlay and eats its touches, so the viewer's X is a bar
            // item, wired through closeSignal (ContactInfoView's rule).
            ToolbarItem(placement: .topBarLeading) {
                Button { photoCloseTick &+= 1 } label: {
                    Image(systemName: "xmark").font(.system(size: 17, weight: .semibold))
                }
                .tint(.primary)
            }
        } else {
            // owner 2026-10-18: the QR of the invite link (only while there is one), then •••.
            ToolbarItemGroup(placement: .topBarTrailing) {
                if inviteLink != nil {
                    Button { showQR = true } label: {
                        Image("ic_qr").renderingMode(.template).resizable().scaledToFit()
                            .frame(width: 20, height: 20)
                    }
                    .tint(.primary)
                    .accessibilityLabel("QR code")
                }
                Menu { moreMenuItems } label: {
                    Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold))
                }
                .tint(.primary)
                .accessibilityLabel("More")
            }
        }
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
                if let rank { Text(rank).font(.subheadline).foregroundStyle(.secondary) }
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
    @State private var showRole = false
    @State private var showRights = false
    @State private var showProfileHere = false
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

    // ⛔ A SHORT SHEET, THEN THEIR PROFILE (owner 2026-10-19, from the reference app's member card):
    // the face and name, Message / Voice / Video, then one card of what I may do to them here. Info
    // opens their regular profile on the group page's own stack, so Back lands on the group again.
    // Block and Report live on that profile, as for anyone else.
    private var card: Color { Color(uiColor: .secondarySystemGroupedBackground) }
    private var rowDivider: some View { Divider().padding(.leading, 56) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    if member.id != me { tiles }
                    actionsCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showRole) {
                RoleEditorView(cid: cid, uid: member.id, name: member.name, current: role)
            }
            .navigationDestination(isPresented: $showRights) {
                AdminRightsView(cid: cid, uid: member.id, name: member.name,
                                grantable: grantable, rights: $rights)
            }
            .navigationDestination(isPresented: $showProfileHere) {
                ContactInfoView(cid: ChatService.convId(me, member.id), name: member.name,
                                photoUrl: gatedMemberPhoto, source: .calls)
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task { profile = await ProfileStore.shared.fetch(member.id) }
            .onAppear {
                guard !rightsLoaded else { return }
                rightsLoaded = true
                rights = currentRights.map(Set.init) ?? Set(Conversation.Right.defaults.map(\.rawValue))
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

    private var header: some View {
        VStack(spacing: 8) {
            // Honor THEIR audience settings, like the 1:1 profile does (audit).
            AvatarView(name: member.name, photoUrl: gatedMemberPhoto, size: 88)
            HStack(spacing: 6) {
                Text(member.name).font(.title2.weight(.bold))
                VerifiedMark(uid: member.id, size: 17, explains: true)
            }
            HStack(spacing: 6) {
                if let h = profile?.handle, !h.isEmpty {
                    Text("@\(h)").font(.subheadline).foregroundStyle(.secondary)
                }
                if isOwner || member.isAdmin {
                    Text(isOwner ? "Owner" : "Admin").font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                if let role { RoleChip(role: role) }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
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
        let other = member.id != me && !isOwner
        let canRemove = other && canRestrict && (iAmOwner || !member.isAdmin)
        let canMute = other && canRestrict && !member.isAdmin
        VStack(spacing: 0) {
            if other && canManageAdmins {
                if member.isAdmin {
                    ProfileInfoRow(title: "Edit Admin Rights", icon: "person.badge.shield.checkmark") { showRights = true }
                    rowDivider
                    ProfileInfoRow(title: "Remove as Admin", icon: "person.badge.minus", chevron: false) {
                        run { try await ChatService.demoteGroupAdmin(cid: cid, uid: member.id, name: member.name) }
                    }
                } else {
                    ProfileInfoRow(title: "Make Group Admin", icon: "person.badge.shield.checkmark", chevron: false) {
                        // A new admin gets the defaults, cut down to what I may hand out.
                        let give = Conversation.Right.defaults.map(\.rawValue).filter { grantable.contains($0) }
                        run { try await ChatService.promoteGroupAdmin(cid: cid, uid: member.id, name: member.name, rights: give) }
                    }
                }
                rowDivider
            }
            // ⛔ ROLE — owner 2026-10-18. Given by admins only (Conversation.canSetRole).
            if canEditRole {
                ProfileInfoRow(title: role == nil ? "Set Role" : "Edit Role", icon: "tag") { showRole = true }
                rowDivider
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
    @State private var searching = true
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
                    .presentationDetents([.medium, .large])
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
