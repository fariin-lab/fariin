import SwiftUI
import PhotosUI
import FirebaseFirestore

// Group info: avatar (admin can change) + name (admin can rename), member list with Admin
// badges, admin actions (add / remove / promote), and Leave. Live from ConversationsRepository.
struct GroupInfoView: View {
    let cid: String
    init(cid: String) { self.cid = cid }
    @Environment(\.dismiss) private var dismiss
    private var repo = ConversationsRepository.shared
    private var me: String { AuthService.shared.uid ?? "" }

    @State private var showRename = false
    @State private var newName = ""
    @State private var showDescEdit = false
    @State private var descText = ""
    @State private var showMute = false
    @State private var showDisappear = false
    @State private var avatarItem: PhotosPickerItem?
    @State private var showAdd = false
    @State private var memberAction: MemberAction?
    @State private var confirmLeave = false
    @State private var confirmClear = false
    @State private var confirmReport = false
    @State private var media: [Message] = []
    @State private var showAllMedia = false
    @State private var uploadingAvatar = false
    @State private var showCall = false
    @State private var pendingDisappear: Int?   // chosen timer awaiting the "for all members" confirm
    @State private var showInvite = false
    @State private var joinReqs: [JoinRequest] = []
    @State private var reqListener: ListenerRegistration?
    @State private var confirmDelete = false
    @State private var showGroupPhoto = false     // tap the poster → the same morph a person's photo uses
    @State private var posterRect: CGRect = .zero // poster photo's global square — the morph's start/end
    @State private var posterPhotoOK: Bool?       // did a real photo turn up behind the url? see useModernHeader
    @AppStorage(ProfileLayoutStyle.storageKey) private var profileLayout = ProfileLayoutStyle.modern.rawValue

    struct MemberAction: Identifiable { let id: String; let name: String; let isAdmin: Bool }

    private var conv: Conversation? { repo.conversations.first { $0.id == cid } }
    private var iAmAdmin: Bool { conv?.isAdmin(me) ?? false }
    private var iAmOwner: Bool { conv?.createdBy == me && !(conv?.createdBy.isEmpty ?? true) }
    // Per-flag admin right check (owner = all; legacy admin with no adminRights entry = all).
    private func can(_ r: Conversation.Right) -> Bool { conv?.adminCan(me, r) ?? false }
    // An admin with the matching right can; members can too when the group's permission toggle is on.
    private var canEditInfo: Bool { can(.changeInfo) || (conv?.membersCanEditInfo ?? false) }
    private var canAdd: Bool { can(.inviteUsers) || (conv?.membersCanAdd ?? false) }

    /// Same rule as a person's profile, including the second test: a NON-EMPTY url is not the same
    /// as a photo, and a stale one would leave a header of flat colour where a picture should be.
    /// `nil` means the poster has not looked yet and counts as yes, so nothing flips in the ordinary
    /// case. Groups with no photo at all keep the round avatar and its camera badge as they were.
    private var useModernHeader: Bool {
        ProfileLayoutStyle.resolved(profileLayout) == .modern
            && conv?.avatarUrl?.isEmpty == false
            && posterPhotoOK != false
    }

    var body: some View {
        Group {   // pushed from the chat header → uses the parent nav bar (no nested stack)
            groupBody
                .alert("Rename group", isPresented: $showRename) {
                    TextField("Group name", text: $newName)
                    Button("Save") { let t = newName; Task { try? await ChatService.renameGroup(cid: cid, title: t) } }
                    Button("Cancel", role: .cancel) {}
                }
                .alert("Group description", isPresented: $showDescEdit) {
                    TextField("Description", text: $descText)
                    Button("Save") { let t = descText; Task { try? await ChatService.setGroupDescription(cid: cid, text: t) } }
                    Button("Cancel", role: .cancel) {}
                }
                .confirmationDialog("Mute Notifications", isPresented: $showMute, titleVisibility: .visible) {
                    Button("Mute for 1 hour")  { Task { await ChatService.setMute(cid, until: ChatService.muteUntil(1)) } }
                    Button("Mute for 8 hours") { Task { await ChatService.setMute(cid, until: ChatService.muteUntil(8)) } }
                    Button("Mute for 1 week")  { Task { await ChatService.setMute(cid, until: ChatService.muteUntil(168)) } }
                    Button("Mute Always")      { Task { await ChatService.setMute(cid, until: ChatService.muteUntil(nil)) } }
                    Button("Unmute")           { Task { await ChatService.setMute(cid, until: 0) } }
                    Button("Cancel", role: .cancel) {}
                }
                .confirmationDialog("Disappearing Messages", isPresented: $showDisappear, titleVisibility: .visible) {
                    // Off is safe → applies directly; turning ON confirms first (deletes for everyone).
                    Button("Off")     { Task { await ChatService.setDisappear(cid, seconds: 0) } }
                    Button("1 Day")   { pendingDisappear = 86_400 }
                    Button("1 Week")  { pendingDisappear = 604_800 }
                    Button("Cancel", role: .cancel) {}
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

    // Split out so the body's modifier chain stays small enough for the type-checker.
    private var groupBody: some View {
        List {
            headerSection
            settingsSection
            if can(.inviteUsers) && !joinReqs.isEmpty { joinRequestsSection }
            mediaSection
            membersSection
            leaveSection
        }
        // Named so the poster can read its own offset and stretch on a rubber-band pull.
        .coordinateSpace(name: "groupScroll")
        .navigationTitle("Group Info")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        // Tap the poster → the same in-place morph a person's photo uses: it grows out of the header
        // and the drag-down flies back into it. An overlay, not a cover, so the page stays behind.
        .overlay {
            if showGroupPhoto {
                ProfilePhotoViewer(name: conv?.title ?? "Group", photoUrl: conv?.avatarUrl ?? "",
                                   sourceFrame: posterRect, poster: true,
                                   isPresented: $showGroupPhoto)
                    .ignoresSafeArea()
            }
        }
        .navigationBarBackButtonHidden(showGroupPhoto)
        .onAppear {
            guard reqListener == nil else { return }
            reqListener = GroupInviteService.joinRequests(cid: cid) { joinReqs = $0 }
        }
        .onDisappear { reqListener?.remove(); reqListener = nil }
        .sheet(isPresented: $showInvite) {
            InviteLinkSheet(cid: cid, groupTitle: conv?.title ?? "Group", groupPhoto: conv?.avatarUrl,
                            initialCode: conv?.inviteCode ?? "")
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $memberAction) { m in
            GroupMemberSheet(cid: cid, member: m, iAmAdmin: iAmAdmin, ownerUid: conv?.createdBy ?? "",
                             canManageAdmins: iAmOwner, canRestrict: can(.banUsers),
                             currentRights: conv?.adminRights[m.id], mutedUntil: conv?.restrictedUntil[m.id] ?? 0)
                .presentationDetents([.medium, .large])
        }
        .confirmationDialog("Leave this group?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave", role: .destructive) {
                Task { try? await ChatService.leaveGroup(cid: cid); await MainActor.run { dismiss() } }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showAdd) {
            AddMembersSheet(cid: cid, existing: Set(conv?.users ?? []))
        }
        .onChange(of: avatarItem) { _, item in
            guard let item else { return }
            Task {
                await MainActor.run { uploadingAvatar = true }
                if let d = try? await item.loadTransferable(type: Data.self) {
                    try? await ChatService.uploadGroupAvatar(cid: cid, data: d)
                }
                // Reset so re-picking (even the same photo) fires onChange again (WallpaperPickerSheet pattern).
                await MainActor.run { uploadingAvatar = false; avatarItem = nil }
            }
        }
        // Local first (offline + instant), then the server; a failed load leaves what we have rather
        // than emptying the section — see ContactInfoView.load for the whole story.
        .task {
            if let local = ThreadMessageCache.shared.messages(for: cid) {
                let localMedia = local
                    .filter { $0.isImage || $0.isVideo || $0.isAlbum }
                    .flatMap { $0.expandedGalleryItems(cid: cid) }
                    .reversed()
                if !localMedia.isEmpty { media = Array(localMedia) }
            }
            if let fresh = await ChatService.sharedMedia(cid) { media = fresh }
        }
        // MediaGalleryView, like the 1:1 profile (audit): SharedMediaGridView renders only items with
        // an imageUrl, so group VIDEOS vanished from the grid entirely, and any that were reachable
        // opened in the image viewer — the endless-spinner routing already fixed on the profile page.
        .sheet(isPresented: $showAllMedia) {
            NavigationStack {
                MediaGalleryView(cid: cid, title: conv?.title ?? "Group", photoUrl: conv?.avatarUrl)
            }
        }
        .fullScreenCover(isPresented: $showCall) { GroupCallView() }
    }

    @ViewBuilder private var headerSection: some View {
        if useModernHeader {
            Section {
                groupPoster
                    // Edge to edge: the row's own insets would frame the photo like a card.
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        } else {
            classicHeaderSection
        }
    }

    private var groupPoster: some View {
        ProfilePosterHeader(
            name: conv?.title ?? "Group",
            photoUrl: conv?.avatarUrl,
            scrollSpace: "groupScroll",
            onPhotoRect: { posterRect = $0 },
            onTap: { showGroupPhoto = true },
            // Nothing behind the url → fall back to the circle rather than show a slab of colour.
            onPhotoResolved: { posterPhotoOK = $0 },
            photoHidden: showGroupPhoto,
            // This page is a List, and a List clips its rows. Running the photo up under the bars
            // the way a person's profile does would have it sliced off at the row's top edge, so
            // here it starts below them. Everything else — the square, the wash, the join into the
            // page — is the same header.
            bleedUnderBars: false,
            edgeBleed: 0,
            caption: { groupCaption($0) },
            actions: { groupGlassActions }
        )
    }

    /// Name, member count and description, over the photo. Same content the round header showed,
    /// including the admin's "add a description" prompt — nothing moved into a menu.
    private func groupCaption(_ text: Color) -> some View {
        VStack(spacing: 3) {
            Text(conv?.title ?? "Group").font(.title.weight(.bold)).foregroundStyle(text)
                .lineLimit(2).multilineTextAlignment(.center)
            Text(conv?.memberCountLabel ?? " ").font(.subheadline).foregroundStyle(text.opacity(0.82))
                .frame(minHeight: 20)
            if let d = conv?.groupDescription, !d.isEmpty {
                Text(d).font(.footnote).foregroundStyle(text.opacity(0.82))
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
                    .onTapGesture { if canEditInfo { descText = d; showDescEdit = true } }
            } else if canEditInfo {
                Button("Add group description…") { descText = ""; showDescEdit = true }
                    .font(.footnote).foregroundStyle(text.opacity(0.82))
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The group's three actions as circles, plus the photo picker for anyone allowed to change it.
    /// The camera used to be a badge on the corner of the round avatar; a poster has no corner to
    /// hang it on, so it becomes a peer of the others rather than a new place to hunt for.
    private var groupGlassActions: some View {
        HStack(spacing: 0) {
            Button { startCall(video: false) } label: { PosterActionIcon(icon: "phone.fill") }.tint(.primary)
            Button { startCall(video: true) } label: { PosterActionIcon(icon: "video.fill") }.tint(.primary)
            Button { showMute = true } label: { PosterActionIcon(icon: "ic_bell_off") }.tint(.primary)
            if canEditInfo {
                PhotosPicker(selection: $avatarItem, matching: .images) {
                    ZStack {
                        PosterActionIcon(icon: "camera.fill").opacity(uploadingAvatar ? 0.35 : 1)
                        if uploadingAvatar { ProgressView() }
                    }
                }
                .buttonStyle(.plain)
                .disabled(uploadingAvatar)
            }
        }
    }

    private var classicHeaderSection: some View {
        Section {
            VStack(spacing: 10) {
                if canEditInfo {
                    PhotosPicker(selection: $avatarItem, matching: .images) {
                        ZStack(alignment: .bottomTrailing) {
                            AvatarView(name: conv?.title ?? "Group", photoUrl: conv?.avatarUrl, size: 88)
                                .overlay { if uploadingAvatar {
                                    ZStack { Circle().fill(.black.opacity(0.35)); ProgressView().tint(.white) }
                                } }
                            Image(systemName: "camera.circle.fill")
                                .font(.system(size: 26)).symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(uploadingAvatar)
                } else {
                    AvatarView(name: conv?.title ?? "Group", photoUrl: conv?.avatarUrl, size: 88)
                }
                Text(conv?.title ?? "Group").font(.title2.weight(.bold))
                Text(conv?.memberCountLabel ?? "").font(.subheadline).foregroundStyle(.secondary)
                // Description (tap to add/edit if admin) — like standard group info.
                if let d = conv?.groupDescription, !d.isEmpty {
                    Text(d).font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .onTapGesture { if canEditInfo { descText = d; showDescEdit = true } }
                } else if canEditInfo {
                    Button("Add group description…") { descText = ""; showDescEdit = true }
                        .font(.footnote)
                }
                // The SAME row the poster shows, for the same reason a person's no-photo profile
                // uses it: labelled pills here and glass circles there is two designs in one app.
                groupGlassActions
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
        }
    }

    private func startCall(video: Bool) {
        Task { await GroupCallService.shared.start(cid: cid, title: conv?.title ?? "Group", video: video) }
        showCall = true
    }

    // Colored icon chip for list rows (premium look vs plain SF Symbols).
    private func chip(_ icon: String, _ color: Color) -> some View {
        Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 29, height: 29)
            .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var joinRequestsSection: some View {
        Section("Join requests (\(joinReqs.count))") {
            ForEach(joinReqs) { r in
                HStack(spacing: 12) {
                    AvatarView(name: r.name, photoUrl: r.photo, size: 34)
                    Text(r.name).foregroundStyle(.primary).lineLimit(1)
                    Spacer(minLength: 8)
                    Button { Task { try? await GroupInviteService.approveJoin(cid: cid, uid: r.uid) } } label: {
                        Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.green)
                    }.buttonStyle(.plain)
                    Button { Task { try? await GroupInviteService.denyJoin(cid: cid, uid: r.uid) } } label: {
                        Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.red)
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private var membersSection: some View {
        Section(conv?.memberCountLabel.capitalized ?? "Members") {
            if canAdd {
                Button { showAdd = true } label: { rowLabel("person.badge.plus", "Add Members", .blue) }
                Button { showInvite = true } label: { rowLabel("link", "Invite via Link", .teal) }
            }
            ForEach(sortedMembers, id: \.self) { uid in memberRow(uid) }
        }
    }

    private var settingsSection: some View {
        Section {
            Button { showMute = true } label: { rowLabel("bell.slash.fill", "Mute Notifications", .gray) }
            // Disappearing messages is a group-wide setting → needs the Change-info right to edit.
            if can(.changeInfo) {
                Button { showDisappear = true } label: {
                    HStack {
                        rowLabel("timer", "Disappearing Messages", .orange)
                        Spacer()
                        Text(disappearLabel).foregroundStyle(.secondary)
                    }
                }
            } else if (conv?.disappearSeconds ?? 0) > 0 {
                HStack {
                    rowLabel("timer", "Disappearing Messages", .orange)
                    Spacer()
                    Text(disappearLabel).foregroundStyle(.secondary)
                }
            }
            // Announcement mode + who-can-do-what: group governance → needs the Change-info right.
            if can(.changeInfo) {
                Toggle(isOn: Binding(
                    get: { conv?.onlyAdminsSend ?? false },
                    set: { v in Task { try? await ChatService.setOnlyAdminsSend(cid: cid, v) } }
                )) { rowLabel("megaphone.fill", "Only admins can send", .pink) }
                Toggle(isOn: Binding(
                    get: { conv?.membersCanAdd ?? false },
                    set: { v in Task { try? await ChatService.setGroupPermission(cid: cid, key: "membersCanAdd", v) } }
                )) { rowLabel("person.badge.plus", "Members can add others", .green) }
                Toggle(isOn: Binding(
                    get: { conv?.membersCanEditInfo ?? false },
                    set: { v in Task { try? await ChatService.setGroupPermission(cid: cid, key: "membersCanEditInfo", v) } }
                )) { rowLabel("pencil", "Members can edit group info", .purple) }
            }
        }
    }

    // A list row: colored icon chip + label (premium look).
    private func rowLabel(_ icon: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 12) {
            chip(icon, color)
            Text(text).foregroundStyle(.primary)
        }
    }

    private var disappearLabel: String {
        switch conv?.disappearSeconds ?? 0 {
        case 86_400:  return "1 day"
        case 604_800: return "1 week"
        default:      return "Off"
        }
    }

    @ViewBuilder private var mediaSection: some View {
        if !media.isEmpty {
            Section("Media") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(media.prefix(12)) { m in
                            // Videos carry thumbUrl/thumbEnc (no imageUrl) — they were invisible here.
                            if let url = m.imageUrl ?? m.thumbUrl {
                                SecureImageView(imageUrl: url, enc: m.imageUrl != nil ? m.enc : m.thumbEnc, cid: cid)
                                    .frame(width: 84, height: 84)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                }
                Button("See All") { showAllMedia = true }.tint(.primary)
            }
        }
    }

    private var leaveSection: some View {
        Section {
            Button(role: .destructive) { confirmClear = true } label: {
                HStack(spacing: 12) { chip("trash.fill", .red); Text("Clear Chat").foregroundStyle(.red) }
            }
            Button(role: .destructive) { confirmLeave = true } label: {
                HStack(spacing: 12) { chip("rectangle.portrait.and.arrow.right.fill", .red); Text("Leave Group").foregroundStyle(.red) }
            }
            Button(role: .destructive) { confirmReport = true } label: {
                HStack(spacing: 12) { chip("exclamationmark.bubble.fill", .red); Text("Report Group").foregroundStyle(.red) }
            }
            // Only the owner can permanently delete the whole group (for everyone).
            if iAmOwner {
                Button(role: .destructive) { confirmDelete = true } label: {
                    HStack(spacing: 12) { chip("trash.slash.fill", .red); Text("Delete Group").foregroundStyle(.red) }
                }
            }
        } footer: {
            if let label = createdByLabel {
                Text(label).frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.top, 6)
            }
        }
        .confirmationDialog("Clear this chat?", isPresented: $confirmClear, titleVisibility: .visible) {
            // Local clear (hides history for ME only) — NOT a global delete of my messages.
            Button("Clear Chat", role: .destructive) { Task { await ChatService.deleteForMe(cid) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This clears the chat from your device only.") }
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
            Button("Delete Group", role: .destructive) {
                Task { try? await GroupInviteService.deleteGroup(cid: cid); await MainActor.run { dismiss() } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This permanently deletes the group and all its messages for everyone. This cannot be undone.") }
    }

    // "Created by you · 26 Jun 2026" footer, like the reference group screens.
    private var createdByLabel: String? {
        guard let conv, conv.isGroup, !conv.createdBy.isEmpty else { return nil }
        let who = conv.createdBy == me ? "you" : (conv.names[conv.createdBy] ?? "someone")
        guard let d = conv.createdAt else { return "Created by \(who)" }
        let f = DateFormatter(); f.dateStyle = .medium
        return "Created by \(who) · \(f.string(from: d))"
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if canEditInfo {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { newName = conv?.title ?? ""; showRename = true }
            }
        }
    }


    private var sortedMembers: [String] {
        (conv?.users ?? []).sorted { a, b in
            if a == me { return true }
            if b == me { return false }
            let aAdmin = conv?.isAdmin(a) ?? false, bAdmin = conv?.isAdmin(b) ?? false
            if aAdmin != bAdmin { return aAdmin }
            return name(a).lowercased() < name(b).lowercased()
        }
    }

    private func name(_ uid: String) -> String {
        uid == me ? "You" : (conv?.names[uid] ?? "User")
    }

    @ViewBuilder private func memberRow(_ uid: String) -> some View {
        let isAdmin = conv?.isAdmin(uid) ?? false
        // Anyone can tap a member to view their profile; the sheet gates admin actions.
        Button {
            memberAction = MemberAction(id: uid, name: conv?.names[uid] ?? "User", isAdmin: isAdmin)
        } label: {
            HStack(spacing: 12) {
                AvatarView(name: name(uid), photoUrl: conv?.photos[uid], size: 40)
                Text(name(uid)).foregroundStyle(.primary)
                Spacer()
                if isAdmin { Text("Admin").font(.caption).foregroundStyle(.secondary) }
            }
        }
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
            .filter { !$0.isGroup && !$0.isCleared(me) }
            .compactMap { c in
                let u = c.otherUid(me)
                guard !u.isEmpty, !existing.contains(u) else { return nil }
                return (u, c.name(for: me), c.photoUrl(for: me))
            }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    var body: some View {
        NavigationStack {
            List {
                if !query.isEmpty {
                    let found = results.filter { $0.id != me && !existing.contains($0.id) }
                    if found.isEmpty { Text("No users found.").foregroundStyle(.secondary) }
                    ForEach(found) { p in
                        memberPickRow(p.id, p.name.isEmpty ? p.handle : p.name, p.photoUrl)
                    }
                } else {
                    if candidates.isEmpty {
                        Text("Search by name or username to add anyone.").foregroundStyle(.secondary)
                    }
                    ForEach(candidates, id: \.id) { p in memberPickRow(p.id, p.name, p.photo) }
                }
            }
            .searchable(text: $query, prompt: "Name or username")
            .onChange(of: query) { _, q in search(q) }
            .navigationTitle("Add Members")
            .navigationBarTitleDisplayMode(.inline)
            .overlay { if adding { ProgressView().padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)) } }
            .alert("Couldn't add members", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
            .alert("Members added", isPresented: Binding(get: { noticeText != nil }, set: { if !$0 { noticeText = nil } })) {
                Button("OK") { dismiss() }
            } message: { Text(noticeText ?? "") }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add") {
                        let ids = Array(selected)
                        adding = true
                        Task {
                            do {
                                let keyless = try await ChatService.addGroupMembers(cid: cid, add: ids)
                                await MainActor.run {
                                    if keyless.isEmpty { dismiss() }
                                    else {
                                        noticeText = "\(keyless.joined(separator: ", ")) hasn't opened Kulan yet — they'll see messages once they do."
                                        adding = false
                                    }
                                }
                            } catch {
                                let msg = error.localizedDescription
                                await MainActor.run { errorText = msg; adding = false }
                            }
                        }
                    }
                    .disabled(selected.isEmpty || adding).fontWeight(.semibold)
                }
            }
        }
    }

    @ViewBuilder private func memberPickRow(_ id: String, _ name: String, _ photo: String?) -> some View {
        Button { toggle(id) } label: {
            HStack(spacing: 12) {
                AvatarView(name: name, photoUrl: photo, size: 40)
                Text(name).foregroundStyle(.primary)
                Spacer()
                Image(systemName: selected.contains(id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected.contains(id) ? Color.accentColor : .secondary)
            }
        }
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
    @Environment(\.dismiss) private var dismiss
    @State private var profile: UserProfile?
    @State private var confirmRemove = false
    @State private var rights: Set<String> = []
    @State private var rightsLoaded = false
    private var me: String { AuthService.shared.uid ?? "" }
    private var isOwner: Bool { member.id == ownerUid }
    private var iAmOwner: Bool { ownerUid == me }
    private var isMuted: Bool { mutedUntil > Date().timeIntervalSince1970 * 1000 }

    private func mute(_ seconds: Double) {
        Task { try? await ChatService.muteMember(cid: cid, uid: member.id, name: member.name, seconds: seconds); dismiss() }
    }

    /// Their audience map, applied the same way ContactInfoView applies it. Sharing a group is not
    /// the same as being a contact, so the "My Friends" test is the real message-history one.
    private var gatedMemberPhoto: String? {
        guard let p = profile else { return nil }
        return PrivacyPrefs.allows(p.privacy, "photo",
                                   contactOfMine: PrivacyPrefs.isContact(member.id)) ? p.photoUrl : nil
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
                        Text(member.name).font(.title2.weight(.bold))
                        if let h = profile?.handle, !h.isEmpty {
                            Text("@\(h)").font(.subheadline).foregroundStyle(.secondary)
                        }
        if isOwner || member.isAdmin {
                            Text(isOwner ? "Owner" : "Admin").font(.caption.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                        if let a = gatedMemberAbout, !a.isEmpty {
                            Text(a).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                // Anyone can message a fellow member (opens/creates the 1:1).
                if member.id != me {
                    Section {
                        Button {
                            AppRouter.shared.pendingChatName = member.name
                            AppRouter.shared.pendingChatPhoto = profile?.photoUrl
                            AppRouter.shared.pendingChatId = ChatService.convId(me, member.id)
                            dismiss()
                        } label: { Label("Message", systemImage: "message") }
                    }
                }
                // The owner is protected: no admin can demote or remove them. Promote/demote needs the
                // Add-admins right; removing a member needs the Restrict-members right.
                if member.id != me && !isOwner && (canManageAdmins || canRestrict) {
                    Section {
                        if canManageAdmins {
                            if member.isAdmin {
                                Button("Remove as Admin") {
                                    Task { try? await ChatService.demoteGroupAdmin(cid: cid, uid: member.id, name: member.name); dismiss() }
                                }
                            } else {
                                Button("Make Admin") {
                                    Task { try? await ChatService.promoteGroupAdmin(cid: cid, uid: member.id, name: member.name); dismiss() }
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
                                Task { try? await ChatService.unmuteMember(cid: cid, uid: member.id, name: member.name); dismiss() }
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
                    Task { try? await ChatService.removeGroupMember(cid: cid, uid: member.id, name: member.name); dismiss() }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}
