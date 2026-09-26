import SwiftUI
import FirebaseAuth

/// Privacy › Profile Photo › Hide From — owner, 2026-09-25: "user allowed to hide specific people,
/// can select from … and choose". The people listed here never see the profile photo, whatever the
/// audience above says. Enforced by storage.rules (`canSeePhoto`); this page only edits the list.
struct HideFromPage: View {
    private var privacy = PhotoPrivacy.shared

    init() {
        PhotoPrivacy.shared.seedFromCache()
        _loaded = State(initialValue: PhotoPrivacy.shared.loaded)
    }
    @State private var people: [String: UserProfile] = [:]
    @State private var showPicker = false
    @State private var error: String?
    /// True from the first frame when the list is already known on this phone (see
    /// `PhotoPrivacy.seedFromCache`), so the page never flips from one face to the other.
    @State private var loaded: Bool
    /// The inline list's search text, used only while nobody is hidden yet.
    @State private var query = ""

    var body: some View {
        Group {
            // Owner 2026-09-25: with nobody hidden, an "Add People" button in an empty page is one
            // tap too many. The people are the page until the first one is added; the button only
            // appears once there is a list for it to add to.
            //
            // ⚠️ NEITHER FACE UNTIL THE LIST IS KNOWN. Showing the list face while loading is what
            // flipped "Add People" into the people a second later (his screen recording).
            if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if privacy.hidden.isEmpty {
                inlinePicker
            } else {
                hiddenList
            }
        }
        .navigationTitle("Hide From")
        .navigationBarTitleDisplayMode(.inline)
        .task { await privacy.load(); loaded = true; await resolve() }
        .onChange(of: privacy.hidden) { _, _ in Task { await resolve() } }
        .sheet(isPresented: $showPicker) {
            HideFromPicker(already: Set(privacy.hidden)) { add($0) }
        }
    }

    /// The Block User sheet's list, as the page itself (owner, 2026-09-26). One tap hides that
    /// person; the page then shows the list face above with them on it.
    private var inlinePicker: some View {
        HideFromCandidates(already: [], query: $query) { uid in query = ""; add(uid) }
            .safeAreaInset(edge: .top) {
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20).padding(.vertical, 6)
                }
            }
    }

    private func add(_ uid: String) {
        Task {
            do { try await privacy.add([uid]) }
            catch { self.error = "Could not update the list. \(error.localizedDescription)" }
        }
    }

    private var hiddenList: some View {
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
                            .listRowInsets(PersonRow.insets)
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
    }

    private func resolve() async {
        for uid in privacy.hidden where people[uid] == nil {
            if let p = await ProfileStore.shared.cachedPeer(uid) { people[uid] = p }
        }
    }
}

/// ⛔ THE BLOCK USER SHEET'S LIST — owner, 2026-09-26, with that sheet's screenshot: "the Hide From
/// users list, make it like this UI, the same as the Block Users page". The same A–Z cards, the
/// letter index down the side, the search under the title, the 40pt avatar and semibold name; a
/// person already on the list stays listed, greyed and marked, as an already-blocked person does
/// there. One tap hides that person and the sheet closes, the way one tap there blocks. The
/// ticks-and-Done picker is gone.
private struct HideFromPicker: View {
    let already: Set<String>
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            HideFromCandidates(already: already, query: $query) { uid in onPick(uid); dismiss() }
                .navigationTitle("Hide From")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { dismiss() } label: { Image(systemName: "xmark") }
                            .tint(.primary)
                            .accessibilityLabel("Close")
                    }
                }
        }
    }
}

/// The A–Z list itself: the sheet above, and the Hide From page while nobody is hidden yet.
private struct HideFromCandidates: View {
    let already: Set<String>
    @Binding var query: String
    let onPick: (String) -> Void

    private struct Candidate: Identifiable {
        let id: String
        let name: String
        let photoUrl: String?
    }

    /// Every 1:1 chat, the people already hidden included: they stay listed, greyed and marked, so
    /// the list reads as your people rather than a list that silently lost some of them.
    private var candidates: [Candidate] {
        let me = Auth.auth().currentUser?.uid ?? ""
        var seen = Set<String>()
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return ConversationsRepository.shared.conversations
            .filter { !$0.isGroup && !$0.isCleared(me) }
            .compactMap { c -> Candidate? in
                let other = c.otherUid(me)
                guard !other.isEmpty, other != me, seen.insert(other).inserted else { return nil }
                return Candidate(id: other, name: c.name(for: me), photoUrl: c.photos[other])
            }
            .filter { q.isEmpty || $0.name.lowercased().contains(q) }
    }

    /// A–Z cards with an index, grouped exactly as `BlockPickerView` groups them: anything not
    /// starting with a letter goes under "#", last.
    private var sections: [(letter: String, people: [Candidate])] {
        let groups = Dictionary(grouping: candidates) { c -> String in
            let f = c.name.trimmingCharacters(in: .whitespaces).first.map(String.init)?.uppercased() ?? "#"
            return f.rangeOfCharacter(from: .letters) == nil ? "#" : f
        }
        return groups.map { (letter: $0.key,
                             people: $0.value.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) }
            .sorted { a, b in
                if a.letter == "#" { return false }
                if b.letter == "#" { return true }
                return a.letter < b.letter
            }
    }

    private func row(_ c: Candidate) -> some View {
        let hidden = already.contains(c.id)
        return Button { onPick(c.id) } label: {
            HStack(spacing: 12) {
                AvatarView(name: c.name, photoUrl: c.photoUrl, size: 40)
                    .opacity(hidden ? 0.5 : 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.name.isEmpty ? "Fariin user" : c.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(hidden ? .secondary : .primary)
                        .lineLimit(1)
                    if hidden {
                        Text("Already hidden").font(.subheadline).italic().foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(hidden)
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if sections.isEmpty {
                    Text(query.isEmpty ? "You have no chats to choose from." : "No match.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(sections, id: \.letter) { section in
                        Section(section.letter) {
                            ForEach(section.people) { row($0) }
                        }
                        .id(section.letter)
                    }
                }
            }
            .listStyle(.insetGrouped)
            // Same air as the Block User sheet: a third of inset-grouped's default between cards.
            .listSectionSpacing(14)
            .contentMargins(.top, 6, for: .scrollContent)
            .overlay(alignment: .trailing) {
                if query.isEmpty && sections.count > 1 {
                    VStack(spacing: 1) {
                        ForEach(sections.map(\.letter), id: \.self) { l in
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
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
    }
}

private struct PersonRow: View {
    let name: String
    let handle: String
    let photoUrl: String?

    /// ⛔ THE STORY PICKER'S 52pt ROW — owner, 2026-09-26, "hide profile pictures users has
    /// spaces": the grouped list's own ~11pt above and below a 40pt avatar, plus 2 of ours, made a
    /// ~64pt row. 6 above and below, no padding of our own, as `StoryPeoplePicker.rowInsets`.
    static let insets = EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)

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
    }
}
