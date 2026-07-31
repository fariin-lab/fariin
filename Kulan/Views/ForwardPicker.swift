import SwiftUI

// Forward a message to one or more chats. Pick chats (multi-select), optionally add your own
// text, tap Send — the sheet closes INSTANTLY (owner's pick, WhatsApp model) and the re-sends
// run behind: each message re-encrypts for its target via ChatService.forwardMessage, then the
// added text follows as its own message. onQueued fires a "Sent to …" toast at close;
// onFailed reports a partial failure honestly instead of holding the sheet hostage.
struct ForwardPicker: View {
    let messages: [Message]           // one or many (bulk forward)
    let sourceCid: String
    var onSent: () -> Void = {}       // fired at close (e.g. exit selection mode)
    var onQueued: (String) -> Void = { _ in }   // toast label ("Sent to Adnan")
    var onFailed: () -> Void = {}     // something didn't arrive after the background run

    // Single-message convenience (unchanged call sites).
    init(message: Message, sourceCid: String, onSent: @escaping () -> Void = {},
         onQueued: @escaping (String) -> Void = { _ in }, onFailed: @escaping () -> Void = {}) {
        self.messages = [message]; self.sourceCid = sourceCid
        self.onSent = onSent; self.onQueued = onQueued; self.onFailed = onFailed
    }
    init(messages: [Message], sourceCid: String, onSent: @escaping () -> Void = {},
         onQueued: @escaping (String) -> Void = { _ in }, onFailed: @escaping () -> Void = {}) {
        self.messages = messages; self.sourceCid = sourceCid
        self.onSent = onSent; self.onQueued = onQueued; self.onFailed = onFailed
    }

    @Environment(\.dismiss) private var dismiss
    @State private var repo = ConversationsRepository.shared
    @State private var query = ""
    @State private var selected = Set<String>()
    @State private var comment = ""

    private var me: String { AuthService.shared.uid ?? "" }

    private var people: [Conversation] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = repo.conversations.filter { ((Flags.groupsEnabled && $0.isGroup) || !$0.otherUid(me).isEmpty) && $0.id != sourceCid && (Flags.groupsEnabled || !$0.isGroup) }
        return (q.isEmpty ? list : list.filter { $0.displayName(me).lowercased().contains(q) })
            .sorted { $0.displayUpdatedAt(me) > $1.displayUpdatedAt(me) }
    }

    private var snippet: String {
        if messages.count > 1 { return "\(messages.count) messages" }
        let message = messages[0]
        if message.isAlbum { return "🖼 Album" }
        if message.isImage { return "📷 Photo" }
        if message.isVideo { return "🎥 Video" }
        if message.isAudio { return "🎤 Voice message" }
        return message.safeText   // never leak a raw kulan-…: marker (contact/location card)
    }

    var body: some View {
        NavigationStack {
            Group {
                if people.isEmpty {
                    ContentUnavailableView("No other chats", systemImage: "paperplane",
                                           description: Text("Start another chat to forward into it."))
                } else {
                    List {
                        Section {
                            ForEach(people) { c in
                                Button { toggle(c.id) } label: {
                                    HStack(spacing: 12) {
                                        AvatarView(name: c.displayName(me), photoUrl: c.displayPhoto(me), size: 44)
                                        Text(c.displayName(me))
                                            .font(.system(size: 16, weight: .medium)).foregroundStyle(.primary)
                                        Spacer()
                                        Image(systemName: selected.contains(c.id) ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 20))
                                            .foregroundStyle(selected.contains(c.id) ? Color.accentColor : Color.secondary)
                                    }
                                }
                                .listRowSeparator(.hidden)
                            }
                        } header: {
                            Text("Forwarding: \(snippet)").textCase(nil)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .searchable(text: $query, prompt: "Search")
            // Add-your-own-text (owner's pick): appears once a chat is chosen; lands as its OWN
            // message right after the forwards, in every picked chat — never glued to a caption.
            .safeAreaInset(edge: .bottom) {
                if !selected.isEmpty {
                    TextField("Add a message…", text: $comment, axis: .vertical)
                        .lineLimit(1...3)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
            .navigationTitle("Forward to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "xmark") }.tint(.primary) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Send") { sendAll() }
                        .disabled(selected.isEmpty)
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func sendAll() {
        let targets = selected
        let note = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        // Oldest first so forwarded messages land in the same order they were sent.
        let ordered = messages.sorted { $0.createdAt < $1.createdAt }
        let src = sourceCid
        let queued = onQueued, failed = onFailed
        onSent()
        dismiss()
        // Telegram model (owner's 416 report: "i still land on where i sent from"): forwarding to
        // ONE chat lands you IN that chat — watching your forward arrive IS the confirmation, so no
        // toast there. Several chats can't all be landed in → stay put, the toast confirms instead.
        // Same route a banner tap uses; MainShell foregrounds Chats and pushes.
        if targets.count == 1, let cid = targets.first,
           let c = repo.conversations.first(where: { $0.id == cid }) {
            AppRouter.shared.pendingChatName = c.displayName(me)
            AppRouter.shared.pendingChatPhoto = c.displayPhoto(me)
            AppRouter.shared.pendingChatId = cid
        } else {
            queued("Sent to \(targets.count) chats")
        }
        Task {
            var anyFailed = false
            for cid in targets {
                for m in ordered {
                    do { try await ChatService.forwardMessage(m, from: src, to: cid) }
                    catch { anyFailed = true }
                }
                if !note.isEmpty {
                    do { try await ChatService.sendText(cid: cid, text: note) }
                    catch { anyFailed = true }
                }
            }
            if anyFailed { await MainActor.run { failed() } }
        }
    }
}
