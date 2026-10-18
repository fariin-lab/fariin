import SwiftUI
import FirebaseFirestore

// ⛔ GROUP SETTINGS — owner 2026-10-18: who-can-do-what and the group's management, on their own
// page behind the Group Settings row of the group info page, instead of on the info page itself.
// Every switch here is one the group already had (or the one new `onlyAdminsCall`), written through
// the same `ChatService` call and held to the same rule (firestore.rules, the change-info right).

extension GroupMemberSheet {
    /// The member card, filled from the group the same way wherever it is opened.
    static func make(cid: String, conv: Conversation?, me: String, uid: String) -> GroupMemberSheet {
        let iAmOwner = conv?.createdBy == me && !(conv?.createdBy.isEmpty ?? true)
        return GroupMemberSheet(
            cid: cid,
            member: GroupInfoView.MemberAction(id: uid, name: conv?.names[uid] ?? "User",
                                               isAdmin: conv?.isAdmin(uid) ?? false),
            iAmAdmin: conv?.isAdmin(me) ?? false,
            ownerUid: conv?.createdBy ?? "",
            canManageAdmins: iAmOwner,
            canRestrict: conv?.adminCan(me, .banUsers) ?? false,
            currentRights: conv?.adminRights[uid],
            mutedUntil: conv?.restrictedUntil[uid] ?? 0,
            label: conv?.memberLabels[uid] ?? "",
            canEditLabel: uid == me || (conv?.adminCan(me, .changeInfo) ?? false))
    }
}

struct GroupSettingsView: View {
    let cid: String
    private var repo = ConversationsRepository.shared
    private var me: String { AuthService.shared.uid ?? "" }
    init(cid: String) { self.cid = cid }

    @State private var joinReqs: [JoinRequest] = []
    @State private var reqListener: ListenerRegistration?
    @State private var actionError: String?

    private var conv: Conversation? { repo.conversations.first { $0.id == cid } }
    private func can(_ r: Conversation.Right) -> Bool { conv?.adminCan(me, r) ?? false }
    /// The permissions are group rules: the change-info right edits them, other admins read them.
    private var canEdit: Bool { can(.changeInfo) }

    var body: some View {
        List {
            permissionsSection
            Section {
                NavigationLink { GroupAdminsView(cid: cid) } label: {
                    settingLabel("Administrators", "person.badge.shield.checkmark",
                                 value: "\(conv?.admins.count ?? 0)")
                }
                NavigationLink { GroupMembersListView(cid: cid) } label: {
                    settingLabel("Members", "person.2", value: "\(conv?.users.count ?? 0)")
                }
                if can(.inviteUsers) {
                    NavigationLink { GroupRequestsView(cid: cid) } label: {
                        settingLabel("Requests & Invites", "link",
                                     value: joinReqs.isEmpty ? nil : "\(joinReqs.count)")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Group Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard reqListener == nil, can(.inviteUsers) else { return }
            reqListener = GroupInviteService.joinRequests(cid: cid) { joinReqs = $0 }
        }
        .onDisappear { reqListener?.remove(); reqListener = nil }
        .alert("Could not do that", isPresented: Binding(get: { actionError != nil },
                                                          set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(actionError ?? "") }
    }

    private var permissionsSection: some View {
        Section {
            Toggle(isOn: bool(get: { !($0.onlyAdminsSend) },
                              set: { v in try await ChatService.setOnlyAdminsSend(cid: cid, !v) })) {
                settingLabel("Anyone can send messages", "bubble.left.and.bubble.right")
            }
            whoPicker("Add members", "person.badge.plus",
                      get: { $0.membersCanAdd }, key: "membersCanAdd")
            whoPicker("Edit group details", "pencil",
                      get: { $0.membersCanEditInfo }, key: "membersCanEditInfo")
            Picker(selection: bool(get: { !($0.onlyAdminsCall) },
                                   set: { v in try await ChatService.setGroupPermission(cid: cid, key: "onlyAdminsCall", !v) })) {
                Text("Everyone").tag(true)
                Text("Admins only").tag(false)
            } label: { settingLabel("Start group call", "phone") }
            .pickerStyle(.menu)
            Toggle(isOn: bool(get: { $0.isRestricted },
                              set: { v in try await ChatService.setGroupRestricted(cid, on: v) })) {
                settingLabel("Restricted Group", "ic_restricted_chat")
            }
            // Removing a member is the admin right "Restrict / remove members", set per admin on
            // the Administrators page; there is no member-wide switch for it.
            NavigationLink { GroupAdminsView(cid: cid) } label: {
                settingLabel("Remove users", "person.badge.minus", value: "Admins")
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("With \u{201C}Anyone can send messages\u{201D} off, only admins can send and the group is read-only for everyone else. Restricted Group stops forwarding, copying, saving and screenshots for everyone. Which admins can remove members is set for each admin under Administrators.")
        }
        .disabled(!canEdit)
    }

    /// Everyone / Admins only, for a `membersCan*` switch (true = Everyone).
    private func whoPicker(_ title: String, _ icon: String,
                           get: @escaping (Conversation) -> Bool, key: String) -> some View {
        Picker(selection: bool(get: get, set: { v in try await ChatService.setGroupPermission(cid: cid, key: key, v) })) {
            Text("Everyone").tag(true)
            Text("Admins only").tag(false)
        } label: { settingLabel(title, icon) }
        .pickerStyle(.menu)
    }

    /// A binding onto the live group: reads the conversation, writes through `set`, says so if the
    /// write is refused (the page never pretends a change went through).
    private func bool(get: @escaping (Conversation) -> Bool,
                      set: @escaping (Bool) async throws -> Void) -> Binding<Bool> {
        Binding(
            get: { conv.map(get) ?? false },
            set: { v in
                Task {
                    do { try await set(v) } catch {
                        let msg = error.localizedDescription
                        await MainActor.run { actionError = msg }
                    }
                }
            })
    }

    private func settingLabel(_ title: String, _ icon: String, value: String? = nil) -> some View {
        HStack(spacing: 12) {
            Group {
                if icon.hasPrefix("ic_") {
                    Image(icon).renderingMode(.template).resizable().scaledToFit().frame(width: 20, height: 20)
                } else {
                    Image(systemName: icon).font(.system(size: 16))
                }
            }
            .frame(width: 26)
            .foregroundStyle(.primary)
            Text(title)
            if let value {
                Spacer()
                Text(value).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Administrators

/// The group's admins, owner first. Tap one for their rights (the owner sets them on the member card,
/// "Restrict / remove members" among them); the owner adds admins from the members.
struct GroupAdminsView: View {
    let cid: String
    private var repo = ConversationsRepository.shared
    private var me: String { AuthService.shared.uid ?? "" }
    init(cid: String) { self.cid = cid }

    @State private var opened: String?
    @State private var showPick = false
    @State private var actionError: String?

    private var conv: Conversation? { repo.conversations.first { $0.id == cid } }
    private var iAmOwner: Bool { conv?.createdBy == me && !(conv?.createdBy.isEmpty ?? true) }
    private var admins: [String] {
        GroupMembers.sorted(conv, me: me).filter { conv?.isAdmin($0) ?? false }
            .sorted { a, _ in a == conv?.createdBy }
    }
    private var others: [String] {
        GroupMembers.sorted(conv, me: me).filter { !(conv?.isAdmin($0) ?? false) }
    }

    var body: some View {
        List {
            if iAmOwner && !others.isEmpty {
                Section {
                    Button { showPick = true } label: { Label("Add Admin", systemImage: "plus") }
                }
            }
            Section {
                ForEach(admins, id: \.self) { uid in
                    GroupMemberRow(conv: conv, uid: uid, me: me) { opened = uid }
                        .listRowInsets(EdgeInsets())
                }
            } footer: {
                Text("Tap an admin to see what they can do, including removing members.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Administrators")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: Binding(get: { opened.map { Opened(id: $0) } }, set: { opened = $0?.id })) { o in
            GroupMemberSheet.make(cid: cid, conv: conv, me: me, uid: o.id)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showPick) {
            NavigationStack {
                List(others, id: \.self) { uid in
                    GroupMemberRow(conv: conv, uid: uid, me: me) { promote(uid) }
                        .listRowInsets(EdgeInsets())
                }
                .navigationTitle("Add Admin")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { showPick = false } } }
            }
            .presentationDetents([.medium, .large])
        }
        .alert("Could not do that", isPresented: Binding(get: { actionError != nil },
                                                          set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(actionError ?? "") }
    }

    private func promote(_ uid: String) {
        let name = conv?.names[uid] ?? "User"
        showPick = false
        Task {
            do { try await ChatService.promoteGroupAdmin(cid: cid, uid: uid, name: name) } catch {
                let msg = error.localizedDescription
                await MainActor.run { actionError = msg }
            }
        }
    }
}

/// An id for `.sheet(item:)`.
private struct Opened: Identifiable { let id: String }

// MARK: - Members

/// Every member, searchable, Add Members on top; tap one for their card (remove, mute, admin, label).
struct GroupMembersListView: View {
    let cid: String
    private var repo = ConversationsRepository.shared
    private var me: String { AuthService.shared.uid ?? "" }
    init(cid: String) { self.cid = cid }

    @State private var query = ""
    @State private var opened: String?
    @State private var showAdd = false

    private var conv: Conversation? { repo.conversations.first { $0.id == cid } }
    private var canAdd: Bool { (conv?.adminCan(me, .inviteUsers) ?? false) || (conv?.membersCanAdd ?? false) }
    private var shown: [String] {
        let all = GroupMembers.sorted(conv, me: me)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { (conv?.names[$0] ?? "").lowercased().contains(q) }
    }

    var body: some View {
        List {
            if canAdd && query.isEmpty {
                Section {
                    Button { showAdd = true } label: { Label("Add Members", systemImage: "person.badge.plus") }
                }
            }
            Section(conv?.memberCountLabel.capitalized ?? "Members") {
                ForEach(shown, id: \.self) { uid in
                    GroupMemberRow(conv: conv, uid: uid, me: me) { opened = uid }
                        .listRowInsets(EdgeInsets())
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: "Search members")
        .navigationTitle("Members")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: Binding(get: { opened.map { Opened(id: $0) } }, set: { opened = $0?.id })) { o in
            GroupMemberSheet.make(cid: cid, conv: conv, me: me, uid: o.id)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showAdd) { AddMembersSheet(cid: cid, existing: Set(conv?.users ?? [])) }
    }
}

// MARK: - Requests & Invites

/// The group's invite link and the people waiting to join through it.
struct GroupRequestsView: View {
    let cid: String
    private var repo = ConversationsRepository.shared
    init(cid: String) { self.cid = cid }

    @State private var joinReqs: [JoinRequest] = []
    @State private var reqListener: ListenerRegistration?
    @State private var showInvite = false
    @State private var actionError: String?

    private var conv: Conversation? { repo.conversations.first { $0.id == cid } }

    var body: some View {
        List {
            Section {
                Button { showInvite = true } label: {
                    HStack {
                        Label("Invite Link", systemImage: "link")
                        Spacer()
                        Text((conv?.inviteCode ?? "").isEmpty ? "Off" : "On").foregroundStyle(.secondary)
                    }
                }
                .tint(.primary)
            } footer: {
                Text("Anyone with the link can ask to join or join straight away, as the link is set.")
            }
            Section("\(joinReqs.count) Request\(joinReqs.count == 1 ? "" : "s")") {
                if joinReqs.isEmpty {
                    Text("No one is waiting to join.").foregroundStyle(.secondary)
                }
                ForEach(joinReqs) { r in
                    HStack(spacing: 12) {
                        AvatarView(name: r.name, photoUrl: r.photo, size: 34)
                        Text(r.name).foregroundStyle(.primary).lineLimit(1)
                        Spacer(minLength: 8)
                        Button { act { try await GroupInviteService.approveJoin(cid: cid, uid: r.uid) } } label: {
                            Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.green)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Approve \(r.name)")
                        Button { act { try await GroupInviteService.denyJoin(cid: cid, uid: r.uid) } } label: {
                            Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Decline \(r.name)")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Requests & Invites")
        .navigationBarTitleDisplayMode(.inline)
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
        .alert("Could not do that", isPresented: Binding(get: { actionError != nil },
                                                          set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(actionError ?? "") }
    }

    /// 2026-09-24 audit: approve/deny refusals (group full, already handled) are said, not swallowed.
    private func act(_ op: @escaping () async throws -> Void) {
        Task {
            do { try await op() } catch {
                let msg = error.localizedDescription
                await MainActor.run { actionError = msg }
            }
        }
    }
}

// MARK: - Edit

/// Edit on the group info page: the group's photo and name, saved together.
struct EditGroupView: View {
    let cid: String
    let title: String
    let photoUrl: String?
    /// The group's description now (owner 2026-10-18: "add a Description card here too").
    var description: String = ""
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var desc = ""
    @State private var descLoaded = false
    @State private var newPhoto: Data?
    @State private var showPicker = false
    @State private var saving = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    private var trimmedDesc: String { desc.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// A group description's ceiling, the size the large messengers give one.
    private static let descChars = 255
    private static let descCounterAppearsAt = 20
    private var descRemaining: Int { max(0, Self.descChars - desc.count) }
    private var changed: Bool {
        newPhoto != nil || trimmed != title
            || trimmedDesc != description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 12) {
                        Button { nameFocused = false; showPicker = true } label: { photo }
                            .buttonStyle(.plain)
                        // Edit Profile's "Edit Photo" capsule (owner 2026-10-18): the cards' white, 36 tall.
                        Button { nameFocused = false; showPicker = true } label: {
                            Text("Set New Photo").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                .padding(.horizontal, 20).frame(height: 36)
                                .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                Section {
                    TextField("Group Name", text: $name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .focused($nameFocused)
                }
                // ⛔ THE BIO'S RULES (owner 2026-10-18: "use the logic you used for the bio"): one
                // paragraph (a newline never reaches the field, `Limits.oneParagraph`), up to 5 lines,
                // and a countdown that only appears in the last 20 characters, red at 0.
                Section {
                    VStack(alignment: .trailing, spacing: 6) {
                        TextField("Description",
                                  text: Binding(get: { desc },
                                                set: { desc = Limits.oneParagraph($0, max: Self.descChars) }),
                                  axis: .vertical)
                            .lineLimit(1...5)
                        if descRemaining <= Self.descCounterAppearsAt {
                            Text("\(descRemaining)")
                                .font(.footnote)
                                .monospacedDigit()
                                .foregroundStyle(descRemaining == 0 ? .red : .secondary)
                                .transition(.opacity)
                                .accessibilityLabel("\(descRemaining) characters left")
                        }
                    }
                } footer: {
                    Text("Optional. Shown on the group's info page.")
                }
                .animation(.smooth(duration: 0.22), value: descRemaining <= Self.descCounterAppearsAt)
                if let error { Text(error).foregroundStyle(.red) }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Edit Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .disabled(trimmed.isEmpty || !changed || saving)
                        .fontWeight(.semibold)
                }
            }
            .overlay { if saving { ProgressView().controlSize(.large) } }
            .onAppear {
                if name.isEmpty { name = title }
                if !descLoaded { desc = Limits.oneParagraph(description, max: Self.descChars); descLoaded = true }
            }
            // The app's own photo sheet, as New Group's photo uses.
            .sheet(isPresented: $showPicker) {
                StoryLibraryPicker(
                    onImage: { ui, _ in setPhoto(ui) },
                    onVideo: { _, _ in },   // `photosOnly`: there is no video tile to pick
                    photosOnly: true,
                    pickLabel: "Set Group Photo")
                .storyAlwaysDark()
            }
        }
    }

    private var photo: some View {
        ZStack {
            if let newPhoto, let ui = UIImage(data: newPhoto) {
                Image(uiImage: ui).resizable().scaledToFill()
            } else {
                AvatarView(name: title, photoUrl: photoUrl, size: 120)   // Edit Profile's size (owner 2026-10-18)
            }
        }
        .frame(width: 120, height: 120)
        .clipShape(Circle())
        .contentShape(Circle())
    }

    /// A group photo is a small round picture: 1024 px is plenty, and the upload stays quick.
    private func setPhoto(_ ui: UIImage) {
        showPicker = false
        Task {
            let data = await Task.detached(priority: .userInitiated) { () -> Data? in
                guard let jpeg = ui.jpegData(compressionQuality: 0.9) else { return nil }
                return ChatService.downscaledJPEG(jpeg, maxDimension: 1024, quality: 0.8)
            }.value
            if let data { newPhoto = data }
        }
    }

    /// Name first, then the photo; either refused is said, and the sheet stays.
    private func save() {
        let newName = trimmed, photo = newPhoto, oldName = title
        let newDesc = trimmedDesc, oldDesc = description.trimmingCharacters(in: .whitespacesAndNewlines)
        saving = true; error = nil
        Task {
            do {
                if newName != oldName { try await ChatService.renameGroup(cid: cid, title: newName) }
                if newDesc != oldDesc { try await ChatService.setGroupDescription(cid: cid, text: newDesc) }
                if let photo { _ = try await ChatService.uploadGroupAvatar(cid: cid, data: photo) }
                await MainActor.run { saving = false; dismiss() }
            } catch {
                let msg = error.localizedDescription
                await MainActor.run { saving = false; self.error = msg }
            }
        }
    }
}
