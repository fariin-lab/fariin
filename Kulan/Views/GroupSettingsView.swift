import SwiftUI
import FirebaseFirestore

// ⛔ GROUP SETTINGS — owner 2026-10-18: who-can-do-what and the group's management, on their own
// page behind the Group Settings row of the group info page, instead of on the info page itself.
// Every switch here is one the group already had (or the one new `onlyAdminsCall`), written through
// the same `ChatService` call and held to the same rule (firestore.rules, the change-info right).

extension GroupMemberSheet {
    /// The member card, filled from the group the same way wherever it is opened.
    static func make(cid: String, conv: Conversation?, me: String, uid: String,
                     onInfo: ((String) -> Void)? = nil) -> GroupMemberSheet {
        var sheet = GroupMemberSheet(
            cid: cid,
            member: GroupInfoView.MemberAction(id: uid, name: conv?.names[uid] ?? "User",
                                               isAdmin: conv?.isAdmin(uid) ?? false),
            iAmAdmin: conv?.isAdmin(me) ?? false,
            ownerUid: conv?.createdBy ?? "",
            canManageAdmins: conv?.canManageAdmin(me, uid) ?? false,
            canRestrict: conv?.adminCan(me, .banUsers) ?? false,
            currentRights: conv?.adminRights[uid],
            grantable: conv?.adminRightsOf(me).map(\.rawValue) ?? [],
            mutedUntil: conv?.restrictedUntil[uid] ?? 0,
            role: conv?.roles[uid],
            canEditRole: conv?.canSetRole(me, uid) ?? false)
        sheet.onInfo = onInfo
        return sheet
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

    // The edit head (photo, name, description): what is typed, what was last saved, and the save.
    @State private var editName = ""
    @State private var editDesc = ""
    @State private var savedName = ""
    @State private var savedDesc = ""
    @State private var editLoaded = false
    @State private var pickedPhoto: Data?
    @State private var photoPending = false
    @State private var showPhotoPicker = false
    @State private var editSaving = false
    @State private var editError: String?
    @FocusState private var nameFocused: Bool
    @FocusState private var descFocused: Bool

    private var conv: Conversation? { repo.conversations.first { $0.id == cid } }
    private func can(_ r: Conversation.Right) -> Bool { conv?.adminCan(me, r) ?? false }
    /// The permissions are group rules: the change-info right edits them, other admins read them.
    private var canEdit: Bool { can(.changeInfo) }
    /// Who may change the name, photo and description: the group info page's own gate.
    private var canEditInfo: Bool { can(.changeInfo) || (conv?.membersCanEditInfo ?? false) }

    var body: some View {
        // owner 2026-10-18: ONE THING PER SECTION, each with a short header and at most one short
        // footer (it was one long Permissions card with pickers and a paragraph under it).
        // ⛔ OWNER'S LAYOUT, 2026-10-19 (his picture): Requests & Invites alone at the top; one card
        // with Permissions (the member switches, on their own page, with how many are on),
        // Administrators, Members and Removed Users; Privacy last. Nothing else on this page: the
        // admins note lives on the Administrators page. Every door keeps the right it needed before.
        List {
            // ⛔ THE BAR'S EDIT OPENS THIS PAGE (owner 2026-10-19, his picture): photo, Set New Photo,
            // name and description at the head, for whoever may edit group info; the rest below.
            if canEditInfo { editHead }
            if can(.inviteUsers) {
                Section {
                    NavigationLink { GroupRequestsView(cid: cid) } label: {
                        settingLabel("Requests & Invites", "link",
                                     value: joinReqs.isEmpty ? nil : "\(joinReqs.count)")
                    }
                }
            }
            Section {
                NavigationLink { permissionsPage } label: {
                    settingLabel("Permissions", "switch.2", value: permissionsCount)
                }
                NavigationLink { GroupAdminsView(cid: cid) } label: {
                    settingLabel("Administrators", "person.badge.shield.checkmark",
                                 value: "\(conv?.admins.count ?? 0)")
                }
                NavigationLink { GroupMembersListView(cid: cid) } label: {
                    settingLabel("Members", "person.2", value: "\(conv?.users.count ?? 0)")
                }
                // REMOVED USERS, the people taken out of the group (`bannedUids`).
                if can(.banUsers) || can(.inviteUsers) {
                    NavigationLink { GroupRemovedUsersView(cid: cid) } label: {
                        settingLabel("Removed Users", "person.badge.minus",
                                     value: "\(conv?.bannedUids.count ?? 0)")
                    }
                }
            }
            privacySection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Group Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { doneToolbar }
        .onAppear {
            loadEditFields()
            guard reqListener == nil, can(.inviteUsers) else { return }
            reqListener = GroupInviteService.joinRequests(cid: cid) { joinReqs = $0 }
        }
        .onChange(of: conv != nil) { _, _ in loadEditFields() }
        .onDisappear { reqListener?.remove(); reqListener = nil }
        // The app's own photo sheet, as Edit Group's photo uses.
        .sheet(isPresented: $showPhotoPicker) {
            StoryLibraryPicker(
                onImage: { ui, _ in pickPhoto(ui) },
                onVideo: { _, _ in },   // `photosOnly`: there is no video tile to pick
                photosOnly: true,
                pickLabel: "Set Group Photo")
            .storyAlwaysDark()
        }
        .alert("Could not do that", isPresented: Binding(get: { actionError != nil },
                                                          set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(actionError ?? "") }
    }

    /// The member switches on their own page (owner 2026-10-18), reached from Permissions.
    private var permissionsPage: some View {
        List { membersCanSection }
            .listStyle(.insetGrouped)
            .navigationTitle("Permissions")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Could not do that", isPresented: Binding(get: { actionError != nil },
                                                              set: { if !$0 { actionError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(actionError ?? "") }
    }

    /// "3/4": how many of the member switches on the Permissions page are on.
    private var permissionsCount: String? {
        guard let c = conv else { return nil }
        var on = [!c.onlyAdminsSend, c.membersCanAdd, c.membersCanEditInfo, c.membersCanShareLink]
        if CallFeatures.groupCalls { on.append(!c.onlyAdminsCall) }
        return "\(on.filter { $0 }.count)/\(on.count)"
    }

    /// What every member may do. Admins always may; a switch turned off leaves it to admins.
    private var membersCanSection: some View {
        Section {
            Toggle(isOn: bool(get: { !($0.onlyAdminsSend) },
                              set: { v in try await ChatService.setOnlyAdminsSend(cid: cid, !v) })) {
                settingLabel("Send messages", "bubble.left.and.bubble.right")
            }
            Toggle(isOn: bool(get: { $0.membersCanAdd },
                              set: { v in try await ChatService.setGroupPermission(cid: cid, key: "membersCanAdd", v) })) {
                settingLabel("Add members", "person.badge.plus")
            }
            Toggle(isOn: bool(get: { $0.membersCanEditInfo },
                              set: { v in try await ChatService.setGroupPermission(cid: cid, key: "membersCanEditInfo", v) })) {
                settingLabel("Edit group info", "pencil")
            }
            Toggle(isOn: bool(get: { $0.membersCanShareLink },
                              set: { v in try await ChatService.setGroupPermission(cid: cid, key: "membersCanShareLink", v) })) {
                settingLabel("Share the group link", "link")
            }
            // Hidden while group calls are (CallFeatures.groupCalls, as on the group info page).
            if CallFeatures.groupCalls {
                Toggle(isOn: bool(get: { !($0.onlyAdminsCall) },
                                  set: { v in try await ChatService.setGroupPermission(cid: cid, key: "onlyAdminsCall", !v) })) {
                    settingLabel("Start group calls", "phone")
                }
            }
        } header: {
            Text("What members can do")
        } footer: {
            Text("Admins can always do these. Switch one off and only admins can.")
        }
        .disabled(!canEdit)
    }

    private var privacySection: some View {
        Section {
            Toggle(isOn: bool(get: { $0.isRestricted },
                              set: { v in try await ChatService.setGroupRestricted(cid, on: v) })) {
                settingLabel("Restricted Group", "circle.slash")
            }
        } header: {
            Text("Privacy")
        } footer: {
            Text("Stops forwarding, copying, saving and screenshots in this group, for everyone.")
        }
        .disabled(!canEdit)
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

    // MARK: Edit head

    private var editTrimmedName: String { editName.trimmingCharacters(in: .whitespaces) }
    private var editTrimmedDesc: String { editDesc.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var editDescRemaining: Int { max(0, EditGroupView.descChars - editDesc.count) }
    private var editChanged: Bool {
        photoPending || editTrimmedName != savedName || editTrimmedDesc != savedDesc
    }

    @ViewBuilder private var editHead: some View {
        editPhotoSection
        Section {
            TextField("Group Name", text: $editName)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .focused($nameFocused)
        }
        editDescSection
        if let editError { Text(editError).foregroundStyle(.red) }
    }

    /// The round photo (the letter when there is none) and the white Set New Photo capsule.
    private var editPhotoSection: some View {
        Section {
            VStack(spacing: 12) {
                Button { openPhotoPicker() } label: { editPhoto }
                    .buttonStyle(.plain)
                Button { openPhotoPicker() } label: {
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
    }

    private var editPhoto: some View {
        ZStack {
            if let pickedPhoto, let ui = UIImage(data: pickedPhoto) {
                Image(uiImage: ui).resizable().scaledToFill()
            } else {
                AvatarView(name: conv?.title ?? "Group", photoUrl: conv?.avatarUrl, size: 88)
            }
        }
        .frame(width: 88, height: 88)
        .clipShape(Circle())
        .contentShape(Circle())
    }

    /// Edit Group's description card, with the bio's rules (one paragraph, 5 lines, late countdown).
    private var editDescSection: some View {
        Section {
            VStack(alignment: .trailing, spacing: 6) {
                TextField("Description",
                          text: Binding(get: { editDesc },
                                        set: { editDesc = Limits.oneParagraph($0, max: EditGroupView.descChars) }),
                          axis: .vertical)
                    .lineLimit(1...5)
                    .focused($descFocused)
                if editDescRemaining <= EditGroupView.descCounterAppearsAt {
                    Text("\(editDescRemaining)")
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(editDescRemaining == 0 ? .red : .secondary)
                        .transition(.opacity)
                        .accessibilityLabel("\(editDescRemaining) characters left")
                }
            }
        } footer: {
            Text("Optional. Shown on the group's info page.")
        }
        .animation(.smooth(duration: 0.22), value: editDescRemaining <= EditGroupView.descCounterAppearsAt)
    }

    /// Done, top right: lit only once something in the head changed; saves and stays on the page.
    @ToolbarContentBuilder private var doneToolbar: some ToolbarContent {
        if canEditInfo {
            ToolbarItem(placement: .topBarTrailing) {
                Button { saveEdit() } label: {
                    if editSaving { ProgressView() } else { Text("Done").fontWeight(.semibold) }
                }
                .disabled(editTrimmedName.isEmpty || !editChanged || editSaving)
            }
        }
    }

    private func openPhotoPicker() {
        nameFocused = false; descFocused = false
        showPhotoPicker = true
    }

    /// Fills the fields from the group once, when it is first known.
    private func loadEditFields() {
        guard !editLoaded, let c = conv else { return }
        savedName = c.title.trimmingCharacters(in: .whitespaces)
        savedDesc = Limits.oneParagraph(c.groupDescription, max: EditGroupView.descChars)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        editName = c.title
        editDesc = Limits.oneParagraph(c.groupDescription, max: EditGroupView.descChars)
        editLoaded = true
    }

    /// A picked photo waits for Done, as it does on Edit Group.
    private func pickPhoto(_ ui: UIImage) {
        showPhotoPicker = false
        Task {
            if let data = await EditGroupView.groupPhotoData(ui) {
                pickedPhoto = data; photoPending = true
            }
        }
    }

    /// Edit Group's save (`EditGroupView.commit`); a refusal is said under the fields and the
    /// page keeps what was typed. On success the page stays, with Done dimmed again.
    private func saveEdit() {
        guard let c = conv else { return }
        let newName = editTrimmedName, newDesc = editTrimmedDesc
        let oldName = c.title, oldDesc = c.groupDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let photo: Data? = photoPending ? pickedPhoto : nil
        nameFocused = false; descFocused = false
        editSaving = true; editError = nil
        Task {
            do {
                try await EditGroupView.commit(cid: cid, name: newName, oldName: oldName,
                                               desc: newDesc, oldDesc: oldDesc, photo: photo)
                await MainActor.run {
                    editSaving = false
                    savedName = newName; savedDesc = newDesc; editName = newName
                    if photo != nil { photoPending = false }
                }
            } catch {
                let msg = error.localizedDescription
                await MainActor.run { editSaving = false; editError = msg }
            }
        }
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
    /// The member picked in Add Admin, waiting for the confirm (owner 2026-10-18: "no confirmation").
    @State private var pendingAdmin: String?

    private var conv: Conversation? { repo.conversations.first { $0.id == cid } }
    private var canAddAdmins: Bool { conv?.adminCan(me, .addAdmins) ?? false }
    private var admins: [String] {
        GroupMembers.sorted(conv, me: me).filter { conv?.isAdmin($0) ?? false }
            .sorted { a, _ in a == conv?.createdBy }
    }
    private var others: [String] {
        GroupMembers.sorted(conv, me: me).filter { !(conv?.isAdmin($0) ?? false) }
    }

    var body: some View {
        List {
            // owner 2026-10-18: the owner, or an admin the owner gave "Add new admins".
            if canAddAdmins && !others.isEmpty {
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
                // Moved here from the Group Settings page (owner's picture, 2026-10-19).
                Text("The owner decides what each admin can do. Tap an admin to see what they can do, including removing members.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Administrators")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: Binding(get: { opened.map { Opened(id: $0) } }, set: { opened = $0?.id })) { o in
            GroupMemberSheet.make(cid: cid, conv: conv, me: me, uid: o.id)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $showPick) {
            NavigationStack {
                List(others, id: \.self) { uid in
                    GroupMemberRow(conv: conv, uid: uid, me: me) { pendingAdmin = uid }
                        .listRowInsets(EdgeInsets())
                }
                .navigationTitle("Add Admin")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { showPick = false } } }
                // Making someone an admin hands them power over the group, so it is asked first.
                .alert("Make \(pendingAdmin.flatMap { conv?.names[$0] } ?? "this member") an admin?",
                       isPresented: Binding(get: { pendingAdmin != nil }, set: { if !$0 { pendingAdmin = nil } })) {
                    Button("Cancel", role: .cancel) { pendingAdmin = nil }
                    Button("Make Admin") {
                        if let uid = pendingAdmin { promote(uid) }
                        pendingAdmin = nil
                    }
                } message: {
                    Text("They will be able to manage the group with the rights you give them. You can change or remove them at any time.")
                }
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
        // The defaults, cut down to what I may hand out (all of them, for the owner).
        let mine = conv?.adminRightsOf(me).map(\.rawValue) ?? []
        let give = Conversation.Right.defaults.map(\.rawValue).filter { mine.contains($0) }
        showPick = false
        Task {
            do { try await ChatService.promoteGroupAdmin(cid: cid, uid: uid, name: name, rights: give) } catch {
                let msg = error.localizedDescription
                await MainActor.run { actionError = msg }
            }
        }
    }
}

/// An id for `.sheet(item:)`.
private struct Opened: Identifiable { let id: String }

// MARK: - Removed users

/// owner 2026-10-18: REMOVED USERS. Everyone on the group's `bannedUids` (written by Remove from
/// Group), with Let Back In for each. Letting someone back does not add them; it lets an invite link
/// or a join request work for them again, or an admin add them.
struct GroupRemovedUsersView: View {
    let cid: String
    private var repo = ConversationsRepository.shared
    init(cid: String) { self.cid = cid }

    @State private var busy: String?
    @State private var actionError: String?

    private var conv: Conversation? { repo.conversations.first { $0.id == cid } }

    var body: some View {
        List {
            Section {
                ForEach(conv?.bannedUids ?? [], id: \.self) { uid in
                    HStack(spacing: 12) {
                        AvatarView(name: conv?.names[uid] ?? "User", photoUrl: conv?.photos[uid], size: 40)
                        Text(conv?.names[uid] ?? "User").lineLimit(1)
                        Spacer(minLength: 8)
                        if busy == uid {
                            ProgressView()
                        } else {
                            Button("Let Back In") { unban(uid) }
                                .buttonStyle(.borderless)
                                .disabled(busy != nil)
                        }
                    }
                }
            } footer: {
                if conv?.bannedUids.isEmpty ?? true {
                    Text("Nobody has been removed from this group.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Removed Users")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Could not do that", isPresented: Binding(get: { actionError != nil },
                                                          set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(actionError ?? "") }
    }

    private func unban(_ uid: String) {
        busy = uid
        Task {
            do {
                try await ChatService.unbanGroupMember(cid: cid, uid: uid)
                await MainActor.run { busy = nil }
            } catch {
                let msg = error.localizedDescription
                await MainActor.run { busy = nil; actionError = msg }
            }
        }
    }
}

// MARK: - Admin rights

/// owner 2026-10-18: EDIT ADMIN RIGHTS. One switch per right, saved as it is flipped. The owner sees
/// every right; an admin with "Add new admins" sees only the rights they hold themselves (they
/// cannot give more than they have; firestore.rules `delegatedAdminEditOK` refuses it anyway).
struct AdminRightsView: View {
    let cid: String
    let uid: String
    let name: String
    let grantable: [String]
    @Binding var rights: Set<String>
    @State private var saving = false
    @State private var actionError: String?

    private var shown: [Conversation.Right] {
        Conversation.Right.allCases.filter { grantable.contains($0.rawValue) }
    }

    var body: some View {
        List {
            // owner 2026-10-18: full access in one switch, or a small set below.
            Section {
                Toggle(isOn: Binding(
                    get: { shown.allSatisfy { rights.contains($0.rawValue) } },
                    set: { on in
                        var next = rights
                        for r in shown { if on { next.insert(r.rawValue) } else { next.remove(r.rawValue) } }
                        save(next)
                    })) {
                    Text("All rights").fontWeight(.semibold)
                }
                .disabled(saving)
            }
            Section {
                ForEach(shown) { r in
                    Toggle(r.label, isOn: Binding(
                        get: { rights.contains(r.rawValue) },
                        set: { on in
                            var next = rights
                            if on { next.insert(r.rawValue) } else { next.remove(r.rawValue) }
                            save(next)
                        }))
                        .disabled(saving)
                }
            } header: {
                Text("What \(name) can do")
            } footer: {
                Text("\(name) can only do what is switched on here. Nobody but the owner can remove or change the owner.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Admin Rights")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Could not do that", isPresented: Binding(get: { actionError != nil },
                                                          set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(actionError ?? "") }
    }

    private func save(_ next: Set<String>) {
        let old = rights
        rights = next
        saving = true
        // Only what I may grant goes out, so a list with a right I no longer hold is not refused.
        let list = Conversation.Right.allCases.map(\.rawValue).filter { next.contains($0) && grantable.contains($0) }
        Task {
            do {
                try await ChatService.setAdminRights(cid: cid, uid: uid, rights: list)
                await MainActor.run { saving = false }
            } catch {
                let msg = error.localizedDescription
                await MainActor.run { rights = old; saving = false; actionError = msg }
            }
        }
    }
}

// MARK: - Members

/// Every member, searchable, Add Members on top; tap one for their card (remove, mute, admin, role).
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
            // ⛔ ROLE — owner 2026-10-18: who holds a role, together at the top, so an admin sees
            // them all in one place. Tap one to change or remove it on their card.
            let withRoles = shown.filter { conv?.roles[$0] != nil }
            if !withRoles.isEmpty && query.isEmpty {
                Section {
                    ForEach(withRoles, id: \.self) { uid in
                        GroupMemberRow(conv: conv, uid: uid, me: me) { opened = uid }
                            .listRowInsets(EdgeInsets())
                    }
                } header: { Text("Members with roles") } footer: {
                    Text("Only admins can give a member a role.")
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
        // At the bottom, the system's own iOS 26 Liquid Glass field (owner 2026-10-19).
        .searchable(text: $query, placement: .toolbar, prompt: "Search members")
        .navigationTitle("Members")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: Binding(get: { opened.map { Opened(id: $0) } }, set: { opened = $0?.id })) { o in
            GroupMemberSheet.make(cid: cid, conv: conv, me: me, uid: o.id)
                .presentationDetents([.large])
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
    @FocusState private var descFocused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    private var trimmedDesc: String { desc.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// A group description's ceiling, the size the large messengers give one.
    static let descChars = 255
    static let descCounterAppearsAt = 20
    private var descRemaining: Int { max(0, Self.descChars - desc.count) }
    private var changed: Bool {
        newPhoto != nil || trimmed != title
            || trimmedDesc != description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
          ScrollViewReader { proxy in
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
                            .focused($descFocused)
                        if descRemaining <= Self.descCounterAppearsAt {
                            Text("\(descRemaining)")
                                .font(.footnote)
                                .monospacedDigit()
                                .foregroundStyle(descRemaining == 0 ? .red : .secondary)
                                .transition(.opacity)
                                .accessibilityLabel("\(descRemaining) characters left")
                        }
                    }
                    .id("descEnd")
                } footer: {
                    Text("Optional. Shown on the group's info page.")
                }
                .animation(.smooth(duration: 0.22), value: descRemaining <= Self.descCounterAppearsAt)
                if let error { Text(error).foregroundStyle(.red) }
            }
            .listStyle(.insetGrouped)
            // ⛔ THE LINE BEING TYPED STAYS ABOVE THE KEYS (owner 2026-10-18, build 973: "the
            // description goes under the keyboard"). A List does not follow a field that grows a line
            // at a time, so on focus and on every change the page scrolls the card's end into view.
            .onChange(of: descFocused) { _, on in
                guard on else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    withAnimation(.smooth(duration: 0.25)) { proxy.scrollTo("descEnd", anchor: .bottom) }
                }
            }
            .onChange(of: desc) { _, _ in
                guard descFocused else { return }
                withAnimation(.smooth(duration: 0.2)) { proxy.scrollTo("descEnd", anchor: .bottom) }
            }
          }
            .navigationTitle("Edit Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 2026-10-18 (owner): an X in place of Cancel, and Save in blue (New Group's Create).
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { save() } label: {
                        if saving { ProgressView().tint(.white) } else { Text("Save").fontWeight(.semibold) }
                    }
                    .disabled(trimmed.isEmpty || !changed || saving)
                    .buttonStyle(.borderedProminent).tint(.blue)
                }
            }
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
            if let data = await Self.groupPhotoData(ui) { newPhoto = data }
        }
    }

    /// The picked photo made ready to upload. Shared with the head of Group Settings.
    static func groupPhotoData(_ ui: UIImage) async -> Data? {
        await Task.detached(priority: .userInitiated) { () -> Data? in
            guard let jpeg = ui.jpegData(compressionQuality: 0.9) else { return nil }
            return ChatService.downscaledJPEG(jpeg, maxDimension: 1024, quality: 0.8)
        }.value
    }

    /// The one save both editors use (this sheet and the head of Group Settings): name first, then
    /// the description, then the photo. Only what changed is written; the first refusal throws.
    static func commit(cid: String, name: String, oldName: String,
                       desc: String, oldDesc: String, photo: Data?) async throws {
        if name != oldName { try await ChatService.renameGroup(cid: cid, title: name) }
        if desc != oldDesc { try await ChatService.setGroupDescription(cid: cid, text: desc) }
        if let photo { _ = try await ChatService.uploadGroupAvatar(cid: cid, data: photo) }
    }

    /// Name first, then the photo; either refused is said, and the sheet stays.
    private func save() {
        let newName = trimmed, photo = newPhoto, oldName = title
        let newDesc = trimmedDesc, oldDesc = description.trimmingCharacters(in: .whitespacesAndNewlines)
        saving = true; error = nil
        Task {
            do {
                try await Self.commit(cid: cid, name: newName, oldName: oldName,
                                      desc: newDesc, oldDesc: oldDesc, photo: photo)
                await MainActor.run { saving = false; dismiss() }
            } catch {
                let msg = error.localizedDescription
                await MainActor.run { saving = false; self.error = msg }
            }
        }
    }
}
