import SwiftUI
import AVFoundation
import FirebaseStorage

// Full-screen player for an E2EE video message — the delivery half of the mailman model:
// play from the device copy if we have one; otherwise download the ciphertext, decrypt,
// KEEP it on this device (VideoCache), and then delete the server object (1:1 chats) so
// our storage never holds delivered videos. Groups skip the delete (other members still
// need it) — the 30-day storage sweep collects those.
//
// The player itself is Signal's media-viewer style (not AVKit): a plain AVPlayer layer with a MINIMAL,
// fading chrome — a bottom scrubber + time labels + play/pause, tap the video to toggle the chrome, no
// native transport bar / PiP / AirPlay clutter.
struct VideoPlayerScreen: View {
    let message: Message
    let cid: String

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var unavailable = false
    @State private var isPlaying = true
    @State private var progress: Double = 0        // 0…1 (bound to the scrubber)
    @State private var current: Double = 0         // seconds
    @State private var duration: Double = 0
    @State private var scrubbing = false
    @State private var showChrome = true
    @State private var timeObserver: Any?
    @State private var endObserver: NSObjectProtocol?
    @State private var hideWork: DispatchWorkItem?
    @State private var drag: CGSize = .zero        // drag-to-dismiss offset (follows the finger)
    @State private var dragProgress: Double = 0
    // Pinch-zoom + pan (Signal hosts video in the same zoomable view as photos).
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var panDrag: CGSize = .zero
    @State private var wasPlayingBeforeScrub = false

    private var zoomed: Bool { max(1, zoom * pinch) > 1.01 }

    var body: some View {
        ZStack {
            Color.black.opacity(1 - dragProgress * 0.85).ignoresSafeArea()
            if let player {
                PlayerLayerView(player: player)
                    .scaleEffect(max(1, zoom * pinch))
                    .offset(x: pan.width + panDrag.width, y: pan.height + panDrag.height)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .gesture(
                        MagnificationGesture()
                            .updating($pinch) { v, s, _ in s = v }
                            .onEnded { v in zoom = min(4, max(1, zoom * v)); if zoom <= 1 { pan = .zero } }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.easeInOut(duration: 0.25)) { zoom = zoomed ? 1 : 2; if zoom <= 1 { pan = .zero } }
                    }
                    .onTapGesture { toggleChrome() }
                if !isPlaying && !zoomed {   // center play button (glass) when paused / at end
                    Button { togglePlay() } label: {
                        Image(systemName: "play.fill").font(.system(size: 30)).foregroundStyle(.white)
                            .frame(width: 74, height: 74)
                            .liquidGlass(Circle(), interactive: true)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
            } else if unavailable {
                VStack(spacing: 10) {
                    Image(systemName: "video.slash").font(.system(size: 34))
                    Text("Video no longer available").font(.system(size: 15, weight: .medium))
                    Text("It was delivered and removed from the server.")
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                }
                .foregroundStyle(.white)
            } else {
                ProgressView().tint(.white).scaleEffect(1.4)
            }
        }
        // The whole viewer follows the finger down to dismiss + shrinks gently.
        .scaleEffect(1 - dragProgress * 0.12)
        .offset(drag)
        .overlay(alignment: .top) { if showChrome { topBar } }
        .overlay(alignment: .bottom) { if showChrome, player != nil { scrubberBar } }
        .animation(.easeInOut(duration: 0.25), value: showChrome)
        .animation(.easeInOut(duration: 0.2), value: isPlaying)
        // ONE drag: when zoomed in it PANS the video; at fit it's the drag-down-to-dismiss (1:1 finger
        // follow, commit on flick / past 18%, else spring back).
        .simultaneousGesture(
            DragGesture(minimumDistance: 8)
                .updating($panDrag) { v, s, _ in if zoomed { s = v.translation } }
                .onChanged { g in
                    guard !zoomed, !scrubbing, g.translation.height > 0,
                          abs(g.translation.height) > abs(g.translation.width) else { return }
                    drag = g.translation
                    dragProgress = min(1, g.translation.height / UIScreen.main.bounds.height)
                }
                .onEnded { g in
                    if zoomed {
                        pan.width += g.translation.width; pan.height += g.translation.height
                        return
                    }
                    guard dragProgress > 0 else { return }
                    if g.velocity.height > 700 || g.translation.height > UIScreen.main.bounds.height * 0.18 {
                        dismiss()
                    } else {
                        withAnimation(.spring(response: 0.25, dampingFraction: 1)) { drag = .zero; dragProgress = 0 }
                    }
                }
        )
        .statusBarHidden(true)
        .task { await load() }
        .onDisappear { cleanup() }
    }

    // Minimalist glass X (top-left).
    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .liquidGlass(Circle(), interactive: true)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.top, 6)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // Real Liquid Glass bottom bar (Signal's minimalist control cluster): play/pause · elapsed ·
    // scrubber · duration in ONE glass capsule. Mono-digit 13pt labels.
    private var scrubberBar: some View {
        HStack(spacing: 12) {
            Button { togglePlay() } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .medium)).foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            Text(fmt(current)).font(.system(size: 13).monospacedDigit()).foregroundStyle(.white)
            // Scrub = pause-then-resume (Signal): remember whether it was playing, pause while dragging,
            // seek live, resume on release only if it was playing.
            Slider(value: $progress, in: 0...1) { editing in
                scrubbing = editing
                if editing {
                    wasPlayingBeforeScrub = isPlaying
                    player?.pause(); isPlaying = false
                    cancelAutoHide()
                } else {
                    seek(to: progress)
                    if wasPlayingBeforeScrub { player?.play(); isPlaying = true }
                    scheduleAutoHide()
                }
            }
            .tint(.white)
            Text(fmt(duration)).font(.system(size: 13).monospacedDigit()).foregroundStyle(.white.opacity(0.65))
        }
        .padding(.horizontal, 16).frame(height: 44)
        .liquidGlass(Capsule(), interactive: true)
        .padding(.horizontal, 12).padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func fmt(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s); return String(format: "%d:%02d", t / 60, t % 60)
    }

    // MARK: - Playback control

    private func togglePlay() {
        guard let player else { return }
        if isPlaying { player.pause(); isPlaying = false; showChrome = true; cancelAutoHide() }
        else {
            if current >= duration - 0.05 { player.seek(to: .zero); current = 0; progress = 0 }   // replay from end
            player.play(); isPlaying = true; scheduleAutoHide()
        }
    }

    private func seek(to p: Double) {
        guard let player, duration > 0 else { return }
        player.seek(to: CMTime(seconds: p * duration, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func toggleChrome() {
        showChrome.toggle()
        if showChrome && isPlaying { scheduleAutoHide() } else { cancelAutoHide() }
    }
    private func scheduleAutoHide() {
        cancelAutoHide()
        let w = DispatchWorkItem { if isPlaying && !scrubbing { showChrome = false } }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: w)
    }
    private func cancelAutoHide() { hideWork?.cancel(); hideWork = nil }

    // MARK: - Load (mailman: local → download+decrypt+cache → clear server)

    private func load() async {
        if let local = VideoCache.url(for: message.id) { await MainActor.run { startPlayer(local) }; return }
        // Known-gone (mailman: delivered 1:1 videos are deleted server-side; a 404 is PERMANENT).
        // Terminal state — show unavailable instantly, never re-fetch (Signal's unrecoverable-attachment state).
        if DeadMedia.contains(message.id) { await MainActor.run { unavailable = true }; return }
        guard let s = message.videoUrl, let url = URL(string: s), let meta = message.enc else {
            await MainActor.run { unavailable = true }; return
        }
        guard let (cipher, resp) = try? await URLSession.shared.data(from: url) else {
            await MainActor.run { unavailable = true }; return   // transient network failure — NOT terminal
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let data = await Crypto.shared.decryptBytes(cid, cipher: cipher, meta: meta) else {
            if code == 403 || code == 404 { DeadMedia.mark(message.id) }   // object deleted → permanent, never re-fetch
            await MainActor.run { unavailable = true }
            return
        }
        VideoCache.store(data, for: message.id)
        if let local = VideoCache.url(for: message.id) { await MainActor.run { startPlayer(local) } }
        if cid.contains("_"), message.authorId != AuthService.shared.uid {
            try? await Storage.storage().reference(forURL: s).delete()
        }
    }

    @MainActor private func startPlayer(_ url: URL) {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let p = AVPlayer(url: url)
        player = p
        duration = message.duration ?? 0
        // Smooth scrubber (Signal runs a high-frequency observer); don't fight the user while scrubbing.
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { time in
            if duration <= 0, let d = p.currentItem?.duration.seconds, d.isFinite { duration = d }
            guard !scrubbing else { return }
            current = time.seconds
            progress = duration > 0 ? min(1, current / duration) : 0
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                             object: p.currentItem, queue: .main) { _ in
            isPlaying = false; showChrome = true; cancelAutoHide()
        }
        p.play(); isPlaying = true
        scheduleAutoHide()
    }

    private func cleanup() {
        cancelAutoHide()
        if let o = timeObserver { player?.removeTimeObserver(o) }
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        player?.pause()
    }
}

// Plain AVPlayer layer (aspect-fit), no AVKit transport controls — Signal's media-viewer surface.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> PlayerLayerUIView { PlayerLayerUIView(player: player) }
    func updateUIView(_ v: PlayerLayerUIView, context: Context) { v.setPlayer(player) }
}

private final class PlayerLayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    init(player: AVPlayer) {
        super.init(frame: .zero)
        backgroundColor = .black
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }
    func setPlayer(_ p: AVPlayer) { if playerLayer.player !== p { playerLayer.player = p } }
}
