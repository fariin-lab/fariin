import SwiftUI
import AVFoundation
import FirebaseStorage

// Full-screen player for an E2EE video message — the delivery half of the mailman model:
// play from the device copy if we have one; otherwise download the ciphertext, decrypt,
// KEEP it on this device (VideoCache), and then delete the server object (1:1 chats) so
// our storage never holds delivered videos. Groups skip the delete (other members still
// need it) — the 30-day storage sweep collects those.
//
// The player itself is a custom media-viewer style (not AVKit): a plain AVPlayer layer with a MINIMAL,
// fading chrome — a bottom scrubber + time labels + play/pause, tap the video to toggle the chrome, no
// native transport bar / PiP / AirPlay clutter.
struct VideoPlayerScreen: View {
    let message: Message
    let cid: String
    // The visible viewport of the screen the video came from (window coords) — the drag-close's landing
    // is clipped through it, same as the image viewer. Nil = no clipping (gallery/profile).
    var clipProvider: () -> CGRect? = { nil }
    // Which screen's tile registry to land on — ids are shared across screens, scopes are not.
    var rectScope: MediaOpenRects.Scope = .chat
    // (A second, SwiftUI open/close animation used to live here alongside the UIKit one. It is gone —
    // see the note in ImageViewerView. One pipeline owns both directions for photo and video alike.)

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
    @State private var dismissing = false          // dismiss in flight → live content hidden ONCE
    @State private var closeToken = 0              // bump → the button close flies home like the drag
    // Pinch-zoom + pan (video hosted in the same zoomable view as photos).
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var panDrag: CGSize = .zero
    @State private var wasPlayingBeforeScrub = false
    @State private var skipFlash = 0            // -1 = back 10, +1 = forward 10 (which side flashed)
    @State private var skipFlashShown = false
    @State private var skipFlashWork: DispatchWorkItem?

    private var zoomed: Bool { max(1, zoom * pinch) > 1.01 }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // ONLY the player content hides when a drag-close begins — the flying poster copy replaces
            // it. Background and chrome stay live so the coordinator's root-alpha scrub (the reference app's
            // fromView.alpha) can melt them into the chat with the finger, and back on cancel.
            playerContent
                .opacity(dismissing ? 0 : 1)
        }
        .overlay(alignment: .top) { if showChrome { topBar } }
        .overlay(alignment: .bottom) { if showChrome, player != nil { scrubberBar } }
        .animation(.easeInOut(duration: 0.25), value: showChrome)
        .animation(.easeInOut(duration: 0.2), value: isPlaying)
        // Zoomed-in pan (the dismiss drag is now the shared pan below, images + videos identical).
        .simultaneousGesture(
            DragGesture(minimumDistance: 8)
                .updating($panDrag) { v, s, _ in if zoomed { s = v.translation } }
                .onEnded { g in
                    if zoomed { pan.width += g.translation.width; pan.height += g.translation.height }
                }
        )
        // The interactive dismiss — the SAME code path as the image viewer
        // (MediaDismiss.swift): one UIKit vertical pan, lightweight poster copy locked 1:1 to
        // the finger, constant 0.8 scale, root-alpha scrub, 0.25s spring.
        .overlay {
            // Unconditional: the system .zoom this used to be suppressed for is gone from chat media.
            MediaDismissHost(
                canBegin: { !zoomed && !scrubbing },
                media: {
                    // The video's fitted rect from its stored dimensions (fallback: full screen).
                    let bounds = UIScreen.main.bounds
                    var size = bounds.size
                    if let w = message.width, let h = message.height, w > 0, h > 0 {
                        size = CGSize(width: w, height: h)
                    }
                    // Fly the POSTER, not a live-region snapshot. Passing nil took the
                    // resizableSnapshotView branch, which captures whatever chrome has not finished
                    // hiding yet - the reference app always flies a still frame for video, never a layer or a
                    // snapshot of the screen.
                    return (mediaFitRect(size, in: bounds), poster)
                },
                onHideContent: { hidden in
                    if hidden { player?.pause() }   // freeze playback the moment the copy takes over
                    dismissing = hidden
                },
                // Land on the thumbnail this video came from. Without this the default { nil } was used,
                // so video drifted and faded in mid-air while photos flew home to their tile - the single
                // most visible difference between the two media types.
                targetRect: { MediaOpenRects.rect(MediaOpenRects.key(rectScope, message.id)) },
                targetId: { MediaOpenRects.key(rectScope, message.id) },
                clipRect: clipProvider,
                closeToken: closeToken,
                onDismiss: { instantDismiss() })
        }
        .presentationBackground(.clear)   // the fading backdrop reveals the conversation behind
        .statusBarHidden(true)
        .task { await load() }
        // noteClosed: the cover is gone for real, so a tap that arrived while it was leaving can run
        // now instead of waiting out a fixed guess. See MediaPresentGate.
        // A flying copy outlives this cover on purpose (it lands on the thumbnail after the viewer
        // is gone). If its landing never completes it is left in the window, drawn over the
        // conversation — see `sweepOrphanedFlights`.
        .onDisappear { cleanup(); MediaPresentGate.noteClosed(); MediaDismissHost.scheduleOrphanSweep() }
    }

    /// The still the transition flies. the reference app flies a poster frame for video too — never a player
    /// layer, never a snapshot of the live region — which is what makes video and photo behave alike.
    private var poster: UIImage? { message.thumbUrl.flatMap { DiskImageCache.shared.memoryImage($0) } }

    // The playing surface + its overlays, split out of `body` so the drag-close can hide EXACTLY this
    // (the copy's pixels) while background and chrome ride the root-alpha scrub.
    @ViewBuilder private var playerContent: some View {
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
                // Double-tap the LEFT half → back 10s, RIGHT half → forward 10s (YouTube/native).
                .onTapGesture(count: 2, coordinateSpace: .global) { loc in
                    if loc.x < UIScreen.main.bounds.width / 2 { skip(-10) } else { skip(10) }
                }
                // Single tap on the video → play/pause (user request), and reveal the controls.
                .onTapGesture { togglePlay(); showChromeBriefly() }
            if !isPlaying && !zoomed {   // center play button (glass) when paused / at end
                Button { togglePlay() } label: {
                    Image(systemName: "play.fill").font(.system(size: 30)).foregroundStyle(.primary)
                        .frame(width: 74, height: 74)
                        .liquidGlass(Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
            // ±10s skip flash (double-tap side) — a glass pill on the tapped half.
            if skipFlashShown {
                HStack {
                    if skipFlash < 0 { skipBadge("gobackward.10"); Spacer() }
                    else { Spacer(); skipBadge("goforward.10") }
                }
                .padding(.horizontal, 40)
                .allowsHitTesting(false)
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

    // Video closes exactly like a photo: one pipeline, the UIKit animator pair. The button close
    // flies the poster home through MediaDismissHost, same as the drag (its no-geometry fallback
    // dismisses plainly, so closing is never blocked).
    private func closeViewer() { closeToken += 1 }
    /// The drag-close's exit: the flying poster IS the animation, so the presentation goes without one.
    /// The transaction is what makes that true — a bare `dismiss()` still ran the cover's own slide-out
    /// under the copy, which held the presentation open and blocked an immediate re-tap.
    private func instantDismiss() {
        MediaPresentGate.noteDismissed()
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { dismiss() }
    }

    private func skipBadge(_ icon: String) -> some View {
        Image(systemName: icon).font(.system(size: 26, weight: .medium)).foregroundStyle(.primary)
            .frame(width: 66, height: 66)
            .liquidGlass(Circle(), interactive: false)
    }

    // Minimalist glass X (top-left).
    private var topBar: some View {
        HStack {
            Button { closeViewer() } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary)
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

    // Real Liquid Glass bottom bar (a minimalist control cluster): play/pause · elapsed ·
    // scrubber · duration in ONE glass capsule. Mono-digit 13pt labels.
    private var scrubberBar: some View {
        HStack(spacing: 12) {
            // No play/pause button here (user request) — tap the video center to play/pause.
            Text(fmt(current)).font(.system(size: 13).monospacedDigit()).foregroundStyle(.white)
            // Scrub = pause-then-resume: remember whether it was playing, pause while dragging,
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
    // Ensure the controls are visible right after a tap, then auto-hide again if playing.
    private func showChromeBriefly() {
        showChrome = true
        if isPlaying { scheduleAutoHide() } else { cancelAutoHide() }
    }
    // Jump ±N seconds, clamped to the clip (double-tap left/right). Flashes a brief indicator.
    private func skip(_ seconds: Double) {
        guard let player, duration > 0 else { return }
        let t = max(0, min(duration, current + seconds))
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        current = t
        progress = duration > 0 ? t / duration : 0
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        skipFlash = seconds < 0 ? -1 : 1
        withAnimation(.easeOut(duration: 0.15)) { skipFlashShown = true }
        skipFlashWork?.cancel()
        let w = DispatchWorkItem { withAnimation(.easeIn(duration: 0.25)) { skipFlashShown = false } }
        skipFlashWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
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
        // Terminal state — show unavailable instantly, never re-fetch (the unrecoverable-attachment state).
        if DeadMedia.contains(message.id) { await MainActor.run { unavailable = true }; return }
        guard let s = message.videoUrl, let url = URL(string: s), let meta = message.enc else {
            await MainActor.run { unavailable = true }; return
        }
        guard let (cipher, resp) = try? await MediaSession.shared.data(from: url) else {
            await MainActor.run { unavailable = true }; return   // transient network failure — NOT terminal
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let data = await Crypto.shared.decryptBytes(cid, cipher: cipher, meta: meta) else {
            if code == 403 || code == 404 { DeadMedia.mark(message.id) }   // object deleted → permanent, never re-fetch
            await MainActor.run { unavailable = true }
            return
        }
        // ⛔ THE SERVER COPY GOES ONLY IF THE LOCAL ONE ARRIVED. `VideoCache.store` is a `try?` write
        // that swallows every failure — a full disk, a protection class refusing while the device is
        // locked — and under the mailman model the server object is the ONLY other copy. The line
        // below already gated the player on the file existing; the delete did not, so opening a video
        // with no room to save it destroyed the video permanently.
        VideoCache.store(data, for: message.id)
        guard let local = VideoCache.url(for: message.id) else {
            await MainActor.run { unavailable = true }
            return
        }
        await MainActor.run { startPlayer(local) }
        if cid.contains("_"), message.authorId != AuthService.shared.uid {
            try? await Storage.storage().reference(forURL: s).delete()
        }
    }

    @MainActor private func startPlayer(_ url: URL) {
        // ⛔ ONE THING PLAYS AT A TIME. This screen sets the category and activates the session
        // directly, with no call check and no handover — and only ONE place in the whole app ever
        // pauses the voice player, which is not this one. So a note playing on the floating bar kept
        // playing underneath a video, both audible at once, and opening a video during a call took
        // the category out from under the call service.
        //
        // The broadcast that used to prevent this was removed on the reasoning that there is only one
        // player now. There are three: this, the gallery and the story player.
        VoiceNotePlayer.shared.pause()
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let p = AVPlayer(url: url)
        player = p
        duration = message.duration ?? 0
        // Smooth scrubber (a high-frequency observer); don't fight the user while scrubbing.
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

// Plain AVPlayer layer (aspect-fit), no AVKit transport controls — a custom media-viewer surface.
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
