import SwiftUI

// Forward a message to one or more chats. Pick chats (multi-select), tap Send, and the
// message is re-sent into each via ChatService.forwardMessage (E2EE re-encrypts media
// for the target chat). Excludes the source chat. Real send pipeline — no fakes.
struct ForwardPicker: View {
    let messages: [Message]           // one or many (bulk forward)
    let sourceCid: String
    var onSent: () -> Void = {}       // called after a fully-successful send (e.g. exit selection mode)

    // Single-message convenience (unchanged call sites).
    init(message: Message, sourceCid: String, onSent: @escaping () -> Void = {}) {
        self.messages = [message]; self.sourceCid = sourceCid; self.onSent = onSent
    }
    init(messages: [Message], sourceCid: String, onSent: @escaping () -> Void = {}) {
        self.messages = messages; self.sourceCid = sourceCid; self.onSent = onSent
    }

    @Environment(\.dismiss) private var dismiss
    @State private var repo = ConversationsRepository.shared
    @State private var query = ""
    @State private var selected = Set<String>()
    @State private var sending = false
    @State private var forwardError = false
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
            .alert("Couldn't forward", isPresented: $forwardError) {
                Button("OK", role: .cancel) {}
            } message: { Text("Some messages didn't send. Check your connection and try again.") }
            .navigationTitle("Forward to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "xmark") }.tint(.primary) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Send") { Task { await sendAll() } }
                        .disabled(selected.isEmpty || sending)
                        .fontWeight(.semibold)
                }
            }
            .overlay {
                if sending {
                    ProgressView().padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .interactiveDismissDisabled(sending)
        }
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func sendAll() async {
        sending = true
        // Oldest first so forwarded messages land in the same order they were sent.
        let ordered = messages.sorted { $0.createdAt < $1.createdAt }
        var sent = Set<String>()
        for cid in selected {
            var allOK = true
            for m in ordered {
                do { try await ChatService.forwardMessage(m, from: sourceCid, to: cid) }
                catch { allOK = false }
            }
            if allOK { sent.insert(cid) }   // only clear a target once EVERY message reached it
        }
        // Drop the chats that fully succeeded — a retry after a partial failure must NOT re-forward
        // to the ones that already received everything (that produced duplicates).
        selected.subtract(sent)
        sending = false
        if selected.isEmpty { onSent(); dismiss() } else { forwardError = true }   // don't pretend it sent
    }
}
