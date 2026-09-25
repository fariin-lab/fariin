import SwiftUI
import FirebaseAuth

/// Privacy › Profile Photo › Hide From — owner, 2026-09-25: "user allowed to hide specific people,
/// can select from … and choose". The people listed here never see the profile photo, whatever the
/// audience above says. Enforced by storage.rules (`canSeePhoto`); this page only edits the list.
struct HideFromPage: View {
    private var privacy = PhotoPrivacy.shared
    @State private var people: [String: UserProfile] = [:]
    @State private var showPicker = false
    @State private var error: String?

    var body: some View {
        List {
            if let error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            Section {
                Button { showPicker = true } label: {
                    Label("Add People", systemImage: "plus.circle.fill")
                }
            }
            if !privacy.hidden.isEmpty {
                Section {
                    ForEach(privacy.hidden, id: \.self) { uid in
                        PersonRow(name: people[uid]?.name ?? "", handle: people[uid]?.handle ?? "",
                                  photoUrl: people[uid]?.photoUrl)
                    }
                    .onDelete { idx in
                        for i in idx {
                            let uid = privacy.hidden[i]
                            Task {
                                do { try await privacy.remove(uid) }
                                catch { self.error = "Could not update the list. \(error.localizedDescription)" }
                            }
                        }
                    }
                } footer: {
                    Text("Swipe left on a person to show them your photo again.")
                }
            }
        }
        .navigationTitle("Hide From")
        .navigationBarTitleDisplayMode(.inline)
        .task { await privacy.load(); await resolve() }
        .onChange(of: privacy.hidden) { _, _ in Task { await resolve() } }
        .sheet(isPresented: $showPicker) {
            HideFromPicker(already: Set(privacy.hidden)) { picked in
                Task {
                    do { try await privacy.add(picked) }
                    catch { self.error = "Could not update the list. \(error.localizedDescription)" }
                }
            }
        }
    }

    private func resolve() async {
        for uid in privacy.hidden where people[uid] == nil {
            if let p = await ProfileStore.shared.cachedPeer(uid) { people[uid] = p }
        }
    }
}

/// Your one-to-one chats, to pick from. Several at once; Done adds them.
private struct HideFromPicker: View {
    let already: Set<String>
    let onDone: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<String> = []
    @State private var query = ""

    private struct Candidate: Identifiable {
        let id: String
        let name: String
        let photoUrl: String?
    }

    private var candidates: [Candidate] {
        let me = Auth.auth().currentUser?.uid ?? ""
        var seen = Set<String>()
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return ConversationsRepository.shared.conversations
            .filter { !$0.isGroup && !$0.isCleared(me) }
            .compactMap { c -> Candidate? in
                let other = c.otherUid(me)
                guard !other.isEmpty, other != me, !already.contains(other), seen.insert(other).inserted
                else { return nil }
                return Candidate(id: other, name: c.name(for: me), photoUrl: c.photos[other])
            }
            .filter { q.isEmpty || $0.name.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            List(candidates) { c in
                Button {
                    if picked.contains(c.id) { picked.remove(c.id) } else { picked.insert(c.id) }
                } label: {
                    HStack {
                        PersonRow(name: c.name, handle: "", photoUrl: c.photoUrl)
                        Spacer()
                        Image(systemName: picked.contains(c.id) ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(picked.contains(c.id) ? Color.accentColor : Color.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if candidates.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "No chats to choose from" : "No results",
                                           systemImage: "person.2")
                }
            }
            .searchable(text: $query, prompt: "Search")
            .navigationTitle("Add People")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { onDone(Array(picked)); dismiss() }
                        .fontWeight(.semibold)
                        .disabled(picked.isEmpty)
                }
            }
        }
    }
}

private struct PersonRow: View {
    let name: String
    let handle: String
    let photoUrl: String?

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: name, photoUrl: photoUrl, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(name.isEmpty ? (handle.isEmpty ? "Fariin user" : "@\(handle)") : name)
                    .foregroundStyle(.primary)
                if !handle.isEmpty, !name.isEmpty {
                    Text("@\(handle)").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
