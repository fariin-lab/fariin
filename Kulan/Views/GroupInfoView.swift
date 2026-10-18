import SwiftUI
import FirebaseFirestore

// ⛔ GROUP INFO, IN THE PERSON PROFILE'S DESIGN — owner 2026-10-18: "make it exactly the design the
// user profile is using". The 1:1 page's own pieces (`ProfileInfoRow`, `ProfileMediaCard`,
// `PosterActionIcon`, `profileSurface`) on the same grey page: the ROUND photo always (never the big
// photo header; that is a person's), name and member count, the round actions, the description as an
// About card (the Fariin official chat's), one settings card, All Media, the members, and the red
// card. Who-can-do-what, admins, the member list and invites live on Group Settings
// (`GroupSettingsView`), not here. Edit changes the name and the photo (`EditGroupView`).
struct GroupInfoView: View {
    let cid: String
    /// The chat's search, opened from the round Search action (the profile's own wiring).
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
    @State private var showSounds = false
    @State private var showSettings = false
    @State private var showEdit = false
    @State private var showGroupPhoto = false    // tap the photo → the same morph a person's photo uses
    @State private var photoCloseTick = 0        // toolbar X → viewer close (see ProfilePhotoViewer.closeSignal)
    @State private var avatarFrame: CGRect = .zero
    @State private var memberQuery = ""
    @State private var searchingMembers = false

    struct MemberAction: Identifiable { let id: String; let name: String; let isAdmin: Bool }

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

    var body: some View {
        page
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .navigationBarBackButtonHidden(showGroupPhoto)
            .overlay {
                if showGroupPhoto {
                    ProfilePhotoViewer(name: title, photoUrl: conv?.avatarUrl ?? "",
                                       sourceFrame: avatarFrame, poster: false,
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
            .sheet(isPresented: $showInvite) {
                InviteLinkSheet(cid: cid, groupTitle: title, groupPhoto: conv?.avatarUrl,
                                initialCode: conv?.inviteCode ?? "")
                    .presentationDetents([.medium, .large])
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

    private var page: some View {
        ScrollView {
            VStack(spacing: 20) { AnyView(sections) }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
    }

    @ViewBuilder private var sections: some View {
        hero
        actionsRow
        if showsAbout { aboutCard.padding(.top, 8) }
        settingsCard.padding(.top, 8)
        if !media.isEmpty {
            ProfileMediaCard(cid: cid, media: media, cardColor: cardColor,
                             onOpen: { m in if m.isVideo { viewerVideo = m } else { viewerImage = m } },
                             onSeeAll: { showAllMedia = true })
                .padding(.top, 8)
        }
        membersBlock.padding(.top, 12)
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
            Text(title).font(.title.weight(.bold))
                .lineLimit(2).multilineTextAlignment(.center)
            Text(conv?.memberCountLabel ?? " ")
                .font(.body).foregroundStyle(.secondary)
                .frame(minHeight: 22)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    /// The profile's five round actions: add a member, video call, mute, search, more.
    private var actionsRow: some View {
        HStack(spacing: 0) {
            if canAdd {
                Button { showAdd = true } label: { PosterActionIcon(icon: "person.badge.plus", onPhoto: false) }
                    .tint(.primary)
                    .accessibilityLabel("Add Members")
            }
            if mayCall {
                Button { startCall(video: true) } label: { PosterActionIcon(icon: "video.fill", onPhoto: false) }
                    .tint(.primary)
                    .accessibilityLabel("Video call")
            }
            Menu { muteMenuItems } label: {
                PosterActionIcon(icon: muted ? "ic_bell" : "ic_bell_off", onPhoto: false)
            }
            .tint(.primary)
            .accessibilityLabel(muted ? "Unmute" : "Mute")
            if let onSearch {
                Button { onSearch() } label: { PosterActionIcon(icon: "magnifyingglass", onPhoto: false) }
                    .tint(.primary)
                    .accessibilityLabel("Search")
            }
            Menu { moreMenuItems } label: { PosterActionIcon(icon: "ellipsis", onPhoto: false) }
                .tint(.primary)
                .accessibilityLabel("More")
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

    /// The ••• menu, the profile's: housekeeping only. Leave / Report / Delete are on the red card.
    @ViewBuilder private var moreMenuItems: some View {
        if mayCall {
            Button { startCall(video: false) } label: { Label("Voice Call", systemImage: "phone") }
        }
        // owner 2026-10-18: the group's wallpaper is everyone's, so only someone who may change
        // group info sees this (same test as the name and photo; firestore.rules says the same).
        if canEditInfo {
            Button { changeWallpaper() } label: {
                Label { Text("Change Wallpaper") } icon: { MenuIcon("ic_wallpaper") }
            }
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

    // MARK: Cards

    private var desc: String { conv?.groupDescription ?? "" }
    private var showsAbout: Bool { !desc.isEmpty || canEditInfo }

    /// The description, as the Fariin official chat's About card. Tap to edit, for whoever may.
    private var aboutCard: some View {
        ProfileAboutContent(text: desc.isEmpty ? "Add a group description" : desc, placeholder: desc.isEmpty)
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
                if can(.changeInfo) { showDisappear = true }
            }
            rowDivider
            ProfileInfoRow(title: "Sounds & Notifications", icon: "ic_notifications",
                           value: muted ? "Muted" : "On") { showSounds = true }
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

    private var rowDivider: some View { Divider().padding(.leading, 56) }

    private var disappearLabel: String {
        let s = conv?.disappearSeconds ?? 0
        return s == 0 ? "Off" : ChatService.disappearShortLabel(s)
    }

    // MARK: Members

    private var membersBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(conv?.memberCountLabel.capitalized ?? "Members").font(.headline)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { searchingMembers.toggle() }
                    if !searchingMembers { memberQuery = "" }
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
            ForEach(Array(shownMembers.enumerated()), id: \.element) { i, uid in
                if i > 0 || (canAdd && memberQuery.isEmpty) { rowDivider }
                GroupMemberRow(conv: conv, uid: uid, me: me) {
                    memberAction = MemberAction(id: uid, name: conv?.names[uid] ?? "User",
                                                isAdmin: conv?.isAdmin(uid) ?? false)
                }
            }
        }
        .profileSurface(plain: cardColor)
    }

    private var shownMembers: [String] {
        let all = GroupMembers.sorted(conv, me: me)
        let q = memberQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { (conv?.names[$0] ?? "").lowercased().contains(q) }
    }

    private func memberSheet(_ m: MemberAction) -> some View {
        GroupMemberSheet.make(cid: cid, conv: conv, me: me, uid: m.id)
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
    private var createdByLabel: String? {
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
        } else if canEditInfo {
            ToolbarItem(placement: .topBarTrailing) { Button("Edit") { showEdit = true } }
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

/// One member: photo, name, their label under it (Member Label), and Owner / Admin on the right.
struct GroupMemberRow: View {
    let conv: Conversation?
    let uid: String
    let me: String
    let onTap: () -> Void

    private var name: String { uid == me ? "You" : (conv?.names[uid] ?? "User") }
    private var role: String? {
        if let c = conv, !c.createdBy.isEmpty, c.createdBy == uid { return "Owner" }
        return (conv?.isAdmin(uid) ?? false) ? "Admin" : nil
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                AvatarView(name: name, photoUrl: conv?.photos[uid], size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(name).foregroundStyle(.primary).lineLimit(1)
                        VerifiedMark(uid: uid, size: 13)
                    }
                    if let label = conv?.memberLabels[uid], !label.isEmpty {
                        MemberLabelChip(text: label)
                    }
                }
                Spacer(minLength: 8)
                if let role { Text(role).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A member's label: one line in the accent colour on a pale capsule (owner's mockup).
struct MemberLabelChip: View {
    let text: String
    var body: some View {
        Text(text)
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
            .confirmationDialog("Leave this group?", isPresented: $confirmLeave, titleVisibility: .visible) {
                Button("Leave", role: .destructive) { run { try await ChatService.leaveGroup(cid: cid) } }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Report this group?", isPresented: $confirmReport, titleVisibility: .visible) {
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
            .confirmationDialog("Delete this group?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Group", role: .destructive) { run { try await GroupInviteService.deleteGroup(cid: cid) } }
                Button("Cancel", role: .cancel) {}
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
    var canManageAdmins: Bool = false      // I'm the owner → can promote/demote + set admin rights
    var canRestrict: Bool = false          // I hold the Restrict-members right → can remove/mute
    var currentRights: [String]? = nil      // this admin's granted rights (nil = all/legacy)
    var mutedUntil: Double = 0              // ms; > now = currently restricted
    var label: String = ""                  // their Member Label ("" = none)
    var canEditLabel: Bool = false          // it is me, or I hold the change-info right
    @State private var showLabelEdit = false
    @State private var labelText = ""
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

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 10) {
                        // Honor THEIR audience settings, like the 1:1 profile does (audit): this
                        // sheet showed a member's photo and bio to every fellow group member even
                        // when they had set those to "No One" / "My Friends".
                        AvatarView(name: member.name, photoUrl: gatedMemberPhoto, size: 88)
                        HStack(spacing: 6) {
                            Text(member.name).font(.title2.weight(.bold))
                            // A member card is a profile, so the mark explains itself here too.
                            VerifiedMark(uid: member.id, size: 17, explains: true)
                        }
                        if let h = profile?.handle, !h.isEmpty {
                            Text("@\(h)").font(.subheadline).foregroundStyle(.secondary)
                        }
        if isOwner || member.isAdmin {
                            Text(isOwner ? "Owner" : "Admin").font(.caption.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                        if !label.isEmpty { MemberLabelChip(text: label) }
                        if let a = gatedMemberAbout, !a.isEmpty {
                            Text(a).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                // ⛔ MEMBER LABEL — owner 2026-10-18. Mine to set, or anyone's with change-info.
                if canEditLabel {
                    Section {
                        Button { labelText = label; showLabelEdit = true } label: {
                            Label(label.isEmpty ? "Add Member Label" : "Edit Member Label", systemImage: "tag")
                        }
                    } footer: {
                        Text("A short label shown under \(member.id == me ? "your" : "their") name in this group.")
                    }
                }
                // Anyone can message a fellow member (opens/creates the 1:1).
                if member.id != me {
                    Section {
                        Button {
                            AppRouter.shared.pendingChatName = member.name
                            AppRouter.shared.pendingChatPhoto = profile?.photoUrl
                            AppRouter.shared.pendingChatId = ChatService.convId(me, member.id)
                            // 2026-09-24 audit: create the chat the way every other entry point does.
                            let other = member.id
                            Task { await ChatService.openConversation(uid: other) }
                            dismiss()
                        } label: { Label("Message", systemImage: "message") }
                    }
                    // 2026-09-24 fix-all #124: Block and Report on the member card, the way the
                    // person's own profile always shows them (ContactInfoView's `dangerCard`: "a user
                    // who feels unsafe must see the way out"). Same glyphs, same confirms, same
                    // `ChatService` calls. The block goes on our 1:1 id (the account block list covers
                    // a chat that does not exist yet); the report names THIS group as where it happened.
                    Section {
                        if memberBlocked {
                            Button {
                                memberBlocked = false
                                let other = member.id
                                Task { await ChatService.setBlocked(ChatService.convId(me, other), false) }
                            } label: {
                                Label { Text("Unblock \(member.name)") } icon: { Image(systemName: "checkmark.circle") }
                            }
                        } else {
                            Button(role: .destructive) { showBlock = true } label: {
                                Label { Text("Block \(member.name)") } icon: { Image("ic_block").renderingMode(.template) }
                            }
                        }
                        Button(role: .destructive) { showReport = true } label: {
                            Label { Text("Report \(member.name)") } icon: { Image("ic_report").renderingMode(.template) }
                        }
                    }
                }
                // The owner is protected: no admin can demote or remove them. Promote/demote needs the
                // Add-admins right; removing a member needs the Restrict-members right.
                if member.id != me && !isOwner && (canManageAdmins || canRestrict) {
                    Section {
                        if canManageAdmins {
                            if member.isAdmin {
                                Button("Remove as Admin") {
                                    run { try await ChatService.demoteGroupAdmin(cid: cid, uid: member.id, name: member.name) }
                                }
                            } else {
                                Button("Make Admin") {
                                    run { try await ChatService.promoteGroupAdmin(cid: cid, uid: member.id, name: member.name) }
                                }
                            }
                        }
                        if canRestrict {
                            Button("Remove from Group", role: .destructive) { confirmRemove = true }
                        }
                    }
                }
                // Per-flag admin permissions — owner-only, for an admin who isn't the owner.
                if iAmOwner && member.isAdmin && !isOwner && member.id != me {
                    Section("Admin permissions") {
                        ForEach(Conversation.Right.allCases) { r in
                            Toggle(r.label, isOn: Binding(
                                get: { rights.contains(r.rawValue) },
                                set: { on in
                                    if on { rights.insert(r.rawValue) } else { rights.remove(r.rawValue) }
                                    let list = Array(rights)
                                    Task { try? await ChatService.setAdminRights(cid: cid, uid: member.id, rights: list) }
                                }))
                        }
                    }
                }
                // Restrictions — an admin with the Restrict right can mute a regular member (auto-expiring).
                if canRestrict && !member.isAdmin && !isOwner && member.id != me {
                    Section("Restrictions") {
                        if isMuted {
                            Button("Lift restrictions") {
                                run { try await ChatService.unmuteMember(cid: cid, uid: member.id, name: member.name) }
                            }
                        } else {
                            Menu {
                                Button("1 hour")  { mute(3600) }
                                Button("1 day")   { mute(86400) }
                                Button("1 week")  { mute(604800) }
                                Button("Forever") { mute(0) }
                            } label: { Label("Mute (can't send)", systemImage: "speaker.slash") }
                        }
                    }
                }
            }
            .navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task { profile = await ProfileStore.shared.fetch(member.id) }
            .onAppear {
                guard !rightsLoaded else { return }
                rightsLoaded = true
                rights = currentRights.map(Set.init) ?? Set(Conversation.Right.allCases.map(\.rawValue))
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
            .alert("Member Label", isPresented: $showLabelEdit) {
                TextField("Label", text: $labelText)
                Button("Save") {
                    let t = labelText, who = member.id
                    run { try await ChatService.setMemberLabel(cid: cid, uid: who, t) }
                }
                if !label.isEmpty {
                    Button("Remove", role: .destructive) {
                        let who = member.id
                        run { try await ChatService.setMemberLabel(cid: cid, uid: who, "") }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Up to \(ChatService.memberLabelMax) characters.") }
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
