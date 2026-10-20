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
    /// The members in page order, re-sorted only when `membersKey` changes (see `memberIds`).
    @State private var sortedIds: [String] = []
    /// Ends the previous notice's timer, so a second notice gets its full time on screen.
    @State private var noticeTask: Task<Void, Never>?
    /// The first load of the link code and the media figures has run (see the `.task` in `core`).
    @State private var figuresLoaded = false
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

    /// The group's own document first (owner 2026-10-20: a role given or taken showed only after a
    /// refresh), the chat list's copy until it answers.
    @State private var live = LiveGroupDoc()
    private var conv: Conversation? { live.conv ?? repo.conversations.first { $0.id == cid } }
    private var iAmAdmin: Bool { conv?.isAdmin(me) ?? false }
    private var iAmOwner: Bool { conv?.createdBy == me && !(conv?.createdBy.isEmpty ?? true) }
    // Per-flag admin right check (owner = all; legacy admin with no adminRights entry = all).
    private func can(_ r: Conversation.Right) -> Bool { conv?.adminCan(me, r) ?? false }
    // An admin with the matching right can; members can too when the group's permission is on.
    // A member an admin restricted from it may not, whatever the group's switch (2026-10-19 fix round).
    private var canEditInfo: Bool {
        guard let c = conv else { return false }
        return c.adminCan(me, .changeInfo)
            || (c.membersCanEditInfo && !c.isRestricted(me, .changeInfo, now: Date().timeIntervalSince1970 * 1000))
    }
    private var canAdd: Bool {
        guard let c = conv else { return false }
        return c.adminCan(me, .inviteUsers)
            || (c.membersCanAdd && !c.isRestricted(me, .addMembers, now: Date().timeIntervalSince1970 * 1000))
    }
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
    /// 2026-10-19 groups v2 step 4: the primary link's code from the server (getShareLink), "" when
    /// the group has none. nil until it answers (or when it fails): then the group doc's old
    /// `inviteCode`, which the server still copies there for builds from before.
    @State private var shareCode: String?
    private var inviteLink: String? {
        guard mayShareLink, let code = shareCode ?? conv?.inviteCode, !code.isEmpty,
              let link = URL(string: KulanApp.groupLink(code: code)) else { return nil }
        return link.absoluteString
    }

    /// The same capsule the profile page raises: up on a spring, gone after a second and a half.
    private func flashNotice(_ text: String) {
        Haptics.notify(.warning)
        notice = text
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { noticeShown = true }
        // The previous notice's timer is cancelled: it used to hide this one early.
        noticeTask?.cancel()
        noticeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { noticeShown = false }
        }
    }

    var body: some View {
        AnyView(coreWithLoads)
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
                if let link = inviteLink {
                    GroupLinkQRSheet(title: title, link: link, photo: conv?.avatarUrl, memberCount: conv?.users.count)
                }
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
                                       sourceFrame: artRect.rect, landsSquare: true, squareCrop: true,
                                       closeSignal: photoCloseTick,
                                       isPresented: $showGroupPhoto)
                        .ignoresSafeArea()
                }
            }
            .modifier(GroupInfoDialogs(cid: cid, current: conv?.disappearSeconds ?? 0,
                                       showDescEdit: $showDescEdit, descText: $descText,
                                       showDisappear: $showDisappear, pendingDisappear: $pendingDisappear,
                                       actionError: $actionError))
            .modifier(GroupInfoExits(cid: cid, conv: conv, me: me,
                                     confirmLeave: $confirmLeave, confirmClear: $confirmClear,
                                     confirmReport: $confirmReport, confirmDelete: $confirmDelete,
                                     actionError: $actionError, onGone: { dismiss() },
                                     onReported: { flashNotice("Thanks for reporting. We'll take a look.") }))
            // A full page, pushed (owner 2026-10-18), not a half sheet.
            .sheet(item: Binding(get: { shareGroupText.map { ShareText(id: $0) } },
                                 set: { shareGroupText = $0?.id })) { t in
                SendContactSheet(contactText: t.id)   // the profile's Share with sheet (owner 2026-10-20)
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
                live.start(cid)   // roles and rights change in front of you (2026-10-20)
                if callListener.reg == nil, CallFeatures.groupCalls {
                    callListener.reg = Firestore.firestore().collection("groupCalls").document(cid)
                        .addSnapshotListener { snap, _ in
                            let d = snap?.data()
                            var on = (d?["active"] as? Bool) ?? false
                            if on, let ts = d?["startedAt"] as? Timestamp,
                               Date().timeIntervalSince(ts.dateValue()) > 4 * 3600 { on = false }
                            callLive = on
                        }
                }
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
    }

    /// `core` with its loads and the member-order cache, apart so neither chain grows too long for
    /// the type checker.
    private var coreWithLoads: some View {
        core
            // The gallery count, the storage figure and the link's code: once when the page opens
            // (2026-10-19 fix round: every return from any page ran the server call and the
            // gallery merge again), then only on coming back from a page that can change them.
            .task {
                guard !figuresLoaded else { return }
                figuresLoaded = true
                Task { await loadShareCode() }
                Task { await loadMediaFigures() }
            }
            // The link page (here or under Group Settings) may have reset or turned off the link.
            .onChange(of: showInvite) { _, open in if !open { Task { await loadShareCode() } } }
            .onChange(of: showSettings) { _, open in if !open { Task { await loadShareCode() } } }
            // The gallery or a clear may have changed the figures.
            .onChange(of: showAllMedia) { _, open in if !open { Task { await loadMediaFigures() } } }
            .onChange(of: showStorage) { _, open in if !open { Task { await loadMediaFigures() } } }
            // The member order, sorted again only when the members, admins or names change.
            .onChange(of: membersKey, initial: true) { _, _ in sortedIds = GroupMembers.sorted(conv, me: me) }
    }

    private func loadShareCode() async {
        guard mayShareLink else { shareCode = nil; return }
        // A failed lookup keeps the group doc's code (see `shareCode`); nothing is changed by it.
        do { shareCode = try await GroupInviteService.shareCode(cid: cid) ?? "" } catch { shareCode = nil }
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
        // 2026-10-19 groups v2: a public group's own link, for every member (copy, share, QR).
        if let name = conv?.publicName, !name.isEmpty {
            GroupPublicLinkCard(name: name, title: title, cardColor: cardColor, photo: conv?.avatarUrl, memberCount: conv?.users.count)
        }
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
    /// it as a round picture; without one, the group's own round avatar. Either way the
    /// name, the count and the description, then the actions.
    private var header: some View {
        VStack(spacing: 16) {
            if let groupPhoto {
                AvatarView(name: title, photoUrl: groupPhoto, size: Self.photoSide)
                    .opacity(showGroupPhoto ? 0 : 1)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { artRect.rect = $0 }
                    .onTapGesture { showGroupPhoto = true }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Group photo")
                    .accessibilityAddTraits(.isButton)
            } else {
                // The group's own round avatar, as everywhere else. No faces bubble (owner
                // 2026-10-19: "we don't need it any more").
                AvatarView(name: title, photoUrl: nil, size: Self.photoSide)
                    // No photo yet: whoever may change it goes straight to Edit Group.
                    .onTapGesture { if canEditInfo { showEdit = true } }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(canEditInfo ? "Add Group Photo" : "Group photo")
                    .accessibilityAddTraits(canEditInfo ? .isButton : [])
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
            // The count stays under the name (owner 2026-10-20, reversing the same day's removal).
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

    /// Five equal glass circles, no labels: Voice, Video, Mute, Search, More. The person profile's
    /// own circle (`PosterActionIcon`). What I may not do stays on the row, greyed, and a tap says
    /// why (owner 2026-10-19), instead of a hole in the row. Voice took the Add circle's place:
    /// the members card has its own Add Members row (owner 2026-10-19).
    private var actionsRow: some View {
        HStack(spacing: 0) {
            Button { callTapped(video: false) } label: { actionIcon("phone.fill", "Voice") }
                .tint(.primary)
                .opacity(callReady ? 1 : 0.45)
                .accessibilityLabel("Voice Call")
            Button { callTapped(video: true) } label: { actionIcon("video.fill", "Video") }
                .tint(.primary)
                .opacity(callReady ? 1 : 0.45)
                .accessibilityLabel("Video Call")
            Menu { muteMenuItems } label: { actionIcon(muted ? "bell.fill" : "bell.slash.fill", muted ? "Unmute" : "Mute") }
                .tint(.primary)
                .accessibilityLabel(muted ? "Unmute" : "Mute")
            Button { onSearch?() } label: { actionIcon("magnifyingglass", "Search") }
                .tint(.primary)
                .disabled(onSearch == nil)
                .opacity(onSearch == nil ? 0.45 : 1)
                .accessibilityLabel("Search")
            Menu { moreMenuItems } label: { actionIcon("ellipsis", "More") }
                .tint(.primary)
                .accessibilityLabel("More")
        }
    }

    /// The person profile's circle at its own size (owner 2026-10-19: "exactly match the User
    /// Profile").
    private func actionIcon(_ name: String, _ label: String) -> some View {
        PosterActionIcon(icon: name, onPhoto: false, label: label)
    }

    private var mayCall: Bool { CallFeatures.groupCalls && (conv?.canStartCall(me) ?? false) }
    private var callReady: Bool { (mayCall || callLive) && !busyElsewhere }
    /// This group's call is going (its own call doc), so the circles join it.
    @State private var callLive = false
    @State private var callListener = ListenerBox()

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
        // Joining a call that is already going is open to every member (audit 2026-10-20).
        if !mayCall && !callLive { flashNotice("Only admins can start a call"); return }
        // Nobody to ring (owner 2026-10-19): said here, not after an empty call screen.
        if (conv?.users.count ?? 0) <= 1 { flashNotice("You're the only one in this group"); return }
        startCall(video: video)
    }

    @ViewBuilder private var muteMenuItems: some View {
        if muted {
            Section(muteUntilLabel) {
                Button("Unmute") { setMuted(0) }
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

    /// The bell reads the group document, which drops a refused write by itself; the refusal is
    /// also said (2026-10-19 fix round), so a mute that did not take is not left unexplained.
    private func setMuted(_ until: Double) {
        Task {
            let ok = await ChatService.setMute(cid, until: until)
            if !ok { actionError = "Your mute setting was not changed. Check your connection and try again." }
        }
    }

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
        // Member Changes (admins, Group Settings), Storage (a page row) and Clear Chat are not in
        // this menu (owner 2026-10-20).
        menuGroupItems
        menuMediaItems
    }

    @ViewBuilder private var menuGroupItems: some View {
        Section {
            // Edit Group is the bar's Edit button now (owner 2026-10-19).
            if canEditInfo {
                // No Edit Description here (owner 2026-10-19): the bar's Edit opens the same page.
                // The group's wallpaper is everyone's, so only someone who may change group info
                // (owner 2026-10-18; firestore.rules says the same).
                Button { changeWallpaper() } label: {
                    Label { Text("Change Wallpaper") } icon: { MenuIcon("ic_wallpaper") }
                }
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
        // No Add Members, Media or Members here: the page has all three; the "N Members" heading
        // opens the full list (owner 2026-10-19).
        Section {
            // Who joined, left, was removed or changed admin, newest first (owner 2026-10-18).
            Button { showMemberChanges = true } label: {
                Label("View Member Changes", systemImage: "clock.arrow.circlepath")
            }
        }
    }

    @ViewBuilder private var menuMediaItems: some View {
        Section {
            // This phone only (2026-10-18): follows Settings > Chats, or overrides it for this chat.
            Menu {
                // Just On / Off (owner 2026-10-20: no "Default (Off)"). The untouched state shows
                // what it does today, the Settings switch's value.
                Picker("Save to Photos", selection: Binding(
                    get: { saveOn },
                    set: { pickSaveChoice($0 ? .always : .never) })) {
                    Text("On").tag(true)
                    Text("Off").tag(false)
                }
            } label: {
                Label("Save to Photos: \(saveOn ? "On" : "Off")", systemImage: "square.and.arrow.down")
            }
        }
    }

    @ViewBuilder private var menuChatItems: some View {
        Section {
            // No Create a Similar Group (owner 2026-10-19): rarely used; New Group does the same.
            Button { confirmClear = true } label: { Label("Clear Chat", systemImage: "eraser") }
        }
    }

    /// Report, Leave and Delete as red rows at the foot of the page, out of the ••• menu (owner
    /// 2026-10-19).
    private var exitCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                ProfileInfoRow(title: "Report Group", icon: "ic_report", tint: Self.exitRed, chevron: false) { confirmReport = true }
                rowDivider
                ProfileInfoRow(title: "Leave Group", icon: "rectangle.portrait.and.arrow.right",
                               tint: Self.exitRed, chevron: false) { confirmLeave = true }
                // Only the owner can permanently delete the whole group (for everyone).
                if iAmOwner {
                    rowDivider
                    ProfileInfoRow(title: "Delete Group", icon: "trash", tint: Self.exitRed, chevron: false) { confirmDelete = true }
                }
            }
            .profileSurface(plain: cardColor)
            if let line = createdLine {
                Text(line).font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            }
        }
    }

    /// A deeper red than the system one for these rows (owner 2026-10-19: ours read pale). The
    /// system red stays at night, where the deep one would sink into the dark card.
    private static let exitRed = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark ? .systemRed : UIColor(red: 0.80, green: 0.12, blue: 0.22, alpha: 1)
    })

    /// "Created by Adnan." / "Created yesterday at 3:54 AM." under the red rows, when known.
    private var createdLine: String? {
        guard let c = conv else { return nil }
        var parts: [String] = []
        if !c.createdBy.isEmpty {
            let who = c.createdBy == me ? "you" : (c.names[c.createdBy] ?? "")
            if !who.isEmpty { parts.append("Created by \(who).") }
        }
        if let at = c.createdAt {
            var when = Self.createdFormat.string(from: at)
            // "Today at…" / "Yesterday at…" read mid-sentence; a real date keeps its capital.
            if when.hasPrefix("Today") || when.hasPrefix("Yesterday") { when = when.prefix(1).lowercased() + when.dropFirst() }
            parts.append("Created \(when).")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private static let createdFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    private func startCall(video: Bool) {
        // Just one other person (owner 2026-10-19): a normal ringing call to them, as from their
        // profile. If I am already on this group's call, the tile goes back to it as before.
        if GroupCallService.shared.activeCid == nil, !callLive, let c = conv, c.users.count == 2,
           let other = c.users.first(where: { $0 != me }) {
            CallService.shared.startCall(to: other, name: c.names[other] ?? "User",
                                         photo: c.photos[other], video: video, fromProfile: true)
            return
        }
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
            // Disappearing Messages lives in Group Settings now (owner 2026-10-20).
            ProfileInfoRow(title: "Sounds & Notifications", icon: "ic_notifications",
                           value: muted ? "Off" : "On") { showSounds = true }
            // Storage on the page, under Sounds (owner 2026-10-20), out of the ⋯ menu.
            rowDivider
            ProfileInfoRow(title: "Storage Used", icon: "internaldrive",
                           value: storage.map { Self.bytes($0.total) } ?? "") { showStorage = true }
            // A private group's link is the admins' (owner 2026-10-19): a member sees no row at all.
            // A public group's link row comes with its username (groups step 2).
            if can(.inviteUsers) {
                rowDivider
                ProfileInfoRow(title: "Group invite link", icon: "link",
                               value: (shareCode ?? conv?.inviteCode ?? "").isEmpty ? "Off" : "On") { inviteRowTapped() }
            }
        }
        .profileSurface(plain: cardColor)
    }

    /// Invite links are an admin right (fix-all #226): that admin manages them; a member who may
    /// share gets the link's own page; anyone else is told why.
    private func inviteRowTapped() {
        if can(.inviteUsers) { showInvite = true }
        else if inviteLink != nil { showMemberLink = true }
        // Owner 2026-10-19: a member is told why there is no link for them.
        else { flashNotice("This group is private. Only admins can share its link.") }
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
    /// Tapping "N Members" opens the whole list (owner 2026-10-19: it replaces Members in the ⋯ menu).
    private var membersHeader: some View {
        Button { showAllMembers = true } label: {
            HStack(spacing: 4) {
                Text(membersTitle).font(.headline)
                Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
            }
            .foregroundStyle(.secondary)
            .frame(minHeight: 44)
            .padding(.leading, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(membersTitle), See All")
    }

    private var membersTitle: String {
        let n = conv?.users.count ?? 0
        return "\(n) Member\(n == 1 ? "" : "s")"
    }

    /// The reference shows six members; past six, the first five and See All.
    private static let membersShown = 6

    /// What the member order depends on. The sort runs when one of these changes, not on every
    /// redraw of the page (2026-10-19 fix round: a large group made each redraw slow).
    struct MembersKey: Equatable {
        let users: [String]
        let admins: [String]
        let names: [String: String]
    }
    private var membersKey: MembersKey {
        let c = conv
        return MembersKey(users: c?.users ?? [], admins: c?.admins ?? [], names: c?.names ?? [:])
    }
    /// The members in page order, from the cache (`sortedIds`); sorted here only until it fills.
    private var memberIds: [String] {
        if sortedIds.isEmpty, let c = conv, !c.users.isEmpty { return GroupMembers.sorted(c, me: me) }
        return sortedIds
    }

    private var membersCard: some View {
        let c = conv
        let all = memberIds
        let hasMore = all.count > Self.membersShown
        let shown = hasMore ? Array(all.prefix(Self.membersShown - 1)) : all
        return VStack(spacing: 0) {
            if canAdd {
                MemberCircleRow(icon: "plus", title: "Add Members") { showAdd = true }
                memberDivider
            }
            ForEach(Array(shown.enumerated()), id: \.element) { i, uid in
                if i > 0 { memberDivider }
                GroupInfoMemberRow(conv: c, uid: uid, me: me) { openMember(uid) }.equatable()
            }
            if hasMore {
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
                MemberBubbleCloud(faces: MemberFace.list(conv, Array(memberIds.prefix(MemberBubbleCloud.capacity))))
                    .equatable()
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
                              onInfo: { uid in profileOf = MemberAction(id: uid, name: conv?.names[uid] ?? "User", isAdmin: false) },
                              onRemoved: { name in flashNotice("\(name) was removed from \(title).") })
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
    private var saveOn: Bool {
        switch saveChoice {
        case .always: true
        case .never: false
        case .standard: AutoSaveToPhotos.isOn
        }
    }

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

/// All Members as a loose cloud (owner's mockup 2026-10-19): two rows of faces of different sizes,
/// the biggest in the middle, smaller ones toward the edges. Fixed spots as shares of the card's
/// width, so it reads organic on every phone and never overlaps. Faces are not buttons: the card
/// around the cloud is.
private struct MemberBubbleCloud: View, Equatable {
    /// Plain values (2026-10-19 fix round), so the cloud is not redrawn while its faces stay the same.
    let faces: [MemberFace]

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
                ForEach(Array(faces.prefix(Self.slots.count).enumerated()), id: \.element.uid) { i, f in
                    bubble(i, f, width: geo.size.width)
                }
            }
            .frame(width: geo.size.width, height: Self.height)
        }
        .frame(height: Self.height)
    }

    private func bubble(_ i: Int, _ f: MemberFace, width: CGFloat) -> some View {
        let s = Self.slots[i]
        return GroupFace(name: f.name, photo: f.photo, size: s.d)
            .position(x: s.x * width, y: s.y * Self.height)
            .accessibilityHidden(true)
    }
}

/// One face in the no-photo disc or the member cloud, as plain values.
private struct MemberFace: Equatable {
    let uid: String
    let name: String
    let photo: String?

    static func list(_ conv: Conversation?, _ ids: [String]) -> [MemberFace] {
        ids.map { MemberFace(uid: $0, name: conv?.names[$0] ?? "User", photo: conv?.photos[$0]) }
    }
}

/// One member on the group page, the reference app's contact cell (owner's mockup 2026-10-19):
/// 36pt photo, 12 to the text, the name in the body style with their Role under it as a tinted
/// pill, Owner / Admin in grey at the end, 7 above and below. The trailing word stays beside a
/// Role here: that is the reference look the owner asked for.
private struct GroupInfoMemberRow: View, Equatable {
    // Plain values, read out of the group once (2026-10-19 fix round): a row whose member did not
    // change compares equal and is not redrawn when anything else in the group moves.
    let uid: String
    let name: String
    let photo: String?
    let rank: String?
    let role: GroupRole?
    let onTap: () -> Void

    init(conv: Conversation?, uid: String, me: String, onTap: @escaping () -> Void) {
        self.uid = uid
        self.name = uid == me ? "You" : (conv?.names[uid] ?? "User")
        self.photo = conv?.photos[uid]
        self.rank = GroupMembers.rank(conv, uid)
        self.role = conv?.roles[uid]
        self.onTap = onTap
    }

    static func == (a: Self, b: Self) -> Bool {
        a.uid == b.uid && a.name == b.name && a.photo == b.photo && a.rank == b.rank && a.role == b.role
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                AvatarView(name: name, photoUrl: photo, size: 36)
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
            if let role { MemberLabelPill(role: role, uid: uid) }
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
    /// 2026-10-19 fix round: each name lowercased once and the admins put in a Set, instead of
    /// both on every comparison of the sort (a large group redrew the page slowly).
    static func sorted(_ conv: Conversation?, me: String) -> [String] {
        guard let c = conv else { return [] }
        let admins = Set(c.admins)
        let keys = c.users.map { uid -> (String, Bool, String) in
            (uid, admins.contains(uid), (c.names[uid] ?? "").lowercased())
        }
        return keys.sorted { a, b in
            if a.0 == me { return true }
            if b.0 == me { return false }
            if a.1 != b.1 { return a.1 }
            return a.2 < b.2
        }.map(\.0)
    }

    /// "Owner" / "Admin" / nil, the trailing word on a member row.
    static func rank(_ conv: Conversation?, _ uid: String) -> String? {
        if let c = conv, !c.createdBy.isEmpty, c.createdBy == uid { return "Owner" }
        return (conv?.isAdmin(uid) ?? false) ? "Admin" : nil
    }
}

/// One member: photo, name, their Role under it, and Owner / Admin on the right.
struct GroupMemberRow: View, Equatable {
    // Plain values, read out of the group once (2026-10-19 fix round): a row whose member did not
    // change compares equal and is not redrawn when anything else in the group moves.
    let uid: String
    let name: String
    let photo: String?
    let rank: String?
    let role: GroupRole?
    let onTap: () -> Void

    init(conv: Conversation?, uid: String, me: String, onTap: @escaping () -> Void) {
        self.uid = uid
        self.name = uid == me ? "You" : (conv?.names[uid] ?? "User")
        self.photo = conv?.photos[uid]
        self.rank = GroupMembers.rank(conv, uid)
        self.role = conv?.roles[uid]
        self.onTap = onTap
    }

    static func == (a: Self, b: Self) -> Bool {
        a.uid == b.uid && a.name == b.name && a.photo == b.photo && a.rank == b.rank && a.role == b.role
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                AvatarView(name: name, photoUrl: photo, size: 40)
                // The Role sits on the name's line, right of it (owner 2026-10-18: "not under the
                // name"). The name gives way first, so a long one truncates before the chip does.
                HStack(spacing: 6) {
                    Text(name).foregroundStyle(.primary).lineLimit(1)
                    VerifiedMark(uid: uid, size: 13)
                    if let role { RoleChip(role: role).layoutPriority(1) }
                }
                Spacer(minLength: 8)
                // Owner / Admin at the reference app's size for this label (owner 2026-10-18): the
                // subheadline style (15pt), secondary grey, not the 17pt the name uses.
                // Owner / Admin always shows here, tag or no tag (owner 2026-10-19: "don't touch the
                // Owner and Admin text when I use a label"). The one-chip rule is for the chip only.
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
    /// The page's "Could not do that" alert (`GroupInfoExits`), for a timer the server refused.
    @Binding var actionError: String?

    /// `setDisappear` answers false when nothing was written (2026-10-19 fix round): say so, the
    /// timer row stays on the value the group really has.
    private func setTimer(_ seconds: Int) {
        Task {
            let ok = await ChatService.setDisappear(cid, seconds: seconds)
            if !ok { actionError = "The disappearing message timer was not changed. Check your connection and try again." }
        }
    }

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
                    // Off only when it is on: "no change" writes nothing, which is not a failure.
                    if s == 0 { if current != 0 { setTimer(0) } }
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
                    if let s = pendingDisappear { setTimer(s) }
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
    /// The page's own notice after a report (owner 2026-10-19: it was silent).
    var onReported: () -> Void = {}

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
            // Apple's centred alert, as Leave and Report (owner 2026-10-19: the dialog came up as a
            // bubble pointing at a random spot). Hides history for ME only, on all my devices
            // (clearedAt on the group doc); nobody else loses anything.
            .alert("Clear this chat?", isPresented: $confirmClear) {
                Button("Cancel", role: .cancel) {}
                Button("Clear Chat", role: .destructive) { Task { await ChatService.deleteForMe(cid) } }
            } message: { Text("Messages are cleared for you on all your devices. Others in the group still have them.") }
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
                    onReported()
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
    private func lettered(_ candidates: [(id: String, name: String, photo: String?)])
        -> [(letter: String, people: [(id: String, name: String, photo: String?)])] {
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
        // Built once per body (2026-10-19 fix round): the chat list was filtered and sorted twice.
        let candidates = self.candidates
        let letterGroups = lettered(candidates)
        return NavigationStack {
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
                    ForEach(letterGroups, id: \.letter) { group in
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
            // One search per pause in typing (2026-10-19 fix round): each key used to start its own
            // search, and a slow early one could land after, and over, the last.
            .task(id: query) { await search(query) }
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

    /// Run by `.task(id: query)`: a newer query cancels this one, during the pause or after.
    private func search(_ q: String) async {
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { results = []; return }
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !Task.isCancelled else { return }
        var r = await ChatService.searchUsers(prefix: trimmed)
        guard !Task.isCancelled else { return }
        if r.isEmpty, let exact = await ChatService.findByHandle(trimmed) { r = [exact] }
        guard !Task.isCancelled else { return }
        results = r
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
    @State private var confirmPromote = false
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
    // ⛔ ONE PAGE (owner 2026-10-19): Member | Admin, the rights and the tag are edited here and
    // written together by Done, instead of on their own pushed pages.
    @State private var baseRights: Set<String> = []
    /// The Member | Admin switch: nil until touched, so it opens on what they are now.
    @State private var adminChoice: Bool? = nil
    @State private var roleText = ""
    @State private var confirmDismissAdmin = false
    var onInfo: ((String) -> Void)? = nil   // push their profile on the opener's stack
    /// Said by the opener after a removal (owner 2026-10-19: it was silent), with their name.
    var onRemoved: ((String) -> Void)? = nil

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
    /// The group's own copy of their photo, drawn on the first frame while the profile loads
    /// (owner 2026-10-20: the card opened blank, then the photo and @name pushed it taller).
    var photoHint: String? = nil

    private var gatedMemberPhoto: String? {
        guard let p = profile else { return photoHint }
        return PrivacyPrefs.allows(p.privacy, "photo",
                                   contactOfMine: PrivacyPrefs.mayViewPhotoOf(member.id)) ? p.photoUrl : nil
    }
    private var gatedMemberAbout: String? {
        guard let p = profile else { return nil }
        return PrivacyPrefs.allows(p.privacy, "bio",
                                   contactOfMine: PrivacyPrefs.isContact(member.id)) ? p.about : nil
    }

    // ⛔ ONE PLAIN PAGE (owner 2026-10-19, his own layout, unlike the reference app's): centred
    // photo and name, Member | Admin, the rights as checkmark rows, one Tag field, then plain text
    // rows. No cards, no section headings, no bottom bar: Done in the top bar saves. Nothing here
    // pushes; the photo opens their regular profile on the group page's own stack, so Back lands
    // on the group again. Block and Report live on that profile, as for anyone else.
    private var card: Color { Color(uiColor: .secondarySystemGroupedBackground) }
    private static let rowSide: CGFloat = 20
    private var rowLine: some View { Divider().padding(.leading, Self.rowSide) }

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
    private var adminSelected: Bool { adminChoice ?? member.isAdmin }
    private var adminBinding: Binding<Bool> {
        Binding(get: { adminSelected }, set: { adminChoice = $0 })
    }
    private var rightsChanged: Bool { mayEditRights && member.isAdmin && adminSelected && rights != baseRights }
    private var promoting: Bool { mayEditRights && !member.isAdmin && adminSelected }
    /// Member picked for a current admin: dismissed as admin on Done, after the confirm.
    private var demoting: Bool { mayEditRights && member.isAdmin && !adminSelected }
    private var cleanedRole: String { GroupRole.clean(roleText) }
    private var roleChanged: Bool { canEditRole && cleanedRole != (role?.text ?? "") }
    private var hasChanges: Bool { rightsChanged || promoting || demoting || roleChanged }
    /// Done only on a page with something it could save.
    private var showsSave: Bool { mayEditRights || canEditRole }

    /// Done. A demote asks first (the Dismiss confirm), everything else goes straight out.
    private func saveChanges() {
        guard hasChanges, !busy else { return }
        if demoting { confirmDismissAdmin = true; return }
        commit(demote: false)
    }

    /// Everything changed on the page in one go: demote, or promote (with the ticked rights), or
    /// the new rights, then the tag. Same calls the old pushed pages made.
    private func commit(demote: Bool) {
        let cid = cid, uid = member.id, name = member.name
        let list = rightsList
        let promote = !demote && promoting, newRights = !demote && rightsChanged
        let writeRole = roleChanged, roleWords = cleanedRole, roleEmoji = role?.emoji
        run {
            if demote {
                try await ChatService.demoteGroupAdmin(cid: cid, uid: uid, name: name)
            } else if promote {
                try await ChatService.promoteGroupAdmin(cid: cid, uid: uid, name: name, rights: list)
            } else if newRights {
                try await ChatService.setAdminRights(cid: cid, uid: uid, rights: list)
            }
            if writeRole {
                try await ChatService.setRole(cid: cid, uid: uid, text: roleWords, emoji: roleEmoji)
            }
        }
    }

    // ⛔ SHORT CARD (owner 2026-10-19, after the reference app's member card): the sheet is as tall
    // as what is on it and never grows. Photo, name, Message/Voice/Video, then the rows that apply:
    // Make Group Admin, Info, Remove from Group. Rights and tag sit on their own pushed page; only
    // that page (or the profile) takes the sheet to full height.
    @State private var showEdit = false
    @State private var cardHeight: CGFloat = 420
    @State private var growing = false
    /// Grow to full height first, then push, so no page slides in while the card is short.
    private func growThenPush(_ push: @escaping () -> Void) {
        growing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { push() }
    }
    /// "@name", or one blank space so the line keeps its height until the profile is in.
    private var handleLine: String {
        guard let h = profile?.handle, !h.isEmpty else { return " " }
        return "@\(h)"
    }
    private var expanded: Bool { showEdit || showProfileHere || growing }

    var body: some View {
        NavigationStack {
            shortCard
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showEdit) { editPage }
            // Back to the short card once the pushed page goes (audit 2026-10-20: it stayed tall).
            .onChange(of: showEdit) { _, on in if !on { growing = false } }
            .onChange(of: showProfileHere) { _, on in if !on { growing = false } }
            .navigationDestination(isPresented: $showProfileHere) {
                ContactInfoView(cid: ChatService.convId(me, member.id), name: member.name,
                                photoUrl: gatedMemberPhoto, source: .calls)
            }
            .task {
                // The phone's saved copy first (no network), then the server's (2026-10-20).
                if profile == nil { profile = await ProfileStore.shared.cachedPeer(member.id) }
                if let fresh = await ProfileStore.shared.fetch(member.id) { profile = fresh }
            }
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
            .alert("Make \(member.name) an admin?", isPresented: $confirmPromote) {
                Button("Cancel", role: .cancel) {}
                Button("Make Admin") {
                    let cid = cid, uid = member.id, name = member.name, list = rightsList
                    run { try await ChatService.promoteGroupAdmin(cid: cid, uid: uid, name: name, rights: list) }
                }
            } message: {
                Text("They will be able to manage the group with the usual admin rights. You can change or remove them any time.")
            }
            .alert("Dismiss \(member.name) as admin?",
                                isPresented: $confirmDismissAdmin) {
                // Same write as Done with Member picked: demote, then the tag if it changed.
                Button("Dismiss Admin", role: .destructive) { commit(demote: true) }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Make \(member.name) the owner?",
                                isPresented: $confirmTransfer) {
                Button("Transfer Ownership", role: .destructive) {
                    run { try await ChatService.transferGroupOwnership(cid: cid, to: member.id, name: member.name) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(member.name) will have full control of this group, including over you. You will stay an admin.")
            }
            .alert("Remove \(member.name) from the group?",
                                isPresented: $confirmRemove) {
                Button("Remove", role: .destructive) {
                    let name = member.name, done = onRemoved
                    run {
                        try await ChatService.removeGroupMember(cid: cid, uid: member.id, name: name)
                        await MainActor.run { done?(name) }
                    }
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
        .presentationDetents(expanded ? [.large] : [.height(cardHeight)])
        .presentationBackground(Color(uiColor: .systemGroupedBackground))
    }

    /// The card itself, measured so the sheet is exactly its height.
    private var shortCard: some View {
        VStack(spacing: 16) {
            header.padding(.top, 28)
            if member.id != me { tiles }
            quickRows
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 44)   // clears the home bar: the detent height includes it
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .liquidGlass(Circle())
            }
            .padding(.top, 14).padding(.trailing, 14)
            .accessibilityLabel("Close")
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
    }

    /// Rights and tag, the owner's one-page editor, pushed from the card. Done writes it all.
    private var editPage: some View {
        ScrollView {
            VStack(spacing: 0) {
                if mayEditRights { roleSwitch.padding(.top, 12) }
                if mayEditRights && adminSelected { rightsRows }
                if canEditRole { tagRow }
            }
            .padding(.bottom, 32)
            .animation(.snappy(duration: 0.25), value: adminSelected)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .navigationTitle(firstName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { doneButton } }
    }

    /// Done: live only once something changed, a spinner while it writes.
    @ViewBuilder private var doneButton: some View {
        if busy {
            ProgressView()
        } else if showsSave {
            Button("Done") { saveChanges() }
                .fontWeight(.semibold)
                .disabled(!hasChanges)
        }
    }

    /// Centred: photo, name with one chip, @handle under. Tapping it opens their profile.
    private var header: some View {
        VStack(spacing: 6) {
            // Honor THEIR audience settings, like the 1:1 profile does (audit).
            AvatarView(name: member.name, photoUrl: gatedMemberPhoto, size: 96)
                .padding(.bottom, 6)
            HStack(spacing: 6) {
                Text(member.name).font(.title2.weight(.bold)).lineLimit(1)
                VerifiedMark(uid: member.id, size: 16, explains: true)
                headerChip
            }
            // The line is always there, blank until the @name is known, so the card's height
            // does not change (and the sheet does not jump) when the profile lands.
            Text(handleLine)
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Self.rowSide)
        .contentShape(Rectangle())
        .onTapGesture { if member.id != me { openProfile() } }
    }

    /// The tag as it reads right now: the field while it can be edited, else the saved one.
    private var liveTag: GroupRole? {
        let words = canEditRole ? cleanedRole : (role?.text ?? "")
        return words.isEmpty ? nil : GroupRole(text: words, emoji: role?.emoji)
    }

    /// One chip only (owner 2026-10-19): the tag, when there is one, stands in for Owner/Admin.
    /// Follows the Tag field and the Member | Admin switch as they change.
    /// ⛔ BOTH, side by side (owner 2026-10-20: "admin is the real badge, label is the label"):
    /// Owner / Admin is their rank, the tag is just a word, and one never hides the other.
    @ViewBuilder private var headerChip: some View {
        if isOwner || adminSelected { adminChip }
        if let t = liveTag { RoleChip(role: t) }
    }

    private var adminChip: some View {
        // Blue with a shield, so the rank never reads as just another tag.
        Label(isOwner ? "Owner" : "Admin", systemImage: isOwner ? "crown.fill" : "checkmark.shield.fill")
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.blue.opacity(0.14), in: Capsule())
            .foregroundStyle(Color.blue)
    }

    /// Member | Admin, the native segmented control. Admin for a member = promote on Done (the
    /// promote defaults come up ticked); Member for an admin = dismiss on Done, after the confirm.
    private var roleSwitch: some View {
        Picker("Role", selection: adminBinding) {
            Text("Member").tag(false)
            Text("Admin").tag(true)
        }
        .pickerStyle(.segmented)
        .disabled(busy)
        .padding(.horizontal, Self.rowSide)
        .padding(.bottom, 12)
    }

    /// One row per right I may hand out, the Edit Admin Rights page's list: tap ticks or unticks.
    private var rightsRows: some View {
        VStack(spacing: 0) {
            ForEach(shownRights, id: \.id) { r in
                rowLine
                rightRow(r)
            }
        }
    }

    /// A switch per right, the same as the Add Admin page (owner 2026-10-19), not a tick.
    private func rightRow(_ r: Conversation.Right) -> some View {
        Toggle(r.shortLabel, isOn: Binding(
            get: { rights.contains(r.rawValue) },
            set: { on in if on { rights.insert(r.rawValue) } else { rights.remove(r.rawValue) } }))
        .padding(.horizontal, Self.rowSide).padding(.vertical, 7)
        .disabled(busy)
    }

    /// Red Remove admin row (owner 2026-10-19), for an admin I may demote while Admin is still
    /// picked. Same confirm as the Member switch.
    private var showsRemoveAdmin: Bool { mayEditRights && member.isAdmin && adminSelected }

    // MARK: Member tag (one plain row)

    /// "Tag" and the field on one line, the kept emoji in front. Same GroupRole rules as before:
    /// cleaned on save, held to maxText as you type (onChange above).
    private var tagRow: some View {
        VStack(spacing: 0) {
            rowLine
            HStack(spacing: 12) {
                Text("Tag").font(.body)
                if let e = role?.emoji { Text(e).font(.body) }
                TextField("None", text: $roleText)
                    .font(.body)
                    .submitLabel(.done)
                    .disabled(busy)
            }
            .padding(.horizontal, Self.rowSide).padding(.vertical, 13)
        }
    }

    /// Round glass circles with their names, the group page's own (owner 2026-10-20: the square
    /// tiles read boxy).
    private var tiles: some View {
        HStack(spacing: 0) {
            Button { openChat() } label: {
                PosterActionIcon(icon: "message.fill", diameter: 58, onPhoto: false, label: "Message")
            }
            .buttonStyle(.plain)
            Button {
                CallService.shared.startCall(to: member.id, name: member.name, photo: gatedMemberPhoto,
                                             video: false, fromProfile: true)
            } label: {
                PosterActionIcon(icon: "phone.fill", diameter: 58, onPhoto: false, label: "Voice")
            }
            .buttonStyle(.plain)
            Button {
                CallService.shared.startCall(to: member.id, name: member.name, photo: gatedMemberPhoto,
                                             video: true, fromProfile: true)
            } label: {
                PosterActionIcon(icon: "video.fill", diameter: 58, onPhoto: false, label: "Video")
            }
            .buttonStyle(.plain)
        }
    }

    /// What I may do to them in this group, then Info, then the red one last. The owner is protected:
    /// no admin demotes or removes them. Promote/demote/rights is `canManageAdmins`; removing needs
    /// the Restrict-members right, and removing an ADMIN is the owner's alone (firestore.rules
    /// nonOwnerAdminWriteOK).
    private var canMuteRow: Bool { isOther && canRestrict && !member.isAdmin }
    private var canTransfer: Bool { isOther && iAmOwner }

    /// Removing a member needs the Restrict-members right; removing an admin is the owner's alone.
    private var canRemove: Bool { isOther && canRestrict && (!member.isAdmin || iAmOwner) }
    private var makesAdmin: Bool { mayEditRights && !member.isAdmin }

    /// One card of icon rows under the tiles; only the rows I may use. Make Group Admin promotes at
    /// once with the default rights (owner 2026-10-19: "quick thing like remove and make admin").
    @ViewBuilder private var quickRows: some View {
        let rows = quickRowList
        if !rows.isEmpty {
            VStack(spacing: 0) {
                ForEach(rows.indices, id: \.self) { i in
                    if i > 0 { Divider().padding(.leading, 62) }
                    rows[i]
                }
            }
            .profileSurface(plain: card, radius: 16)
        }
    }

    private var quickRowList: [AnyView] {
        var rows: [AnyView] = []
        if makesAdmin {
            // Asked first (owner 2026-10-20): it hands them power over the group.
            rows.append(AnyView(iconRow("checkmark.shield", "Make Group Admin") { confirmPromote = true }))
        }
        // No Member Tag or Mute rows on the card (owner 2026-10-19).
        if mayEditRights && member.isAdmin {
            rows.append(AnyView(iconRow("slider.horizontal.3", "Edit Admin Rights") { growThenPush { showEdit = true } }))
        }
        // My own card: my own tag (owner 2026-10-20). The rules let the owner, and admins with
        // change info, tag themselves.
        if member.id == me && canEditRole {
            rows.append(AnyView(iconRow("tag", role == nil ? "Add My Tag" : "Edit My Tag") { growThenPush { showEdit = true } }))
        }
        if canTransfer {
            rows.append(AnyView(iconRow("crown", "Transfer Ownership") { confirmTransfer = true }))
        }
        if member.id != me {
            rows.append(AnyView(iconRow("info.circle", "Info") { openProfile() }))
        }
        if showsRemoveAdmin {
            rows.append(AnyView(iconRow("person.badge.minus", "Dismiss Admin", tint: .red) { confirmDismissAdmin = true }))
        }
        if canRemove {
            rows.append(AnyView(iconRow("minus.circle", "Remove from Group", tint: .red) { confirmRemove = true }))
        }
        return rows
    }

    private func iconRow(_ icon: String, _ title: String, tint: Color = .primary,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) { iconLabel(icon, title, tint: tint) }
            .buttonStyle(.plain)
            .disabled(busy)
    }

    private func iconLabel(_ icon: String, _ title: String, tint: Color) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 20)).frame(width: 28)
            Text(title).font(.body)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 18).padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var muteRow: some View {
        if isMuted {
            Button {
                run { try await ChatService.unmuteMember(cid: cid, uid: member.id, name: member.name) }
            } label: { iconLabel("speaker.wave.2", "Lift Restrictions", tint: .primary) }
            .buttonStyle(.plain)
            .disabled(busy)
        } else {
            Menu {
                Button("1 hour")  { mute(3600) }
                Button("1 day")   { mute(86400) }
                Button("1 week")  { mute(604800) }
                Button("Until I lift it") { mute(0) }
            } label: { iconLabel("speaker.slash", "Mute in This Group", tint: .primary) }
            .disabled(busy)
        }
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
            // Grow to full height FIRST, then push (owner 2026-10-20: the profile slid in while
            // the card was still short, and the card's empty bottom showed as a white band).
            growThenPush { showProfileHere = true }
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
    // The group itself, live (2026-10-20): roles and rights show the moment they change.
    @State private var live = LiveGroupDoc()
    private var conv: Conversation? { live.start(cid); return live.conv ?? repo.conversations.first { $0.id == cid } }
    // A member an admin kept from adding sees no Add (audit 2026-10-20; the rules refuse it).
    private var canAdd: Bool {
        guard let c = conv else { return false }
        return c.adminCan(me, .inviteUsers)
            || (c.membersCanAdd && !c.isRestricted(me, .addMembers, now: Date().timeIntervalSince1970 * 1000))
    }
    private var canInvite: Bool { conv?.adminCan(me, .inviteUsers) ?? false }

    private func name(_ uid: String) -> String { uid == me ? "You" : (conv?.names[uid] ?? "User") }

    /// Members matching the search, sorted by name (or admins first, then by name). Each member's
    /// name and rank worked out once, not on every comparison (2026-10-19 fix round).
    private func members(_ c: Conversation?) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let admins = Set(c?.admins ?? [])
        let owner = c?.createdBy
        let rows = (c?.users ?? []).compactMap { uid -> (uid: String, name: String, rank: Int)? in
            let n = uid == me ? "You" : (c?.names[uid] ?? "User")
            guard q.isEmpty || n.lowercased().contains(q)
                    || (c?.roles[uid]?.display.lowercased().contains(q) ?? false) else { return nil }
            let rank = owner == uid ? 0 : (admins.contains(uid) ? 1 : 2)
            return (uid: uid, name: n, rank: rank)
        }
        let byRank = adminsFirst
        return rows.sorted { a, b in
            if byRank && a.rank != b.rank { return a.rank < b.rank }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }.map(\.uid)
    }

    /// What the list depends on: the sections are built again only when one of these changes.
    private struct ListKey: Equatable {
        let users: [String]
        let admins: [String]
        let names: [String: String]
        let roles: [String: GroupRole]
        let owner: String
        let query: String
        let adminsFirst: Bool
    }
    private var listKey: ListKey {
        let c = conv
        return ListKey(users: c?.users ?? [], admins: c?.admins ?? [], names: c?.names ?? [:],
                       roles: c?.roles ?? [:], owner: c?.createdBy ?? "", query: query, adminsFirst: adminsFirst)
    }
    @State private var cachedSections: [(String, [String])] = []
    @State private var sectionsBuilt = false
    /// The letter a name files under: A–Z, everything else "#".
    private func letter(_ uid: String) -> String {
        guard let c = name(uid).folding(options: .diacriticInsensitive, locale: .current).first,
              c.isLetter, c.isASCII else { return "#" }
        return String(c).uppercased()
    }
    private func buildSections() -> [(String, [String])] {
        let list = members(conv)
        if adminsFirst { return [("", list)] }
        var out: [(String, [String])] = []
        for uid in list {
            let l = letter(uid)
            if let i = out.firstIndex(where: { $0.0 == l }) { out[i].1.append(uid) } else { out.append((l, [uid])) }
        }
        return out.sorted { a, b in a.0 == "#" ? false : (b.0 == "#" ? true : a.0 < b.0) }
    }

    var body: some View {
        let c = conv
        // The cache once it is built; built here only for the very first frame.
        let sections = sectionsBuilt ? cachedSections : buildSections()
        return NavigationStack {
            List {
                ForEach(sections, id: \.0) { sec in
                    Section {
                        ForEach(sec.1, id: \.self) { uid in
                            GroupMemberRow(conv: c, uid: uid, me: me) { opened = OpenedMember(id: uid) }
                                .equatable()
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
                GroupMemberSheet.make(cid: cid, conv: conv, me: me, uid: o.id,
                                      onRemoved: { ToastNotice.show("\($0) was removed from the group.") })
            }
            .sheet(isPresented: $showAdd) { AddMembersSheet(cid: cid, existing: Set(conv?.users ?? [])) }
            .navigationDestination(isPresented: $showInvite) {
                InviteLinkSheet(cid: cid, groupTitle: conv?.title ?? "Group", groupPhoto: conv?.avatarUrl,
                                initialCode: conv?.inviteCode ?? "", embedded: true)
            }
        }
        .onChange(of: listKey, initial: true) { _, _ in
            cachedSections = buildSections()
            sectionsBuilt = true
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
