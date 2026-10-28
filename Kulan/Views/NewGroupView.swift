import SwiftUI
import FirebaseFunctions

// New Group, two pages (owner 2026-10-18, "start here first" of the group redesign):
//   1. Select Members: your chats A to Z in grouped cards, round ticks, the search at the bottom,
//      the people you ticked as faces along the top. Skip with nobody ticked (a group may start
//      with only you; firestore.rules allows one member), Next once someone is.
//   2. New Group: the photo circle and the name in one card, Disappearing Messages, the members,
//      Create. The circle opens the app's own photo sheet (the one Add Story and Create Sticker
//      use), photos only.
struct NewGroupView: View {
    let onOpen: (ChatTarget) -> Void
    // `preselect` pre-includes a contact (e.g. "Add to a Group" from a friend's profile).
    // `initial` ticks several at once (owner 2026-10-18: "Create a similar group" on a group's info
    // page hands over its members, me left out by the caller).
    init(preselect: Person? = nil, initial: [Person] = [], onOpen: @escaping (ChatTarget) -> Void = { _ in }) {
        self.onOpen = onOpen
        var people = initial
        if let p = preselect, !people.contains(where: { $0.id == p.id }) { people.insert(p, at: 0) }
        if !people.isEmpty {
            _selected = State(initialValue: Dictionary(people.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
            var seen = Set<String>()
            _order = State(initialValue: people.map(\.id).filter { seen.insert($0).inserted })
        }
    }

    struct Person: Identifiable, Hashable { let id: String; let name: String; let photo: String? }

    private enum Step: Hashable { case details, permissions }

    @Environment(\.dismiss) private var dismiss
    private var convRepo = ConversationsRepository.shared
    @State private var path: [Step] = []
    @State private var groupName = ""
    @State private var avatarData: Data?
    @State private var showPhotoPicker = false
    @State private var pickedImage: UIImage?
    /// Owner 2026-10-28: the camera circle went straight to the photo library, with no way to take a
    /// picture. It asks first now: Take Photo, Choose Photo, and Remove Photo once one is set.
    @State private var showPhotoOptions = false
    @State private var showCamera = false
    @State private var cropItem: GroupCropItem?
    @State private var disappearSeconds = UserDefaults.standard.integer(forKey: "defaultDisappearSeconds")
    @State private var query = ""
    @State private var results: [UserProfile] = []
    @State private var searching = false
    @State private var selected: [String: Person] = [:]   // uid -> person
    @State private var order: [String] = []                // tap order, for the faces and the list
    @State private var creating = false
    // The group's member switches, chosen before it exists (owner 2026-10-19). The same four the
    // group's own Permissions page holds, with the same defaults; written into the new group itself.
    @State private var membersCanSend = true
    @State private var membersCanAdd = false
    @State private var membersCanEdit = false
    @State private var membersCanCall = true
    @State private var membersCanShare = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    private var me: String { AuthService.shared.uid ?? "" }

    // 1:1 contacts (you can't pull members out of another group), de-duped + sorted.
    private var contacts: [Person] {
        convRepo.conversations
            // No demo chats (audit, 2026-09-24): their made-up people were offered here and, once
            // ticked, written into a real group's `users`.
            .filter { !$0.isGroup && !$0.isCleared(me) && !DemoMode.isDemoConversation($0.id) }
            .compactMap { c in
                let uid = c.otherUid(me)
                guard !uid.isEmpty else { return nil }
                return Person(id: uid, name: c.name(for: me), photo: c.photoUrl(for: me))
            }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// The contacts under their first letter, A to Z, anything else last under "#".
    private var lettered: [(letter: String, people: [Person])] {
        let groups = Dictionary(grouping: contacts) { p -> String in
            let c = p.name.trimmingCharacters(in: .whitespaces).prefix(1).uppercased()
            return c.range(of: "^[A-Z]$", options: .regularExpression) != nil ? c : "#"
        }
        return groups.keys
            .sorted { ($0 == "#" ? 1 : 0, $0) < ($1 == "#" ? 1 : 0, $1) }
            .map { ($0, groups[$0] ?? []) }
    }

    private var picked: [Person] { order.compactMap { selected[$0] } }

    private var canCreate: Bool {
        !groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !creating
    }

    var body: some View {
        NavigationStack(path: $path) {
            membersPage
                .navigationDestination(for: Step.self) { step in
                    if step == .permissions { permissionsPage } else { detailsPage }
                }
        }
    }

    // MARK: - Page 1: Select Members

    private var membersPage: some View {
        List {
            if !selected.isEmpty {
                // +1 = you. 2026-09-24 audit: at the cap the header says so, because the next
                // tap only buzzes and otherwise reads as a broken row.
                Section(selected.count >= Self.maxOthersAtCreate
                        ? "Members · \(selected.count + 1) max"
                        : "Members · \(selected.count + 1)") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(picked) { p in
                                Button { toggle(p) } label: {
                                    VStack(spacing: 4) {
                                        ZStack(alignment: .topTrailing) {
                                            AvatarView(name: p.name, photoUrl: p.photo, size: 52)
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 18))
                                                .symbolRenderingMode(.palette)
                                                .foregroundStyle(.white, .gray)
                                                .offset(x: 4, y: -4)
                                        }
                                        Text(p.name).font(.caption2).lineLimit(1).frame(width: 56)
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
                if lettered.isEmpty {
                    Section {
                        Text("Chat with someone first to add them here.").foregroundStyle(.secondary)
                    }
                }
                ForEach(lettered, id: \.letter) { group in
                    Section(group.letter) {
                        ForEach(group.people) { p in memberRow(p) }
                    }
                }
            } else {
                Section("Results") {
                    let rows = results.map { Person(id: $0.id, name: $0.name.isEmpty ? $0.handle : $0.name, photo: $0.photoUrl) }
                    if rows.isEmpty {
                        if searching {
                            ChatListSkeleton()
                        } else {
                            Text("No one found").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(rows) { p in memberRow(p) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: "Name or username")
        .navigationTitle("Select Members")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: { Image(systemName: "xmark") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                // Skip with nobody ticked (owner 2026-10-18: a group may start with only you),
                // Next once someone is.
                Button(selected.isEmpty ? "Skip" : "Next") { path.append(.details) }
                    .fontWeight(.semibold)
            }
        }
        .onChange(of: query) { _, q in search(q) }
    }

    private func memberRow(_ p: Person) -> some View {
        Button { toggle(p) } label: {
            HStack(spacing: 12) {
                AvatarView(name: p.name, photoUrl: p.photo, size: 40)
                HStack(spacing: 4) {
                    Text(p.name).font(.system(size: 17)).foregroundStyle(.primary)
                    VerifiedMark(uid: p.id, size: 13)
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: selected[p.id] != nil ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(selected[p.id] != nil ? Color.accentColor : Color.secondary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // ⛔ THE FORWARD PAGE'S ROW (owner 2026-10-18: "use the spaces the forward page uses"): 5 pt above
        // and below, 16 at the sides, the separator starting at the name (`ForwardPicker.row`).
        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
        .alignmentGuide(.listRowSeparatorLeading) { _ in 52 }
    }

    // MARK: - Page 2: New Group

    private struct DisappearChoice: Hashable { let label: String; let seconds: Int }
    private static let disappearChoices: [DisappearChoice] = [
        .init(label: "Off", seconds: 0), .init(label: "1 Day", seconds: 86_400),
        .init(label: "1 Week", seconds: 604_800), .init(label: "1 Month", seconds: 2_592_000),
    ]

    private var detailsPage: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    Button { nameFocused = false; showPhotoOptions = true } label: { groupAvatarThumb }
                        .buttonStyle(.plain)
                        .accessibilityLabel(avatarData == nil ? "Set Group Photo" : "Change Group Photo")
                    TextField("Group Name", text: $groupName)
                        .font(.title3)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .focused($nameFocused)
                }
                .padding(.vertical, 6)
            }

            Section {
                // The same choices a group's own info page offers.
                // ⛔ THE WHOLE ROW OPENS IT (owner 2026-10-18, build 969: only "Off" answered a tap; the
                // words did nothing). A Menu whose label is the full row, not a `.menu` Picker, which on
                // iOS 26 only takes taps on its value. Off / 1 Day / 1 Week / 1 Month, his list.
                // ⛔ THE ROW STAYS WHILE THE MENU IS OPEN (owner 2026-10-18, build 973: "the menu opens
                // and the text disappears"). An iOS 26 menu hides its label while it is up, and the label
                // was the whole row. The row is drawn on its own now and the menu's label is a clear
                // layer over it, so only that invisible layer is hidden; the whole row still opens it.
                HStack {
                    Text("Disappearing Messages").foregroundStyle(.primary)
                    Spacer()
                    Text(Self.disappearChoices.first { $0.seconds == disappearSeconds }?.label
                         ?? ChatService.disappearLabel(disappearSeconds).capitalized)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                }
                .overlay {
                    Menu {
                        Picker("Disappearing Messages", selection: $disappearSeconds) {
                            ForEach(Self.disappearChoices, id: \.self) { Text($0.label).tag($0.seconds) }
                            // The Settings default, when it is none of these.
                            if !Self.disappearChoices.contains(where: { $0.seconds == disappearSeconds }) {
                                Text(ChatService.disappearLabel(disappearSeconds).capitalized).tag(disappearSeconds)
                            }
                        }
                    } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                    .accessibilityLabel("Disappearing Messages")
                }
            } footer: {
                Text("New messages in this group disappear for everyone once this time has passed.")
            }

            Section {
                Button { nameFocused = false; path.append(.permissions) } label: {
                    HStack {
                        Text("Permissions").foregroundStyle(.primary)
                        Spacer()
                        Text(permissionsCount).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } footer: {
                Text("What members can do. You can change this later in the group's settings.")
            }

            Section {   // no "Members · N of 30" heading (owner 2026-10-20)
                ForEach(picked) { p in
                    HStack(spacing: 12) {
                        AvatarView(name: p.name, photoUrl: p.photo, size: 40)
                        Text(p.name)
                        VerifiedMark(uid: p.id, size: 13)
                    }
                }
            }

            if let error { Text(error).foregroundStyle(.red) }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("New Group")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // The spinner takes the word's place in the button (owner 2026-10-18), not the page's centre.
                // Owner 2026-10-28: the button went grey with a plain spinner while creating (a disabled
                // button is greyed). It stays blue now, with a white ring turning in the word's place;
                // a second tap does nothing (`create` returns while `creating`).
                Button { create() } label: {
                    Text("Create").fontWeight(.semibold)
                        .opacity(creating ? 0 : 1)
                        .overlay { if creating { CreatingRing() } }
                }
                .disabled(!canCreate && !creating)
                    .buttonStyle(.borderedProminent).tint(.blue)   // blue (owner 2026-10-18)
            }
        }
        // Straight to the name, as the page is for naming the group.
        // ⛔ AFTER THE PUSH, NOT DURING IT (owner 2026-10-18, build 969: "the keyboard comes from the
        // right"). Focus at 0.35 s landed inside the iOS 26 push, so the keyboard rode in sideways with
        // the page. 0.6 s is past the push: the keys rise from the bottom on their own. `.task`, so
        // going back before then cancels it and no keyboard opens over the page being left.
        .task {
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { nameFocused = true }
        }
        .confirmationDialog("Group Photo", isPresented: $showPhotoOptions, titleVisibility: .hidden) {
            Button("Take Photo") { showCamera = true }
            Button("Choose Photo") { showPhotoPicker = true }
            if avatarData != nil {
                Button("Remove Photo", role: .destructive) { avatarData = nil }
            }
        }
        // A taken photo goes through the same circle cropper as a chosen one.
        .fullScreenCover(isPresented: $showCamera, onDismiss: {
            if let ui = pickedImage { pickedImage = nil; cropItem = GroupCropItem(image: ui) }
        }) {
            CameraPicker { data in pickedImage = UIImage(data: data) }
                .ignoresSafeArea()
        }
        // Picked photo -> the circle cropper once the picker is down, as Edit Group (owner 2026-10-23).
        .sheet(isPresented: $showPhotoPicker, onDismiss: {
            if let ui = pickedImage { pickedImage = nil; cropItem = GroupCropItem(image: ui) }
        }) {
            StoryLibraryPicker(
                onImage: { ui, _ in pickedImage = ui; showPhotoPicker = false },
                onVideo: { _, _ in },   // `photosOnly`: there is no video tile to pick
                photosOnly: true,
                pickLabel: "Set Group Photo")
            .storyAlwaysDark()
        }
        .fullScreenCover(item: $cropItem) { c in
            ProfilePhotoCropper(image: c.image,
                                onDone: { circle, _ in cropItem = nil; setPhoto(circle) },
                                onCancel: { cropItem = nil },
                                circleOnly: true,
                                circleSubtitle: "Shown in chats and on the group page")
                .ignoresSafeArea()
        }
    }

    /// "2/4": how many of the member switches are on, as the group's Permissions row shows it.
    private var permissionsCount: String {
        var on = [membersCanSend, membersCanAdd]
        if CallFeatures.groupCalls { on.append(membersCanCall) }
        return "\(on.filter { $0 }.count)/\(on.count)"
    }

    private var permissionsPage: some View {
        List {
            Section {
                Toggle(isOn: $membersCanSend) { permLabel("Send messages", "bubble.left.and.bubble.right") }
                Toggle(isOn: $membersCanAdd) { permLabel("Add members", "person.badge.plus") }
                // Edit info and share link are admins' only (owner 2026-10-19); both stay false.
                if CallFeatures.groupCalls {
                    Toggle(isOn: $membersCanCall) { permLabel("Start group calls", "phone") }
                }
            } header: {
                Text("What members can do")
            } footer: {
                Text("Admins can always do these. Switch one off and only admins can.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Permissions")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Text only, no icon (owner 2026-10-26: "remove those icons").
    private func permLabel(_ title: String, _ icon: String) -> some View {
        Text(title)
    }

    private var groupAvatarThumb: some View {
        ZStack {
            if let avatarData, let ui = UIImage(data: avatarData) {
                Image(uiImage: ui).resizable().scaledToFill()
            } else {
                Circle().fill(Color.accentColor.opacity(0.12))
                Image("ic_group_camera").renderingMode(.template).resizable().scaledToFit()   // his icon (owner 2026-10-18)
                    .frame(width: 28, height: 28).foregroundStyle(Color.accentColor)
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(Circle())
        .contentShape(Circle())
    }

    /// A group photo is a small round picture: 1024 px is plenty, and the upload stays quick.
    private func setPhoto(_ ui: UIImage) {
        showPhotoPicker = false
        Task {
            let data = await Task.detached(priority: .userInitiated) { () -> Data? in
                guard let jpeg = ui.jpegData(compressionQuality: 0.9) else { return nil }
                return ChatService.downscaledJPEG(jpeg, maxDimension: 1024, quality: 0.8)
            }.value
            if let data { avatarData = data }
        }
    }

    /// The create rule allows at most `group_members_max` people in a new group, you included
    /// (firestore.rules, the group branch of the conversation create; admin panel, fallback 30). Past
    /// that the create was refused and the page only said "Could not create group" (2026-09-24
    /// audit). The picker stops one short of the cap instead, the other place being yours.
    private static var maxOthersAtCreate: Int { max(1, AppLimits.shared.groupMembersMax - 1) }

    private func toggle(_ p: Person) {
        if selected[p.id] != nil {
            selected[p.id] = nil
            order.removeAll { $0 == p.id }
            return
        }
        guard selected.count < Self.maxOthersAtCreate else { Haptics.notify(.warning); return }
        selected[p.id] = p
        order.append(p.id)
    }

    private func search(_ q: String) {
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { results = []; searching = false; return }
        searching = true
        Task {
            var r = await ChatService.searchUsers(prefix: trimmed)
            if r.isEmpty, let exact = await ChatService.findByHandle(trimmed) { r = [exact] }
            await MainActor.run {
                guard query.trimmingCharacters(in: .whitespaces) == trimmed else { return }
                results = r.filter { $0.id != me }
                searching = false
            }
        }
    }

    private func create() {
        guard !creating else { return }   // the button stays tappable-looking while it works
        let name = String(groupName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        guard !name.isEmpty else { return }
        // "Create new groups" switched off from the admin panel while this page was open (owner
        // 2026-10-18). The rules refuse it anyway; this says so in words instead of "Try again".
        guard Flags.groupCreateEnabled else {
            error = "Creating new groups isn't available right now."
            return
        }
        creating = true; error = nil
        let timer = disappearSeconds
        let photo = avatarData
        let perms: [String: Bool] = [
            "onlyAdminsSend": !membersCanSend, "membersCanAdd": membersCanAdd,
            "membersCanEditInfo": membersCanEdit, "onlyAdminsCall": !membersCanCall,
            "membersCanShareLink": membersCanShare,
        ]
        Task {
            // ⛔ AT MOST N GROUPS OWNED (owner 2026-10-20: 10, set from the admin panel). Asked of the
            // server, which counts them; a check that cannot be answered lets the create go, and the
            // server's own check on the new group still holds the line.
            if let r = try? await Functions.functions(region: "me-central1").httpsCallable("groupCreateCheck").call(),
               let d = r.data as? [String: Any], d["ok"] as? Bool == false {
                let max = (d["max"] as? Int) ?? AppLimits.shared.groupsOwnedMax
                await MainActor.run {
                    self.error = "You can own up to \(max) groups. Delete one, or make someone else its owner, to create a new one."
                    creating = false
                }
                return
            }
            do {
                // The chat opens now; the photo goes up behind it, not before it (owner 2026-10-18).
                let cid = try await ChatService.createGroup(title: name, memberIds: order, disappearSeconds: timer,
                                                           permissions: perms)
                if let photo {
                    // Once more after a moment (the group may not be on the server yet), then said
                    // (audit 2026-10-20: a failed photo left the group bare without a word).
                    Task.detached(priority: .utility) {
                        if (try? await ChatService.uploadGroupAvatar(cid: cid, data: photo)) != nil { return }
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        if (try? await ChatService.uploadGroupAvatar(cid: cid, data: photo)) != nil { return }
                        await MainActor.run { ToastNotice.show("The group photo was not saved. Set it in Edit.") }
                    }
                }
                // The invite link is made with the group (owner 2026-10-23: it was only made when the
                // Invite Links page first opened, so that page waited on it). Behind the chat, once
                // more after a moment if the group was not on the server yet; the link list is then
                // cached so the page opens filled. If both fail the page still makes one as before.
                Task.detached(priority: .utility) {
                    if (try? await GroupInviteService.createPrimaryLink(cid: cid)) == nil {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        guard (try? await GroupInviteService.createPrimaryLink(cid: cid)) != nil else { return }
                    }
                    _ = try? await GroupInviteService.listLinks(cid: cid)
                }
                await MainActor.run {
                    creating = false
                    onOpen(ChatTarget(id: cid, name: name, photo: nil))
                }
            } catch {
                await MainActor.run { self.error = "Could not create group. Try again."; creating = false }
            }
        }
    }
}

/// A white ring turning in the Create button while the group is made (owner 2026-10-28). On a
/// timeline, not `.repeatForever` (audit H3: the iOS 26 deadlock pattern). Reduce Motion: the
/// system spinner.
private struct CreatingRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            ProgressView().tint(.white)
        } else {
            TimelineView(.animation) { ctx in
                // One turn every 0.8 s.
                let turn = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.8) / 0.8
                Circle()
                    .trim(from: 0, to: 0.72)
                    .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: 18, height: 18)
                    .rotationEffect(.degrees(turn * 360))
            }
            .accessibilityLabel("Creating group")
        }
    }
}
