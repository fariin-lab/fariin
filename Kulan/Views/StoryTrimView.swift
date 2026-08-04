import SwiftUI
import AVFoundation
import AVKit

// The story trim screen, to the owner's reference (2026-08-04, image 2): X on the left, Done on the
// right, the clip playing in the middle, and the filmstrip along the bottom.
//
// IT USES `VideoTrimStrip`, THE TRIMMER THIS APP ALREADY HAS — his instruction in as many words:
// "use my existing trim system, do not build a new trim system". That component owns the whole
// behaviour contract (handles never auto-play, the playhead clamps inside the frame, grey until you
// actually cut, then yellow), and every editor that trims inherits it. Nothing here re-implements a
// single part of it.
//
// NOTHING IS EXPORTED HERE. Done hands back two numbers. The cut is applied once, at post time, by
// exporting exactly that range — so opening trim, changing your mind and closing costs nothing, and
// a clip is never re-encoded while you are still deciding.
struct StoryTrimView: View {
    let url: URL
    let duration: Double
    @Binding var trimStart: Double
    @Binding var trimEnd: Double
    var onClose: () -> Void

    @State private var thumbnails: [UIImage] = []
    @State private var playhead: Double = 0
    @State private var scrubTime: Double?
    @State private var playing = false
    @State private var draggingPlayhead = false
    @State private var player = AVPlayer()
    // What the handles said when this screen opened, so X can put them back. Done keeps whatever is
    // there; X must not leave half a cut behind.
    @State private var openedStart: Double = 0
    @State private var openedEnd: Double = 0

    private var windowSafeTop: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.top }
            .first ?? 47
    }

    private var selectedLength: Double { max(0, trimEnd - trimStart) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                VideoPlayer(player: player)
                    .disabled(true)                       // our own play control, not Apple's chrome
                    .aspectRatio(contentMode: .fit)
                    .overlay {
                        if !playing {
                            Image(systemName: "play.fill")
                                .font(.system(size: 30)).foregroundStyle(.white)
                                .frame(width: 76, height: 76)
                                .background(Color.black.opacity(0.45), in: Circle())
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { playing.toggle() }
                Spacer(minLength: 0)
                strip
            }
        }
        .statusBarHidden(false)
        .task { await load() }
        .onDisappear { player.pause() }
        // The player follows the three things that can move it: play/pause, a handle drag preview,
        // and a playhead drag. One place, so they cannot disagree about where the video is.
        .onChange(of: playing) { _, on in on ? player.play() : player.pause() }
        .onChange(of: scrubTime) { _, t in
            guard let t else { return }
            player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private var header: some View {
        HStack {
            Button {
                trimStart = openedStart; trimEnd = openedEnd
                onClose()
            } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 48, height: 48).contentShape(Circle()).liquidGlass(Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            // The length you are about to keep, not the length of the file — that is the number you
            // are deciding, and his spec asks for it up here.
            Text(clock(selectedLength))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 14).frame(height: 32)
                .liquidGlass(Capsule())

            Spacer()

            Button { onClose() } label: {
                Text("Done").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 20).frame(height: 44)
                    .liquidGlass(Capsule(), interactive: true)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, max(windowSafeTop - 22, 10))
    }

    private var strip: some View {
        VideoTrimStrip(duration: duration, thumbnails: thumbnails,
                       trimStart: $trimStart, trimEnd: $trimEnd,
                       playhead: $playhead, scrubTime: $scrubTime,
                       playing: $playing, draggingPlayhead: $draggingPlayhead)
            .frame(height: 56)
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
            .opacity(thumbnails.isEmpty ? 0 : 1)   // reserve the slot; a strip appearing late jumps the page
    }

    private func clock(_ s: Double) -> String {
        let t = Int(s.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    private func load() async {
        openedStart = trimStart
        openedEnd = trimEnd > 0 ? trimEnd : duration
        if trimEnd <= 0 { trimEnd = duration }
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        await player.seek(to: CMTime(seconds: trimStart, preferredTimescale: 600))

        // The same filmstrip recipe VideoApprovalView uses: ten frames, rotation-corrected, small.
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .positiveInfinity
        gen.maximumSize = CGSize(width: 160, height: 160)
        let count = 10
        var imgs: [UIImage] = []
        for i in 0..<count {
            let t = CMTime(seconds: duration * Double(i) / Double(count - 1), preferredTimescale: 600)
            if let cg = try? await gen.image(at: t).image { imgs.append(UIImage(cgImage: cg)) }
        }
        await MainActor.run { thumbnails = imgs }
    }
}
