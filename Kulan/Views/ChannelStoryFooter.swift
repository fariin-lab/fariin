import SwiftUI
import FirebaseFirestore

/// ⛔ A CHANNEL STORY'S FOOTER (owner 2026-10-29, with a picture): nobody can send the channel a
/// message from its story, and every follower sees the same three numbers, views, reposts and likes,
/// with Share on the right. No names anywhere; the numbers come from `stories/{id}/meta/public`,
/// which the server (`mirrorChannelStoryCounts`) keeps and any signed-in reader may read.
///
/// Drawn through the story library's `StoryFooterAccessory`, which hands over only a story id, so
/// the viewer registers each channel story here as it builds the pages (`register`).
@MainActor
enum ChannelStoryFooter {
    struct Info { var canRepost: Bool; var canShare: Bool }
    private static var stories: [String: Info] = [:]

    static func register(_ storyId: String, _ info: Info) { stories[storyId] = info }
    static func info(_ storyId: String) -> Info? { stories[storyId] }

    /// The heart, handled by the viewer (it owns the like path, `handle(storyId:…)`).
    static let likeNote = Notification.Name("channelStoryLike")
}

/// The live numbers for the story on screen. One listener, following whichever story is showing.
@Observable
@MainActor
final class ChannelStoryCounts {
    static let shared = ChannelStoryCounts()
    private init() {}

    struct Counts: Equatable { var views = 0, likes = 0, reposts = 0 }
    private(set) var counts: [String: Counts] = [:]
    /// My heart, shown at once; dropped when the next server number arrives.
    private(set) var likeDelta: [String: Int] = [:]
    @ObservationIgnored private var watchId = ""
    @ObservationIgnored private var listener: ListenerRegistration?

    func watch(_ storyId: String) {
        guard storyId != watchId else { return }
        listener?.remove()
        watchId = storyId
        listener = FirestoreHub.db.collection("stories").document(storyId)
            .collection("meta").document("public")
            .addSnapshotListener { [weak self] snap, _ in
                guard let self, self.watchId == storyId else { return }
                let d = snap?.data() ?? [:]
                let next = Counts(views: (d["views"] as? NSNumber)?.intValue ?? 0,
                                  likes: (d["likes"] as? NSNumber)?.intValue ?? 0,
                                  reposts: (d["reposts"] as? NSNumber)?.intValue ?? 0)
                if next.likes != self.counts[storyId]?.likes { self.likeDelta[storyId] = nil }
                self.counts[storyId] = next
            }
    }

    func noteLike(_ storyId: String, _ liked: Bool) {
        likeDelta[storyId, default: 0] += liked ? 1 : -1
    }

    func likes(_ storyId: String) -> Int {
        max(0, (counts[storyId]?.likes ?? 0) + (likeDelta[storyId] ?? 0))
    }
}

struct ChannelStoryFooterView: View {
    let storyId: String
    let info: ChannelStoryFooter.Info
    @State private var liked = false
    private var model: ChannelStoryCounts { .shared }

    var body: some View {
        let c = model.counts[storyId] ?? .init()
        HStack(spacing: 22) {
            stat(Image(systemName: "eye"), c.views)
                .accessibilityLabel("\(c.views) views")
            Button {
                guard info.canRepost else { return }
                NotificationCenter.default.post(name: .init("storyRepostTapped"), object: storyId)
            } label: {
                stat(Image("ic_repost").renderingMode(.template).resizable(), c.reposts)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Repost, \(c.reposts) reposts")
            Button(action: toggleLike) {
                HStack(spacing: 7) {
                    Image(systemName: liked ? "heart.fill" : "heart")
                        .font(.system(size: 23))
                        .foregroundStyle(liked ? Color.red : Color.white)
                        .scaleEffect(liked ? 1.12 : 1)
                        .animation(.spring(response: 0.3, dampingFraction: 0.45), value: liked)
                    Text("\(model.likes(storyId))").font(.system(size: 17, weight: .medium)).monospacedDigit()
                        .contentTransition(.numericText())
                }
                .frame(height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(liked ? "Unlike" : "Like")
            Spacer(minLength: 0)
            if info.canShare {
                Button {
                    NotificationCenter.default.post(name: .init("storyActionShareLink"), object: nil)
                } label: {
                    Image(systemName: "arrowshape.turn.up.right")
                        .font(.system(size: 22))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share")
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
        .padding(.horizontal, 6)
        .frame(height: 52)
        .task(id: storyId) {
            liked = StoryPrefs.isStoryLiked(storyId)
            model.watch(storyId)
        }
    }

    private func stat(_ icon: Image, _ n: Int) -> some View {
        HStack(spacing: 7) {
            icon.scaledToFit().font(.system(size: 21)).frame(width: 24, height: 24)
            Text("\(n)").font(.system(size: 17, weight: .medium)).monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(height: 44).contentShape(Rectangle())
    }

    private func toggleLike() {
        // The like is a mark on my own view receipt; with receipts off none is written (see
        // `handle`), so the heart says so instead of turning red for nothing.
        guard StoryPrefs.viewReceiptsOn else {
            ToastNotice.show("Turn on Read Receipts for stories to like them.")
            return
        }
        liked.toggle()
        model.noteLike(storyId, liked)
        UIImpactFeedbackGenerator(style: liked ? .medium : .light).impactOccurred()
        NotificationCenter.default.post(name: ChannelStoryFooter.likeNote, object: storyId,
                                        userInfo: ["liked": liked])
    }
}
