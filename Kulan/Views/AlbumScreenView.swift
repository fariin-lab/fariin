import SwiftUI

// The screen you land on when you tap a group of photos (WhatsApp's album view, user reference).
//
// Before this, tapping any photo in a group jumped STRAIGHT into a full-screen photo and left you to
// swipe sideways blind — you couldn't see what else was in the group or pick from it. Now the group
// opens as a list: every item at full width, stacked vertically, each with its own time and tick.
// You scroll, you pick, and closing that photo brings you BACK HERE rather than out to the chat.
//
// Navigation the user asked for:
//   chat → tap group → this screen → tap a photo → full screen → back → this screen → back → chat
// That falls out of presenting the viewers FROM this screen instead of from the thread.
struct AlbumScreenView: View {
    let message: Message
    let cid: String
    let senderName: String        // already resolved by the caller ("You" for own messages)
    var onSave: (Message) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var viewerImage: Message?
    @State private var viewerVideo: Message?

    private var dark: Bool { scheme == .dark }

    private var timeString: String {
        message.createdAt.formatted(date: .omitted, time: .shortened)
    }

    /// Every image in the album as a viewer-ready Message, so the full-screen pager stays inside the
    /// group. Same synthetic "<msgId>-<index>" ids the bubble's own hero sources use.
    private var imageGallery: [Message] {
        message.album.enumerated().filter { !$0.element.isVideo }.map { idx, im in
            let data: [String: Any] = ["type": "image", "imageUrl": im.imageUrl, "enc": im.enc.asDict,
                                       "authorId": message.authorId, "width": im.width, "height": im.height]
            return Message(id: "\(message.id)-\(idx)", data: data, cid: cid, crypto: Crypto.shared)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(Array(message.album.enumerated()), id: \.offset) { i, item in
                        row(i, item)
                    }
                }
                .padding(.vertical, 4)
            }
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    // Name over "N Photos", the way the reference stacks them.
                    VStack(spacing: 1) {
                        Text(senderName).font(.headline)
                        Text(countLabel).font(.caption).foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left").font(.headline).foregroundStyle(.primary)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            for m in imageGallery { onSave(m) }
                        } label: { Label("Save All Photos", systemImage: "square.and.arrow.down") }
                    } label: {
                        Image(systemName: "ellipsis").font(.headline).foregroundStyle(.primary)
                    }
                }
            }
        }
        // Full height, no grabber: it should read as a page you can flick away, not a half sheet.
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        // Presented FROM this screen, which is what makes "back" land on the album again.
        .fullScreenCover(item: $viewerImage) { m in
            ImageViewerView(message: m, in: imageGallery, cid: cid, suppressDismissPan: false,
                            onDeleteForMe: { _ in })
        }
        .fullScreenCover(item: $viewerVideo) { m in
            VideoPlayerScreen(message: m, cid: cid, suppressDismissPan: false)
        }
    }

    private var countLabel: String {
        let photos = message.album.filter { !$0.isVideo }.count
        let videos = message.album.count - photos
        if videos == 0 { return "\(photos) Photo\(photos == 1 ? "" : "s")" }
        if photos == 0 { return "\(videos) Video\(videos == 1 ? "" : "s")" }
        return "\(message.album.count) Items"
    }

    @ViewBuilder private func row(_ i: Int, _ item: Message.AlbumItem) -> some View {
        // Natural aspect at full width, so a portrait shot stays portrait — the list is for judging
        // WHICH photo you want, so nothing may be cropped to a uniform tile.
        let ratio = item.height > 0 ? item.width / item.height : 1
        SecureImageView(imageUrl: item.imageUrl, enc: item.enc, cid: cid, fill: false)
            .aspectRatio(max(0.4, min(3, ratio)), contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipped()
            .overlay(alignment: .center) {
                if item.isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 48)).foregroundStyle(.white.opacity(0.95))
                        .shadow(color: .black.opacity(0.4), radius: 4)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                // Same meta the bubble shows, so a row reads as the message it is.
                HStack(spacing: 3) {
                    Text(timeString).font(.system(size: 12))
                    if message.authorId == AuthService.shared.uid {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                    }
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 3)
                .padding(10)
            }
            .contentShape(Rectangle())
            .onTapGesture { open(i, item) }
    }

    private func open(_ i: Int, _ item: Message.AlbumItem) {
        if item.isVideo, let vurl = item.videoUrl, let venc = item.videoEnc {
            let d: [String: Any] = ["type": "video", "videoUrl": vurl, "enc": venc.asDict,
                                    "thumbUrl": item.imageUrl, "thumbEnc": item.enc.asDict,
                                    "authorId": message.authorId, "width": item.width,
                                    "height": item.height, "duration": item.duration]
            viewerVideo = Message(id: "\(message.id)-\(i)", data: d, cid: cid, crypto: Crypto.shared)
            return
        }
        viewerImage = imageGallery.first { $0.id == "\(message.id)-\(i)" } ?? imageGallery.first
    }
}
