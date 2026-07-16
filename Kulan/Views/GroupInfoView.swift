import SwiftUI
import PhotosUI

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

    struct MemberAction: Identifiable { let id: String; let name: String; let isAdmin: Bool }

    private var conv: Conversation? { repo.conversations.first { $0.id == cid } }
    private var iAmAdmin: Bool { conv?.isAdmin(me) ?? false }
    // Admins always can; members can too when the matching permission toggle is on.
    private var canEditInfo: Bool { iAmAdmin || (conv?.membersCanEditInfo ?? false) }
    private var canAdd: Bool { iAmAdmin || (conv?.membersCanAdd ?? false) }

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
            mediaSection
            membersSection
            leaveSection
        }
        .navigationTitle("Group Info")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sheet(item: $memberAction) { m in
            GroupMemberSheet(cid: cid, member: m, iAmAdmin: iAmAdmin, ownerUid: conv?.createdBy ?? "",
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
        .task { media = await ChatService.sharedMedia(cid) }
        .sheet(isPresented: $showAllMedia) { SharedMediaGridView(cid: cid, media: media) }
        .fullScreenCover(isPresented: $showCall) { GroupCallView() }
    }

    private var headerSection: some View {
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
                // Same clean action row as the user profile (icon-in-pill + caption below).
                HStack(spacing: 10) {
                    groupAction("video.fill", "Video") { startCall(video: true) }
                    groupAction("phone.fill", "Voice") { startCall(video: false) }
                    groupAction("bell.slash.fill", "Mute") { showMute = true }
                }
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
        }
    }

    // Matches ContactInfoView.tileLabel — icon in a pill, caption below, neutral color.
    private func groupAction(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                Text(label).font(.caption).foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
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

    private var membersSection: some View {
        Section(conv?.memberCountLabel.capitalized ?? "Members") {
            if canAdd {
                Button { showAdd = true } label: { rowLabel("person.badge.plus", "Add Members", .blue) }
            }
            ForEach(sortedMembers, id: \.self) { uid in memberRow(uid) }
        }
    }

    private var settingsSection: some View {
        Section {
            Button { showMute = true } label: { rowLabel("bell.slash.fill", "Mute Notifications", .gray) }
            // Disappearing messages is a group-wide setting → admin-only to change.
            if iAmAdmin {
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
            // Announcement mode (admin): only admins can send. Enforced in the message rules.
            if iAmAdmin {
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

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 10) {
                        AvatarView(name: member.name, photoUrl: profile?.photoUrl, size: 88)
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
                        if let a = profile?.about, !a.isEmpty {
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
                // The owner is protected: no admin can demote or remove them.
                if iAmAdmin && member.id != me && !isOwner {
                    Section {
                        if member.isAdmin {
                            Button("Remove as Admin") {
                                Task { try? await ChatService.demoteGroupAdmin(cid: cid, uid: member.id, name: member.name); dismiss() }
                            }
                        } else {
                            Button("Make Admin") {
                                Task { try? await ChatService.promoteGroupAdmin(cid: cid, uid: member.id, name: member.name); dismiss() }
                            }
                        }
                        Button("Remove from Group", role: .destructive) { confirmRemove = true }
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
                // Restrictions — any admin can mute a regular member with an auto-expiring timeout.
                if iAmAdmin && !member.isAdmin && !isOwner && member.id != me {
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
