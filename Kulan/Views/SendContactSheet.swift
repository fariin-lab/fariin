import SwiftUI

// "Send to" chat picker for Share Contact — sends the contact's Fariin link into one or more chats
// (multi-select), instead of the system share sheet. Real send pipeline via ChatService.sendText.
struct SendContactSheet: View {
    let contactText: String   // e.g. "Chat with Kasim on Fariin: kulan://u/abdi1"

    @Environment(\.dismiss) private var dismiss
    @State private var repo = ConversationsRepository.shared
    @State private var query = ""
    @State private var selected = Set<String>()
    @State private var sending = false
    private var me: String { AuthService.shared.uid ?? "" }

    private var people: [Conversation] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = repo.conversations.filter { ((Flags.groupsEnabled && $0.isGroup) || !$0.otherUid(me).isEmpty) && !$0.isCleared(me) && (Flags.groupsEnabled || !$0.isGroup) }
        return (q.isEmpty ? list : list.filter { $0.displayName(me).lowercased().contains(q) })
            .sorted { $0.displayUpdatedAt(me) > $1.displayUpdatedAt(me) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Recent Chats") {
                    ForEach(people) { c in
                        Button { toggle(c.id) } label: {
                            HStack(spacing: 12) {
                                AvatarView(name: c.displayName(me), photoUrl: c.displayPhoto(me), size: 44)
                                Text(c.displayName(me)).font(.system(size: 17, weight: .medium)).foregroundStyle(.primary)
                                if !c.isGroup { VerifiedMark(uid: c.otherUid(me), size: 13) }
                                Spacer()
                                Image(systemName: selected.contains(c.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 22))
                                    .foregroundStyle(selected.contains(c.id) ? Color.primary : Color.secondary)
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search")
            .navigationTitle("Send to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .cancellationAction) { CloseXButton { dismiss() } }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .cancellationAction) { CloseXButton { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { Task { await sendAll() } }
                        .disabled(selected.isEmpty || sending).fontWeight(.semibold)
                }
            }
            .overlay {
                if sending { ProgressView().padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)) }
            }
            .interactiveDismissDisabled(sending)
        }
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
    private func sendAll() async {
        sending = true
        for cid in selected {
            let conv = repo.conversations.first { $0.id == cid }
            try? await ChatService.sendText(cid: cid, text: contactText,
                                            group: conv?.isGroup == true ? conv?.users : nil)
        }
        sending = false
        dismiss()
    }
}
