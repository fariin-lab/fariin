import SwiftUI

// "Add people" from a connected 1:1 call: pick who joins, and the call moves onto a multi-person
// call with them (CallService.moveToGroup). Same people source as New Group and the forward
// picker (my 1:1 chats, no blocked, no demo, no unanswered requests), the reference app's layout:
// count under the title, selected faces in a strip, "Frequently contacted", then A–Z with an index.
struct AddPeopleSheet: View {
    let alreadyIn: Set<String>
    let onAdd: ([CallMember]) -> Void
    /// The bottom button. A link call sends the link instead of adding to a member list.
    let actionTitle: String

    init(alreadyIn: Set<String>, actionTitle: String = "Add to call", onAdd: @escaping ([CallMember]) -> Void) {
        self.alreadyIn = alreadyIn.filter { !$0.isEmpty }
        self.actionTitle = actionTitle
        self.onAdd = onAdd
    }

    /// Everyone in the call, the people already in it included. Matches the ad-hoc room's cap.
    static let maxInCall = 31

    @Environment(\.dismiss) private var dismiss
    @State private var repo = ConversationsRepository.shared
    @State private var query = ""
    @State private var selected: [CallMember] = []     // in the order they were picked
    @State private var found: [CallMember] = []        // a full @username typed into search
    @State private var abouts: [String: String] = [:]  // uid -> about line, cache only

    private var me: String { AuthService.shared.uid ?? "" }
    private var total: Int { alreadyIn.count + selected.count }

    /// My 1:1 chats, newest first, under the same filters the forward picker uses.
    private var chats: [Conversation] {
        repo.conversations
            .filter { !$0.isGroup && !$0.otherUid(me).isEmpty && !$0.isCleared(me) }
            .filter { !$0.isBlockedByMe(me) && !DemoMode.isDemoConversation($0.id) }
            .filter { MessageRequests.stance($0, myUid: me) != .incoming }
            .sorted { $0.displayUpdatedAt(me) > $1.displayUpdatedAt(me) }
    }

    private func member(_ c: Conversation) -> CallMember {
        CallMember(uid: c.otherUid(me), name: c.name(for: me), photoUrl: c.photoUrl(for: me))
    }

    /// One entry per person, newest chat first.
    private var people: [CallMember] {
        var seen = Set<String>()
        return chats.map { member($0) }.filter { seen.insert($0.uid).inserted }
    }

    private var blockedUids: Set<String> {
        Set(repo.conversations.filter { !$0.isGroup && $0.isBlockedByMe(me) }.map { $0.otherUid(me) })
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    /// The app keeps no per-chat message count, so "frequently" is the most recent people, as in
    /// the forward picker and New Message.
    private var frequent: [CallMember] {
        trimmedQuery.isEmpty ? Array(people.prefix(7)) : []
    }

    private var matches: [CallMember] {
        let q = trimmedQuery.lowercased()
        let local = people.filter { $0.name.lowercased().contains(q) }
        let localIds = Set(local.map(\.uid))
        return local + found.filter { !localIds.contains($0.uid) }
    }

    private static func letter(_ name: String) -> String {
        let folded = name.trimmingCharacters(in: .whitespaces)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        guard let ch = folded.first?.uppercased(), ch.count == 1,
              let scalar = ch.unicodeScalars.first, ("A"..."Z").contains(String(scalar)) else { return "#" }
        return ch
    }

    private struct AZSection: Identifiable {
        let letter: String
        let people: [CallMember]
        var id: String { letter }
    }

    /// A–Z sections, "#" last.
    private var sections: [AZSection] {
        let grouped = Dictionary(grouping: people) { Self.letter($0.name) }
        return grouped.keys
            .sorted { ($0 == "#" ? "~" : $0) < ($1 == "#" ? "~" : $1) }
            .map { key in AZSection(letter: key, people: grouped[key, default: []].sorted { $0.name.lowercased() < $1.name.lowercased() }) }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if !selected.isEmpty { selectedStrip }
                    if !trimmedQuery.isEmpty {
                        Section {
                            if matches.isEmpty {
                                Text("No one found").foregroundStyle(.secondary)
                            }
                            ForEach(matches) { row($0) }
                        }
                    } else if people.isEmpty {
                        Text("Chat with someone first to add them here.").foregroundStyle(.secondary)
                    } else {
                        Section { ForEach(frequent) { row($0) } } header: { sectionTitle("Frequently contacted") }
                        ForEach(sections) { s in
                            Section { ForEach(s.people) { row($0) } } header: { sectionTitle(s.letter) }
                                .id("az-\(s.letter)")
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollDismissesKeyboard(.interactively)
                .overlay(alignment: .trailing) {
                    if trimmedQuery.isEmpty, !people.isEmpty {
                        letterIndex(sections.map(\.letter)) { l in
                            proxy.scrollTo("az-\(l)", anchor: .top)
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Name or username")   // the app's own wording (NewGroupView); there are no numbers here
            .safeAreaInset(edge: .bottom) { addButton }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // A plain title. The count lives on the members section, the way NewGroupView says
                // "Members · N", not as a fraction under the title (owner, 2026-10-07).
                ToolbarItem(placement: .principal) {
                    Text("Add people").font(.system(size: 17, weight: .semibold))
                }
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .topBarTrailing) { CloseXButton { dismiss() } }
                        .sharedBackgroundVisibility(.hidden)   // don't double-wrap the glass X
                } else {
                    ToolbarItem(placement: .topBarTrailing) { CloseXButton { dismiss() } }
                }
            }
            .task { await loadAbouts() }
            .onChange(of: query) { _, q in lookUp(q) }
        }
    }

    // MARK: - Pieces

    private var selectedStrip: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(selected) { p in
                        VStack(spacing: 4) {
                            ZStack(alignment: .topTrailing) {
                                AvatarView(name: p.name, photoUrl: p.photoUrl, size: 52)
                                Button { selected.removeAll { $0.uid == p.uid } } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 18))
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .gray)
                                }
                                .buttonStyle(.plain)
                                .offset(x: 4, y: -4)
                            }
                            Text(p.name).font(.caption2).lineLimit(1).frame(width: 56)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            sectionTitle(total >= Self.maxInCall ? "Members · \(total) max" : "Members · \(total)")
        }
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s).font(.system(size: 17, weight: .semibold)).foregroundStyle(.secondary).textCase(nil)
    }

    private func row(_ p: CallMember) -> some View {
        let inCall = alreadyIn.contains(p.uid)
        let on = inCall || selected.contains { $0.uid == p.uid }
        return Button { toggle(p) } label: {
            HStack(spacing: 12) {
                AvatarView(name: p.name, photoUrl: p.photoUrl, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(p.name).font(.system(size: 17)).foregroundStyle(.primary)
                        VerifiedMark(uid: p.uid, size: 13)
                    }
                    .lineLimit(1)
                    if inCall {
                        Text("In this call").font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                    } else if let about = abouts[p.uid] {
                        Text(about).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                // The app's own tick (NewGroupView): the accent is white-or-black here, never a
                // brand green (owner, 2026-10-07: "this page looks like the other app").
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(on ? Color.primary : Color.secondary)
                    .opacity(inCall ? 0.5 : 1)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(inCall)
        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 28))   // clear of the index
        .alignmentGuide(.listRowSeparatorLeading) { _ in 52 }
    }

    /// The right-hand letters. A drag that starts on them runs through the list the way the
    /// system's own contacts index does; a tap is a drag of zero length.
    private func letterIndex(_ letters: [String], go: @escaping (String) -> Void) -> some View {
        let rowH: CGFloat = 16
        return VStack(spacing: 0) {
            ForEach(letters, id: \.self) { l in
                Text(l).font(.system(size: 11, weight: .semibold)).foregroundStyle(.primary)   // as NewChatView's index
                    .frame(width: 20, height: rowH)
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            guard !letters.isEmpty else { return }
            let i = min(max(Int(v.location.y / rowH), 0), letters.count - 1)
            go(letters[i])
        })
        .padding(.trailing, 2)
    }

    private var addButton: some View {
        let ready = !selected.isEmpty
        return Button {
            guard ready else { return }
            let picked = selected
            dismiss()
            onAdd(picked)
        } label: {
            // The app's accent is white-or-black (Theme.accent), so the button is the inverse of the
            // page: white with black lettering in dark mode, black with white in light. No brand
            // green and no plus glyph (owner, 2026-10-07: "make it like my app").
            Text(actionTitle)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color(uiColor: .systemBackground))
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Capsule().fill(Color.primary.opacity(ready ? 1 : 0.35)))
        }
        .buttonStyle(.plain)
        .disabled(!ready)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(.bar)
    }

    // MARK: - Actions

    private func toggle(_ p: CallMember) {
        guard !alreadyIn.contains(p.uid) else { return }
        if selected.contains(where: { $0.uid == p.uid }) {
            selected.removeAll { $0.uid == p.uid }
            return
        }
        guard total < Self.maxInCall else { Haptics.notify(.warning); return }
        selected.append(p)
    }

    /// Names are matched locally above. A full @username is looked up exactly, the only lookup
    /// the server allows (ChatService.searchUsers).
    /// TODO: "number" in the prompt has no lookup behind it yet; the app has no phone search.
    private func lookUp(_ q: String) {
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        let handle = trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
        guard !handle.isEmpty else { found = []; return }
        Task {
            let r = await ChatService.searchUsers(prefix: handle)
            await MainActor.run {
                guard query.trimmingCharacters(in: .whitespaces) == trimmed else { return }
                let blocked = blockedUids
                found = r.filter { $0.id != me && !blocked.contains($0.id) }
                    .map { CallMember(uid: $0.id, name: $0.name.isEmpty ? $0.handle : $0.name, photoUrl: $0.photoUrl) }
            }
        }
    }

    /// Second lines from the on-disk profile cache only, as the forward picker does: no network
    /// read per row, and no about = a one-line row.
    private func loadAbouts() async {
        var out: [String: String] = [:]
        for p in people where out[p.uid] == nil {
            if let prof = await ProfileStore.shared.cachedPeer(p.uid) {
                let a = prof.about.trimmingCharacters(in: .whitespacesAndNewlines)
                if !a.isEmpty { out[p.uid] = a }
            }
        }
        if !out.isEmpty { abouts = out }
    }
}
