import SwiftUI
import AVFoundation
import UIKit

// A finalized item ready to send, in the user's selection order (mixed photos + videos → ONE group).
enum SendMedia {
    case image(UIImage)
    case video(url: URL, thumb: UIImage, duration: Double)   // final (trimmed) url + poster + duration
}

// One media item awaiting approval — the mixed-selection unit (the approval flow treats images
// and videos as one attachment list).
// THE ID IS THE PHOTO LIBRARY'S OWN ID where there is one (owner 2026-08-04: remove a video in the
// editor, go back, and it was still ticked in the picker). It used to be a fresh UUID minted at the
// handoff, which threw away the only link back to what the picker had selected — so a removal here
// could never reach it. Camera captures, which have no library id, still get a UUID string.
enum ApprovalMedia: Identifiable {
    case image(String, UIImage)
    case video(String, URL, UIImage?, Double)   // id, local url, poster thumb, duration (s)

    var id: String {
        switch self {
        case .image(let id, _): return id
        case .video(let id, _, _, _): return id
        }
    }
    var isVideo: Bool { if case .video = self { return true }; return false }
    var thumb: UIImage? {
        switch self {
        case .image(_, let ui): return ui
        case .video(_, _, let t, _): return t
        }
    }
}

// Mixed-media pre-send approval — replaces the images-only screen. Standard behavior:
//   • ONE selection of images + videos, swipeable zoomable pages in selection order.
//   • Per-item editing: images get crop + pen (the same editors as the single-photo flow);
//     videos get TRIM (filmstrip with drag handles, live-looped preview of the kept range).
//   • Thumbnail rail (videos badged with a duration) — tap to jump, X removes from the batch.
//   • ONE shared caption + HD toggle + one Send for the whole batch.
// On send, trimmed videos are exported to their kept range first; the callback then receives the
// final images + video URLs so the chat can deliver the whole group in one action.
struct MediaApprovalView: View {
    @State var items: [ApprovalMedia]
    /// Removed here → deselect there. The picker stays open behind this screen and keeps its own
    /// selection, so a removal has to be told to it or the tick outlives the item.
    var onRemove: (String) -> Void = { _ in }
    var onSend: (_ ordered: [SendMedia], _ caption: String, _ hd: Bool) -> Void   // ORDERED mixed group
    // false when presented OVER the media sheet: the caller closes the sheet (whole stack, one motion);
    // self-dismissing first flashed the sheet for a beat before it closed.
    var selfDismissOnSend: Bool = true
    @Environment(\.dismiss) private var dismiss

    @State private var page = 0
    @State private var caption = ""
    @State private var hd = false
    @State private var editCrop = false
    @State private var editPen = false
    @State private var exporting = false
    @FocusState private var captionFocused: Bool

    // Per-VIDEO trim state, keyed by item id (each video trims independently).
    @State private var trimStart: [String: Double] = [:]
    @State private var trimEnd: [String: Double] = [:]
    @State private var strips: [String: [UIImage]] = [:]   // filmstrip thumbs
    @State private var scrubTime: Double?                // live seek while dragging a handle
    @State private var playheads: [String: Double] = [:]   // live playback position per video → scrubber
    @State private var videoPlaying: [String: Bool] = [:]  // per-video play state — PAUSED by default (single-editor parity)
    // Pinch-zoom + pan for the CURRENT video page (same mechanism as the single video editor). Resets on
    // page change. Images zoom via ZoomImageView already; this brings video zoom to parity in the pager.
    @State private var vZoom: CGFloat = 1
    @GestureState private var vPinch: CGFloat = 1
    @State private var vPan: CGSize = .zero
    @GestureState private var vDrag: CGSize = .zero
    private var vZoomed: Bool { max(1, vZoom * vPinch) > 1.01 }

    private let stripHeight: CGFloat = 40   // IDENTICAL to the single video editor (shared VideoTrimStrip)
    private let handleW: CGFloat = 12
    private let minDuration: Double = 1

    private var current: ApprovalMedia? { items.indices.contains(page) ? items[page] : nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $page) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    pageView(item, index: i).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            if exporting {
                ZStack { Color.black.opacity(0.45).ignoresSafeArea(); ProgressView().tint(.white).scaleEffect(1.3) }
            }
        }
        // Swipe DOWN on the media closes the keyboard (reads the drag without consuming zoom/pan).
        .simultaneousGesture(
            DragGesture(minimumDistance: 18)
                .onChanged { g in if captionFocused, g.translation.height > 24 { captionFocused = false } }
        )
        // Swiping to another page pauses everything (single-editor parity) and resets the video zoom/pan
        // so each page opens fit (zoomed out), never carrying the previous page's zoom.
        .onChange(of: page) { _, _ in videoPlaying = [:]; vZoom = 1; vPan = .zero }
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomControls }
        // Per-IMAGE editing (the same tools as the single-photo editor), presented INLINE with the SAME
        // 0.28s cross-fade the single editor uses — they were fullScreenCovers (slide-up modals), which
        // made Crop/Pen feel different between single and multi editing.
        .overlay { cropPenOverlays }
    }

    // Inline Crop / Pen overlays (identical transition to ChatImageEditor's own cropOverlay).
    @ViewBuilder private var cropPenOverlays: some View {
        if editCrop, case .image(let id, let ui)? = current {
            ChatCropView(image: ui, inline: true,
                         onClose: { withAnimation(.easeInOut(duration: 0.28)) { editCrop = false } }) { cropped in
                replace(id, with: .image(id, cropped))
            }
            .transition(.opacity)
        }
        if editPen, case .image(let id, let ui)? = current {
            ChatImageEditor(source: ui, editOnly: true, startDrawing: true,
                            onReturn: { edited in replace(id, with: .image(id, edited)) },
                            inline: true,
                            onClose: { withAnimation(.easeInOut(duration: 0.28)) { editPen = false } })
                .transition(.opacity)
        }
    }

    // MARK: - Pages

    // 9:16 or taller → long-portrait presentation (rounded corners on the media itself). Shared by the
    // image AND video pages so both match; standard ratios keep the untouched full-bleed path.
    private func isTall(_ s: CGSize) -> Bool { s.width > 0 && s.height >= s.width * (16.0 / 9.0) - 1 }

    @ViewBuilder private func pageView(_ item: ApprovalMedia, index: Int) -> some View {
        switch item {
        case .image(_, let ui):
            // IDENTICAL frame system to the SINGLE image editor: one full-screen ZoomImageView with
            // screen-centered pinch zoom; tall (9:16+) images get rounded corners on the image itself via
            // cornerRadius. Normal ratios: cornerRadius 0 → unchanged full-screen.
            ZoomImageView(image: ui, onSingleTap: { captionFocused = false },
                          cornerRadius: isTall(ui.size) ? 22 : 0)
                .ignoresSafeArea()
        case .video(let id, let url, let thumb, let duration):
            // EXACT single-video-editor behavior: starts PAUSED with the big Play button, tap toggles,
            // pauses while trimming/scrubbing, playhead tracks real time. Tall (9:16+) videos fit with
            // rounded corners on the video (same aspectRatio(.fit) + clipShape as everything else — the
            // poster thumb carries the video's aspect); standard ratios stay full-bleed.
            let player = PagedTrimPlayer(url: url,
                            playing: page == index && !exporting && scrubTime == nil && (videoPlaying[id] ?? false),
                            start: trimStart[id] ?? 0,
                            end: max((trimStart[id] ?? 0) + 0.1, trimEnd[id] ?? duration),
                            scrubTime: page == index ? scrubTime : nil,
                            onTime: { t in if page == index, scrubTime == nil { playheads[id] = t } })
            Group {
                if let t = thumb, isTall(t.size) {
                    player.aspectRatio(t.size.width / t.size.height, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    player.ignoresSafeArea()
                }
            }
            // Pinch-zoom + pan for THIS video, only while it's the current page — the SAME mechanism as
            // the single video editor. When zoomed in, a high-priority drag pans (so it beats the TabView
            // paging); at fit, horizontal swipes page normally.
            .scaleEffect(page == index ? max(1, vZoom * vPinch) : 1)
            .offset(x: page == index ? vPan.width + vDrag.width : 0,
                    y: page == index ? vPan.height + vDrag.height : 0)
            .gesture(
                MagnificationGesture()
                    .updating($vPinch) { v, s, _ in s = v }
                    .onEnded { v in vZoom = min(4, max(1, vZoom * v)); if vZoom <= 1 { vPan = .zero } }
            )
            .highPriorityGesture(
                vZoomed ? DragGesture().updating($vDrag) { v, s, _ in s = v.translation }
                    .onEnded { v in vPan.width += v.translation.width; vPan.height += v.translation.height } : nil
            )
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                withAnimation(.easeInOut(duration: 0.2)) { vZoom = vZoom > 1 ? 1 : 2; if vZoom <= 1 { vPan = .zero } }
            }
            .onTapGesture {
                if captionFocused { captionFocused = false }
                else { videoPlaying[id] = !(videoPlaying[id] ?? false) }
            }
            .overlay {
                if !(videoPlaying[id] ?? false) && scrubTime == nil && !vZoomed {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 66)).foregroundStyle(.white.opacity(0.85))
                        .allowsHitTesting(false)
                }
            }
            .task(id: id) { await loadVideoMeta(id: id, url: url, duration: duration) }
        }
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .liquidGlass(Circle(), interactive: true)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func toolButton(_ icon: String, active: Bool = false, label: String? = nil, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let label { Text(label).font(.system(size: 13, weight: .bold)) }
                else { Image(systemName: icon).font(.system(size: 16, weight: .medium)) }
            }
            .foregroundStyle(active ? Color(hex: 0x3DA1FD) : .primary)
            .frame(width: 40, height: 40)   // 40px tools (user spec, was 44)
            .liquidGlass(Circle(), interactive: true)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // Trim strip (video pages) + adaptive tool row + rail + caption + send.
    private var bottomControls: some View {
        VStack(spacing: 12) {
            if !captionFocused {
                // Video page → its trim filmstrip sits directly above the tools.
                if case .video(let id, _, _, let duration)? = current, let thumbs = strips[id], duration > 0 {
                    trimStrip(id: id, duration: duration, thumbs: thumbs)
                        .padding(.horizontal, 20)   // IDENTICAL margin to the single editor's strip
                }
                HStack(spacing: 10) {
                    // Image tools only make sense on an image page; HD applies to the whole batch.
                    if current?.isVideo == false {
                        // Same 0.28s cross-fade IN as the single editor's crop/pen (not a modal slide).
                        toolButton("crop") { withAnimation(.easeInOut(duration: 0.28)) { editCrop = true } }
                        toolButton("scribble") { withAnimation(.easeInOut(duration: 0.28)) { editPen = true } }
                    }
                    toolButton("", active: hd, label: "HD") { hd.toggle() }
                    rail
                }
                .padding(.horizontal, 16)
            }
            HStack(spacing: 10) {
                // Multi-line caption: grows from 1 up to ~7 lines, then scrolls.
                TextField("", text: $caption,
                          prompt: Text("Add a caption…").foregroundColor(Color(.systemGray3)),
                          axis: .vertical)
                    .lineLimit(1...7)
                    .foregroundStyle(.primary).focused($captionFocused)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .frame(minHeight: 40)
                    .liquidGlass(RoundedRectangle(cornerRadius: 20, style: .continuous), interactive: true)
                Button { send() } label: {
                    Image(systemName: "arrow.up").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 40, height: 40)   // 40px send (user spec)
                        .background(Color(hex: 0x3DA1FD), in: Circle())
                }
                .buttonStyle(StoryPressStyle())
                .disabled(exporting)
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 8)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.2), value: captionFocused)
        .animation(.easeInOut(duration: 0.2), value: page)
    }

    // Ordered thumbnail rail: mixed types, current ring-highlighted, video thumbs duration-badged.
    // RIGHT-ALIGNED (modern messengers): a short rail hugs the trailing edge next to the tools, and the
    // current page's thumb is auto-scrolled into view — the RTL container + re-flipped tiles trick pins
    // the content right even when it doesn't fill the width; item order stays first→last, left→right.
    private var rail: some View {
        ScrollViewReader { proxy in
            railScroll
                .onChange(of: page) { _, p in
                    guard items.indices.contains(p) else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(items[p].id, anchor: .center) }
                }
                // INITIAL position too: the rail opens scrolled to its END (trailing alignment), so when
                // the active page is early in the batch its highlighted thumb sat off-screen left — the
                // "I can't see the active one" report. Center it on appear, no animation.
                .onAppear {
                    guard items.indices.contains(page) else { return }
                    proxy.scrollTo(items[page].id, anchor: .center)
                }
        }
    }

    private var railScroll: some View {
        // GeometryReader gives the rail's visible width; the content fills AT LEAST that width aligned
        // TRAILING, so a short rail sits at the RIGHT edge (user request — the RTL trick didn't hold).
        // Order stays first→last, left→right; overflow starts scrolled to the end (newest visible).
        GeometryReader { geo in
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    ZStack(alignment: .topTrailing) {
                        ZStack(alignment: .bottomLeading) {
                            Group {
                                if let t = item.thumb {
                                    Image(uiImage: t).resizable().scaledToFill()
                                } else {
                                    Rectangle().fill(.gray.opacity(0.3))
                                        .overlay { Image(systemName: "video.fill").font(.system(size: 14)).foregroundStyle(.white) }
                                }
                            }
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            if case .video(_, _, _, let d) = item {
                                Text(fmt(d)).font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                    .padding(.horizontal, 4).padding(.vertical, 1.5)
                                    .background(.black.opacity(0.55), in: Capsule())
                                    .padding(3)
                            }
                        }
                        .overlay {
                            if i == page {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Color(hex: 0x3DA1FD), lineWidth: 2.5)
                            }
                        }
                        .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { page = i } }
                        if i == page {
                            Button { remove(i) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 16))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.7))
                            }
                            .offset(x: 6, y: -6)
                        }
                    }
                    .id(item.id)                                      // scroll-to target (current page)
                }
            }
            .padding(.top, 6)
            .frame(minWidth: geo.size.width, alignment: .trailing)   // short rail hugs the RIGHT edge
        }
        .defaultScrollAnchor(.trailing)
        }
        .frame(height: 60)
    }

    // MARK: - Video trim (per item)

    // THE shared trimmer (VideoTrimStrip) — the SAME implementation as the single video editor, fed the
    // pager's per-item state via bindings. Every trim behavior/fix lives once in VideoTrimStrip and works
    // identically here: no auto-play on drag, playhead clamped inside the yellow frame, 32pt grab area.
    private func trimStrip(id: String, duration: Double, thumbs: [UIImage]) -> some View {
        let dur = max(0.01, duration)
        return VideoTrimStrip(
            duration: dur, thumbnails: thumbs,
            trimStart: Binding(get: { trimStart[id] ?? 0 }, set: { trimStart[id] = $0 }),
            trimEnd: Binding(get: { trimEnd[id] ?? dur }, set: { trimEnd[id] = $0 }),
            playhead: Binding(get: { playheads[id] ?? (trimStart[id] ?? 0) }, set: { playheads[id] = $0 }),
            scrubTime: $scrubTime,
            // Real play state (single-editor parity): the strip pauses the video on any drag, and it
            // STAYS paused until the user taps Play — exactly like the single editor.
            playing: Binding(get: { videoPlaying[id] ?? false }, set: { videoPlaying[id] = $0 }),
            draggingPlayhead: .constant(false),
            stripHeight: stripHeight, handleW: handleW, minDuration: minDuration)
    }

    private func loadVideoMeta(id: String, url: URL, duration: Double) async {
        guard strips[id] == nil else { return }
        if trimEnd[id] == nil { await MainActor.run { trimEnd[id] = duration } }
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .positiveInfinity
        gen.maximumSize = CGSize(width: 120, height: 120)
        let count = 8
        var imgs: [UIImage] = []
        for i in 0..<count {
            let t = CMTime(seconds: duration * Double(i) / Double(count - 1), preferredTimescale: 600)
            if let cg = try? await gen.image(at: t).image { imgs.append(UIImage(cgImage: cg)) }
        }
        await MainActor.run { strips[id] = imgs }
    }

    private func trimmed(_ id: String, duration: Double) -> Bool {
        (trimStart[id] ?? 0) > 0.05 || (trimEnd[id] ?? duration) < duration - 0.05
    }

    // MARK: - Mutations + send

    private func replace(_ id: String, with item: ApprovalMedia) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i] = item }
    }

    private func remove(_ i: Int) {
        guard items.indices.contains(i) else { return }
        // Tell the picker BEFORE dropping it: it keeps its own selection, and without this the tick
        // stayed on something the user had just removed.
        onRemove(items[i].id)
        items.remove(at: i)
        if items.isEmpty { dismiss(); return }
        if page >= items.count { page = items.count - 1 }
    }

    private func send() {
        let cap = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        // PHOTOS ONLY → there is NO export work to do, so don't show the exporting overlay and don't
        // hop through a Task. Doing both flashed a full-screen dimmer + spinner on a send that only
        // had to hand the images over; the chat adds the optimistic album bubble itself, so the send
        // is instant. Only a video (trim export / first-frame extraction) actually needs to wait.
        let photosOnly = items.allSatisfy { if case .image = $0 { return true } else { return false } }
        if photosOnly {
            let ordered: [SendMedia] = items.compactMap {
                if case .image(_, let ui) = $0 { return .image(ui) } else { return nil }
            }
            onSend(ordered, cap, hd)
            if selfDismissOnSend { dismiss() }
            return
        }
        exporting = true
        Task {
            // Build the ORDERED mixed list (selection order preserved) so the chat can deliver photos
            // AND videos as ONE group.
            var ordered: [SendMedia] = []
            for item in items {
                switch item {
                case .image(_, let ui):
                    ordered.append(.image(ui))
                case .video(let id, let url, let poster, let duration):
                    let finalURL: URL
                    var finalDuration = duration
                    let didTrim = trimmed(id, duration: duration)
                    if didTrim,
                       let out = await Self.exportTrimmed(url: url, start: trimStart[id] ?? 0, end: trimEnd[id] ?? duration) {
                        finalURL = out
                        // The exported clip is only the KEPT range — its duration is trimEnd-trimStart,
                        // NOT the original length (using the original miscalibrated the player scrubber).
                        finalDuration = max(0.1, (trimEnd[id] ?? duration) - (trimStart[id] ?? 0))
                    } else {
                        finalURL = url
                    }
                    // A poster for the grid: the TRIMMED clip's first frame when trimmed (its real start
                    // frame, not the original 0:00), else the loaded thumb.
                    var thumb = poster
                    if didTrim { thumb = await Self.firstFrame(finalURL) ?? poster }
                    if thumb == nil { thumb = await Self.firstFrame(finalURL) }
                    ordered.append(.video(url: finalURL, thumb: thumb ?? UIImage(), duration: finalDuration))
                }
            }
            await MainActor.run {
                exporting = false
                onSend(ordered, cap, hd)
                if selfDismissOnSend { dismiss() }
            }
        }
    }

    private static func firstFrame(_ url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 640)
        return (try? await gen.image(at: .zero).image).map { UIImage(cgImage: $0) }
    }

    private static func exportTrimmed(url: URL, start: Double, end: Double) async -> URL? {
        let asset = AVURLAsset(url: url)
        // ⛔ THE TRACKS ARE LOADED BEFORE THE SESSION IS ASKED TO EXPORT. Crash on build 695, iOS 27
        // beta, 2026-08-26 22:36: SIGSEGV at address 0 on a background task inside
        // `exportAsynchronously` → `IsExportPresetCompatibleWithAssetAndOutputFileType` →
        // `CFArrayGetCount`. The old call had the session load an unloaded asset's tracks itself,
        // and a clip it cannot read came back as no array at all. Loading here turns that into a
        // nil return (the caller then sends the untrimmed original), and `export(to:as:)` is the
        // API every other export in the app already uses.
        guard let tracks = try? await asset.load(.tracks), !tracks.isEmpty,
              let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality)
        else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                        end: CMTime(seconds: end, preferredTimescale: 600))
        do { try await session.export(to: out, as: .mp4) } catch { return nil }
        return out
    }

    private func fmt(_ s: Double) -> String {
        let t = Int(s.rounded()); return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// AVPlayer page for the approval pager — loops within [start, end], seeks while a trim handle drags,
// and plays only while its page is front-most. Reuses TrimPlayerUIView (the single-video editor's player).
private struct PagedTrimPlayer: UIViewRepresentable {
    let url: URL
    var playing: Bool
    var start: Double
    var end: Double
    var scrubTime: Double?
    var onTime: ((Double) -> Void)? = nil

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
