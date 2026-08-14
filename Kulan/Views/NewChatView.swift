import SwiftUI

struct ChatTarget: Identifiable, Hashable {
    let id: String      // cid
    let name: String
    let photo: String?
}

// New Message screen: search by name/username (+ QR), and an A–Z sectioned list of
// everyone you've chatted with, with a side index — native-styled. (No groups / phone
// lookup / note-to-self: those aren't real features in Fariin, so they're omitted.)
struct NewChatView: View {
    let onOpen: (ChatTarget) -> Void
    init(onOpen: @escaping (ChatTarget) -> Void = { _ in }) { self.onOpen = onOpen }

    @Environment(\.dismiss) private var dismiss
    private var convRepo = ConversationsRepository.shared
    @State private var query = ""
    @State private var results: [UserProfile] = []
    @State private var searching = false
    @State private var error: String?
    @State private var showScan = false
    @State private var showNewGroup = false
    @State private var showNewContact = false
    /// @handles for the people in the list, read from Firestore's ON-DISK cache only.
    ///
    /// WHY THE ROWS LOOKED EMPTY (owner 2026-08-13, three screens side by side: "ours looks the
    /// cheapest one"). Both references put a second line under every name — one shows what the
    /// person wrote about themselves, the other shows when they were last seen — so their rows carry
    /// two lines of a real person and ours carried a name floating in a white box. A handle is the
    /// one fact we already hold about everybody, and it is the one this app identifies people by.
    ///
    /// Cache-only on purpose: this screen must not open fifty network reads, and a name with no
    /// handle yet simply has no second line, which is exactly what theirs does for a contact with no
    /// About set.
    @State private var handles: [String: String] = [:]

    private var me: String { AuthService.shared.uid ?? "" }
    /// Enough people that a shortcut to the recent ones is a shortcut. Below that it would just be
    /// the same faces twice on one screen.
    private var frequentThreshold: Int { 6 }
    private var frequent: [Conversation] {
        let all = convRepo.conversations.filter { !$0.isCleared(me) && !$0.isGroup }
        guard all.count >= frequentThreshold else { return [] }
        return Array(all.sorted { $0.displayUpdatedAt(me) > $1.displayUpdatedAt(me) }.prefix(3))
    }
    private var inviteText: String {
        let h = ProfileStore.shared.me?.handle ?? ""
        return h.isEmpty ? "Chat with me on Fariin." : "Chat with me on Fariin, my username is @\(h)"
    }

    // People you've chatted with, grouped by first letter (A–Z, then "#").
    private var sections: [(letter: String, convs: [Conversation])] {
        // 1:1 people only — a group here rendered as a person (first member's name/photo)
        // and opened the group mislabeled.
        let all = convRepo.conversations.filter { !$0.isCleared(me) && !$0.isGroup }
        let grouped = Dictionary(grouping: all) { c -> String in
            let n = c.name(for: me).trimmingCharacters(in: .whitespaces).uppercased()
            guard let f = n.first, f.isLetter else { return "#" }
            return String(f)
        }
        return grouped
            .map { ($0.key, $0.value.sorted { $0.name(for: me).lowercased() < $1.name(for: me).lowercased() }) }
            .sorted { $0.letter == "#" ? false : ($1.letter == "#" ? true : $0.letter < $1.letter) }
    }
    private var indexLetters: [String] { sections.map(\.letter) }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if query.isEmpty {
                        // THE BLOCK AT THE TOP, FILLED. Both references open with three or four ways
                        // to start something; ours opened with one row and a lot of white, which is
                        // most of what read as cheap. Every row here is a feature this app actually
                        // has — the two that were missing were sitting in the corner as a glyph
                        // (Scan QR) and buried in Settings (the invite text). Nothing invented:
                        // there are no communities, channels or broadcasts here to list.
                        Section {
                            if Flags.groupsEnabled {
                                Button { showNewGroup = true } label: { actionRow("person.2.fill", "New group") }
                                    .tint(.primary)
                            }
                            Button { showNewContact = true } label: { actionRow("person.crop.circle.badge.plus", "New contact") }
                                .tint(.primary)
                            Button { showScan = true } label: { actionRow("qrcode.viewfinder", "Scan QR code") }
                                .tint(.primary)
                            ShareLink(item: inviteText) {
                                actionRow("square.and.arrow.up", "Invite friends")
                            }
                            .tint(.primary)
                        }
                        // The recent few, above the alphabet — the reference app's "Frequently
                        // contacted". Only once there are enough people that skipping the alphabet
                        // saves you something; see `frequent`.
                        if !frequent.isEmpty {
                            Section("Frequently contacted") {
                                ForEach(frequent) { conv in personButton(conv) }
                            }
                        }
                    }
                    if let error { Text(error).foregroundStyle(.red) }

                    if !query.isEmpty {
                        Section("Results") {
                            ForEach(results) { user in
                                // Search finds STRANGERS — honor their Profile Picture audience
                                // (photo hidden unless they allow non-contacts; a shared chat
                                // qualifies as contact).
                                Button { start(user) } label: {
                                    personRow(name: user.name.isEmpty ? user.handle : user.name,
                                              handle: user.handle,
                                              photo: PrivacyPrefs.allows(user.privacy, "photo",
                                                                          contactOfMine: PrivacyPrefs.isContact(user.id))
                                                     ? user.photoUrl : nil,
                                              uid: user.id)
                                }
                            }
                            if results.isEmpty {
                                if searching {
                                    ChatListSkeleton()   // shimmer rows instead of a spinner
                                } else {
                                    Text("No one found for “\(query)”").foregroundStyle(.secondary)
                                }
                            }
                        }
                    } else if sections.isEmpty {
                        EmptyStateView(title: "Start a new chat", icon: "square.and.pencil",
                                       text: "Search a username to message someone.")
                    } else {
                        ForEach(sections, id: \.letter) { section in
                            Section(section.letter) {
                                ForEach(section.convs) { conv in personButton(conv) }
                            }
                            .id(section.letter)
                        }
                    }
                }
                .listStyle(.insetGrouped)   // grouped cards (matches the reference)
                // THE AIR WAS THE OTHER HALF OF IT. Default inset-grouped spacing puts about 35pt
                // between every card and a deep well under the search field, so four contacts filled
                // a screen and each letter read as an isolated box rather than a list. Both
                // references sit at roughly a third of that.
                .listSectionSpacing(14)
                .contentMargins(.top, 6, for: .scrollContent)
                // A–Z side index (SwiftUI has no native one) — tap a letter to jump.
                .overlay(alignment: .trailing) {
                    if query.isEmpty && indexLetters.count > 1 {
                        VStack(spacing: 1) {
                            ForEach(indexLetters, id: \.self) { l in
                                Text(l)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.tint)
                                    .frame(width: 16)
                                    .contentShape(Rectangle())
                                    .onTapGesture { withAnimation { proxy.scrollTo(l, anchor: .top) } }
                            }
                        }
                        .padding(.trailing, 1)
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Name or username")
            .navigationTitle("New Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showScan = true } label: { Image(systemName: "qrcode.viewfinder") }
                }
            }
            .sheet(isPresented: $showScan) {
                ScanQRView { user in showScan = false; start(user) }
            }
            .sheet(isPresented: $showNewGroup) {
                NewGroupView { t in showNewGroup = false; dismiss(); onOpen(t) }
            }
            .sheet(isPresented: $showNewContact) {
                NewContactView { t in showNewContact = false; dismiss(); onOpen(t) }
            }
            .task { await loadHandles() }
            .onChange(of: query) { _, q in
                let trimmed = q.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { results = []; searching = false; return }
                searching = true
                Task {
                    var r = await ChatService.searchUsers(prefix: trimmed)
                    if r.isEmpty, let exact = await ChatService.findByHandle(trimmed) { r = [exact] }
                    await MainActor.run {
                        guard query.trimmingCharacters(in: .whitespaces) == trimmed else { return }
                        results = r
                        searching = false
                    }
                }
            }
        }
    }

    private func actionRow(_ icon: String, _ title: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(.green).frame(width: 30)
            Text(title).foregroundStyle(.primary)
            Spacer(minLength: 0)   // ShareLink's label would otherwise hug its text and centre it
        }
        .contentShape(Rectangle())
    }

    /// One person in the alphabet (or in Frequently contacted). Extracted because it is drawn from
    /// two places now, and the two used to be one inline closure each.
    private func personButton(_ conv: Conversation) -> some View {
        Button {
            onOpen(ChatTarget(id: conv.id, name: conv.name(for: me), photo: conv.photoUrl(for: me)))
        } label: {
            personRow(name: conv.name(for: me),
                      handle: handles[conv.otherUid(me)],
                      photo: conv.photoUrl(for: me),
                      uid: conv.isGroup ? nil : conv.otherUid(me))
        }
    }

    /// Fill the second lines from the on-disk cache. One pass when the screen opens; anybody the
    /// cache does not know keeps a one-line row. No network read happens here at all.
    private func loadHandles() async {
        let uids = Set(convRepo.conversations
            .filter { !$0.isCleared(me) && !$0.isGroup }
            .map { $0.otherUid(me) }
            .filter { !$0.isEmpty })
        var found: [String: String] = [:]
        for uid in uids {
            if let p = await ProfileStore.shared.cachedPeer(uid), !p.handle.isEmpty {
                found[uid] = p.handle
            }
        }
        guard !found.isEmpty else { return }
        handles = found
    }

    /// `uid` is here so the row can draw a verified mark. It is optional rather than required because
    /// the second call site is a conversation, where a group has no single account behind it.
    @ViewBuilder
    private func personRow(name: String, handle: String?, photo: String?, uid: String?) -> some View {
        HStack(spacing: 12) {
            AvatarView(name: name, photoUrl: photo, size: 44)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(name).font(.body.weight(.medium)).foregroundStyle(.primary)
                    if let uid { VerifiedMark(uid: uid, size: 13) }
                }
                if let handle, !handle.isEmpty {
                    Text("@\(handle)").font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
        }
        // 2, not 4: with the row's own inset-grouped padding on top of it these were ~74pt tall, so
        // four people were a screenful. Theirs land in the mid-60s.
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    // The conversation ID is deterministic, so open the thread INSTANTLY and
    // create/touch the conversation doc in the background.
    private func start(_ user: UserProfile) {
        let cid = ChatService.convId(me, user.id)
        onOpen(ChatTarget(id: cid, name: user.name.isEmpty ? user.handle : user.name, photo: user.photoUrl))
        Task { try? await ChatService.openConversation(other: user) }
    }
}
