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
        NavigationStack {
            // ⛔ A GRID OF FACES, FOUR TO A ROW (owner, 2026-08-20). It was one full-width row per
            // person, which is a list of names — you read it. A grid of pictures is scanned, and
            // when the people you message most are the first four, the one you want is usually in
            // the first row.
            //
            // THE ORDER IS THE CHAT LIST'S AND ALWAYS WAS: `people` sorts on `displayUpdatedAt`,
            // the same key `MainShell` sorts the chat list by, so the most recent conversation is
            // first here for the same reason it is first there. Not alphabetical, not arbitrary.
            ScrollView {
                LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 18) {
                    ForEach(people) { c in
                        Button { toggle(c.id) } label: { personTile(c) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
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
            // ⛔ THE ROW ALONG THE BOTTOM, which is the half this sheet was missing. Sending it to
            // somebody in the app and sending it OUT of the app are the same intention, and the
            // reference sheet puts both on one screen rather than making you dismiss and hunt for
            // the system share sheet.
            //
            // Two buttons and no more. Copy is the one he named. "Share to…" is the system sheet,
            // which is where WhatsApp, Snapchat and everything else the phone actually has live —
            // hard-coding tiles for named apps would list apps that may not be installed and would
            // need a new tile every time he wants another one.
            .safeAreaInset(edge: .bottom) { linkActions }
        }
    }

    @State private var copied = false

    private var linkActions: some View {
        HStack(spacing: 28) {
            Spacer(minLength: 0)
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
        }
        .padding(.top, 14)
        .padding(.bottom, 8)
        .background(.bar)
        .sheet(isPresented: $showSystemShare) { SystemShareSheet(items: [link]) }
    }

    @State private var showSystemShare = false

    /// Just the url. `contactText` is the sentence that goes into a CHAT bubble; a clipboard or
    /// another app wants the link on its own, or the person pasting it gets our sentence too.
    private var link: String {
        contactText.split(separator: " ").last.map(String.init) ?? contactText
    }

    private func actionTile(_ icon: String, _ title: String, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.primary)
                    .frame(width: 58, height: 58)
                    .background(Color.secondary.opacity(0.15), in: Circle())
                Text(title).font(.system(size: 12)).foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
    }

    /// Four across, which is what he asked for and what the reference sheet uses.
    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    @ViewBuilder private func personTile(_ c: Conversation) -> some View {
        let picked = selected.contains(c.id)
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                AvatarView(name: c.displayName(me), photoUrl: c.displayPhoto(me), size: 64)
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
            .frame(width: 64, height: 64)
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
