import SwiftUI
import AVFoundation
import UIKit

// Pre-send video editor (parity with the image editor): plays the picked video (looping within the
// trimmed range, tap to play/pause) with a Photos-style TRIM filmstrip (drag the two handles to cut the
// start/end), a caption field, and Send. On Send it exports just the trimmed range (or sends the original
// untouched if nothing was trimmed). Crop / pen are a follow-up (a larger video-composition feature).
struct VideoApprovalView: View {
    let url: URL
    var onSend: (_ finalURL: URL, _ caption: String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var caption = ""
    @State private var playing = true
    @FocusState private var captionFocused: Bool

    // Trim state
    @State private var duration: Double = 0
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0
    @State private var thumbnails: [UIImage] = []
    @State private var scrubTime: Double? = nil   // non-nil while dragging a handle → seek preview
    @State private var exporting = false

    private let stripHeight: CGFloat = 50
    private let handleW: CGFloat = 12
    private let minDuration: Double = 1   // keep at least ~1s

    private var trimmed: Bool { duration > 0 && (trimStart > 0.05 || trimEnd < duration - 0.05) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TrimmingPlayerView(url: url, playing: $playing, start: trimStart, end: max(trimStart + 0.1, trimEnd), scrubTime: scrubTime)
                .ignoresSafeArea()
                .contentShape(Rectangle())
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
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
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
                HStack(spacing: 0) {
                    ForEach(thumbnails.indices, id: \.self) { i in
                        Image(uiImage: thumbnails[i]).resizable().scaledToFill()
                            .frame(width: W / CGFloat(thumbnails.count), height: stripHeight).clipped()
                    }
                }
                .frame(width: W, height: stripHeight).clipShape(RoundedRectangle(cornerRadius: 8))
                // Dim outside the selection.
                Rectangle().fill(.black.opacity(0.55)).frame(width: startX, height: stripHeight)
                Rectangle().fill(.black.opacity(0.55)).frame(width: max(0, W - endX), height: stripHeight).offset(x: endX)
                // Yellow selection frame.
                RoundedRectangle(cornerRadius: 3).stroke(Color.yellow, lineWidth: 3)
                    .frame(width: max(0, endX - startX), height: stripHeight).offset(x: startX)
                // Handles.
                trimHandle.offset(x: max(0, startX - handleW / 2))
                    .gesture(handleDrag(isStart: true, width: W))
                trimHandle.offset(x: min(W - handleW, endX - handleW / 2))
                    .gesture(handleDrag(isStart: false, width: W))
            }
            .coordinateSpace(name: "trim")
        }
        .frame(height: stripHeight)
        .padding(.horizontal, 16)
    }

    private var trimHandle: some View {
        RoundedRectangle(cornerRadius: 3).fill(Color.yellow)
            .frame(width: handleW, height: stripHeight)
            .overlay(RoundedRectangle(cornerRadius: 1.5).fill(.black.opacity(0.55)).frame(width: 2, height: 18))
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
            TextField("", text: $caption, prompt: Text("Add a caption…").foregroundColor(Color(.systemGray3)))
                .foregroundStyle(.white).focused($captionFocused)
                .padding(.horizontal, 16).frame(height: 46)
                .liquidGlass(Capsule(), interactive: true)
            Button { send() } label: {
                Image(systemName: "arrow.up").font(.system(size: 19, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 46, height: 46).liquidGlass(Circle(), interactive: true, tint: Theme.defaultBubble(false))
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
        guard trimmed else { onSend(url, cap); dismiss(); return }
        exporting = true
        Task {
            let out = await exportTrimmed()
            await MainActor.run { exporting = false; onSend(out ?? url, cap); dismiss() }
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

    func makeUIView(context: Context) -> TrimPlayerUIView { TrimPlayerUIView(url: url) }
    func updateUIView(_ v: TrimPlayerUIView, context: Context) {
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
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    init(url: URL) {
        player = AVPlayer(playerItem: AVPlayerItem(url: url))
        super.init(frame: .zero)
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        // Loop within [start, end]: every 0.1s check the play head and seek back to start at the out-point.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] time in
            guard let self, self.player.rate > 0 else { return }
            if time.seconds >= self.end - 0.03 || time.seconds < self.start - 0.1 {
                self.player.seek(to: CMTime(seconds: self.start, preferredTimescale: 600),
                                 toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
        player.play()
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
