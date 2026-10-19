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
    @State private var reqListener = ListenerBox()
    @State private var actionError: String?
    @State private var held = HeldConversation()

    /// ⛔ THE LAST GROUP SEEN, KEPT (owner 2026-10-19: flipping Restricted Group emptied the page,
    /// "Administrators 0, Members 0", Requests & Invites gone). The chat list can drop this group
    /// for a moment while a write settles; the page keeps what it last showed instead of reading
    /// that gap as "no group". A plain box, so keeping it never redraws anything.
    private var conv: Conversation? {
        // The group's own document first (owner 2026-10-19, third report): the page no longer
        // depends on the chat list having this group in its window at all.
        if let own = ownConv { held.conv = own; return own }
        if let live = repo.conversations.first(where: { $0.id == cid }) { held.conv = live; return live }
        return held.conv
    }
    @State private var ownConv: Conversation?
    @State private var convListener = ListenerBox()
    private func can(_ r: Conversation.Right) -> Bool { conv?.adminCan(me, r) ?? false }
    /// The permissions are group rules: the change-info right edits them, other admins read them.
    private var canEdit: Bool { can(.changeInfo) }

    /// The primary link's code from the server (getShareLink), as the requests page reads it; nil
    /// until it answers or when it fails, then the group doc's old `inviteCode`.
    @State private var shareCode: String?
    /// Public picked with no link name yet: the Group Type page asks for one and saves it.
    @State private var showTypePage = false
    @State private var confirmPrivate = false
    @State private var savingType = false

    private var isPublicNow: Bool { conv?.isPublic ?? false }

    var body: some View {
        // ⛔ OWNER'S LAYOUT, 2026-10-19 (second picture): a plain page like the admin sheet, no
        // cards, thin separators, small grey titles. Joining, People, Members can (the old
        // Permissions page, now ticks on this page), Privacy. Every row keeps the right it needed.
        List {
            joiningSection
            peopleSection
            membersCanSection
            privacySection
        }
        .listStyle(.plain)
        .navigationTitle("Group Settings")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showTypePage) { GroupTypeView(cid: cid) }
        // Started once and kept while a child page is pushed; removed with the page (`ListenerBox`).
        .onAppear {
            if convListener.reg == nil {
                convListener.reg = Firestore.firestore().collection("conversations").document(cid)
                    .addSnapshotListener { snap, _ in
                        guard let snap, snap.exists, let data = snap.data() else { return }
                        ownConv = Conversation(id: snap.documentID, data: data)
                    }
            }
            // Again on every return: the link page may have reset or turned off the link.
            if can(.inviteUsers) { Task { await loadShareCode() } }
            guard reqListener.reg == nil, can(.inviteUsers) else { return }
            reqListener.reg = GroupInviteService.joinRequests(cid: cid) { joinReqs = $0 }
        }
        // Rights can arrive with the group's own document, after the first appearance.
        .onChange(of: can(.inviteUsers)) { _, now in
            guard now else { return }
            Task { await loadShareCode() }
            guard reqListener.reg == nil else { return }
            reqListener.reg = GroupInviteService.joinRequests(cid: cid) { joinReqs = $0 }
        }
        // The Group Type page's own confirm, word for word: going private gives the link up.
        .confirmationDialog("Make this group private?", isPresented: $confirmPrivate, titleVisibility: .visible) {
            Button("Make Private", role: .destructive) { makePrivate() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("fariin.com/\(conv?.publicName ?? "") will stop working. The link stays reserved for this group for 30 days, then anyone can take it.")
        }
        .alert("Could not do that", isPresented: Binding(get: { actionError != nil },
                                                          set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(actionError ?? "") }
    }

    // MARK: Joining

    /// Type and links: change-info admins see Type; the invite link and requests need inviteUsers.
    @ViewBuilder private var joiningSection: some View {
        if canEdit || can(.inviteUsers) {
            Section {
                if canEdit { typeRow }
                if isPublicNow && canEdit {
                    NavigationLink { GroupTypeView(cid: cid) } label: {
                        valueRow("Public link", "fariin.com/\(conv?.publicName ?? "")")
                    }
                } else if can(.inviteUsers) {
                    NavigationLink {
                        InviteLinkSheet(cid: cid, groupTitle: conv?.title ?? "Group", groupPhoto: conv?.avatarUrl,
                                        initialCode: shareCode ?? conv?.inviteCode ?? "", embedded: true)
                    } label: {
                        valueRow("Invite link", inviteValue)
                    }
                }
                if can(.inviteUsers) {
                    NavigationLink { GroupRequestsView(cid: cid) } label: {
                        valueRow("Requests", joinReqs.isEmpty ? "None" : "\(joinReqs.count) waiting")
                    }
                }
            } header: {
                sectionTitle("Joining")
            }
        }
    }

    private var typeRow: some View {
        HStack(spacing: 12) {
            Text("Type")
            Spacer(minLength: 12)
            Picker("Type", selection: typeBinding) {
                Text("Private").tag(false)
                Text("Public").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(savingType)
        }
    }

    /// Reads the live group; a pick only asks. Public needs a link name, which the Group Type page
    /// takes and saves (a private group has none); Private asks first, as that page does.
    private var typeBinding: Binding<Bool> {
        Binding(get: { isPublicNow },
                set: { wantsPublic in
                    guard wantsPublic != isPublicNow else { return }
                    if wantsPublic { showTypePage = true } else { confirmPrivate = true }
                })
    }

    /// The short link, no https://, or "Off" when the group has none.
    private var inviteValue: String {
        let code = shareCode ?? conv?.inviteCode ?? ""
        guard !code.isEmpty else { return "Off" }
        return KulanApp.groupLink(code: code).replacingOccurrences(of: "https://", with: "")
    }

    private func loadShareCode() async {
        do { shareCode = try await GroupInviteService.shareCode(cid: cid) ?? "" } catch { shareCode = nil }
    }

    /// The same write the Group Type page makes on its Make Private.
    private func makePrivate() {
        guard !savingType else { return }
        savingType = true
        Task {
            do { try await GroupDirectory.setName(cid: cid, name: "") } catch {
                actionError = error.localizedDescription
            }
            savingType = false
        }
    }

    // MARK: People

    private var peopleSection: some View {
        Section {
            NavigationLink { GroupMembersListView(cid: cid) } label: {
                valueRow("Members", "\(conv?.users.count ?? 0)")
            }
            NavigationLink { GroupAdminsView(cid: cid) } label: {
                valueRow("Admins", "\(conv?.admins.count ?? 0)")
            }
            // REMOVED USERS, the people taken out of the group (`bannedUids`).
            if can(.banUsers) || can(.inviteUsers) {
                NavigationLink { GroupRemovedUsersView(cid: cid) } label: {
                    valueRow("Removed", "\(conv?.bannedUids.count ?? 0)")
                }
            }
        } header: {
            sectionTitle("People")
        }
    }

    // MARK: Members can

    /// What every member may do (the old Permissions page). Admins always may; a row without its
    /// tick leaves it to admins. Change-info admins tap to flip it; everyone else only reads.
    private var membersCanSection: some View {
        Section {
            checkRow("Send messages", on: conv.map { !$0.onlyAdminsSend } ?? false) { v in
                try await ChatService.setOnlyAdminsSend(cid: cid, !v)
            }
            checkRow("Add members", on: conv?.membersCanAdd ?? false) { v in
                try await ChatService.setGroupPermission(cid: cid, key: "membersCanAdd", v)
            }
            // "Change group info" is back for members (owner 2026-10-19, later the same day: "add
            // Change group info"). Sharing the link stays the admins'.
            checkRow("Change group info", on: conv?.membersCanEditInfo ?? false) { v in
                try await ChatService.setGroupPermission(cid: cid, key: "membersCanEditInfo", v)
            }
            // Hidden while group calls are (CallFeatures.groupCalls, as on the group info page).
            if CallFeatures.groupCalls {
                checkRow("Start calls", on: conv.map { !$0.onlyAdminsCall } ?? false) { v in
                    try await ChatService.setGroupPermission(cid: cid, key: "onlyAdminsCall", !v)
                }
            }
        } header: {
            sectionTitle("Members can")
        }
    }

    /// One tick row. Writes the flipped value at once, like the old switches did.
    @ViewBuilder
    private func checkRow(_ title: String, on: Bool,
                          write: @escaping (Bool) async throws -> Void) -> some View {
        if canEdit {
            Button { run { try await write(!on) } } label: { checkLabel(title, on: on) }
        } else {
            checkLabel(title, on: on)
        }
    }

    private func checkLabel(_ title: String, on: Bool) -> some View {
        HStack {
            Text(title).foregroundStyle(.primary)
            Spacer()
            if on {
                Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(canEdit ? Color.accentColor : Color.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: Privacy

    private var privacySection: some View {
        Section {
            Toggle(isOn: bool(get: { $0.isRestricted },
                              set: { v in try await ChatService.setGroupRestricted(cid, on: v) })) {
                Text("Restricted group")
            }
            .disabled(!canEdit)
        } header: {
            sectionTitle("Privacy")
        } footer: {
            Text("Stops forwarding, copying, saving and screenshots for everyone.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    // MARK: Pieces

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased()).font(.footnote).foregroundStyle(.secondary).textCase(nil)
    }

    private func valueRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        }
    }

    /// Runs a write and says so if it is refused.
    private func run(_ op: @escaping () async throws -> Void) {
        Task {
            do { try await op() } catch {
                let msg = error.localizedDescription
                await MainActor.run { actionError = msg }
            }
        }
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
    /// A refusal that came back while the Add Admin sheet was still on screen or going down: an
    /// alert raised then is lost, so it waits for the sheet's `onDismiss` (2026-10-19 fix round).
    @State private var pickerShown = false
    @State private var queuedError: String?

    private var conv: Conversation? { repo.conversations.first { $0.id == cid } }
    private var canAddAdmins: Bool { conv?.adminCan(me, .addAdmins) ?? false }
    /// The admins (owner first) and everyone else, from one sort of the members.
    private func split(_ c: Conversation?) -> (admins: [String], others: [String]) {
        let all = GroupMembers.sorted(c, me: me)
        let adminSet = Set(c?.admins ?? [])
        let owner = c?.createdBy
        var admins = all.filter { adminSet.contains($0) }
        if let owner, let i = admins.firstIndex(of: owner) {
            let first = admins.remove(at: i)
            admins.insert(first, at: 0)
        }
        return (admins, all.filter { !adminSet.contains($0) })
    }

    var body: some View {
        // Read once per body (2026-10-19 fix round): the group lookup and the sort ran per use.
        let conv = self.conv
        let (admins, others) = split(conv)
        return List {
            // owner 2026-10-18: the owner, or an admin the owner gave "Add new admins".
            if canAddAdmins && !others.isEmpty {
                Section {
                    Button { showPick = true } label: { Label("Add Admin", systemImage: "plus") }
                }
            }
            Section {
                ForEach(admins, id: \.self) { uid in
                    GroupMemberRow(conv: conv, uid: uid, me: me) { opened = uid }.equatable()
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
        .sheet(isPresented: $showPick, onDismiss: {
            pickerShown = false
            if let q = queuedError { queuedError = nil; actionError = q }
        }) {
            NavigationStack {
                List(others, id: \.self) { uid in
                    GroupMemberRow(conv: conv, uid: uid, me: me) { pendingAdmin = uid }.equatable()
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
            .onAppear { pickerShown = true }
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
                await MainActor.run {
                    if pickerShown { queuedError = msg } else { actionError = msg }
                }
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
                // The empty state sits in the card itself (owner 2026-10-19), not under it.
                if conv?.bannedUids.isEmpty ?? true {
                    Text("Nobody has been removed from this group.").foregroundStyle(.secondary)
                }
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
    @State private var pendingRemove: String?
    @State private var removeError: String?

    private var conv: Conversation? { repo.conversations.first { $0.id == cid } }
    private var canAdd: Bool { (conv?.adminCan(me, .inviteUsers) ?? false) || (conv?.membersCanAdd ?? false) }
    private func canRemove(_ uid: String) -> Bool {
        guard let c = conv, uid != me, !c.isOwner(uid), c.adminCan(me, .banUsers) else { return false }
        return c.isOwner(me) || !c.isAdmin(uid)
    }
    private func filtered(_ conv: Conversation?) -> [String] {
        let all = GroupMembers.sorted(conv, me: me)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { (conv?.names[$0] ?? "").lowercased().contains(q) }
    }

    var body: some View {
        // Read once per body (2026-10-19 fix round): the group lookup and the sort ran per use.
        let conv = self.conv
        let shown = filtered(conv)
        return List {
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
                        GroupMemberRow(conv: conv, uid: uid, me: me) { opened = uid }.equatable()
                            .listRowInsets(EdgeInsets())
                    }
                } header: { Text("Members with roles") } footer: {
                    Text("Only admins can give a member a role.")
                }
            }
            Section(conv?.memberCountLabel.capitalized ?? "Members") {
                ForEach(shown, id: \.self) { uid in
                    GroupMemberRow(conv: conv, uid: uid, me: me) { opened = uid }.equatable()
                        .listRowInsets(EdgeInsets())
                        // Swipe left to remove, as the Blocked list unblocks (owner 2026-10-19). The
                        // member card's own rule: remove right, never me or the owner, an admin only
                        // by the owner.
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if canRemove(uid) {
                                Button("Remove", role: .destructive) { pendingRemove = uid }
                            }
                        }
                }
            }
        }
        .confirmationDialog("Remove \(conv?.names[pendingRemove ?? ""] ?? "this member") from the group?",
                            isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                guard let uid = pendingRemove else { return }
                let name = conv?.names[uid] ?? "User"
                pendingRemove = nil
                Task {
                    do { try await ChatService.removeGroupMember(cid: cid, uid: uid, name: name) }
                    catch { removeError = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) { pendingRemove = nil }
        }
        .alert("Could not remove", isPresented: Binding(get: { removeError != nil }, set: { if !$0 { removeError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(removeError ?? "") }
        .listStyle(.insetGrouped)
        // At the bottom, the system's own iOS 26 Liquid Glass field (owner 2026-10-19).
        .searchable(text: $query, placement: .toolbar, prompt: "Search members")
        // `.toolbar` placement alone leaves the field at the top on a pushed page; asking for the
        // system search item in the bottom bar is what puts it at the foot on iOS 26.
        .toolbar { DefaultToolbarItem(kind: .search, placement: .bottomBar) }
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
    /// The primary link's code from the server (getShareLink), as the group info page reads it;
    /// nil until it answers or when it fails, then the group doc's old `inviteCode`.
    @State private var shareCode: String?

    private var conv: Conversation? { repo.conversations.first { $0.id == cid } }

    private func loadShareCode() async {
        do { shareCode = try await GroupInviteService.shareCode(cid: cid) ?? "" } catch { shareCode = nil }
    }

    var body: some View {
        List {
            // The invite link card is gone from here (owner 2026-10-19): the link has its own row
            // on Group Settings. This page is only the people waiting to join.
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
        .navigationTitle("Join Requests")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard reqListener == nil else { return }
            reqListener = GroupInviteService.joinRequests(cid: cid) { joinReqs = $0 }
        }
        .onDisappear { reqListener?.remove(); reqListener = nil }
        .task { await loadShareCode() }
        // Again after the link sheet closes: it may have reset or turned off the link.
        .sheet(isPresented: $showInvite, onDismiss: { Task { await loadShareCode() } }) {
            InviteLinkSheet(cid: cid, groupTitle: conv?.title ?? "Group", groupPhoto: conv?.avatarUrl,
                            initialCode: shareCode ?? conv?.inviteCode ?? "")
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
    private static let descChars = 255
    private static let descCounterAppearsAt = 20
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
                    // No badge on the photo; the "Set New Photo" capsule under it, in Liquid Glass
                    // (owner 2026-10-19, correcting my earlier reading).
                    VStack(spacing: 12) {
                        Button { nameFocused = false; showPicker = true } label: { photo }
                            .buttonStyle(.plain)
                        Button { nameFocused = false; showPicker = true } label: {
                            Text("Set New Photo").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                .padding(.horizontal, 20).frame(height: 36)
                                .liquidGlass(Capsule(), interactive: true)
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

/// The Group Settings page's last-seen group (see `GroupSettingsView.conv`).
final class HeldConversation { var conv: Conversation? }

/// A listener kept for the page's real lifetime (2026-10-19 fix round). `.onDisappear` also fires
/// when a child page is pushed on top, which dropped the group's listener while Permissions was
/// open: its switches read a stale group, snapped back and were written twice. Held in `@State`,
/// the box goes (and removes the listener) only when the page itself leaves the stack.
final class ListenerBox {
    var reg: ListenerRegistration?
    deinit { reg?.remove() }
}
