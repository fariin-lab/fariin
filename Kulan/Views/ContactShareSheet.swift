import SwiftUI

// "Share Contact" picker: the user's Kulan contacts (1:1 chat peers) in an alphabetical searchable
// list. TAP a contact → a small native confirmation (Send / Cancel) — no checkboxes, no caption
// (user spec). Send delivers ONE contact card via the normal encrypted text pipeline.
struct ContactShareSheet: View {
    var onSend: (_ contact: SharedContact) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var repo = ConversationsRepository.shared
    @State private var query = ""
    @State private var pending: SharedContact?   // tapped → native Send/Cancel confirm
    private var me: String { AuthService.shared.uid ?? "" }

    struct SharedContact: Identifiable {
        let uid: String
        let name: String
        let photo: String?
        var id: String { uid }
    }

    // Unique 1:1 peers, alphabetical; searchable by name.
    private var contacts: [SharedContact] {
        var seen = Set<String>()
        var out: [SharedContact] = []
        for c in repo.conversations where !c.isGroup && !c.isCleared(me) {
            let uid = c.otherUid(me)
            guard !uid.isEmpty, !seen.contains(uid) else { continue }
            seen.insert(uid)
            out.append(SharedContact(uid: uid, name: c.displayName(me), photo: c.displayPhoto(me)))
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = q.isEmpty ? out : out.filter { $0.name.lowercased().contains(q) }
        return filtered.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(contacts) { c in
                    Button { pending = c } label: {
                        HStack(spacing: 12) {
                            AvatarView(name: c.name, photoUrl: c.photo, size: 44)
                            Text(c.name).font(.system(size: 17, weight: .medium)).foregroundStyle(.primary)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: "Search")
            .navigationTitle("Contacts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .cancellationAction) { CloseXButton { dismiss() } }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .cancellationAction) { CloseXButton { dismiss() } }
                }
            }
            // Native bottom confirmation: Send / Cancel only (no caption for contacts — user spec).
            .confirmationDialog("Send Contact",
                isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                titleVisibility: .visible,
                presenting: pending) { c in
                    Button("Send") { onSend(c); dismiss() }
                    Button("Cancel", role: .cancel) { }
                } message: { c in
                    Text("Send \"\(c.name)\"?")
                }
        }
    }
}
