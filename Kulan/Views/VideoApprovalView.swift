import SwiftUI
import AVFoundation

// Pre-send video approval (parity with the image editor): plays the picked video (looping, tap to
// play/pause), with a caption field + Send. No auto-send. (Crop / pen / trim for video are a larger
// AVFoundation feature and will come as a follow-up — this is the caption + preview step.)
struct VideoApprovalView: View {
    let url: URL
    var onSend: (_ caption: String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var caption = ""
    @State private var playing = true
    @FocusState private var captionFocused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            LoopingVideoView(url: url, playing: $playing)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    if captionFocused { captionFocused = false } else { playing.toggle() }
                }
            if !playing {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 66)).foregroundStyle(.white.opacity(0.85))
                    .allowsHitTesting(false)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).liquidGlass(Circle(), interactive: true).contentShape(Circle())
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            TextField("", text: $caption, prompt: Text("Add a caption…").foregroundColor(Color(.systemGray3)))
                .foregroundStyle(.white).focused($captionFocused)
                .padding(.horizontal, 16).frame(height: 46)
                .liquidGlass(Capsule(), interactive: true)
            Button {
                onSend(caption.trimmingCharacters(in: .whitespacesAndNewlines))
                dismiss()
            } label: {
                Image(systemName: "arrow.up").font(.system(size: 19, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 46, height: 46).background(Color(hex: 0x3DA1FD), in: Circle())
            }
            .buttonStyle(StoryPressStyle())
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 8)
    }
}

// AVPlayer that loops + honors a `playing` binding, aspect-fit.
private struct LoopingVideoView: UIViewRepresentable {
    let url: URL
    @Binding var playing: Bool

    func makeUIView(context: Context) -> PlayerUIView { PlayerUIView(url: url) }
    func updateUIView(_ v: PlayerUIView, context: Context) { playing ? v.play() : v.pause() }
    static func dismantleUIView(_ v: PlayerUIView, coordinator: ()) { v.teardown() }
}

final class PlayerUIView: UIView {
    private let player: AVPlayer
    private var endObserver: NSObjectProtocol?
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    init(url: URL) {
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        super.init(frame: .zero)
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            self?.player.seek(to: .zero); self?.player.play()
        }
        player.play()
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }
    func play() { player.play() }
    func pause() { player.pause() }
    func teardown() {
        player.pause()
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
    }
}
