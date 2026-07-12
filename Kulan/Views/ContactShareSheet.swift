import SwiftUI

// "Share Contact" picker (Telegram-style, our look): the user's Kulan contacts (1:1 chat peers) in an
// alphabetical searchable list with circle checkboxes — multi-select, then one Send delivers a contact
// CARD message per selection (+ an optional caption as a follow-up text). Local data only; the send
// itself rides the normal encrypted text pipeline.
struct ContactShareSheet: View {
    var onSend: (_ contacts: [SharedContact], _ caption: String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var repo = ConversationsRepository.shared
    @State private var query = ""
    @State private var selected: [String] = []   // uids in tap order
    @State private var caption = ""
    @FocusState private var captionFocused: Bool
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
                    Button { toggle(c.uid) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selected.contains(c.uid) ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 24))
                                .foregroundStyle(selected.contains(c.uid) ? Color.accentColor : Color(.systemGray3))
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
            // Caption + send bar (only while something is selected) — pinned above the keyboard.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !selected.isEmpty {
                    HStack(spacing: 10) {
                        TextField("", text: $caption,
                                  prompt: Text("Add a caption…").foregroundColor(Color(.systemGray)),
                                  axis: .vertical)
                            .lineLimit(1...5)
                            .focused($captionFocused)
                            .padding(.horizontal, 16).padding(.vertical, 9).frame(minHeight: 40)
                            .liquidGlass(RoundedRectangle(cornerRadius: 20, style: .continuous), interactive: true)
                        Button { send() } label: {
                            Image(systemName: "arrow.up").font(.system(size: 17, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .liquidGlass(Circle(), interactive: true, tint: Theme.defaultBubble(false))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: selected.isEmpty)
        }
    }

    private func toggle(_ uid: String) {
        if let i = selected.firstIndex(of: uid) { selected.remove(at: i) }
        else { selected.append(uid) }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func send() {
        let byId = Dictionary(uniqueKeysWithValues: contacts.map { ($0.uid, $0) })
        // Resolve in TAP order from the full (unfiltered) contact set.
        var all = byId
        for c in allContacts() { all[c.uid] = c }
        let picked = selected.compactMap { all[$0] }
        guard !picked.isEmpty else { return }
        onSend(picked, caption.trimmingCharacters(in: .whitespacesAndNewlines))
        dismiss()
    }

    // Unfiltered list (a search must never drop already-selected contacts from the send).
    private func allContacts() -> [SharedContact] {
        var seen = Set<String>()
        var out: [SharedContact] = []
        for c in repo.conversations where !c.isGroup && !c.isCleared(me) {
            let uid = c.otherUid(me)
            guard !uid.isEmpty, !seen.contains(uid) else { continue }
            seen.insert(uid)
            out.append(SharedContact(uid: uid, name: c.displayName(me), photo: c.displayPhoto(me)))
        }
        return out
    }
}
