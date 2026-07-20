import SwiftUI

struct ChatTarget: Identifiable, Hashable {
    let id: String      // cid
    let name: String
    let photo: String?
}

// New Message screen: search by name/username (+ QR), and an A–Z sectioned list of
// everyone you've chatted with, with a side index — native-styled. (No groups / phone
// lookup / note-to-self: those aren't real features in Kulan, so they're omitted.)
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

    private var me: String { AuthService.shared.uid ?? "" }

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
                        Section {
                            if Flags.groupsEnabled {
                                Button { showNewGroup = true } label: { actionRow("person.2.fill", "New group") }
                                    .tint(.primary)
                            }
                            Button { showNewContact = true } label: { actionRow("person.crop.circle.badge.plus", "New contact") }
                                .tint(.primary)
                        }
                    }
                    if let error { Text(error).foregroundStyle(.red) }

                    if !query.isEmpty {
                        Section("Results") {
                            ForEach(results) { user in
                                Button { start(user) } label: {
                                    personRow(name: user.name.isEmpty ? user.handle : user.name,
                                              handle: user.handle, photo: user.photoUrl)
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
                                ForEach(section.convs) { conv in
                                    Button {
                                        onOpen(ChatTarget(id: conv.id, name: conv.name(for: me), photo: conv.photoUrl(for: me)))
                                    } label: {
                                        personRow(name: conv.name(for: me), handle: nil, photo: conv.photoUrl(for: me))
                                    }
                                }
                            }
                            .id(section.letter)
                        }
                    }
                }
                .listStyle(.insetGrouped)   // grouped cards (matches the reference)
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
        }
    }

    @ViewBuilder
    private func personRow(name: String, handle: String?, photo: String?) -> some View {
        HStack(spacing: 12) {
            AvatarView(name: name, photoUrl: photo, size: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.body.weight(.medium)).foregroundStyle(.primary)
                if let handle, !handle.isEmpty {
                    Text("@\(handle)").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
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
