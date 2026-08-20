import SwiftUI
import UIKit

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
        // ⛔ NO NAVIGATION BAR. The reference sheet he gave is a grabber, a search field, faces, and a
        // row of actions along the bottom — there is no title strip and no Send in a corner. A nav
        // bar under a grabber reads as two headers stacked, which is what the first version looked
        // like beside his screenshot.
        VStack(spacing: 0) {
            searchRow
            peopleGrid
            actionBar
        }
        .background(Color(.systemBackground))
        // Half height, and draggable to full — his first bullet. `.medium` is the system's own half
        // detent rather than a hand-picked number, so it is right on every screen size.
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(sending)
        .overlay {
            if sending {
                ProgressView().padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private var searchRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 16))
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Color.secondary.opacity(0.12), in: Capsule())
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private var peopleGrid: some View {
        // THE ORDER IS THE CHAT LIST'S: `people` sorts on `displayUpdatedAt`, the same key MainShell
        // sorts the chat list by, so the most recent conversation is first here for the same reason
        // it is first there. Not alphabetical, not arbitrary.
        ScrollView {
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 20) {
                ForEach(people) { c in
                    Button { toggle(c.id) } label: { personTile(c) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
    }

    /// Copy and Share always; Send only once somebody is picked, which is the only time it means
    /// anything. It takes the trailing end of the same row rather than a corner of a bar that no
    /// longer exists.
    private var actionBar: some View {
        HStack(spacing: 24) {
            actionTile(copied ? "checkmark" : "link", copied ? "Copied" : "Copy link") {
                UIPasteboard.general.string = link
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                withAnimation(.easeOut(duration: 0.18)) { copied = true }
                Task {
                    try? await Task.sleep(nanoseconds: 1_600_000_000)
                    withAnimation(.easeOut(duration: 0.18)) { copied = false }
                }
            }
            actionTile("square.and.arrow.up", "Share to…") { showSystemShare = true }
            Spacer(minLength: 0)
            if !selected.isEmpty {
                Button { Task { await sendAll() } } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(Color.accentColor, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(sending)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: selected.isEmpty)
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(.bar)
        .sheet(isPresented: $showSystemShare) { SystemShareSheet(items: [link]) }
    }

    @State private var copied = false
    @State private var showSystemShare = false

    /// Just the url. `contactText` is the sentence that goes into a CHAT bubble; a clipboard or
    /// another app wants the link on its own, or whoever pastes it gets our sentence too.
    private var link: String {
        contactText.split(separator: " ").last.map(String.init) ?? contactText
    }

    private func actionTile(_ icon: String, _ title: String, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.primary)
                    .frame(width: 52, height: 52)
                    .background(Color.secondary.opacity(0.15), in: Circle())
                Text(title).font(.system(size: 12)).foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
    }

    /// Three across. It was four; the newer reference images he gave are three, and at three the
    /// face is big enough to recognise without reading the name under it.
    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    @ViewBuilder private func personTile(_ c: Conversation) -> some View {
        let picked = selected.contains(c.id)
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                AvatarView(name: c.displayName(me), photoUrl: c.displayPhoto(me), size: 76)
                    .overlay {
                        // The ring is the selection, not a tick floating over a face.
                        Circle().strokeBorder(picked ? Color.accentColor : .clear, lineWidth: 3)
                    }
                if picked {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .offset(x: 2, y: 2)
                }
            }
            .frame(width: 76, height: 76)
            HStack(spacing: 3) {
                Text(c.displayName(me))
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(2).multilineTextAlignment(.center)
                if !c.isGroup { VerifiedMark(uid: c.otherUid(me), size: 10) }
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
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

/// UIActivityViewController bridge. `ShareLink` is a button, and this row needs to PRESENT one from
/// a tap. There is an identical private bridge in `OfficialChatView`; it is private, so this is a
/// second one rather than a shared type nothing else asked for.
struct SystemShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
