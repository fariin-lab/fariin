import SwiftUI
import AVFoundation
import AVKit

// Video-story editor — the video plays looping on the same rounded canvas card as the photo
// editor (muted poster-frame wash behind it, black frame above/below), with the same caption
// bar (40px) + NEXT (46px) layout. Tools: mute toggle only — crop/pen/text are photo tools.
// Videos longer than the story cap are auto-trimmed to the first 30s at post time
// (as standard messengers do); a label says so up front, nothing is rejected.
struct StoryVideoEditorView: View {
    let url: URL
    var onPosted: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    @State private var caption = ""
    @State private var muted = false
    @State private var duration: Double = 0
    @State private var thumbnail: UIImage?
    @State private var thumbnailData: Data?
    @State private var pendingShare: StoryVideoShare?
    @State private var loadFailed = false
    @FocusState private var captionFocused: Bool
    @StateObject private var keyboard = KeyboardWatcher()   // manual keyboard rise (same as the photo editor)
    // One AVQueuePlayer + looper for the whole editor session.
    @State private var player = AVQueuePlayer()
    @State private var looper: AVPlayerLooper?
    @State private var playing = true
    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    @State private var showTrim = false
    /// The cut, in seconds. Applied at POST time by exporting exactly this range, so nothing is
    /// re-encoded while you are still deciding.
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0

    private var isTrimmed: Bool { trimStart > 0.05 || (duration > 0 && trimEnd < duration - 0.05) }
    private var trimmedLength: Double { max(0, trimEnd - trimStart) }

    private func togglePlay() {
        playing.toggle()
        if playing { player.play() } else { player.pause() }
    }

    private var windowSafeTop: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.top }
            .first ?? 47
    }

    struct StoryVideoShare: Identifiable { let id = UUID(); let payload: StoryVideoPayload; let caption: String }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                let cardTop: CGFloat = 8
                let cardBottomGap: CGFloat = 44
                let cardH = geo.size.height - cardTop - cardBottomGap
                if cardH > 0 {
                    // Muted wash behind the video — poster frame, same recipe as the photo editor.
                    if let thumbnail {
                        Image(uiImage: thumbnail).resizable().scaledToFill()
                            .frame(width: geo.size.width, height: cardH)
                            .blur(radius: 90, opaque: true)
                            .saturation(0.4)
                            .overlay(Color.black.opacity(0.4))
                            .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
                            .position(x: geo.size.width / 2, y: cardTop + cardH / 2)
                            .allowsHitTesting(false)
                    } else {
                        RoundedRectangle(cornerRadius: 40, style: .continuous)
                            .fill(Color(white: 0.08))
                            .frame(width: geo.size.width, height: cardH)
                            .position(x: geo.size.width / 2, y: cardTop + cardH / 2)
                    }
                    // The looping video, aspect-fit, contained in the card.
                    //
                    // PINCH ZOOMS IT (owner 2026-08-04). The scale lives on the player view and the
                    // mask stays put, so the video grows INSIDE the card instead of spilling over its
                    // rounded edge. Springs back if you pinch below 1, and 4x is as far in as a story
                    // is worth going.
                    LoopingPlayerView(player: player)
                        .frame(width: geo.size.width, height: cardH)
                        .scaleEffect(zoom)
                        .mask {
                            RoundedRectangle(cornerRadius: 40, style: .continuous)
                                .frame(width: geo.size.width, height: cardH)
                        }
                        .position(x: geo.size.width / 2, y: cardTop + cardH / 2)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { v in zoom = min(4, max(0.9, baseZoom * v)) }
                                .onEnded { _ in
                                    baseZoom = max(1, zoom)
                                    if zoom < 1 { withAnimation(.snappy(duration: 0.25)) { zoom = 1 } }
                                }
                        )
                        // Tap puts the keyboard away if it is up, otherwise it plays and pauses —
                        // the caption always wins, because a tap meant for dismissing a keyboard
                        // should never also stop the video.
                        .onTapGesture {
                            if captionFocused { captionFocused = false } else { togglePlay() }
                        }

                    // The play mark, only while paused, exactly as his reference draws it.
                    if !playing {
                        Image(systemName: "play.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(.white)
                            .frame(width: 84, height: 84)
                            .background(Color.black.opacity(0.45), in: Circle())
                            .position(x: geo.size.width / 2, y: cardTop + cardH / 2)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }

                // Top controls: X (left), trim notice + mute (right).
                VStack {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.primary)
                                .shadow(color: .black.opacity(0.35), radius: 2)
                                .frame(width: 48, height: 48).contentShape(Circle()).liquidGlass(Circle())
                        }
                        Spacer()
                        // NOTHING IS THROWN AWAY ANY MORE, so the notice stopped being a warning and
                        // became a fact: a long video posts as several stories that play one after
                        // another. It used to read "First 30s will be shared", which was the app
                        // telling you it was about to discard the rest.
                        if segmentCount > 1 {
                            Text("Posts as \(segmentCount) stories")
                                .font(.footnote.weight(.medium)).foregroundStyle(.primary)
                                .padding(.horizontal, 12).frame(height: 32)
                                .liquidGlass(Capsule())
                        }
                        Button { muted.toggle(); player.isMuted = muted } label: {
                            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.primary)
                                .frame(width: 48, height: 48).contentShape(Circle()).liquidGlass(Circle())
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, max(windowSafeTop - 22, 10))
                    Spacer()
                }
                .ignoresSafeArea(.keyboard, edges: .bottom)

                // Bottom bar — caption + NEXT, lifted manually above the keyboard (photo-editor math).
                VStack {
                    Spacer()
                    bottomBar
                        .padding(.bottom, keyboard.height > 0
                            ? max(8, geo.frame(in: .global).maxY - (UIScreen.main.bounds.height - keyboard.height) - 2)
                            : -14)
                }
            }
        }
        .ignoresSafeArea(.keyboard)
        .statusBarHidden(false)
        .alert("Couldn't load this video", isPresented: $loadFailed) {
            Button("OK", role: .cancel) { dismiss() }
        }
        .sheet(item: $pendingShare) { s in
            ShareStorySheet(image: s.payload.thumbnail, caption: s.caption, video: s.payload,
                            onPosted: { onPosted(); dismiss() })
        }
        .fullScreenCover(isPresented: $showTrim) {
            StoryTrimView(url: url, duration: duration,
                          trimStart: $trimStart, trimEnd: $trimEnd,
                          onClose: { showTrim = false })
        }
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
        .onDisappear { player.pause() }
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {
            HStack(alignment: .bottom, spacing: 10) {
                HStack(spacing: 10) {
                    TextField("", text: $caption, prompt: Text("Add a caption…").foregroundColor(Color.white.opacity(0.6)), axis: .vertical)
                        .foregroundStyle(.white).focused($captionFocused)
                        // ...and the text itself carries a hairline shadow so it reads on white.
                        .shadow(color: .black.opacity(0.45), radius: 1.5)
                        .lineLimit(1...5)
                        .onChange(of: caption) { _, v in
                            if v.count > Limits.storyCaptionChars { caption = String(v.prefix(Limits.storyCaptionChars)) }
                        }
                }
                .padding(.horizontal, 18).padding(.vertical, 9).frame(minHeight: 40)
                // Liquid Glass, tinted dark (owner 2026-08-04). Plain glass goes pale over a bright
                // frame and swallows the white placeholder, which is the bug the flat pill was
                // covering for; the tint is Apple's own, so this is real glass that still gives
                // white text something to sit on. The text keeps its hairline shadow for the same
                // reason.
                .liquidGlass(RoundedRectangle(cornerRadius: 20, style: .continuous),
                             tint: .black.opacity(0.28))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)

                if captionFocused { compactSendButton }
            }
            .padding(.bottom, 10)

            if !captionFocused {
                HStack(spacing: 14) {
                    // TRIM ONLY, and only here. Aa, crop and pen draw ON a picture; on a video they
                    // would have to be burned into every frame at export, which is a different job
                    // from the photo editor's and not one to fake with a button that does nothing.
                    HStack(spacing: 22) {
                        Button { player.pause(); playing = false; showTrim = true } label: {
                            Image(systemName: "scissors")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(isTrimmed ? .green : .white)
                                .frame(width: 32, height: 32).contentShape(Rectangle())
                        }
                        .buttonStyle(StoryPressStyle())
                    }
                    .padding(.horizontal, 20).frame(height: 46)
                    .liquidGlass(Capsule())

                    Spacer()
                    sendButton
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var compactSendButton: some View {
        Button {
            // Same keyboard-dismissal race as the photo editor: resign, settle, then present.
            captionFocused = false
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                send()
            }
        } label: {
            Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .liquidGlass(Circle(), interactive: true, tint: Color(.systemBlue))
        }
        .buttonStyle(StoryPressStyle()).disabled(thumbnailData == nil)
    }

    private var sendButton: some View {
        Button { send() } label: {
            HStack(spacing: 4) {
                Text("NEXT").font(.system(size: 16, weight: .semibold))
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 22).frame(height: 46)
            .liquidGlass(Capsule(), interactive: true, tint: Color(.systemBlue))
            .contentShape(Capsule())   // whole pill tappable (not just the text)
        }
        .buttonStyle(StoryPressStyle()).disabled(thumbnailData == nil)
    }

    private func send() {
        guard let thumbnailData else { return }
        pendingShare = StoryVideoShare(
            payload: StoryVideoPayload(url: url, thumbnail: thumbnailData, muted: muted,
                                       trim: isTrimmed ? trimStart...trimEnd : nil),
            caption: caption.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// How many stories this post will become, so the notice can say it plainly.
    private var segmentCount: Int {
        let len = isTrimmed ? trimmedLength : duration
        guard len > Double(Limits.storyVideoSeconds) + 0.5 else { return 1 }
        return Int(ceil(min(len, Double(Limits.storyVideoPickSeconds)) / Double(Limits.storyVideoSeconds)))
    }

    // Load duration + poster frame, start the loop. The poster is the SAME frame recipe the
    // uploader's transcoder uses (just after the start — frame 0 is often black).
    private func load() async {
        let asset = AVURLAsset(url: url)
        guard let dur = try? await asset.load(.duration).seconds, dur > 0 else { loadFailed = true; return }
        duration = dur
        if trimEnd <= 0 { trimEnd = dur }   // the trim starts as "all of it"
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1600, height: 1600)
        let t = CMTime(seconds: min(0.1, dur / 2), preferredTimescale: 600)
        if let cg = try? await gen.image(at: t).image {
            let ui = UIImage(cgImage: cg)
            thumbnail = ui
            thumbnailData = ui.jpegData(compressionQuality: 0.72)
        } else {
            loadFailed = true
            return
        }
        // Editor preview plays with sound (stories are sound-on media, like every big app).
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        let item = AVPlayerItem(asset: asset)
        looper = AVPlayerLooper(player: player, templateItem: item)
        player.isMuted = muted
        player.play()
    }
}

// Aspect-FIT AVPlayerLayer host (the editor shows the whole frame; the viewer fills the screen).
private struct LoopingPlayerView: UIViewRepresentable {
    let player: AVQueuePlayer

    final class PlayerHostView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> PlayerHostView {
        let v = PlayerHostView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        return v
    }

    func updateUIView(_ v: PlayerHostView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
    }
}
