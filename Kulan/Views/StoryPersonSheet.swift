import SwiftUI

/// ⛔ THE SHORT SHEET FROM A STORY — owner 2026-10-15, with the reference app's story sheet beside
/// ours: tapping the person on a story opened the whole profile at full height ("us become full").
/// Now it opens this: their photo and name, then Message, Voice call, Video call, Contact info.
/// Contact info pushes the full profile in the same sheet and grows it to full height, so the
/// 2026-08-03 order ("open FULL profile sheet") still holds one tap further in.
///
/// Message and the calls do not run here: they are handed to `onAction`, which the story stage runs
/// in the sheet's `onDismiss`. Starting a call or a chat while this sheet is still on screen is the
/// "nothing happens" bug `BottomActionSheet` records.
struct StoryPersonSheet: View {
    enum Action { case message, voice, video }

    let cid: String
    let name: String
    let photoUrl: String?
    @Binding var detent: PresentationDetent
    let onAction: (Action) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showProfile = false

    static let rowHeight: CGFloat = 56
    /// Header (top pad + avatar + gap) + four rows + three hairlines + bottom pad.
    static let height: CGFloat = 20 + 52 + 16 + 4 * rowHeight + 3 + 24

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                AvatarView(name: name, photoUrl: photoUrl, size: 52)
                Text(name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.borderless)
                .liquidGlass(Circle(), interactive: true)
                .accessibilityLabel("Close")
            }

            VStack(spacing: 0) {
                row("Message", icon: "message") { pick(.message) }
                Divider().padding(.leading, 56)
                row("Voice call", icon: "phone") { pick(.voice) }
                Divider().padding(.leading, 56)
                row("Video call", icon: "video") { pick(.video) }
                Divider().padding(.leading, 56)
                row("Contact info", icon: "info.circle") {
                    detent = .large
                    showProfile = true
                }
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(uiColor: .systemGroupedBackground))
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $showProfile) {
            ContactInfoView(cid: cid, name: name, photoUrl: photoUrl,
                            source: .story)   // no chat underneath → no Search/Wallpaper
        }
        // Back from the profile: the sheet returns to its short height.
        .onChange(of: showProfile) { _, open in
            if !open { detent = .height(Self.height) }
        }
    }

    private func pick(_ a: Action) {
        onAction(a)
        dismiss()
    }

    private func row(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .frame(width: 24)
                Text(title).font(.body)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .frame(height: Self.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// ⛔ MESSAGE FROM A STORY OPENS THE CHAT OVER THE STORY — owner 2026-10-15: "I land in their
    /// chat, I go back, I should land where I came from, the story, not the chat list".
    ///
    /// Not inside this sheet: there the chat's "read older" drag and the sheet's drag-to-close are
    /// one gesture (his 2026-08-18 report). Not through `AppRouter` either (52ec309a, 2026-10-11):
    /// that closes the story and opens the chat in Chats, so Back lands on the chat list. Here the
    /// chat goes up full screen OVER the stage, the way the repost composer does
    /// (`StoryComposerPresenter`, `.overFullScreen`, the stage stays in the window and paused).
    ///
    /// The 1:1 is created first, as in `ContactInfoView.goToChat` (owner 2026-10-12: a first "Hi"
    /// into a chat with no document failed and the header read "User").
    static func openChat(cid: String, otherUid: String, name: String, photoUrl: String?,
                         onClosed: @escaping () -> Void) {
        let present = {
            StoryComposerPresenter.present(
                StoryChatCover(cid: cid, name: name, photoUrl: photoUrl),
                onDismissed: onClosed, clearBackground: true)
        }
        if let existing = ConversationsRepository.shared.conversations.first(where: { $0.id == cid }) {
            present()
            if existing.names[otherUid] == nil {
                Task { await ChatService.openConversation(uid: otherUid) }
            }
            return
        }
        Task { @MainActor in
            await ChatService.openConversation(uid: otherUid)
            present()
        }
    }
}

/// The chat as a page PUSHED on an empty, see-through root, so it keeps the system Back button and
/// the edge swipe exactly as in Chats. Popping it reveals the story behind (the root and the host
/// are clear), and an empty path closes the cover.
private struct StoryChatCover: View {
    let cid: String
    let name: String
    let photoUrl: String?

    @Environment(\.dismiss) private var dismiss
    @State private var path: [String]

    init(cid: String, name: String, photoUrl: String?) {
        self.cid = cid; self.name = name; self.photoUrl = photoUrl
        _path = State(initialValue: [cid])
    }

    var body: some View {
        NavigationStack(path: $path) {
            Color.clear
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: String.self) { id in
                    ThreadView(cid: id, title: name, photoUrl: photoUrl)
                }
        }
        .containerBackground(.clear, for: .navigation)
        .onChange(of: path) { _, p in
            if p.isEmpty { dismiss() }
        }
    }
}
