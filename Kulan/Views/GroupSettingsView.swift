import SwiftUI
import UIKit
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

/// ⛔ A GROUP SETTING IS SAVED WHEN THE SERVER SAYS SO (audit 2026-10-26 item 20). Offline, a
/// Firestore write never fails: it waits in the local cache, every listener shows it at once, and
/// the switch looked saved while nothing had left the phone. Now a settings write is refused at once
/// when there is no connection, and one the server has not confirmed within `seconds` is reported,
/// so the page puts the switch back and says so. The pages read the group from server-confirmed
/// snapshots only (`hasPendingWrites` skipped), so a late write shows up when it really lands.
enum GroupSettingWrite {
    struct NotSaved: LocalizedError {
        var errorDescription: String? { "The change was not saved. Check your connection and try again." }
    }

    /// One answer, whichever of the write and the timer comes first. The write is not cancelled (a
    /// Firestore write cannot be); it is only no longer waited for.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    static func confirmed(within seconds: Double = 12, _ op: @escaping () async throws -> Void) async throws {
        guard NetworkState.shared.isOnline else { throw NotSaved() }
        let once = Once()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            Task {
                do { try await op(); if once.claim() { c.resume() } }
                catch { if once.claim() { c.resume(throwing: error) } }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if once.claim() { c.resume(throwing: NotSaved()) }
            }
        }
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
    /// ⛔ A CLOSED GROUP IS READ-ONLY HERE (audit 2026-10-26 item 4): ended by its owner, or
    /// suspended / disabled by Fariin. The rules refuse every change, so no switch, link, type or
    /// request row offers one; the members and admins stay readable.
    private var closed: Bool { conv.map { $0.groupMod.state == "ended" || $0.fariinLocked } ?? false }
    private func can(_ r: Conversation.Right) -> Bool { !closed && (conv?.adminCan(me, r) ?? false) }
    /// The permissions are group rules: the change-info right edits them, other admins read them.
    private var canEdit: Bool { can(.changeInfo) }

    /// The primary link's code from the server (getShareLink), as the requests page reads it; nil
    /// until it answers or when it fails, then the group doc's old `inviteCode`.
    @State private var shareCode: String?
    /// Permissions page: Send media's kinds shown, and the slow-mode step while dragging.
    @State private var mediaExpanded = false
    @State private var slowDraft: Int?

    private var isPublicNow: Bool { conv?.isPublic ?? false }

    /// The Reactions row's value: Off, Any, or the channel's own emoji.
    private var reactionsValue: String {
        switch conv?.reactMode {
        case "off": return "Off"
        case "some": return (conv?.reactList ?? []).joined()
        default: return "Any"
        }
    }

    // Sign Posts is gone (owner 2026-10-29: "remove this feature"): a post always comes from the
    // channel. What is left here is Reactions.
    @ViewBuilder private var channelPostsSection: some View {
        if canEdit {
            Section {
                // What followers may react with (2026-10-29).
                NavigationLink { ChannelReactionsSettingsView(cid: cid) } label: {
                    HStack {
                        Text("Reactions")
                        Spacer()
                        Text(reactionsValue).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    var body: some View {
        // ⛔ SHORT CARDS THAT OPEN THEIR OWN PAGES (owner 2026-10-19, later: "when you tap you get
        // the options you need, instead of one flat page"). Joining (Group Type, link, requests),
        // People (members, admins, removed), Permissions. Every row keeps the right it needed.
        List {
            joiningSection
            // 2026-10-27: not on a group whose members Fariin staff hid (`hideMembers`), for
            // anyone but staff; the owner and admins included.
            // A channel's own admins manage its admins (2026-10-28), though its members are hidden.
            if conv?.isChannel == true || !(conv?.hideMembers == true && !AdminStore.shared.isAdmin) { peopleSection }
            // A channel: followers have no permissions to set; its posts have Reactions instead.
            if conv?.isChannel == true { channelPostsSection } else { permissionsSection }
            chatSection
        }
        .listStyle(.insetGrouped)
        // owner 2026-10-27 ("space between cards is big"): the group page's own card gap (20).
        .listSectionSpacing(20)
        .contentMargins(.top, 12, for: .scrollContent)
        .navigationTitle(conv?.isChannel == true ? "Channel Settings" : "Group Settings")
        .navigationBarTitleDisplayMode(.inline)
        // Started once and kept while a child page is pushed; removed with the page (`ListenerBox`).
        .onAppear {
            attachListeners()
            // Again on every return: the link page may have reset or turned off the link.
            if can(.inviteUsers) {
                Task { await loadShareCode() }
                GroupLinksCache.warm(cid)   // the Invite Link page then opens filled (owner 2026-10-21)
            }
        }
        // 2026-10-20 (owner): after `FirestoreHub.swap` both listeners belong to the stuck client.
        // Let go of them off-main and attach again on the fresh one; what is on screen stays.
        .onReceive(NotificationCenter.default.publisher(for: FirestoreHub.swapped)) { _ in
            guard convListener.reg != nil || reqListener.reg != nil else { return }
            FirestoreHub.drop([convListener.reg, reqListener.reg])
            convListener.reg = nil
            reqListener.reg = nil
            attachListeners()
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
        // Disappearing Messages, moved here from the group page (owner 2026-10-20). Turning it on
        // asks first: in a group it deletes for every member.
        // The question after the page is really down (its onDismiss), not on a guessed delay
        // (audit 2026-10-20: a slow close dropped the alert).
        // A full page from the right, not a sheet (owner 2026-10-20). The question once it is back.
        .onChange(of: showDisappear) { _, open in
            if !open, let s = chosenDisappear { chosenDisappear = nil; pendingDisappear = s }
        }
        .navigationDestination(isPresented: $showDisappear) {
            let current = conv?.disappearSeconds ?? 0
            DisappearingMessagesView(cid: cid, current: current, pushed: true) { s in
                if s == 0 { if current != 0 { setTimer(0) } }
                else if s != current {
                    chosenDisappear = s
                }
            }
        }
        .alert("Turn on disappearing messages?", isPresented: Binding(
            get: { pendingDisappear != nil }, set: { if !$0 { pendingDisappear = nil } })) {
            Button("Cancel", role: .cancel) { pendingDisappear = nil }
            Button("Turn On") {
                if let s = pendingDisappear { setTimer(s) }
                pendingDisappear = nil
            }
        } message: {
            Text(ChannelWords.forChat(cid, "New messages in this group will be deleted for all members after \(ChatService.disappearLabel(pendingDisappear ?? 86_400)). Everyone will see that you turned this on."))
        }
    }

    @State private var showDisappear = false
    @State private var pendingDisappear: Int?
    @State private var chosenDisappear: Int?

    private func setTimer(_ seconds: Int) {
        Task {
            // Confirmed by the server, or said (audit 2026-10-26 item 20); offline it is not tried.
            let ok = (try? await GroupSettingWrite.confirmed {
                if !(await ChatService.setDisappear(cid, seconds: seconds)) { throw GroupSettingWrite.NotSaved() }
            }) != nil
            if !ok {
                actionError = "The disappearing message timer was not changed. Check your connection and try again."
            }
        }
    }

    /// Disappearing Messages and, for admins, Member Changes (owner 2026-10-20: out of the group page).
    private var chatSection: some View {
        Section {
            Button {
                if canEdit { showDisappear = true }
                else if closed { actionError = ChannelWords.forChat(cid, conv?.groupMod.noticeText ?? "") }
                else { actionError = "Only admins can change this." }
            } label: {
                HStack {
                    valueRow("timer", "Disappearing Messages",
                             (conv?.disappearSeconds ?? 0) == 0 ? "Off" : ChatService.disappearLabel(conv?.disappearSeconds ?? 0))
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .foregroundStyle(.primary)
            }
            // ⛔ CHAT HISTORY FOR NEW MEMBERS (owner 2026-10-20): Visible or Hidden. Change-info admins.
            // Not in a channel: its posts are what a follower comes for (2026-10-29).
            if canEdit, conv?.isChannel != true {
                NavigationLink {
                    ChatHistoryForNewMembersPage(cid: cid, hidden: (conv?.hideHistoryAt ?? 0) > 0)
                } label: {
                    valueRow("ic_gs_chat_history", "Chat History",
                             (conv?.hideHistoryAt ?? 0) > 0 ? "Hidden" : "Visible")
                }
            }
            // ONE HISTORY (owner 2026-10-26): Recent Actions, the server's admin log, lives here only.
            // It replaced the History page built from notice lines and the row on the group page.
            if (conv?.isAdmin(me) ?? false) || (conv?.isOwner(me) ?? false) {
                NavigationLink { GroupRecentActionsView(cid: cid) } label: {
                    valueRow("clock.arrow.circlepath", "Recent Actions", "")
                }
            }
        }
    }

    // MARK: Joining

    /// Type and links: change-info admins see Type; the invite link and requests need inviteUsers.
    @ViewBuilder private var joiningSection: some View {
        if canEdit || can(.inviteUsers) {
            Section {
                // Private / Public and the public link name live on the Group Type page.
                if canEdit {
                    NavigationLink { GroupTypeView(cid: cid) } label: {
                        valueRow("ic_gs_group_type", conv?.isChannel == true ? "Channel Type" : "Group Type", isPublicNow ? "Public" : "Private")
                    }
                }
                if can(.inviteUsers) {   // public groups have invite links too (owner 2026-10-20)
                    NavigationLink {
                        InviteLinkSheet(cid: cid, groupTitle: conv?.title ?? "Group", groupPhoto: conv?.avatarUrl,
                                        initialCode: shareCode ?? conv?.inviteCode ?? "", embedded: true)
                    } label: {
                        valueRow("link", "Invite Link", inviteValue == "Off" ? "Off" : "On")
                    }
                }
                if can(.inviteUsers) {
                    NavigationLink { GroupRequestsView(cid: cid) } label: {
                        valueRow("ic_gs_join_requests", conv?.isChannel == true ? "Follow Requests" : "Join Requests",
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

    /// Started once and kept while a child page is pushed (`ListenerBox`); again after a swap.
    private func attachListeners() {
        if convListener.reg == nil {
            // Server-confirmed copies only (audit 2026-10-26 item 20): a write still waiting in the
            // local cache is not shown as the group's state. The metadata changes are what bring
            // the confirmed copy in when the server acknowledges a write.
            convListener.reg = FirestoreHub.db.collection("conversations").document(cid)
                .addSnapshotListener(includeMetadataChanges: true) { snap, _ in
                    guard let snap, snap.exists, !snap.metadata.hasPendingWrites, let data = snap.data() else { return }
                    ownConv = Conversation(id: snap.documentID, data: data)
                }
        }
        guard reqListener.reg == nil, can(.inviteUsers) else { return }
        reqListener.reg = GroupInviteService.joinRequests(cid: cid) { joinReqs = $0 }
    }

    // MARK: People

    private var peopleSection: some View {
        Section {
            // A channel's people are its followers; its "members" are only the admins (2026-10-29).
            if conv?.isChannel == true {
                NavigationLink { ChannelFollowersView(cid: cid, count: conv?.followerCount ?? 0) } label: {
                    valueRow("ic_gs_members", "Followers", "\(conv?.followerCount ?? 0)")
                }
                // Moved here off the channel's info page (owner 2026-10-29); hidden with the
                // feature (`Flags.schedulePosts`).
                if Flags.schedulePosts {
                    NavigationLink { ScheduledPostsView(cid: cid) } label: {
                        valueRow("calendar.badge.clock", "Scheduled Posts", "")
                    }
                }
            } else {
                NavigationLink { GroupMembersListView(cid: cid) } label: {
                    valueRow("ic_gs_members", "Members", "\(conv?.users.count ?? 0)")
                }
            }
            NavigationLink { GroupAdminsView(cid: cid) } label: {
                valueRow("ic_gs_admins", "Administrators", "\(conv?.admins.count ?? 0)")
            }
            // REMOVED USERS, the people taken out of the group (`bannedUids`).
            if can(.banUsers) || can(.inviteUsers) {
                NavigationLink { GroupRemovedUsersView(cid: cid) } label: {
                    valueRow("ic_gs_banned", "Banned Users", "\(conv?.bannedUids.count ?? 0)")
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
                valueRow("ic_gs_permissions", "Permissions", "\(permissionCount.on)/\(permissionCount.of)")
            }
        }
    }

    /// The member switches and Protect Content, on their own page.
    /// ⛔ OWNER 2026-10-20, the reference's layout (our words): one card. Send messages, then Send
    /// media with its count and a chevron that opens the kinds as tick rows in the same card, then
    /// the other member rights; Slow mode under it; Protect content last.
    private var permissionsPage: some View {
        List {
            Section {
                switchRow("Send messages", get: { !$0.onlyAdminsSend }) { v in
                    try await ChatService.setOnlyAdminsSend(cid: cid, !v)
                }
                if !(conv?.onlyAdminsSend ?? false) {
                    mediaHeaderRow
                    if mediaExpanded {
                        ForEach(Conversation.SendKind.allCases, id: \.self) { k in mediaTickRow(k) }
                    }
                }
                switchRow("Add members", get: { $0.membersCanAdd }) { v in
                    try await ChatService.setGroupPermission(cid: cid, key: "membersCanAdd", v)
                }
                switchRow("Change group info", get: { $0.membersCanEditInfo }) { v in
                    try await ChatService.setGroupPermission(cid: cid, key: "membersCanEditInfo", v)
                }
                if CallFeatures.groupCalls {
                    switchRow("Start calls", get: { !$0.onlyAdminsCall }) { v in
                        try await ChatService.setGroupPermission(cid: cid, key: "onlyAdminsCall", !v)
                    }
                }
            } header: {
                Text("What can members do?")
            } footer: {
                Text("Turned off, only admins can do it.")
            }
            if AppFeatures.slowMode { slowModeSection }
            privacySection
        }
        .animation(.snappy(duration: 0.25), value: mediaExpanded)
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

    // MARK: Send media row, its tick rows, and Slow mode (owner 2026-10-20)

    /// "Send media  7/9 ⌄" with the all-or-nothing switch; tapping the words opens the kinds.
    private var mediaHeaderRow: some View {
        HStack(spacing: 6) {
            Button { mediaExpanded.toggle() } label: {
                HStack(spacing: 6) {
                    Text("Send media").foregroundStyle(.primary)
                    Text("\(mediaOnCount)/\(Conversation.SendKind.allCases.count)")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Image(systemName: mediaExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { mediaOnCount > 0 }, set: { setAllMedia($0) }))
                .labelsHidden()
                .disabled(!canEdit)
        }
    }

    /// One kind: a tick (allowed) or an empty circle (admins only); tap flips it.
    private func mediaTickRow(_ k: Conversation.SendKind) -> some View {
        let on = conv?.membersMaySend(k) ?? true
        return Button {
            guard canEdit else { return }
            run { try await writeKind(k, !on) }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
                Text(k.label).foregroundStyle(.primary)
                Spacer()
            }
            .padding(.leading, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Slow mode: how long a member waits between messages. Admins are never slowed.
    private static let slowSteps: [(Int, String)] =
        [(0, "Off"), (5, "5s"), (10, "10s"), (30, "30s"), (60, "1m"), (300, "5m"), (900, "15m"), (3600, "1h")]

    private var slowModeSection: some View {
        let current = conv?.slowModeSeconds ?? 0
        // The nearest step, so a value no step names (another client's) never reads as Off.
        let index = Self.slowSteps.indices.min { abs(Self.slowSteps[$0].0 - current) < abs(Self.slowSteps[$1].0 - current) } ?? 0
        return Section {
            VStack(spacing: 6) {
                HStack {
                    ForEach(Self.slowSteps.indices, id: \.self) { i in
                        Text(Self.slowSteps[i].1).font(.caption)
                            .foregroundStyle(i == index ? Color.primary : Color.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                Slider(value: Binding(
                    get: { Double(slowDraft ?? index) },
                    // A tick per step, as the link limits have (owner 2026-10-20).
                    set: { v in
                        let i = Int(v.rounded())
                        if i != (slowDraft ?? index) { UISelectionFeedbackGenerator().selectionChanged() }
                        slowDraft = i
                    }),
                    in: 0...Double(Self.slowSteps.count - 1), step: 1) { editing in
                        guard !editing, let d = slowDraft else { return }
                        let secs = Self.slowSteps[d].0
                        guard secs != current else { slowDraft = nil; return }
                        // The thumb stays where it was let go until the server answers; refused or
                        // not confirmed, it goes back (audit 2026-10-26 item 20).
                        Task {
                            do { try await GroupSettingWrite.confirmed { try await ChatService.setGroupSlowMode(cid: cid, seconds: secs) } }
                            catch { actionError = error.localizedDescription }
                            slowDraft = nil
                        }
                    }
                .disabled(!canEdit)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Slow mode")
        } footer: {
            Text("How long each member must wait before sending their next message.")
        }
    }

    // MARK: Media & content (owner 2026-10-20: one switch for all, then each kind on its own)

    private var mediaOnCount: Int {
        Conversation.SendKind.allCases.filter { conv?.membersMaySend($0) ?? true }.count
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
                    Toggle(isOn: bool("kind." + k.rawValue, get: { $0.membersMaySend(k) }, set: { v in
                        try await writeKind(k, v)
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

    /// One kind; while the old `media` key is still there, its photos/videos partner is written too.
    private func writeKind(_ k: Conversation.SendKind, _ on: Bool) async throws {
        var pair: (String, Bool)?
        if conv?.memberSend["media"] != nil, k == .photos || k == .videos {
            let other: Conversation.SendKind = k == .photos ? .videos : .photos
            pair = (other.rawValue, conv?.membersMaySend(other) ?? true)
        }
        try await ChatService.setMemberSendKind(cid: cid, k.rawValue, on, pair: pair)
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
        Toggle(title, isOn: bool(title, get: get, set: write))
            .disabled(!canEdit)
    }

    // ⛔ NO ADMINS SECTION HERE (owner 2026-10-25: "this page is only members"). Who may post group
    // stories is each admin's Add story right, on their own page.

    // MARK: Privacy

    private var privacySection: some View {
        Section {
            Toggle(isOn: bool("protect", get: { $0.isRestricted },
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
            // "ic_" = the owner's own outline icons (2026-10-21), else an SF Symbol.
            if icon.hasPrefix("ic_") {
                Image(icon).resizable().scaledToFit().frame(width: 24, height: 24).frame(width: 26)
            } else {
                // 21, not 17 (owner 2026-10-21: beside his 24pt drawings these looked small).
                Image(systemName: icon).font(.system(size: 21)).frame(width: 26)
            }
            Text(title)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        }
    }

    /// Runs a write and says so if it is refused, or not confirmed in time (`GroupSettingWrite`).
    private func run(_ op: @escaping () async throws -> Void) {
        Task {
            do { try await GroupSettingWrite.confirmed(op) } catch {
                let msg = error.localizedDescription
                await MainActor.run { actionError = msg }
            }
        }
    }

    /// A binding onto the live group: reads the conversation, writes through `set`, says so if the
    /// write is refused (the page never pretends a change went through).
    /// `key` names the switch: while its write is out, the switch holds the tap (`inFlight`); refused
    /// or not confirmed in time, it goes back to the group's confirmed value and the alert says why
    /// (audit 2026-10-26 item 20).
    private func bool(_ key: String, get: @escaping (Conversation) -> Bool,
                      set: @escaping (Bool) async throws -> Void) -> Binding<Bool> {
        Binding(
            get: { inFlight[key] ?? conv.map(get) ?? false },
            set: { v in
                inFlight[key] = v
                Task {
                    do {
                        try await GroupSettingWrite.confirmed { try await set(v) }
                        // The confirmed copy normally lands with the write's answer; a moment more
                        // if it is behind, so the switch does not flick back and forth.
                        if await MainActor.run(body: { conv.map(get) != v }) {
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                        }
                    } catch {
                        let msg = error.localizedDescription
                        await MainActor.run { actionError = msg }
                    }
                    await MainActor.run { inFlight[key] = nil }
                }
            })
    }
    /// The switches whose write is still out, with the value tapped (see `bool`).
    @State private var inFlight: [String: Bool] = [:]
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
    /// The member whose profile Info opened, pushed on this page's stack.
    @State private var profileUid: String?
    @State private var showPick = false
    /// Bumped after a channel admin invite goes out, so the waiting list shows it at once.
    @State private var invitesTick = 0
    /// A channel's admin invites still waiting, and the one being revoked (`ChannelPendingAdminsLoader`).
    @State private var pendingAdmins: [ChannelAdminInvites.Pending] = []
    @State private var revokingAdmin: ChannelAdminInvites.Pending?
    @State private var actionError: String?
    /// The member picked in Add Admin; their Add Admin page is pushed in the sheet.
    @State private var pickedAdmin: String?
    @State private var pickQuery = ""
    @State private var showInvite = false

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
                if canAddAdmins && conv?.isChannel == true {
                    // A channel has no members to pick from: an admin is invited, and accepts (2026-10-29).
                    // Worded "Add Admin" like a group's (owner 2026-10-29); the accept step stays.
                    Button { showInvite = true } label: { Label("Add Admin", systemImage: "person.badge.plus") }
                } else if canAddAdmins && !others.isEmpty {
                    Button { showPick = true } label: { Label("Add Admin", systemImage: "person.badge.plus") }
                }
                ForEach(admins, id: \.self) { uid in
                    GroupMemberRow(conv: conv, uid: uid, me: me) { opened = uid }.equatable()
                        .listRowInsets(EdgeInsets())
                }
            } footer: {
                // Moved here from the Group Settings page (owner's picture, 2026-10-19).
                Text(conv?.isChannel == true
                     ? "Admins post in the channel. The owner decides what else each admin can do. Followers never see who the admins are."
                     : "The owner decides what each admin can do. Tap an admin to see what they can do, including removing members.")
            }
            // A channel's admin invites not yet accepted (moved here off the info page, 2026-10-29).
            if conv?.isChannel == true && canAddAdmins && !pendingAdmins.isEmpty {
                ChannelPendingAdminsSection(pending: pendingAdmins) { revokingAdmin = $0 }
            }
        }
        .listStyle(.insetGrouped)
        .modifier(ChannelPendingAdminsLoader(cid: cid, on: conv?.isChannel == true && canAddAdmins,
                                             tick: invitesTick, pending: $pendingAdmins,
                                             revoking: $revokingAdmin))
        .navigationTitle("Administrators")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: Binding(get: { opened.map { Opened(id: $0) } }, set: { opened = $0?.id })) { o in
            // Info closes the card and pushes their profile here, as a full page (2026-10-20).
            GroupMemberSheet.make(cid: cid, conv: conv, me: me, uid: o.id,
                                  onInfo: { profileUid = $0 })
        }
        .navigationDestination(item: $profileUid) { uid in
            ContactInfoView(cid: ChatService.convId(me, uid), name: conv?.names[uid] ?? "User",
                            photoUrl: conv?.photos[uid], source: .calls)
        }
        .sheet(isPresented: $showInvite) {
            AddPeopleSheet(alreadyIn: Set(conv?.users ?? []), actionTitle: "Add", linkCap: 16) { people in
                let title = conv?.title ?? "Channel"
                Task {
                    do {
                        let refused = try await ChannelAdminInvites.invite(cid: cid, title: title, people: people)
                        ToastNotice.show(refused.isEmpty ? "Sent. They become an admin when they accept."
                                         : "Sent. Not sent to: " + refused.joined(separator: ", "))
                        invitesTick += 1
                    } catch { ToastNotice.show(error.localizedDescription) }
                }
            }
        }
        .sheet(isPresented: $showPick, onDismiss: { pickedAdmin = nil; pickQuery = "" }) {
            // Pick a member, then their Add Admin page (rights, tag, the button), in the sheet.
            NavigationStack {
                let q = pickQuery.trimmingCharacters(in: .whitespaces)
                let pickList = q.isEmpty ? others
                    : others.filter { (conv?.names[$0] ?? "").localizedCaseInsensitiveContains(q) }
                List(pickList, id: \.self) { uid in
                    GroupMemberRow(conv: conv, uid: uid, me: me) { pickedAdmin = uid }.equatable()
                        .listRowInsets(EdgeInsets())
                }
                .navigationTitle("Choose Member")
                .navigationBarTitleDisplayMode(.inline)
                // owner 2026-10-27: a search at the foot (the Glow list's placement) and an X, not "Cancel".
                .searchable(text: $pickQuery, prompt: "Search")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showPick = false } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("Close")
                    }
                    DefaultToolbarItem(kind: .search, placement: .bottomBar)
                }
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
        case .postStories:    return "Add story"
        case .addAdmins:      return "Add admins"
        }
    }
    /// The same right in a channel's words (2026-10-29): posts and followers, not messages and members.
    func shortLabel(channel: Bool) -> String {
        guard channel else { return shortLabel }
        switch self {
        case .changeInfo:     return "Change channel info"
        case .deleteMessages: return "Delete posts"
        case .banUsers:       return "Remove followers"
        case .inviteUsers:    return "Invite followers"
        case .pinMessages:    return "Pin posts"
        default:              return shortLabel
        }
    }
    /// Rights that do something here: a channel has no calls. It does have stories (owner
    /// 2026-10-29 audit F4): an admin's Add story switch was hidden, so only the owner could post one.
    /// Needs the server's CHANNEL_ADMIN_RIGHTS to carry postStories too (server lane).
    func applies(channel: Bool) -> Bool {
        !channel || self != .manageCalls
    }
    /// The chat list first, then any channel this device has decoded (a visitor's page, a link,
    /// a channel I just unfollowed: `KnownChannels`, owner 2026-10-29 audit U1).
    static func isChannel(_ cid: String) -> Bool {
        ConversationsRepository.shared.conversations.first { $0.id == cid }?.isChannel == true
            || KnownChannels.contains(cid)
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
    @State private var tagColor: String?
    @State private var busy = false
    @State private var actionError: String?
    @State private var promoted = false

    // The group itself, live (2026-10-20): roles and rights show the moment they change.
    @State private var live = LiveGroupDoc()
    private var conv: Conversation? { live.start(cid); return live.conv ?? repo.conversations.first { $0.id == cid } }
    private var name: String { conv?.names[uid] ?? "User" }
    private var grantable: [Conversation.Right] {
        let mine = Set(conv?.adminRightsOf(me).map(\.rawValue) ?? [])
        return Conversation.Right.allCases.filter { mine.contains($0.rawValue) && $0.applies(channel: conv?.isChannel == true) }
    }
    /// No tags in a channel (owner 2026-10-29).
    private var mayTag: Bool { conv?.isChannel != true && (conv?.adminCan(me, .changeInfo) ?? false) }

    // ⛔ THE MEMBER CARD'S EDIT PAGE DESIGN (owner 2026-10-25: "this page is using old design"):
    // centred photo, name and the Admin badge they are about to get, "What this admin can do", the
    // tag field with its count and colours, and the blue Add in the top bar like that page's Done.
    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    AvatarView(name: name, photoUrl: conv?.photos[uid], size: 80)
                    HStack(spacing: 6) {
                        Text(name).font(.title3.weight(.semibold)).lineLimit(1)
                        VerifiedMark(uid: uid, size: 15)
                    }
                    HStack(spacing: 6) {
                        Label("Admin", systemImage: "checkmark.shield.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline)
                            .lineLimit(1)
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
                            .foregroundStyle(Color.primary)
                        let words = GroupRole.clean(tag)
                        if mayTag && !words.isEmpty {
                            RoleChip(role: GroupRole(text: words, emoji: nil, color: tagColor))
                        }
                    }
                    .animation(.snappy(duration: 0.2), value: tag)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .listRowBackground(Color.clear)
            }
            Section {
                ForEach(grantable, id: \.id) { r in
                    Toggle(r.shortLabel(channel: conv?.isChannel == true), isOn: Binding(
                        get: { rights.contains(r.rawValue) },
                        set: { on in if on { rights.insert(r.rawValue) } else { rights.remove(r.rawValue) } }))
                    .disabled(busy)
                }
            } header: {
                Text("What this admin can do")
            } footer: {
                if grantable.contains(.addAdmins) && !rights.contains(Conversation.Right.addAdmins.rawValue) {
                    Text(ChannelWords.forChat(cid, "They won't be able to make other members admins."))
                }
            }
            if mayTag {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "tag").foregroundStyle(.secondary)
                        TagTextField(text: $tag, autoFocus: false)
                            .disabled(busy)
                        Text("\(tag.utf16.count)/\(GroupRole.maxText)")
                            .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    TagColourRow(color: $tagColor)
                        .disabled(busy)
                } header: {
                    Text("Tag")
                } footer: {
                    Text(ChannelWords.forChat(cid, "A short word next to the name in this group, like Host or Teacher. Everyone in the group sees it."))
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .contentMargins(.top, 0, for: .scrollContent)
        .listSectionSpacing(.compact)
        .navigationTitle("Add Admin")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if busy {
                    ProgressView()
                } else {
                    Button("Add") { add() }
                        .fontWeight(.semibold)
                        .buttonStyle(.glassProminent)
                        .tint(Color(hex: 0x2392FE))
                }
            }
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
        let tint = tagColor
        let already = promoted
        Task {
            do {
                // Once promoted, a retry only saves the tag (audit 2026-10-20: a failed tag left
                // the button live and a second tap promoted, and posted the notice, again).
                if !already {
                    try await ChatService.promoteGroupAdmin(cid: cid, uid: uid, name: name, rights: list)
                    await MainActor.run { promoted = true }
                }
                if !words.isEmpty { try await ChatService.setRole(cid: cid, uid: uid, text: words, emoji: nil, color: tint) }
                await MainActor.run { busy = false; onDone() }
            } catch {
                let msg = error.localizedDescription
                await MainActor.run {
                    busy = false
                    actionError = promoted ? "\(name) is an admin now, but the tag was not saved. \(msg)" : msg
                }
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
    /// Names of banned people the group doc does not hold (a channel's followers never were members).
    @State private var fetched: [String: UserProfile] = [:]

    // The group itself, live (2026-10-20): roles and rights show the moment they change.
    @State private var live = LiveGroupDoc()
    private var conv: Conversation? { live.start(cid); return live.conv ?? repo.conversations.first { $0.id == cid } }
    private func name(_ uid: String) -> String { conv?.names[uid] ?? fetched[uid]?.name ?? "User" }
    private func photo(_ uid: String) -> String? { conv?.photos[uid] ?? fetched[uid]?.photoUrl }

    var body: some View {
        List {
            Section {
                // The empty state sits in the card itself (owner 2026-10-19), not under it.
                if conv?.bannedUids.isEmpty ?? true {
                    Text(conv?.isChannel == true ? "Nobody is banned from this channel." : "Nobody is banned from this group.")
                        .foregroundStyle(.secondary)
                }
                ForEach(conv?.bannedUids ?? [], id: \.self) { uid in
                    HStack(spacing: 12) {
                        AvatarView(name: name(uid), photoUrl: photo(uid), size: 40)
                        Text(name(uid)).lineLimit(1)
                        Spacer(minLength: 8)
                        if busy == uid {
                            ProgressView()
                        } else {
                            Button("Unban") { unban(uid) }
                                .buttonStyle(.borderless)
                                .disabled(busy != nil)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Banned Users")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: conv?.bannedUids ?? []) {
            for uid in conv?.bannedUids ?? [] where conv?.names[uid] == nil && fetched[uid] == nil {
                if let p = await ProfileStore.shared.fetch(uid) { fetched[uid] = p }
            }
        }
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
        Conversation.Right.allCases.filter { grantable.contains($0.rawValue) && $0.applies(channel: Conversation.Right.isChannel(cid)) }
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
                    Toggle(Conversation.Right.isChannel(cid) ? r.shortLabel(channel: true) : r.label, isOn: Binding(
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
                // Confirmed or put back, never left spinning offline (audit 2026-10-26 item 20).
                try await GroupSettingWrite.confirmed { try await ChatService.setAdminRights(cid: cid, uid: uid, rights: list) }
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
    /// The member whose profile Info opened, pushed on this page's stack.
    @State private var profileUid: String?
    @State private var showAdd = false
    @State private var pendingRemove: String?
    @State private var removeError: String?

    // The group itself, live (2026-10-20): roles and rights show the moment they change.
    @State private var live = LiveGroupDoc()
    private var conv: Conversation? { live.start(cid); return live.conv ?? repo.conversations.first { $0.id == cid } }
    // A member an admin kept from adding sees no Add (audit 2026-10-20; the rules refuse it).
    private var canAdd: Bool {
        // An ended or Fariin-locked group takes nobody new (audit 2026-10-26 item 4).
        guard let c = conv, c.groupMod.state != "ended", !c.fariinLocked else { return false }
        return c.adminCan(me, .inviteUsers)
            || (c.membersCanAdd && !c.isRestricted(me, .addMembers, now: Date().timeIntervalSince1970 * 1000))
    }
    private func canRemove(_ uid: String) -> Bool {
        guard let c = conv, uid != me, !c.isOwner(uid), c.adminCan(me, .banUsers) else { return false }
        return c.isOwner(me) || !c.isAdmin(uid)
    }
    private func filtered(_ conv: Conversation?) -> [String] {
        let all = GroupMembers.sorted(conv, me: me)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        // And by @username (audit 2026-10-26 item 17), once the members' handles are in.
        let handleQ = q.hasPrefix("@") ? String(q.dropFirst()) : q
        return all.filter {
            (conv?.names[$0] ?? "").lowercased().contains(q)
                || (!handleQ.isEmpty && (handles[$0]?.lowercased().contains(handleQ) ?? false))
        }
    }
    @State private var handles: [String: String] = [:]
    @State private var handlesAsked = false

    var body: some View {
        // Read once per body (2026-10-19 fix round): the group lookup and the sort ran per use.
        let conv = self.conv
        let shown = filtered(conv)
        return List {
            if canAdd && query.isEmpty {
                Section {
                    Button { showAdd = true } label: { Label { Text("Add Members") } icon: { Image("ic_add_members_line") } }
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
                                Button("Remove", role: .destructive) { pendingRemove = uid }.tint(.red)   // the app tint is .primary (black)
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
                    do {
                        try await ChatService.removeGroupMember(cid: cid, uid: uid, name: name)
                        await MainActor.run { ToastNotice.show("\(name) was removed from the group.") }
                    } catch { removeError = error.localizedDescription }
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
        .onChange(of: query) { _, q in
            guard !q.isEmpty, !handlesAsked else { return }
            handlesAsked = true
            let uids = conv?.users ?? []
            Task { handles = await ProfileStore.shared.handles(for: uids) }
        }
        // `.toolbar` placement alone leaves the field at the top on a pushed page; asking for the
        // system search item in the bottom bar is what puts it at the foot on iOS 26.
        .toolbar { DefaultToolbarItem(kind: .search, placement: .bottomBar) }
        .navigationTitle("Members")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: Binding(get: { opened.map { Opened(id: $0) } }, set: { opened = $0?.id })) { o in
            // Info closes the card and pushes their profile here, as a full page (2026-10-20).
            GroupMemberSheet.make(cid: cid, conv: conv, me: me, uid: o.id,
                                  onInfo: { profileUid = $0 })
        }
        .navigationDestination(item: $profileUid) { uid in
            ContactInfoView(cid: ChatService.convId(me, uid), name: conv?.names[uid] ?? "User",
                            photoUrl: conv?.photos[uid], source: .calls)
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
    @State private var busyReqs = Set<String>()   // one tap per person while it is answered
    /// Answered on this screen: the row goes AT ONCE (owner 2026-10-23: "I need to approve 10 people
    /// fast, each card gone in a second"), the server catches up behind; a failure brings it back.
    @State private var answeredReqs = Set<String>()
    private var shownReqs: [JoinRequest] { joinReqs.filter { !answeredReqs.contains($0.uid) } }
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
    // A member an admin kept from adding sees no Add (audit 2026-10-20; the rules refuse it).
    private var canAdd: Bool {
        // An ended or Fariin-locked group takes nobody new (audit 2026-10-26 item 4).
        guard let c = conv, c.groupMod.state != "ended", !c.fariinLocked else { return false }
        return c.adminCan(me, .inviteUsers)
            || (c.membersCanAdd && !c.isRestricted(me, .addMembers, now: Date().timeIntervalSince1970 * 1000))
    }

    var body: some View {
        // Requests only (owner 2026-10-20): the invite links have their own page and card.
        List { requestsSections }
        .listStyle(.insetGrouped)
        .navigationTitle(Conversation.Right.isChannel(cid) ? "Follow Requests" : "Join Requests")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard reqListener == nil else { return }
            reqListener = GroupInviteService.joinRequests(cid: cid) { joinReqs = $0 }
        }
        .onDisappear { reqListener?.remove(); reqListener = nil }
        // 2026-10-20 (owner): after `FirestoreHub.swap` the requests listener belongs to the stuck
        // client. Let go of it off-main and listen again on the fresh one.
        .onReceive(NotificationCenter.default.publisher(for: FirestoreHub.swapped)) { _ in
            busyReqs = []   // an answer waiting on the stuck client never returns; free the rows
            guard reqListener != nil else { return }
            FirestoreHub.drop([reqListener])
            reqListener = GroupInviteService.joinRequests(cid: cid) { joinReqs = $0 }
        }
        .task { await loadShareCode() }
        .task { links = try? await GroupInviteService.listLinks(cid: cid) }
        .sheet(isPresented: $showAdd) { AddMembersSheet(cid: cid, existing: Set(conv?.users ?? [])) }
        // Again after the link sheet closes: it may have reset or turned off the link.
        .sheet(isPresented: $showInvite, onDismiss: {
            Task {
                await loadShareCode()
                // The link page may have turned approval on or off: the line below says which.
                if let fresh = try? await GroupInviteService.listLinks(cid: cid) { links = fresh }
            }
        }) {
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
        if shownReqs.isEmpty {
            // ⛔ ONE QUIET CARD (owner 2026-10-20, with a screenshot): a line in the card, a note under.
            Section {
                Text("No one is waiting to join.")
                    .font(.body).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
            } footer: {
                Text(ChannelWords.forChat(cid, "People who ask to join “\(conv?.title ?? "this group")” with a group link show up here."))
            }
        } else {
            Section("Waiting to join") {
                ForEach(shownReqs) { r in
                    HStack(spacing: 12) {
                        AvatarView(name: r.name, photoUrl: r.photo, size: 40)
                        Text(r.name).foregroundStyle(.primary).lineLimit(1)
                        Spacer(minLength: 8)
                        Button { answer(r.uid) { try await GroupInviteService.denyJoin(cid: cid, uid: r.uid) } } label: {
                            Text("Decline").font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(Capsule().fill(Color(.tertiarySystemFill)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Decline \(r.name)")
                        Button { answer(r.uid) { try await GroupInviteService.approveJoin(cid: cid, uid: r.uid) } } label: {
                            Text("Approve").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                // Blue, not the accent (owner 2026-10-21: white on white in dark mode).
                                .background(Capsule().fill(Color(hex: 0x0A84FF)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Approve \(r.name)")
                    }
                    .disabled(busyReqs.contains(r.uid))
                    .opacity(busyReqs.contains(r.uid) ? 0.5 : 1)
                }
            }
        }
    }

    private var approvalLine: String {
        guard let p = links?.primary else { return "People who ask to join through a link show up here." }
        return p.requestApproval
            ? (Conversation.Right.isChannel(cid) ? "Approve New Followers is on: people who use the link wait here for an admin."
                                                  : "Approve New Members is on: people who use the link wait here for an admin.")
            : (Conversation.Right.isChannel(cid) ? "Approve New Followers is off: people who use the link follow straight away."
                                                  : "Approve New Members is off: people who use the link join straight away.")
    }

    // MARK: Invites

    @ViewBuilder private var invitesSections: some View {
        let active = ([links?.primary].compactMap { $0 } + (links?.links ?? [])).filter { $0.state() == .active }
        if links == nil {
            Section { ProgressView().frame(maxWidth: .infinity) }
        } else if active.isEmpty {
            Section {
                Text(ChannelWords.forChat(cid, "This group has no invite link on.")).foregroundStyle(.secondary)
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
                Button { showAdd = true } label: { Label { Text(ChannelWords.forChat(cid, "Add Members")) } icon: { Image("ic_add_members_line") } }
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

    /// Approve or Decline, once: a second tap while the first is answered would come back as
    /// "already handled" and show an error over a request that worked (audit 2026-10-20).
    private func answer(_ uid: String, _ op: @escaping () async throws -> Void) {
        guard !busyReqs.contains(uid) else { return }
        busyReqs.insert(uid)
        withAnimation(.easeOut(duration: 0.2)) { _ = answeredReqs.insert(uid) }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            do {
                try await op()
                await MainActor.run { _ = busyReqs.remove(uid) }
            } catch {
                let msg = error.localizedDescription
                await MainActor.run {
                    busyReqs.remove(uid)
                    withAnimation { _ = answeredReqs.remove(uid) }   // it did not go through: back on the list
                    actionError = msg
                }
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
    /// Opened from "Add group description...": the keyboard comes up in Description (owner 2026-10-22).
    var focusDescription = false
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var desc = ""
    @State private var descLoaded = false
    @State private var newPhoto: Data?
    @State private var removePhoto = false
    @State private var confirmRemovePhoto = false
    @State private var showPicker = false
    @State private var pickedImage: UIImage?
    @State private var cropItem: GroupCropItem?
    @State private var saving = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool
    @FocusState private var descFocused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    private var trimmedDesc: String { desc.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// A group description's ceiling, the size the large messengers give one.
    /// From the admin panel (`group_desc_max`, fallback 150; owner 2026-10-22).
    private static var descChars: Int { AppLimits.shared.groupDescMax }
    private static let descCounterAppearsAt = 20
    private var descRemaining: Int { max(0, Self.descChars - desc.count) }
    private var changed: Bool {
        newPhoto != nil || removePhoto || trimmed != title
            || trimmedDesc != description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
          ScrollViewReader { proxy in
            List {
                Section {
                    // No badge on the photo; "Set New Photo" under it as plain accent text, no glass
                    // capsule (owner 2026-10-29, replaces the 10-19 Liquid Glass capsule).
                    VStack(spacing: 12) {
                        Button { nameFocused = false; showPicker = true } label: { photo }
                            .buttonStyle(.plain)
                            // A small X on the photo removes it (owner 2026-10-20), after a yes.
                            .overlay(alignment: .topTrailing) {
                                if hasPhoto {
                                    Button { nameFocused = false; confirmRemovePhoto = true } label: {
                                        // ⛔ THE PROFILE PHOTO'S OWN "−" BADGE (owner 2026-10-28: "use
                                        // exactly the badge you used on the profile avatar";
                                        // ProfilePhotoSheet.removeBadge): a minus, 17 semibold, a 40 pt
                                        // Liquid Glass circle, the same offset. Was a small dark ✕.
                                        // Owner 2026-10-29: smaller (30 pt) and mostly outside the photo,
                                        // ~60% out / 40% over it. Centre sits 6 pt past the rim on the
                                        // 45° line of the 120 pt circle.
                                        Image(systemName: "minus")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(Color(.label))
                                            .frame(width: 30, height: 30)
                                            .liquidGlass(Circle(), interactive: true)
                                            .contentShape(Circle().inset(by: -7))
                                    }
                                    .buttonStyle(.plain)
                                    .offset(x: 2, y: -2)
                                    .accessibilityLabel("Remove Photo")
                                }
                            }
                            .alert(ChannelWords.forChat(cid, "Remove group photo?"), isPresented: $confirmRemovePhoto) {
                                Button("Remove", role: .destructive) { newPhoto = nil; removePhoto = true }
                                Button("Cancel", role: .cancel) {}
                            }
                        Button { nameFocused = false; showPicker = true } label: {
                            Text("Set New Photo").font(.body).foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 20).frame(height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                // Name and description in ONE card (owner 2026-10-20), a line between them.
                Section {
                    TextField(ChannelWords.forChat(cid, "Group Name"), text: $name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .focused($nameFocused)
                // ⛔ THE BIO'S RULES (owner 2026-10-18: "use the logic you used for the bio"): one
                // paragraph (a newline never reaches the field, `Limits.oneParagraph`), up to 5 lines,
                // and a countdown that only appears in the last 20 characters, red at 0.
                    VStack(alignment: .trailing, spacing: 6) {
                        TextField("Description",
                                  text: Binding(get: { desc },
                                                set: { desc = Limits.oneParagraph($0, max: Self.descChars) }),
                                  axis: .vertical)
                            .lineLimit(1...5)
                            .focused($descFocused)
                        // Always "used/limit", as the tag field (owner 2026-10-21: say how many
                        // characters they can write); red at the limit.
                        Text("\(desc.count)/\(Self.descChars)")
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(descRemaining == 0 ? .red : .secondary)
                            .accessibilityLabel("\(descRemaining) characters left")
                    }
                    .id("descEnd")
                } footer: {
                    Text(ChannelWords.forChat(cid, "Optional. Shown on the group's info page."))
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
            .navigationTitle(ConversationsRepository.shared.conversations.first(where: { $0.id == cid })?.isChannel == true ? "Edit Channel" : "Edit Group")
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
                // A beat after the sheet starts rising, so the field is in a window to take focus.
                if focusDescription { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { descFocused = true } }
            }
            // The app's own photo sheet, as New Group's photo uses.
            // The picked photo goes to the circle cropper once the picker is down (owner 2026-10-23:
            // "I can't choose the area"), the same move-and-scale a profile photo uses. One cover
            // asked for while the sheet is still closing is how "nothing happens" bugs start, so
            // it waits for onDismiss.
            .sheet(isPresented: $showPicker, onDismiss: {
                if let ui = pickedImage { pickedImage = nil; cropItem = GroupCropItem(image: ui) }
            }) {
                StoryLibraryPicker(
                    onImage: { ui, _ in pickedImage = ui; showPicker = false },
                    onVideo: { _, _ in },   // `photosOnly`: there is no video tile to pick
                    photosOnly: true,
                    pickLabel: ChannelWords.forChat(cid, "Set Group Photo"))
                .storyAlwaysDark()
            }
            .fullScreenCover(item: $cropItem) { c in
                ProfilePhotoCropper(image: c.image,
                                    onDone: { circle, _ in cropItem = nil; setPhoto(circle) },
                                    onCancel: { cropItem = nil },
                                    circleOnly: true,
                                    circleSubtitle: ChannelWords.forChat(cid, "Shown in chats and on the group page"))
                    .ignoresSafeArea()
            }
        }
    }

    private var photo: some View {
        ZStack {
            if let newPhoto, let ui = UIImage(data: newPhoto) {
                Image(uiImage: ui).resizable().scaledToFill()
            } else if removePhoto {
                AvatarView(name: title, photoUrl: nil, size: 120)
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
        Task {
            let data = await Task.detached(priority: .userInitiated) { () -> Data? in
                guard let jpeg = ui.jpegData(compressionQuality: 0.9) else { return nil }
                return ChatService.downscaledJPEG(jpeg, maxDimension: 1024, quality: 0.8)
            }.value
            if let data { newPhoto = data; removePhoto = false }
        }
    }

    private var hasPhoto: Bool { newPhoto != nil || (!removePhoto && !(photoUrl ?? "").isEmpty) }

    /// Name first, then the photo; either refused is said, and the sheet stays.
    /// What the last Save already wrote, so a retry after a failed later step does not rename the
    /// group twice (two "renamed the group" rows; audit 2026-10-20).
    @State private var savedName: String?
    @State private var savedDesc: String?

    private func save() {
        let newName = trimmed, photo = newPhoto, oldName = savedName ?? title
        let newDesc = trimmedDesc, oldDesc = savedDesc ?? description.trimmingCharacters(in: .whitespacesAndNewlines)
        saving = true; error = nil
        Task {
            do {
                if newName != oldName {
                    try await ChatService.renameGroup(cid: cid, title: newName)
                    await MainActor.run { savedName = newName }
                }
                if newDesc != oldDesc {
                    try await ChatService.setGroupDescription(cid: cid, text: newDesc)
                    await MainActor.run { savedDesc = newDesc }
                }
                if let photo { _ = try await ChatService.uploadGroupAvatar(cid: cid, data: photo) }
                else if removePhoto, !(photoUrl ?? "").isEmpty { try await ChatService.removeGroupAvatar(cid: cid) }
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

/// A short capsule over the whole app, for a done action whose page stays (audit 2026-10-20:
/// removals from the lists said nothing).
@MainActor enum ToastNotice {
    static func show(_ text: String) {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first
        else { return }
        let label = PaddedToastLabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .label
        label.numberOfLines = 2
        label.textAlignment = .center
        label.backgroundColor = .secondarySystemBackground
        label.layer.cornerRadius = 18
        label.layer.masksToBounds = true
        let maxW = window.bounds.width - 48
        let size = label.sizeThatFits(CGSize(width: maxW, height: 200))
        let w = min(maxW, size.width), h = size.height
        label.frame = CGRect(x: (window.bounds.width - w) / 2,
                             y: window.bounds.height - window.safeAreaInsets.bottom - h - 70, width: w, height: h)
        label.alpha = 0
        window.addSubview(label)
        UIView.animate(withDuration: 0.25) { label.alpha = 1 }
        UIView.animate(withDuration: 0.3, delay: 1.8, options: []) { label.alpha = 0 } completion: { _ in
            label.removeFromSuperview()
        }
    }
}

private final class PaddedToastLabel: UILabel {
    private let inset = UIEdgeInsets(top: 10, left: 18, bottom: 10, right: 18)
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: inset)) }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let s = super.sizeThatFits(CGSize(width: size.width - inset.left - inset.right, height: size.height))
        return CGSize(width: s.width + inset.left + inset.right, height: s.height + inset.top + inset.bottom)
    }
}

/// A listener kept for the page's real lifetime (2026-10-19 fix round). `.onDisappear` also fires
/// when a child page is pushed on top, which dropped the group's listener while Permissions was
/// open: its switches read a stale group, snapped back and were written twice. Held in `@State`,
/// the box goes (and removes the listener) only when the page itself leaves the stack.
final class ListenerBox {
    var reg: ListenerRegistration?
    // ⛔ NEVER `remove()` HERE DIRECTLY (crash builds 1010 + 1011, 2026-10-23, SIGABRT on the
    // com.google.firebase.firestore thread): the last reference can die inside a Firestore callback
    // block being released ON FIRESTORE'S OWN QUEUE, and remove() from there trips its assertion.
    // `FirestoreHub.drop` removes on a utility queue instead.
    deinit { FirestoreHub.drop([reg]) }
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
    @ObservationIgnored private var swapObserver: NSObjectProtocol?

    /// 2026-10-20 (owner): after `FirestoreHub.swap` the listener belongs to the stuck client. Let go
    /// of it off-main and listen again on the fresh one; `conv` stays on screen meanwhile. Every page
    /// that holds one of these follows the swap without code of its own.
    init() {
        swapObserver = NotificationCenter.default.addObserver(
            forName: FirestoreHub.swapped, object: nil, queue: .main) { [weak self] _ in
            guard let self, let cid = self.started else { return }
            FirestoreHub.drop([self.reg])
            self.reg = nil
            self.started = nil
            self.start(cid)
        }
    }

    func start(_ cid: String) {
        guard started != cid, !cid.isEmpty else { return }
        started = cid
        reg?.remove()
        reg = FirestoreHub.db.collection("conversations").document(cid)
            .addSnapshotListener { [weak self] snap, error in
                guard let self else { return }
                // Removed, or the group deleted, while a page is open (audit 2026-10-20): the read
                // is refused or the doc is gone. Take me out of the copy, so every admin control
                // the page shows turns off at once instead of failing on tap.
                if error != nil || snap?.exists == false {
                    if var c = self.conv, let me = AuthService.shared.uid {
                        c.users.removeAll { $0 == me }
                        c.admins.removeAll { $0 == me }
                        self.conv = c
                    }
                    return
                }
                guard let snap, let data = snap.data() else { return }
                self.conv = Conversation(id: snap.documentID, data: data)
            }
    }

    deinit {
        FirestoreHub.drop([reg])   // never remove() directly in a deinit: see ListenerBox
        if let swapObserver { NotificationCenter.default.removeObserver(swapObserver) }
    }
}

/// Visible or Hidden, ticked, as the Group Type page picks a type. Hidden: people who join from now
/// on see the chat from the moment they come in; nobody already in the group loses anything.
struct ChatHistoryForNewMembersPage: View {
    let cid: String
    @State var hidden: Bool
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                row("Visible", on: !hidden) { set(false) }
                row("Hidden", on: hidden) { set(true) }
            } footer: {
                Text(hidden
                     ? "People who join from now on see only messages sent after they join. Members already in the group still see everything."
                     : "People who join can see the messages sent before they joined.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Chat History")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(saving)
        .alert("Could not do that", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func row(_ title: String, on: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if on { Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Color.accentColor) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func set(_ value: Bool) {
        guard value != hidden, !saving else { return }
        let old = hidden
        hidden = value
        saving = true
        Task {
            // Back to the old tick if the server did not confirm in time (audit 2026-10-26 item 20).
            do { try await GroupSettingWrite.confirmed { try await ChatService.setHideHistory(cid: cid, hidden: value) } }
            catch { hidden = old; self.error = error.localizedDescription }
            saving = false
        }
    }
}

/// A photo picked for the group, waiting in the circle cropper.
struct GroupCropItem: Identifiable { let id = UUID(); let image: UIImage }
