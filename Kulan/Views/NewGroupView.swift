import SwiftUI

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
    init(preselect: Person? = nil, onOpen: @escaping (ChatTarget) -> Void = { _ in }) {
        self.onOpen = onOpen
        if let p = preselect {
            _selected = State(initialValue: [p.id: p])
            _order = State(initialValue: [p.id])
        }
    }

    struct Person: Identifiable, Hashable { let id: String; let name: String; let photo: String? }

    private enum Step: Hashable { case details }

    @Environment(\.dismiss) private var dismiss
    private var convRepo = ConversationsRepository.shared
    @State private var path: [Step] = []
    @State private var groupName = ""
    @State private var avatarData: Data?
    @State private var showPhotoPicker = false
    @State private var disappearSeconds = UserDefaults.standard.integer(forKey: "defaultDisappearSeconds")
    @State private var query = ""
    @State private var results: [UserProfile] = []
    @State private var searching = false
    @State private var selected: [String: Person] = [:]   // uid -> person
    @State private var order: [String] = []                // tap order, for the faces and the list
    @State private var creating = false
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
        !groupName.trimmingCharacters(in: .whitespaces).isEmpty && !creating
    }

    var body: some View {
        NavigationStack(path: $path) {
            membersPage
                .navigationDestination(for: Step.self) { _ in detailsPage }
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

    private var detailsPage: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    Button { nameFocused = false; showPhotoPicker = true } label: { groupAvatarThumb }
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
                Picker("Disappearing Messages", selection: $disappearSeconds) {
                    Text("Off").tag(0)
                    Text("1 Day").tag(86_400)
                    Text("1 Week").tag(604_800)
                    // The Settings default, when it is none of the three.
                    if ![0, 86_400, 604_800].contains(disappearSeconds) {
                        Text(ChatService.disappearLabel(disappearSeconds).capitalized).tag(disappearSeconds)
                    }
                }
                .pickerStyle(.menu)
            } footer: {
                Text("New messages in this group disappear for everyone once this time has passed.")
            }

            Section(selected.isEmpty ? "1 Member" : "\(selected.count + 1) Members") {
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
                Button("Create") { create() }.disabled(!canCreate).fontWeight(.semibold)
            }
        }
        .overlay { if creating { ProgressView().controlSize(.large) } }
        // Straight to the name, as the page is for naming the group.
        // ⛔ AFTER THE PUSH, NOT DURING IT (owner 2026-10-18, build 969: "the keyboard comes from the
        // right"). Focus at 0.35 s landed inside the iOS 26 push, so the keyboard rode in sideways with
        // the page. 0.6 s is past the push: the keys rise from the bottom on their own. `.task`, so
        // going back before then cancels it and no keyboard opens over the page being left.
        .task {
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { nameFocused = true }
        }
        .sheet(isPresented: $showPhotoPicker) {
            StoryLibraryPicker(
                onImage: { ui, _ in setPhoto(ui) },
                onVideo: { _, _ in },   // `photosOnly`: there is no video tile to pick
                photosOnly: true,
                pickLabel: "Set Group Photo")
            .storyAlwaysDark()
        }
    }

    private var groupAvatarThumb: some View {
        ZStack {
            if let avatarData, let ui = UIImage(data: avatarData) {
                Image(uiImage: ui).resizable().scaledToFill()
            } else {
                Circle().fill(Color.accentColor.opacity(0.12))
                Image(systemName: "camera.fill").font(.system(size: 24)).foregroundStyle(Color.accentColor)
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

    /// The create rule allows at most 30 people in a new group, you included (firestore.rules, the
    /// group branch of the conversation create). Past that the create was refused and the page only
    /// said "Could not create group" (2026-09-24 audit). The picker stops at 29 others instead.
    private static let maxOthersAtCreate = 29

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
        let name = groupName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        creating = true; error = nil
        let timer = disappearSeconds
        Task {
            do {
                let cid = try await ChatService.createGroup(title: name, memberIds: order)
                if let avatarData { try? await ChatService.uploadGroupAvatar(cid: cid, data: avatarData) }
                // `createGroup` already set the Settings default; this writes only a different
                // choice (setDisappear skips a value the chat already has).
                await ChatService.setDisappear(cid, seconds: timer)
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
