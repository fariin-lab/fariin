import SwiftUI
import AVFoundation
import UIKit

// Pre-send video editor (parity with the image editor): plays the picked video (looping within the
// trimmed range, tap to play/pause) with a Photos-style TRIM filmstrip (drag the two handles to cut the
// start/end), a caption field, and Send. On Send it exports just the trimmed range (or sends the original
// untouched if nothing was trimmed). Crop / pen are a follow-up (a larger video-composition feature).
struct VideoApprovalView: View {
    let url: URL
    var onSend: (_ finalURL: URL, _ caption: String, _ hd: Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var caption = ""
    @State private var playing = false   // PAUSED by default — plays only when the user taps play (user request)
    @State private var hd = false
    @FocusState private var captionFocused: Bool

    // Pinch-to-zoom + pan on the video preview (1×…4×), like the photo viewer.
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var drag: CGSize = .zero

    // Trim state
    @State private var duration: Double = 0
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0
    @State private var thumbnails: [UIImage] = []
    @State private var scrubTime: Double? = nil   // non-nil while dragging a handle → seek preview
    @State private var playhead: Double = 0        // live playback position (seconds) → scrubber line
    @State private var draggingPlayhead = false
    @State private var exporting = false

    private let stripHeight: CGFloat = 40   // 40px trim strip (user request)
    private let handleW: CGFloat = 12
    private let minDuration: Double = 1   // keep at least ~1s

    private var trimmed: Bool { duration > 0 && (trimStart > 0.05 || trimEnd < duration - 0.05) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // Same layout as the image editor: the video aspect-FITS the area BETWEEN the chrome (the
            // top bar + trim strip + caption, reserved by safeAreaInset below) instead of filling the
            // whole screen behind them — fully visible / zoomed-out, letterboxed on black, rounded
            // corners. (Was .ignoresSafeArea() → edge-to-edge full screen.)
            // The white playhead line tracks the player's REAL current time during playback (Bug 1/2 fix):
            // the periodic time observer reports the position every 0.05s and we write it to `playhead`,
            // so the line glides frame-by-frame in sync with the video instead of sitting frozen near the
            // left handle. While the user is dragging a handle/the playhead, `scrubTime` owns the position,
            // so we ignore player time then (no fight between the seek-preview and the observer).
            TrimmingPlayerView(url: url, playing: $playing, start: trimStart, end: max(trimStart + 0.1, trimEnd),
                               scrubTime: scrubTime,
                               onTime: { t in if scrubTime == nil { playhead = t } })
                .scaleEffect(max(1, zoom * pinch))
                .offset(x: pan.width + drag.width, y: pan.height + drag.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())   // NO rounded corners on the frame (user request)
                .gesture(
                    MagnificationGesture()
                        .updating($pinch) { v, s, _ in s = v }
                        .onEnded { v in zoom = min(4, max(1, zoom * v)); if zoom <= 1 { pan = .zero } }
                )
                .simultaneousGesture(
                    zoom > 1 ? DragGesture().updating($drag) { v, s, _ in s = v.translation }
                        .onEnded { v in pan.width += v.translation.width; pan.height += v.translation.height } : nil
                )
                .onTapGesture(count: 2) { withAnimation(.easeInOut(duration: 0.2)) { zoom = zoom > 1 ? 1 : 2; if zoom <= 1 { pan = .zero } } }
                .onTapGesture { if captionFocused { captionFocused = false } else { playing.toggle() } }
            if !playing && scrubTime == nil {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 66)).foregroundStyle(.white.opacity(0.85))
                    .allowsHitTesting(false)
            }
            if exporting {
                ZStack { Color.black.opacity(0.4).ignoresSafeArea(); ProgressView().tint(.white).scaleEffect(1.3) }
            }
        }
        // Top bar FLOATS over the video (X · HD) instead of sitting on a black band above it — the
        // video extends up to the top, no black "header". Only the bottom chrome insets the video.
        .overlay(alignment: .top) { topBar }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomControls }
        .task { await loadVideo() }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).liquidGlass(Circle(), interactive: true).contentShape(Circle())
            }
            .buttonStyle(.plain)
            Spacer()
            if trimmed {
                Text(trimLabel).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).frame(height: 32).liquidGlass(Capsule(), interactive: false)
            }
            // HD toggle (top-right) — 1080p when on, else 720p (matches the photo editor's HD).
            Button { hd.toggle() } label: {
                Text("HD").font(.system(size: 13, weight: .bold))
                    .foregroundStyle(hd ? Color(hex: 0x3DA1FD) : .white)
                    .frame(width: 44, height: 44).liquidGlass(Circle(), interactive: true).contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    @ViewBuilder private var bottomControls: some View {
        VStack(spacing: 12) {
            if !thumbnails.isEmpty && duration > 0 { trimStrip }
            captionBar
        }
        .padding(.bottom, 8)
    }

    // Photos-style trim: filmstrip with a yellow selection frame + two draggable handles; outside dimmed.
    private var trimStrip: some View {
        GeometryReader { geo in
            let W = geo.size.width
            let dur = max(0.01, duration)
            let startX = CGFloat(trimStart / dur) * W
            let endX = CGFloat(trimEnd / dur) * W
            ZStack(alignment: .leading) {
                // Thumbnails + the dimmed end sections share ONE rounded clip so the strip's outer
                // corners (including the dimmed parts) are rounded, not square.
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        ForEach(thumbnails.indices, id: \.self) { i in
                            Image(uiImage: thumbnails[i]).resizable().scaledToFill()
                                .frame(width: W / CGFloat(thumbnails.count), height: stripHeight).clipped()
                        }
                    }
                    .frame(width: W, height: stripHeight)
                    Rectangle().fill(.black.opacity(0.55)).frame(width: startX, height: stripHeight)
                    Rectangle().fill(.black.opacity(0.55)).frame(width: max(0, W - endX), height: stripHeight).offset(x: endX)
                }
                .frame(width: W, height: stripHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                // Yellow selection frame (rounded to match the rounded handle caps).
                RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.yellow, lineWidth: 3)
                    .frame(width: max(0, endX - startX), height: stripHeight).offset(x: startX)
                // PLAYHEAD scrubber: a white vertical line that tracks playback within the selection and
                // can be dragged to scrub. Clamped to the trimmed range; hidden when the range is empty.
                let phX = CGFloat((min(max(playhead, trimStart), trimEnd)) / dur) * W
                if trimEnd > trimStart {
                    Capsule().fill(.white)
                        .frame(width: 3, height: stripHeight + 8)
                        .shadow(color: .black.opacity(0.4), radius: 1.5)
                        .offset(x: min(max(0, phX - 1.5), W - 3))
                        .gesture(playheadDrag(width: W))
                }
                // Rounded trim handles.
                trimHandle.offset(x: max(0, startX - handleW / 2))
                    .gesture(handleDrag(isStart: true, width: W))
                trimHandle.offset(x: min(W - handleW, endX - handleW / 2))
                    .gesture(handleDrag(isStart: false, width: W))
            }
            .coordinateSpace(name: "trim")
        }
        .frame(height: stripHeight)
        .padding(.horizontal, 20)   // left/right margin so the strip + handles don't touch the edges
    }

    // Fully-rounded yellow grip (premium/native look) with a darker notch in the middle.
    private var trimHandle: some View {
        RoundedRectangle(cornerRadius: handleW / 2, style: .continuous).fill(Color.yellow)
            .frame(width: handleW, height: stripHeight)
            .overlay(Capsule().fill(.black.opacity(0.55)).frame(width: 2.5, height: 18))
    }

    // Drag the playhead to scrub; releasing resumes playback from that point.
    private func playheadDrag(width W: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("trim"))
            .onChanged { g in
                draggingPlayhead = true; playing = false
                let dur = max(0.01, duration)
                let t = Double(min(max(0, g.location.x), W) / W) * dur
                playhead = min(max(t, trimStart), trimEnd)
                scrubTime = playhead
            }
            .onEnded { _ in scrubTime = nil; draggingPlayhead = false; playing = true }
    }

    private func handleDrag(isStart: Bool, width W: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("trim"))
            .onChanged { g in
                let dur = max(0.01, duration)
                let t = Double(min(max(0, g.location.x), W) / W) * dur
                if isStart { trimStart = min(t, trimEnd - minDuration); scrubTime = trimStart }
                else { trimEnd = max(t, trimStart + minDuration); scrubTime = trimEnd }
                playing = false
            }
            .onEnded { _ in scrubTime = nil; playing = true }
    }

    private var captionBar: some View {
        HStack(spacing: 10) {
            TextField("", text: $caption, prompt: Text("Add a caption…").foregroundColor(Color(.systemGray3)),
                      axis: .vertical)
                .lineLimit(1...7)   // multi-line caption, grows up to ~7 lines then scrolls (Signal)
                .foregroundStyle(.white).focused($captionFocused)
                .padding(.horizontal, 16).padding(.vertical, 9).frame(minHeight: 40)
                .liquidGlass(RoundedRectangle(cornerRadius: 20, style: .continuous), interactive: true)
            Button { send() } label: {
                Image(systemName: "arrow.up").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40).liquidGlass(Circle(), interactive: true, tint: Theme.defaultBubble(false))   // 40px send (user spec)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain).disabled(exporting)
        }
        .padding(.horizontal, 16).padding(.top, 4)
    }

    private var trimLabel: String {
        let s = Int((trimEnd - trimStart).rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - Video load / export

    private func loadVideo() async {
        let asset = AVURLAsset(url: url)
        let dur = (try? await asset.load(.duration).seconds) ?? 0
        guard dur > 0 else { return }
        await MainActor.run { duration = dur; trimEnd = dur }

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .positiveInfinity
        gen.maximumSize = CGSize(width: 160, height: 160)
        let count = 10
        var imgs: [UIImage] = []
        for i in 0..<count {
            let t = CMTime(seconds: dur * Double(i) / Double(count - 1), preferredTimescale: 600)
            if let cg = try? await gen.image(at: t).image { imgs.append(UIImage(cgImage: cg)) }
        }
        await MainActor.run { thumbnails = imgs }
    }

    private func send() {
        let cap = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed else { onSend(url, cap, hd); dismiss(); return }
        exporting = true
        Task {
            let out = await exportTrimmed()
            await MainActor.run { exporting = false; onSend(out ?? url, cap, hd); dismiss() }
        }
    }

    private func exportTrimmed() async -> URL? {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        session.outputURL = out
        session.outputFileType = .mp4
        session.timeRange = CMTimeRange(start: CMTime(seconds: trimStart, preferredTimescale: 600),
                                        end: CMTime(seconds: trimEnd, preferredTimescale: 600))
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }
        return session.status == .completed ? out : nil
    }
}

// AVPlayer that loops within [start, end] and supports scrub-seeking while a trim handle is dragged.
private struct TrimmingPlayerView: UIViewRepresentable {
    let url: URL
    @Binding var playing: Bool
    var start: Double
    var end: Double
    var scrubTime: Double?
    var onTime: ((Double) -> Void)? = nil   // live playhead position (seconds)

    func makeUIView(context: Context) -> TrimPlayerUIView {
        let v = TrimPlayerUIView(url: url); v.onTime = onTime; return v
    }
    func updateUIView(_ v: TrimPlayerUIView, context: Context) {
        v.onTime = onTime
        v.setRange(start: start, end: end)
        if let s = scrubTime { v.seek(to: s) }
        playing ? v.play() : v.pause()
    }
    static func dismantleUIView(_ v: TrimPlayerUIView, coordinator: ()) { v.teardown() }
}

final class TrimPlayerUIView: UIView {
    private let player: AVPlayer
    private var timeObserver: Any?
    private var start: Double = 0
    private var end: Double = .greatestFiniteMagnitude
    var onTime: ((Double) -> Void)?
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    init(url: URL) {
        player = AVPlayer(playerItem: AVPlayerItem(url: url))
        super.init(frame: .zero)
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        // Loop within [start, end]: every 0.05s check the play head, report it (drives the scrubber),
        // and seek back to start at the out-point.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] time in
            guard let self else { return }
            self.onTime?(time.seconds)
            guard self.player.rate > 0 else { return }
            if time.seconds >= self.end - 0.03 || time.seconds < self.start - 0.1 {
                self.player.seek(to: CMTime(seconds: self.start, preferredTimescale: 600),
                                 toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
        // Do NOT auto-play — the owner's `playing` binding drives play/pause (paused by default).
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    func setRange(start: Double, end: Double) { self.start = start; self.end = end }
    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func play() {
        if player.currentTime().seconds >= end - 0.03 || player.currentTime().seconds < start - 0.1 {
            player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.play()
    }
    func pause() { player.pause() }
    func teardown() {
        player.pause()
        if let o = timeObserver { player.removeTimeObserver(o) }
    }
}
