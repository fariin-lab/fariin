import SwiftUI
import AVFoundation
import UIKit

// One clip in the (multi-)video editor: local url + poster thumb + duration (both straight from the picker).
struct ApprovalClip: Identifiable {
    let id = UUID()
    /// The photo library id this clip came from, so removing it here can untick it in the picker.
    /// nil for anything that was not picked from the library.
    var assetId: String? = nil
    let url: URL
    var thumb: UIImage?
    var duration: Double
}

// Pre-send video editor (parity with the image editor): plays the picked video (looping within the
// trimmed range, tap to play/pause) with a Photos-style TRIM filmstrip (drag the two handles to cut the
// start/end), a caption field, and Send. On Send it exports just the trimmed range (or sends the original
// untouched if nothing was trimmed).
//
// MULTI-VIDEO MODE (user spec, reference screenshot): the SAME page — identical zoom, HD button, trim
// strip, caption, spacing — plus a horizontal THUMBNAIL RAIL at the canvas's bottom-right showing every
// selected video (duration badge, blue border on the current one, X to remove it). Tapping a thumb
// switches the editor to that clip; each clip keeps its own trim. Send exports every clip.
struct VideoApprovalView: View {
    // Per-clip trim state, stashed when switching clips so every video keeps its own cut.
    private struct ClipTrim {
        var duration: Double
        var trimStart: Double
        var trimEnd: Double
        var videoSize: CGSize
        var thumbnails: [UIImage]
    }

    @State private var clipList: [ApprovalClip]
    /// Removed here → deselect there (see MediaApprovalView.onRemove).
    var onRemove: (String) -> Void = { _ in }
    @State private var current = 0
    @State private var stash: [UUID: ClipTrim] = [:]
    let onSend: (_ finalURL: URL, _ caption: String, _ hd: Bool) -> Void
    let onSendMulti: ((_ finalURLs: [URL], _ caption: String, _ hd: Bool) -> Void)?
    // false when presented OVER the media sheet: the caller closes the sheet (whole stack, one motion);
    // self-dismissing first flashed the sheet for a beat before it closed.
    let selfDismissOnSend: Bool
    @Environment(\.dismiss) private var dismiss

    // ⛔ OUT OF THE TILE AND BACK — owner 2026-10-14: "when I tap a video it is the old design,
    // coming from the bottom". Same as the photo editor: opened from an attach tile, a still of the
    // video flies out of the tile onto `restRect`, the tools fade in during the flight (`arrival`),
    // and X / a drag down fly it back through `MediaDismissHost`. Nil keeps the plain cover.
    private let singleKey: String?
    private let singlePoster: UIImage?
    /// Several clips opened out of an attach tile: the fly-home follows whichever clip is showing.
    private let clipsFromAttach: Bool
    private var sourceKey: String? {
        guard clipsFromAttach else { return singleKey }
        return clipList.indices.contains(current) ? clipList[current].assetId.map { MediaOpenRects.key(.attach, $0) } : nil
    }
    private var poster: UIImage? {
        guard clipsFromAttach else { return arrival.image ?? singlePoster }   // the sharper one, when it came
        return clipList.indices.contains(current) ? clipList[current].thumb : nil
    }
    @ObservedObject private var arrival: EditorArrival
    private var arrived: Bool { arrival.landed }
    @State private var dismissing = false   // a close is flying: the live video hidden, the copy shows it
    @State private var closeToken = 0       // bump: MediaDismissHost runs the X as a fly-home
    @State private var chromeShown = false

    // Single video (the existing call sites, unchanged).
    init(url: URL, onSend: @escaping (_ finalURL: URL, _ caption: String, _ hd: Bool) -> Void,
         selfDismissOnSend: Bool = true,
         sourceKey: String? = nil, poster: UIImage? = nil,
         arrival: EditorArrival = EditorArrival(landed: true)) {
        _clipList = State(initialValue: [ApprovalClip(url: url, thumb: nil, duration: 0)])
        self.onSend = onSend
        self.onSendMulti = nil
        self.selfDismissOnSend = selfDismissOnSend
        self.singleKey = poster == nil ? nil : sourceKey   // nothing to fly without a still
        self.singlePoster = poster
        self.clipsFromAttach = false
        self.pendingLoad = nil
        _arrival = ObservedObject(wrappedValue: arrival)
    }

    /// Opened out of an attach tile before its file is here (owner 2026-10-14, the same recipe as the
    /// photo: the reference picker flies the poster and builds no player until it is needed). The
    /// poster stands in on the page; the player is built the moment `load` says the library's file
    /// can be played; our copy, when it is made, is what Send uses.
    init(pending load: AttachVideoLoad,
         onSend: @escaping (_ finalURL: URL, _ caption: String, _ hd: Bool) -> Void,
         selfDismissOnSend: Bool = true,
         sourceKey: String? = nil, poster: UIImage? = nil,
         arrival: EditorArrival = EditorArrival(landed: true)) {
        _clipList = State(initialValue: [ApprovalClip(url: Self.placeholderURL, thumb: poster, duration: 0)])
        _clipReady = State(initialValue: false)
        self.onSend = onSend
        self.onSendMulti = nil
        self.selfDismissOnSend = selfDismissOnSend
        self.singleKey = poster == nil ? nil : sourceKey
        self.singlePoster = poster
        self.clipsFromAttach = false
        self.pendingLoad = load
        _arrival = ObservedObject(wrappedValue: arrival)
    }

    // Multiple videos → the same editor with the thumbnail rail.
    init(clips: [ApprovalClip], onSendMulti: @escaping (_ finalURLs: [URL], _ caption: String, _ hd: Bool) -> Void,
         selfDismissOnSend: Bool = true, onRemove: @escaping (String) -> Void = { _ in },
         start: Int = 0, arrival: EditorArrival? = nil) {
        _clipList = State(initialValue: clips)
        // Opened on the tapped clip (owner 2026-10-14), not always the first.
        _current = State(initialValue: clips.indices.contains(start) ? start : 0)
        self.onSend = { _, _, _ in }
        self.onSendMulti = onSendMulti
        self.selfDismissOnSend = selfDismissOnSend
        self.onRemove = onRemove
        self.singleKey = nil
        self.singlePoster = nil
        self.clipsFromAttach = arrival != nil
        self.pendingLoad = nil
        _arrival = ObservedObject(wrappedValue: arrival ?? EditorArrival(landed: true))
    }

    /// The file still arriving, for an editor opened on its poster (see `init(pending:)`).
    private let pendingLoad: AttachVideoLoad?
    /// False while the clip's url is `placeholderURL`: no player is built, the poster stands in.
    @State private var clipReady = true
    /// Our own copy of a pending file, preferred by Send over the library's url.
    @State private var sendFile: URL?
    /// What a pending clip carries until its file is known. Never opened: `clipReady` gates it.
    static let placeholderURL = URL(fileURLWithPath: "/dev/null")
    private var sendURL: URL { sendFile ?? activeURL }
    private func isTall(_ s: CGSize) -> Bool { s.width > 0 && s.height >= s.width * (16.0 / 9.0) - 1 }

    /// The last measured height of the bottom controls, so the open can land before this screen
    /// exists to measure them: strip 40 + gap 12 + caption bar (4 above + 40) + 8 below.
    private static var lastControlsH: CGFloat = 104

    /// Where the video sits at rest, in window coordinates: the safe-area box minus the bottom
    /// controls (the `safeAreaInset`), the video aspect-fit inside, as `.resizeAspect` draws it.
    static func restRect(_ video: CGSize, controlsH: CGFloat? = nil) -> CGRect? {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return nil }
        let inset = window.safeAreaInsets, b = window.bounds
        let width = b.width - inset.left - inset.right
        let height = max(0, b.height - inset.top - inset.bottom - (controlsH ?? lastControlsH))
        return mediaFitRect(video, in: CGRect(x: inset.left, y: inset.top, width: width, height: height))
    }
    @State private var controlsH: CGFloat = VideoApprovalView.lastControlsH

    /// No zoom-out first (owner 2026-10-14, as the photo editor): a zoomed X lifts off the zoomed
    /// rect (`zoomedRect`). The keyboard still goes down first, or the close is refused.
    private func close() {
        guard sourceKey != nil else { dismiss(); return }
        closeFlag.buttonClose = true
        guard captionFocused else { closeToken += 1; return }
        captionFocused = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { closeToken += 1 }
    }
    @State private var closeFlag = ZoomRectProbe()   // only its buttonClose flag is used here

    /// Where the zoomed video is drawn: `scaleEffect` about the rest rect's centre (the view's frame
    /// is centred on it in both layouts), then `offset` by the pan.
    private func zoomedRect(_ rest: CGRect) -> CGRect {
        let z = max(1, zoom)
        let w = rest.width * z, h = rest.height * z
        return CGRect(x: rest.midX - w / 2 + pan.width, y: rest.midY - h / 2 + pan.height, width: w, height: h)
    }

    private var activeURL: URL { clipList[current].url }
    private var activeClipId: UUID { clipList[current].id }

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
    @State private var videoSize: CGSize = .zero   // natural (rotation-corrected) size → tall-video rounding
    @State private var duration: Double = 0
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0
    @State private var thumbnails: [UIImage] = []
    @State private var scrubTime: Double? = nil   // non-nil while dragging a handle → seek preview
    @State private var playhead: Double = 0        // live playback position (seconds) → scrubber line
    @State private var draggingPlayhead = false
    @State private var exporting = false
    @State private var sent = false   // see send()

    private let stripHeight: CGFloat = 40   // 40px trim strip (user request)
    private let handleW: CGFloat = 12
    private let minDuration: Double = 1   // keep at least ~1s

    private var trimmed: Bool { duration > 0 && (trimStart > 0.05 || trimEnd < duration - 0.05) }
    // 9:16 or taller → long-portrait presentation (rounded corners on the video itself).
    private var isTallVideo: Bool { videoSize.width > 0 && videoSize.height >= videoSize.width * (16.0 / 9.0) - 1 }

    var body: some View {
        ZStack {
            // While the still flies, its own black backdrop (under this cover) is the background.
            Color.black.ignoresSafeArea().opacity(arrived ? 1 : 0)
            // Same layout as the image editor: the video aspect-FITS the area BETWEEN the chrome (the
            // top bar + trim strip + caption, reserved by safeAreaInset below) instead of filling the
            // whole screen behind them — fully visible / zoomed-out, letterboxed on black, rounded
            // corners. (Was .ignoresSafeArea() → edge-to-edge full screen.)
            // The white playhead line tracks the player's REAL current time during playback (Bug 1/2 fix):
            // the periodic time observer reports the position every 0.05s and we write it to `playhead`,
            // so the line glides frame-by-frame in sync with the video instead of sitting frozen near the
            // left handle. While the user is dragging a handle/the playhead, `scrubTime` owns the position,
            // so we ignore player time then (no fight between the seek-preview and the observer).
            Group {
                let base = TrimmingPlayerView(url: activeURL, playing: $playing, start: trimStart, end: max(trimStart + 0.1, trimEnd),
                                              scrubTime: scrubTime,
                                              onTime: { t in if scrubTime == nil { playhead = t } })
                    .id(activeClipId)   // switching clips rebuilds the player (the UIView holds its url)
                    // Opened out of a tile: the still that flew in waits UNDER the player, fitted the
                    // same way, so the hand-over never shows black while the first frame decodes.
                    .background {
                        if let poster {
                            Image(uiImage: poster).resizable().scaledToFit()
                        }
                    }
                if !clipReady {
                    posterStandIn   // the file cannot be played yet (see `pendingLoad`)
                } else if isTallVideo {
                    // LONG PORTRAIT (9:16+, user spec): the view takes the video's own fitted rect and the
                    // ROUNDED CORNERS hug the video itself — standard ratios keep the untouched chain.
                    base.aspectRatio(videoSize.width / videoSize.height, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                } else {
                    base
                }
            }
                .scaleEffect(max(1, zoom * pinch))
                .offset(x: pan.width + drag.width, y: pan.height + drag.height)
                .opacity(dismissing || !arrived ? 0 : 1)   // the flying still stands in for it
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
                // SWIPE between clips (user report: the mixed editor pages by swipe, this one only via
                // rail taps). Horizontal-dominant swipe at rest switches clip; disabled while zoomed
                // (the pan owns the drag there) and for single clips.
                .simultaneousGesture(
                    max(1, zoom * pinch) > 1.01 || clipList.count < 2 ? nil : DragGesture(minimumDistance: 30)
                        .onEnded { g in
                            let dx = g.translation.width, dy = g.translation.height
                            guard abs(dx) > abs(dy) * 1.5, abs(dx) > 60 else { return }
                            let next = dx < 0 ? current + 1 : current - 1
                            guard clipList.indices.contains(next) else { return }
                            withAnimation(.easeInOut(duration: 0.2)) { switchTo(next) }
                        }
                )
            if !playing && scrubTime == nil {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 66)).foregroundStyle(.white.opacity(0.85))
                    .allowsHitTesting(false)
                    .opacity(dismissing ? 0 : 1)   // a close hides it at once, as before
                    .animation(.easeInOut(duration: 0.15)) { $0.opacity(chromeOpacity) }
            }
            // Play tapped before the file was playable: it starts the moment the player exists.
            if playing && !clipReady {
                ProgressView().tint(.white).scaleEffect(1.3).allowsHitTesting(false)
            }
            if exporting {
                ZStack { Color.black.opacity(0.4).ignoresSafeArea(); ProgressView().tint(.white).scaleEffect(1.3) }
            }
        }
        // Top bar FLOATS over the video (X · HD) instead of sitting on a black band above it — the
        // video extends up to the top, no black "header". Only the bottom chrome insets the video.
        .overlay(alignment: .top) { topBar.animation(.easeInOut(duration: 0.15)) { $0.opacity(chromeOpacity) } }
        // Thumbnail RAIL (multi-video only): bottom-right of the canvas, above the trim strip — the
        // reference position. Hidden while the caption keyboard is up (the strip area is reclaimed).
        .overlay(alignment: .bottomTrailing) {
            if clipList.count > 1 && !captionFocused { thumbRail }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomControls
                .animation(.easeInOut(duration: 0.15)) { $0.opacity(chromeOpacity) }
                .background(
                    GeometryReader { g in
                        Color.clear
                            .onAppear { if !captionFocused { controlsH = g.size.height; Self.lastControlsH = g.size.height } }
                            .onChange(of: g.size.height) { _, h in if !captionFocused { controlsH = h; Self.lastControlsH = h } }
                    }
                )
        }
        .overlay {
            if let sourceKey, let poster {
                MediaDismissHost(
                    // The X may start zoomed; a drag still needs fit (zoomed, it pans the video).
                    canBegin: { arrived && !captionFocused && !exporting && (zoom <= 1.01 || closeFlag.buttonClose) },
                    media: {
                        let size = videoSize.width > 0 ? videoSize : poster.size
                        guard let r = Self.restRect(size, controlsH: controlsH) else { return nil }
                        return (zoom > 1.01 ? zoomedRect(r) : r, poster)
                    },
                    onHideContent: { hide in
                        dismissing = hide
                        if hide { playing = false }
                    },
                    targetRect: { MediaOpenRects.liveRect(sourceKey) },
                    targetId: { sourceKey },
                    clipRect: { MediaOpenRects.attachClipRect },
                    closeToken: closeToken,
                    onDismiss: {
                        // The copy IS the animation, so the cover goes without its own slide.
                        MediaPresentGate.noteDismissed()
                        withoutPresentationAnimation { dismiss() }
                    },
                    copyFromMediaFrame: true)   // lift off where the video is drawn, above the tools
            }
        }
        .onAppear {
            // One hop, so the fade runs outside the no-animation transaction that presented the cover.
            // A file still arriving (see `pendingLoad`): the player is built when it can be played,
            // and our copy, when made, is what Send uses. Either may already be here.
            if let pendingLoad {
                pendingLoad.onPlayback = { url in
                    guard !clipReady, let first = clipList.first else { return }
                    clipList[0] = ApprovalClip(assetId: first.assetId, url: url, thumb: first.thumb, duration: 0)
                    clipReady = true
                }
                pendingLoad.onFile = { sendFile = $0 }
            }
            if sourceKey != nil, !chromeShown {
                // No withAnimation: it also animated the cover's first layout, sliding the tools up
                // from the bottom (owner 2026-10-14). Only the scoped opacities below animate.
                DispatchQueue.main.async { chromeShown = true }
            }
        }
        .onDisappear { if sourceKey != nil { MediaPresentGate.noteClosed() } }
        // Nothing is tappable until the still has landed.
        .allowsHitTesting(arrived)
        .task(id: activeClipId) { if clipReady { await loadVideoIfNeeded() } }
    }

    /// The tools fade in over 0.15s when opened out of a tile (the reference picker's interface fade).
    private var chromeOpacity: Double { sourceKey == nil || chromeShown ? 1 : 0 }

    // MARK: - Thumbnail rail (multi-video)

    private var thumbRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(clipList.enumerated()), id: \.element.id) { i, clip in
                    railThumb(i, clip)
                }
            }
            .padding(.top, 10)      // room for the X badge poking above the current thumb
            .padding(.trailing, 10)
            .padding(.leading, 4)
        }
        .frame(maxWidth: 252)       // ~4 of the 48px thumbs; more scroll horizontally
        .padding(.trailing, 8)
        .padding(.bottom, 10)
    }

    @ViewBuilder private func railThumb(_ i: Int, _ clip: ApprovalClip) -> some View {
        let isCurrent = i == current
        Button { switchTo(i) } label: {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let t = railImage(clip) {
                        Image(uiImage: t).resizable().scaledToFill()
                    } else {
                        Color.gray.opacity(0.3)
                    }
                }
                .frame(width: 48, height: 48)   // 48px thumbs (user spec 2026-07-14: "make small";
                                                // matches the mixed pager's rail)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                // Duration badge (reference look: small dark capsule, bottom-left).
                Text(railDuration(clip))
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 1.5)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(3)
            }
            .overlay {
                if isCurrent {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color(hex: 0x3DA1FD), lineWidth: 2.5)
                }
            }
            .overlay(alignment: .topTrailing) {
                // X on the CURRENT thumb removes that video from the batch (reference behavior).
                if isCurrent && clipList.count > 1 {
                    Button { removeClip(i) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(.black.opacity(0.72), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: 7, y: -7)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func railImage(_ clip: ApprovalClip) -> UIImage? {
        clip.thumb ?? stash[clip.id]?.thumbnails.first ?? (clip.id == activeClipId ? thumbnails.first : nil)
    }

    private func railDuration(_ clip: ApprovalClip) -> String {
        let d: Double = {
            if clip.id == activeClipId, duration > 0 { return trimEnd - trimStart }
            if let s = stash[clip.id] { return s.trimEnd - s.trimStart }
            return clip.duration
        }()
        let s = Int(max(0, d).rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - Clip switching

    private func stashCurrent() {
        guard duration > 0 else { return }
        stash[activeClipId] = ClipTrim(duration: duration, trimStart: trimStart, trimEnd: trimEnd,
                                       videoSize: videoSize, thumbnails: thumbnails)
    }

    private func switchTo(_ i: Int) {
        guard i != current, clipList.indices.contains(i) else { return }
        stashCurrent()
        playing = false
        scrubTime = nil
        zoom = 1; pan = .zero
        current = i
        restoreOrReset(clipList[i].id)
    }

    private func restoreOrReset(_ id: UUID) {
        if let s = stash[id] {
            duration = s.duration; trimStart = s.trimStart; trimEnd = s.trimEnd
            videoSize = s.videoSize; thumbnails = s.thumbnails
        } else {
            duration = 0; trimStart = 0; trimEnd = 0
            videoSize = .zero; thumbnails = []
        }
        playhead = trimStart
        // duration == 0 → the .task(id:) reload fetches this clip's metadata + filmstrip.
    }

    private func removeClip(_ i: Int) {
        guard clipList.count > 1, clipList.indices.contains(i) else { return }
        if let aid = clipList[i].assetId { onRemove(aid) }
        stash.removeValue(forKey: clipList[i].id)
        clipList.remove(at: i)
        if i == current {
            let next = min(i, clipList.count - 1)
            current = next
            playing = false
            zoom = 1; pan = .zero
            restoreOrReset(clipList[next].id)
        } else if i < current {
            current -= 1
        }
    }

    private var topBar: some View {
        HStack {
            Button { close() } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(.primary)
                    .frame(width: 44, height: 44).liquidGlass(Circle(), interactive: true).contentShape(Circle())
            }
            .buttonStyle(.plain)
            Spacer()
            if trimmed {
                Text(trimLabel).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                    .padding(.horizontal, 12).frame(height: 32).liquidGlass(Capsule(), interactive: false)
            }
            // HD toggle (top-right) — 1080p when on, else 720p (matches the photo editor's HD).
            Button { hd.toggle() } label: {
                Text("HD").font(.system(size: 13, weight: .bold))
                    .foregroundStyle(hd ? Color(hex: 0x3DA1FD) : .primary)
                    .frame(width: 44, height: 44).liquidGlass(Circle(), interactive: true).contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    @ViewBuilder private var bottomControls: some View {
        VStack(spacing: 12) {
            // Trim bar HIDES while the caption keyboard is up (user request; matches the multi pager) —
            // typing needs the space, and trimming while typing isn't a real flow.
            if !captionFocused {
                if !thumbnails.isEmpty && duration > 0 {
                    // Owner 2026-10-14: the trim bar arrives the way the caption bar does, a 0.15s
                    // fade in place. It popped in when its filmstrip finished loading.
                    trimStrip.transition(.opacity)
                } else {
                    // RESERVE the strip's slot while the filmstrip loads: the strip appearing LATE grew
                    // the bottom inset after the first frame, so the video fitted BIG first and re-fitted
                    // smaller a beat later (the "zoom out is coming late" report). The image editor never
                    // did this because its chrome height is known synchronously — now this one is too.
                    Color.clear.frame(height: stripHeight)
                }
            }
            captionBar
        }
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.2), value: captionFocused)
        .animation(.easeInOut(duration: 0.15), value: thumbnails.isEmpty || duration <= 0)
    }

    // THE shared trimmer (VideoTrimStrip) — one implementation for the single editor AND the multi
    // pager, so every trim fix lands everywhere at once.
    private var trimStrip: some View {
        VideoTrimStrip(duration: duration, thumbnails: thumbnails,
                       trimStart: $trimStart, trimEnd: $trimEnd,
                       playhead: $playhead, scrubTime: $scrubTime,
                       playing: $playing, draggingPlayhead: $draggingPlayhead,
                       stripHeight: stripHeight, handleW: handleW, minDuration: minDuration)
            .padding(.horizontal, 20)   // left/right margin so the strip + handles don't touch the edges
    }

    private var captionBar: some View {
        HStack(spacing: 10) {
            TextField("", text: $caption, prompt: Text("Add a caption…").foregroundColor(Color(.systemGray3)),
                      axis: .vertical)
                .lineLimit(1...7)   // multi-line caption, grows up to ~7 lines then scrolls
                .foregroundStyle(.primary).focused($captionFocused)
                .padding(.horizontal, 16).padding(.vertical, 9).frame(minHeight: 40)
                .liquidGlass(RoundedRectangle(cornerRadius: 20, style: .continuous), interactive: true)
            Button { send() } label: {
                Image(systemName: "arrow.up").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40).liquidGlass(Circle(), interactive: true, tint: Theme.defaultBubble(false))   // 40px send (user spec)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain).disabled(exporting || !clipReady)   // nothing to send until the file is playable
        }
        .padding(.horizontal, 16).padding(.top, 4)
    }

    private var trimLabel: String {
        let s = Int((trimEnd - trimStart).rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - Video load / export

    // Per-clip load, driven by .task(id: activeClipId): a clip restored from the stash (duration > 0)
    // skips the work; a fresh clip loads its metadata + filmstrip.
    private func loadVideoIfNeeded() async {
        guard duration <= 0 else { return }
        await loadVideo()
    }

    private func loadVideo() async {
        let asset = AVURLAsset(url: activeURL)
        let dur = (try? await asset.load(.duration).seconds) ?? 0
        guard dur > 0 else { return }
        // Natural (rotation-corrected) size → drives the long-portrait rounded presentation.
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let sz = try? await track.load(.naturalSize),
           let tf = try? await track.load(.preferredTransform) {
            let r = CGRect(origin: .zero, size: sz).applying(tf)
            let natural = CGSize(width: abs(r.width), height: abs(r.height))
            await MainActor.run { videoSize = natural }
        }
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
        // A double tap sent the clip twice (audit, 2026-09-24): an untrimmed send never disables
        // the button, and a trimmed one turns `exporting` off just before handing over, so the
        // button is live again during the dismiss. One send per screen.
        guard !sent else { return }
        sent = true
        let cap = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        // MULTI: export every clip with ITS OWN trim (stashed per clip), deliver the batch in order.
        if let onSendMulti {
            stashCurrent()
            exporting = true
            let clips = clipList
            let cuts = stash
            Task {
                var outs: [URL] = []
                for clip in clips {
                    if let cut = cuts[clip.id], cut.duration > 0,
                       cut.trimStart > 0.05 || cut.trimEnd < cut.duration - 0.05 {
                        outs.append(await exportTrimmed(url: clip.url, start: cut.trimStart, end: cut.trimEnd) ?? clip.url)
                    } else {
                        outs.append(clip.url)
                    }
                }
                await MainActor.run { exporting = false; onSendMulti(outs, cap, hd); if selfDismissOnSend { dismiss() } }
            }
            return
        }
        guard trimmed else { onSend(sendURL, cap, hd); if selfDismissOnSend { dismiss() }; return }
        exporting = true
        Task {
            let out = await exportTrimmed(url: sendURL, start: trimStart, end: trimEnd)
            await MainActor.run { exporting = false; onSend(out ?? sendURL, cap, hd); if selfDismissOnSend { dismiss() } }
        }
    }

    private func exportTrimmed(url: URL, start: Double, end: Double) async -> URL? {
        let asset = AVURLAsset(url: url)
        // Tracks loaded before the export is asked for — the build-695 crash, see the same helper
        // in `MediaApprovalView` for the trace.
        guard let tracks = try? await asset.load(.tracks), !tracks.isEmpty,
              let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality)
        else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                        end: CMTime(seconds: end, preferredTimescale: 600))
        do { try await session.export(to: out, as: .mp4) } catch { return nil }
        return out
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

extension VideoApprovalView {
    /// The poster, laid out as the player will be, while a pending file is not playable yet.
    @ViewBuilder var posterStandIn: some View {
        if let poster {
            let image = Image(uiImage: poster).resizable().scaledToFit()
            if isTall(poster.size) {
                image.clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            } else {
                image
            }
        } else {
            Color.clear
        }
    }
}
