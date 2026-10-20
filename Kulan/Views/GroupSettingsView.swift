import SwiftUI
import FirebaseFirestore

// ⛔ GROUP SETTINGS — owner 2026-10-18: who-can-do-what and the group's management, on their own
// page behind the Group Settings row of the group info page, instead of on the info page itself.
// Every switch here is one the group already had (or the one new `onlyAdminsCall`), written through
// the same `ChatService` call and held to the same rule (firestore.rules, the change-info right).

extension GroupMemberSheet {
    /// The member card, filled from the group the same way wherever it is opened.
    static func make(cid: String, conv: Conversation?, me: String, uid: String,
                     onInfo: ((String) -> Void)? = nil,
                     onRemoved: ((String) -> Void)? = nil) -> GroupMemberSheet {
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
        sheet.onRemoved = onRemoved
        sheet.photoHint = conv?.photos[uid]
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

    private var isPublicNow: Bool { conv?.isPublic ?? false }

    var body: some View {
        // ⛔ SHORT CARDS THAT OPEN THEIR OWN PAGES (owner 2026-10-19, later: "when you tap you get
        // the options you need, instead of one flat page"). Joining (Group Type, link, requests),
        // People (members, admins, removed), Permissions. Every row keeps the right it needed.
        List {
            joiningSection
            peopleSection
            permissionsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Group Settings")
        .navigationBarTitleDisplayMode(.inline)
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
                // Private / Public and the public link name live on the Group Type page.
                if canEdit {
                    NavigationLink { GroupTypeView(cid: cid) } label: {
                        valueRow("person.2", "Group Type", isPublicNow ? "Public" : "Private")
                    }
                }
                if !isPublicNow && can(.inviteUsers) {
                    NavigationLink {
                        InviteLinkSheet(cid: cid, groupTitle: conv?.title ?? "Group", groupPhoto: conv?.avatarUrl,
                                        initialCode: shareCode ?? conv?.inviteCode ?? "", embedded: true)
                    } label: {
                        valueRow("link", "Invite Link", inviteValue == "Off" ? "Off" : "On")
                    }
                }
                if can(.inviteUsers) {
                    NavigationLink { GroupRequestsView(cid: cid) } label: {
                        valueRow("person.badge.clock", "Requests & Invites",
                                 joinReqs.isEmpty ? "None" : "\(joinReqs.count)")
                    }
                }
            }
        }
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

    // MARK: People

    private var peopleSection: some View {
        Section {
            NavigationLink { GroupMembersListView(cid: cid) } label: {
                valueRow("person.3", "Members", "\(conv?.users.count ?? 0)")
            }
            NavigationLink { GroupAdminsView(cid: cid) } label: {
                valueRow("checkmark.shield", "Administrators", "\(conv?.admins.count ?? 0)")
            }
            // REMOVED USERS, the people taken out of the group (`bannedUids`).
            if can(.banUsers) || can(.inviteUsers) {
                NavigationLink { GroupRemovedUsersView(cid: cid) } label: {
                    valueRow("person.crop.circle.badge.minus", "Removed Members", "\(conv?.bannedUids.count ?? 0)")
                }
            }
        }
    }

    // MARK: Permissions

    /// How many of the member switches are on, for the row's "3/4".
    private var permissionCount: (on: Int, of: Int) {
        guard let c = conv else { return (0, 0) }
        var flags = [!c.onlyAdminsSend, c.membersCanAdd, c.membersCanEditInfo]
        if CallFeatures.groupCalls { flags.append(!c.onlyAdminsCall) }
        return (flags.filter { $0 }.count, flags.count)
    }

    private var permissionsSection: some View {
        Section {
            NavigationLink { permissionsPage } label: {
                valueRow("key", "Permissions", "\(permissionCount.on)/\(permissionCount.of)")
            }
        }
    }

    /// The member switches and Protect Content, on their own page.
    private var permissionsPage: some View {
        List {
            membersCanSection
            if !(conv?.onlyAdminsSend ?? false) { mediaRowSection }
            privacySection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Permissions")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// What every member may do. On = members may, off = admins only; admins always may.
    /// Switches, not ticks (owner 2026-10-19: a missing tick did not read as "admins only").
    /// Change-info admins flip them; everyone else sees them greyed.
    private var membersCanSection: some View {
        Section {
            switchRow("Send messages", get: { !$0.onlyAdminsSend }) { v in
                try await ChatService.setOnlyAdminsSend(cid: cid, !v)
            }
            switchRow("Add members", get: { $0.membersCanAdd }) { v in
                try await ChatService.setGroupPermission(cid: cid, key: "membersCanAdd", v)
            }
            // "Change group info" is back for members (owner 2026-10-19, later the same day: "add
            // Change group info"). Sharing the link stays the admins'.
            switchRow("Change group info", get: { $0.membersCanEditInfo }) { v in
                try await ChatService.setGroupPermission(cid: cid, key: "membersCanEditInfo", v)
            }
            // Hidden while group calls are (CallFeatures.groupCalls, as on the group info page).
            if CallFeatures.groupCalls {
                switchRow("Start calls", get: { !$0.onlyAdminsCall }) { v in
                    try await ChatService.setGroupPermission(cid: cid, key: "onlyAdminsCall", !v)
                }
            }
        } header: {
            Text("Members can")
        } footer: {
            Text("Turned off, only admins can do it. Admins can always do these.")
        }
    }

    // MARK: Media & content (owner 2026-10-20: one switch for all, then each kind on its own)

    private var mediaOnCount: Int {
        Conversation.SendKind.allCases.filter { conv?.memberSend[$0.rawValue] != false }.count
    }

    /// "Media & content · 7 of 9 ›", which opens its own page, like every row in Group Settings.
    private var mediaRowSection: some View {
        Section {
            NavigationLink { mediaPage } label: {
                valueRow("photo.on.rectangle", "Media & content",
                         "\(mediaOnCount) of \(Conversation.SendKind.allCases.count)")
            }
        } footer: {
            Text("What members can send besides text.")
        }
    }

    private var mediaPage: some View {
        List {
            Section {
                Toggle(isOn: Binding(
                    get: { mediaOnCount == Conversation.SendKind.allCases.count },
                    set: { on in setAllMedia(on) })) {
                    Text("Allow all").fontWeight(.semibold)
                }
                .disabled(!canEdit)
            } footer: {
                Text("Turn this off to stop all media at once. Admins can always send everything.")
            }
            Section {
                ForEach(Conversation.SendKind.allCases, id: \.self) { k in
                    Toggle(isOn: bool(get: { $0.memberSend[k.rawValue] != false }, set: { v in
                        var next = conv?.memberSend ?? [:]
                        next[k.rawValue] = v
                        try await ChatService.setMemberSend(cid: cid, next)
                    })) {
                        Label(k.label, systemImage: k.icon)
                    }
                    .disabled(!canEdit)
                }
            } header: {
                Text("Members can send")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Media & content")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func setAllMedia(_ on: Bool) {
        let all = Dictionary(uniqueKeysWithValues: Conversation.SendKind.allCases.map { ($0.rawValue, on) })
        run {
            try await ChatService.setMemberSend(cid: cid, all,
                                                notice: on ? "allowed all media" : "turned off all media for members")
        }
    }

    /// One switch, written at once through `bool`, which says so if the write is refused.
    private func switchRow(_ title: String, get: @escaping (Conversation) -> Bool,
                           write: @escaping (Bool) async throws -> Void) -> some View {
        Toggle(title, isOn: bool(get: get, set: write))
            .disabled(!canEdit)
    }

    // MARK: Privacy

    private var privacySection: some View {
        Section {
            Toggle(isOn: bool(get: { $0.isRestricted },
                              set: { v in try await ChatService.setGroupRestricted(cid, on: v) })) {
                Text("Protect Content")
            }
            .disabled(!canEdit)
        } header: {
            Text("Content")
        } footer: {
            Text("Stops forwarding, copying, saving and screenshots for everyone.")
        }
    }

    // MARK: Pieces

    /// A row in the cards: the outline glyph the group page uses, the title, the value in grey.
    private func valueRow(_ icon: String, _ title: String, _ value: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 17)).frame(width: 26)
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
    /// The member picked in Add Admin; their Add Admin page is pushed in the sheet.
    @State private var pickedAdmin: String?

    // The group itself, live (2026-10-20): roles and rights show the moment they change.
    @State private var live = LiveGroupDoc()
    private var conv: Conversation? { live.start(cid); return live.conv ?? repo.conversations.first { $0.id == cid } }
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
            Section {
                // owner 2026-10-18: the owner, or an admin the owner gave "Add new admins". In the
                // same card as the admins (owner 2026-10-19).
                if canAddAdmins && !others.isEmpty {
                    Button { showPick = true } label: { Label("Add Admin", systemImage: "person.badge.plus") }
                }
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
        }
        .sheet(isPresented: $showPick, onDismiss: { pickedAdmin = nil }) {
            // Pick a member, then their Add Admin page (rights, tag, the button), in the sheet.
            NavigationStack {
                List(others, id: \.self) { uid in
                    GroupMemberRow(conv: conv, uid: uid, me: me) { pickedAdmin = uid }.equatable()
                        .listRowInsets(EdgeInsets())
                }
                .navigationTitle("Choose Member")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { showPick = false } } }
                .navigationDestination(item: $pickedAdmin) { uid in
                    AddAdminPage(cid: cid, uid: uid) { showPick = false }
                }
            }
        }
        .alert("Could not do that", isPresented: Binding(get: { actionError != nil },
                                                          set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(actionError ?? "") }
    }
}

/// An id for `.sheet(item:)`.
private struct Opened: Identifiable { let id: String }

extension Conversation.Right {
    /// The owner's short names for the rights on the admin pages (the model's labels stay as they are).
    var shortLabel: String {
        switch self {
        case .changeInfo:     return "Change group info"
        case .deleteMessages: return "Delete messages"
        case .banUsers:       return "Remove members"
        case .inviteUsers:    return "Add members"
        case .pinMessages:    return "Pin messages"
        case .manageCalls:    return "Video chats"
        case .addAdmins:      return "Add admins"
        }
    }
}

// ⛔ ADD ADMIN AS ONE PAGE (owner 2026-10-19): pick a member, then this page: who, a switch for each
// right I may hand out (the defaults on), their tag, and Add Admin at the foot. It replaces the
// "Make X an admin?" alert that gave the defaults and left the rights for later.
struct AddAdminPage: View {
    let cid: String
    let uid: String
    let onDone: () -> Void

    private var repo = ConversationsRepository.shared
    private var me: String { AuthService.shared.uid ?? "" }
    init(cid: String, uid: String, onDone: @escaping () -> Void) {
        self.cid = cid; self.uid = uid; self.onDone = onDone
    }

    @State private var rights: Set<String> = []
    @State private var loaded = false
    @State private var tag = ""
    @State private var busy = false
    @State private var actionError: String?

    // The group itself, live (2026-10-20): roles and rights show the moment they change.
    @State private var live = LiveGroupDoc()
    private var conv: Conversation? { live.start(cid); return live.conv ?? repo.conversations.first { $0.id == cid } }
    private var name: String { conv?.names[uid] ?? "User" }
    private var grantable: [Conversation.Right] {
        let mine = Set(conv?.adminRightsOf(me).map(\.rawValue) ?? [])
        return Conversation.Right.allCases.filter { mine.contains($0.rawValue) }
    }
    private var mayTag: Bool { conv?.adminCan(me, .changeInfo) ?? false }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    AvatarView(name: name, photoUrl: conv?.photos[uid], size: 56)
                    HStack(spacing: 6) {
                        Text(name).font(.title3.weight(.semibold)).lineLimit(1)
                        VerifiedMark(uid: uid, size: 15)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            }
            Section {
                ForEach(grantable, id: \.id) { r in
                    Toggle(r.shortLabel, isOn: Binding(
                        get: { rights.contains(r.rawValue) },
                        set: { on in if on { rights.insert(r.rawValue) } else { rights.remove(r.rawValue) } }))
                    .disabled(busy)
                }
            } header: {
                Text("What they can do")
            } footer: {
                if grantable.contains(.addAdmins) && !rights.contains(Conversation.Right.addAdmins.rawValue) {
                    Text("They won't be able to make other members admins.")
                }
            }
            if mayTag {
                Section {
                    TextField("None", text: $tag).disabled(busy)
                } header: {
                    Text("Tag")
                } footer: {
                    Text("A short word shown next to \(name)'s name in the group.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Add Admin")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button { add() } label: {
                Group {
                    if busy { ProgressView().tint(.white) } else { Text("Add Admin").fontWeight(.semibold) }
                }
                .frame(maxWidth: .infinity, minHeight: 50)
                .foregroundStyle(.white)
                .background(Color.accentColor, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .padding(.horizontal, 20).padding(.bottom, 8)
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            let mine = Set(grantable.map(\.rawValue))
            rights = Set(Conversation.Right.defaults.map(\.rawValue).filter { mine.contains($0) })
        }
        .onChange(of: tag) { _, new in
            if new.utf16.count > GroupRole.maxText { tag = GroupRole.fit(new, max: GroupRole.maxText) }
        }
        .alert("Could not do that", isPresented: Binding(get: { actionError != nil },
                                                          set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(actionError ?? "") }
    }

    /// Promote with the switched-on rights, then the tag if one was typed. Closes on success only.
    private func add() {
        guard !busy else { return }
        busy = true
        let cid = cid, uid = uid, name = name
        let list = Conversation.Right.allCases.map(\.rawValue).filter { rights.contains($0) }
        let words = mayTag ? GroupRole.clean(tag) : ""
        Task {
            do {
                try await ChatService.promoteGroupAdmin(cid: cid, uid: uid, name: name, rights: list)
                if !words.isEmpty { try await ChatService.setRole(cid: cid, uid: uid, text: words, emoji: nil) }
                await MainActor.run { busy = false; onDone() }
            } catch {
                let msg = error.localizedDescription
                await MainActor.run { busy = false; actionError = msg }
            }
        }
    }
}

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

    // The group itself, live (2026-10-20): roles and rights show the moment they change.
    @State private var live = LiveGroupDoc()
    private var conv: Conversation? { live.start(cid); return live.conv ?? repo.conversations.first { $0.id == cid } }

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

    // The group itself, live (2026-10-20): roles and rights show the moment they change.
    @State private var live = LiveGroupDoc()
    private var conv: Conversation? { live.start(cid); return live.conv ?? repo.conversations.first { $0.id == cid } }
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
        .alert("Remove \(conv?.names[pendingRemove ?? ""] ?? "this member") from the group?",
                            isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } })) {
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

    // The group itself, live (2026-10-20): roles and rights show the moment they change.
    @State private var live = LiveGroupDoc()
    private var conv: Conversation? { live.start(cid); return live.conv ?? repo.conversations.first { $0.id == cid } }

    private func loadShareCode() async {
        do { shareCode = try await GroupInviteService.shareCode(cid: cid) ?? "" } catch { shareCode = nil }
    }

    // ⛔ REQUESTS & INVITES (owner 2026-10-19: "only requests; add the second page, our own way").
    // Requests: who is waiting, Approve / Decline, and an empty state that says whether the link
    // asks for approval at all. Invites: who came in through each of the group's links, and the
    // two ways to bring more people (the link, Add Members).
    @State private var tab = 0
    @State private var links: GroupLinkList?
    @State private var showAdd = false
    private var me: String { AuthService.shared.uid ?? "" }
    private var canAdd: Bool { (conv?.adminCan(me, .inviteUsers) ?? false) || (conv?.membersCanAdd ?? false) }

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $tab) {
                    Text(joinReqs.isEmpty ? "Requests" : "Requests (\(joinReqs.count))").tag(0)
                    Text("Invites").tag(1)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if tab == 0 { requestsSections } else { invitesSections }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Requests & Invites")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard reqListener == nil else { return }
            reqListener = GroupInviteService.joinRequests(cid: cid) { joinReqs = $0 }
        }
        .onDisappear { reqListener?.remove(); reqListener = nil }
        .task { await loadShareCode() }
        .task { links = try? await GroupInviteService.listLinks(cid: cid) }
        .sheet(isPresented: $showAdd) { AddMembersSheet(cid: cid, existing: Set(conv?.users ?? [])) }
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

    // MARK: Requests

    @ViewBuilder private var requestsSections: some View {
        if joinReqs.isEmpty {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: "person.badge.clock").font(.system(size: 38)).foregroundStyle(.secondary)
                    Text("No one is waiting to join").font(.headline)
                    Text(approvalLine).font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 18)
            } footer: {
                if links?.primary != nil {
                    Text("Change this under Invite Link › Approve New Members.")
                }
            }
        } else {
            Section("Waiting to join") {
                ForEach(joinReqs) { r in
                    HStack(spacing: 12) {
                        AvatarView(name: r.name, photoUrl: r.photo, size: 40)
                        Text(r.name).foregroundStyle(.primary).lineLimit(1)
                        Spacer(minLength: 8)
                        Button { act { try await GroupInviteService.denyJoin(cid: cid, uid: r.uid) } } label: {
                            Text("Decline").font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(Capsule().fill(Color(.tertiarySystemFill)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Decline \(r.name)")
                        Button { act { try await GroupInviteService.approveJoin(cid: cid, uid: r.uid) } } label: {
                            Text("Approve").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(Capsule().fill(Color.accentColor))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Approve \(r.name)")
                    }
                }
            }
        }
    }

    private var approvalLine: String {
        guard let p = links?.primary else { return "People who ask to join through a link show up here." }
        return p.requestApproval
            ? "Approve New Members is on: people who use the link wait here for an admin."
            : "Approve New Members is off: people who use the link join straight away."
    }

    // MARK: Invites

    @ViewBuilder private var invitesSections: some View {
        let active = ([links?.primary].compactMap { $0 } + (links?.links ?? [])).filter { $0.state() == .active }
        if links == nil {
            Section { ProgressView().frame(maxWidth: .infinity) }
        } else if active.isEmpty {
            Section {
                Text("This group has no invite link on.").foregroundStyle(.secondary)
            }
        }
        ForEach(active) { l in
            Section {
                if l.joined.isEmpty {
                    Text("No one has joined with this link yet.").foregroundStyle(.secondary)
                }
                ForEach(l.joined) { f in
                    HStack(spacing: 12) {
                        AvatarView(name: f.name, photoUrl: f.photoUrl, size: 36)
                        Text(f.name.isEmpty ? "Member" : f.name).lineLimit(1)
                    }
                }
            } header: {
                Text(l.isPrimary ? "Main link" : l.title)
            } footer: {
                Text("\(l.usedCount) joined\(l.usageLimit > 0 ? " of \(l.usageLimit)" : "")")
            }
        }
        Section {
            Button { showInvite = true } label: { Label("Share Invite Link", systemImage: "link") }
            if canAdd {
                Button { showAdd = true } label: { Label("Add Members", systemImage: "person.badge.plus") }
            }
        } header: {
            Text("Invite more people")
        }
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

/// ⛔ THE GROUP'S OWN DOCUMENT, LIVE (owner 2026-10-20: "made admin, the page did not show it until I
/// went back in"). The chat list's feed is a windowed, coalesced query; a page that shows roles and
/// rights listens to the group itself. A reference type, so holding it in a view's @State costs a
/// pointer on the stack, not a whole Conversation (see the ThreadView stack note, build 990).
@Observable
final class LiveGroupDoc {
    private(set) var conv: Conversation?
    @ObservationIgnored private var reg: ListenerRegistration?
    @ObservationIgnored private var started: String?

    func start(_ cid: String) {
        guard started != cid, !cid.isEmpty else { return }
        started = cid
        reg?.remove()
        reg = Firestore.firestore().collection("conversations").document(cid)
            .addSnapshotListener { [weak self] snap, _ in
                guard let snap, snap.exists, let data = snap.data() else { return }
                self?.conv = Conversation(id: snap.documentID, data: data)
            }
    }

    deinit { reg?.remove() }
}
