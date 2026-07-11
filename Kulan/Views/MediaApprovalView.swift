import SwiftUI
import AVFoundation
import UIKit

// One media item awaiting approval — the mixed-selection unit (Signal's approval flow treats images
// and videos as one attachment list; so do we).
enum ApprovalMedia: Identifiable {
    case image(UUID, UIImage)
    case video(UUID, URL, UIImage?, Double)   // id, local url, poster thumb, duration (s)

    var id: UUID {
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

// Mixed-media pre-send approval — replaces the images-only screen. Signal/WhatsApp behavior:
//   • ONE selection of images + videos, swipeable zoomable pages in selection order.
//   • Per-item editing: images get crop + pen (the same editors as the single-photo flow);
//     videos get TRIM (filmstrip with drag handles, live-looped preview of the kept range).
//   • Thumbnail rail (videos badged with a duration) — tap to jump, X removes from the batch.
//   • ONE shared caption + HD toggle + one Send for the whole batch.
// On send, trimmed videos are exported to their kept range first; the callback then receives the
// final images + video URLs so the chat can deliver the whole group in one action.
struct MediaApprovalView: View {
    @State var items: [ApprovalMedia]
    var onSend: (_ images: [UIImage], _ videos: [URL], _ caption: String, _ hd: Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var page = 0
    @State private var caption = ""
    @State private var hd = false
    @State private var editCrop = false
    @State private var editPen = false
    @State private var exporting = false
    @FocusState private var captionFocused: Bool

    // Per-VIDEO trim state, keyed by item id (each video trims independently).
    @State private var trimStart: [UUID: Double] = [:]
    @State private var trimEnd: [UUID: Double] = [:]
    @State private var strips: [UUID: [UIImage]] = [:]   // filmstrip thumbs
    @State private var scrubTime: Double?                // live seek while dragging a handle
    @State private var playheads: [UUID: Double] = [:]   // live playback position per video → scrubber

    private let stripHeight: CGFloat = 44
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
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomControls }
        // Per-IMAGE editing (same tools as the single-photo editor); edits replace the page in place.
        .fullScreenCover(isPresented: $editCrop) {
            if case .image(let id, let ui)? = current {
                ChatCropView(image: ui) { cropped in replace(id, with: .image(id, cropped)) }
            }
        }
        .fullScreenCover(isPresented: $editPen) {
            if case .image(let id, let ui)? = current {
                ChatImageEditor(source: ui, editOnly: true, startDrawing: true,
                                onReturn: { edited in replace(id, with: .image(id, edited)) })
            }
        }
    }

    // MARK: - Pages

    @ViewBuilder private func pageView(_ item: ApprovalMedia, index: Int) -> some View {
        switch item {
        case .image(_, let ui):
            ZoomImageView(image: ui, onSingleTap: { captionFocused = false },
                          onDim: { _ in }, onDismiss: {}, allowsDismissPan: false)
                .ignoresSafeArea()
        case .video(let id, let url, _, let duration):
            // Loops within the trimmed range; plays only while ITS page is showing.
            PagedTrimPlayer(url: url,
                            playing: page == index && !exporting,
                            start: trimStart[id] ?? 0,
                            end: max((trimStart[id] ?? 0) + 0.1, trimEnd[id] ?? duration),
                            scrubTime: page == index ? scrubTime : nil,
                            onTime: { t in if scrubTime == nil { playheads[id] = t } })
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { captionFocused = false }
                .task(id: id) { await loadVideoMeta(id: id, url: url, duration: duration) }
        }
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
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
                else { Image(systemName: icon).font(.system(size: 17, weight: .medium)) }
            }
            .foregroundStyle(active ? Color(hex: 0x3DA1FD) : .white)
            .frame(width: 44, height: 44)
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
                        .padding(.horizontal, 16)
                }
                HStack(spacing: 10) {
                    // Image tools only make sense on an image page; HD applies to the whole batch.
                    if current?.isVideo == false {
                        toolButton("crop") { editCrop = true }
                        toolButton("scribble") { editPen = true }
                    }
                    toolButton("", active: hd, label: "HD") { hd.toggle() }
                    rail
                }
                .padding(.horizontal, 16)
            }
            HStack(spacing: 10) {
                // Multi-line caption (Signal): grows from 1 up to ~7 lines, then scrolls.
                TextField("", text: $caption,
                          prompt: Text("Add a caption…").foregroundColor(Color(.systemGray3)),
                          axis: .vertical)
                    .lineLimit(1...7)
                    .foregroundStyle(.white).focused($captionFocused)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .frame(minHeight: 46)
                    .liquidGlass(RoundedRectangle(cornerRadius: 23, style: .continuous), interactive: true)
                Button { send() } label: {
                    Image(systemName: "arrow.up").font(.system(size: 19, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 46, height: 46)
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
    private var rail: some View {
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
                }
            }
            .padding(.top, 6)
        }
        .defaultScrollAnchor(.trailing)
        .frame(height: 60)
    }

    // MARK: - Video trim (per item)

    private func trimStrip(id: UUID, duration: Double, thumbs: [UIImage]) -> some View {
        GeometryReader { geo in
            let W = geo.size.width
            let dur = max(0.01, duration)
            let s = trimStart[id] ?? 0
            let e = trimEnd[id] ?? dur
            let startX = CGFloat(s / dur) * W
            let endX = CGFloat(e / dur) * W
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(thumbs.indices, id: \.self) { i in
                        Image(uiImage: thumbs[i]).resizable().scaledToFill()
                            .frame(width: W / CGFloat(thumbs.count), height: stripHeight).clipped()
                    }
                }
                .frame(width: W, height: stripHeight).clipShape(RoundedRectangle(cornerRadius: 8))
                Rectangle().fill(.black.opacity(0.55)).frame(width: startX, height: stripHeight)
                Rectangle().fill(.black.opacity(0.55)).frame(width: max(0, W - endX), height: stripHeight).offset(x: endX)
                RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.yellow, lineWidth: 3)
                    .frame(width: max(0, endX - startX), height: stripHeight).offset(x: startX)
                // Playhead scrubber (tracks playback, draggable to scrub) within the trimmed range.
                let e = trimEnd[id] ?? dur
                let ph = min(max(playheads[id] ?? s, s), e)
                let phX = CGFloat(ph / dur) * W
                if e > s {
                    Capsule().fill(.white)
                        .frame(width: 3, height: stripHeight + 8)
                        .shadow(color: .black.opacity(0.4), radius: 1.5)
                        .offset(x: min(max(0, phX - 1.5), W - 3))
                        .gesture(playheadDrag(id: id, duration: dur, width: W))
                }
                trimHandle.offset(x: max(0, startX - handleW / 2))
                    .gesture(handleDrag(id: id, duration: dur, isStart: true, width: W))
                trimHandle.offset(x: min(W - handleW, endX - handleW / 2))
                    .gesture(handleDrag(id: id, duration: dur, isStart: false, width: W))
            }
        }
        .frame(height: stripHeight)
    }

    // Fully-rounded yellow grip (premium/native look).
    private var trimHandle: some View {
        RoundedRectangle(cornerRadius: handleW / 2, style: .continuous).fill(Color.yellow)
            .frame(width: handleW, height: stripHeight)
            .overlay(Capsule().fill(.black.opacity(0.55)).frame(width: 2.5, height: 16))
    }

    private func playheadDrag(id: UUID, duration: Double, width W: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                let t = Double(min(max(0, g.location.x), W) / W) * duration
                let s = trimStart[id] ?? 0, e = trimEnd[id] ?? duration
                playheads[id] = min(max(t, s), e)
                scrubTime = playheads[id]
            }
            .onEnded { _ in scrubTime = nil }
    }

    private func handleDrag(id: UUID, duration: Double, isStart: Bool, width W: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                let t = Double(min(max(0, g.location.x), W) / W) * duration
                if isStart {
                    trimStart[id] = min(t, (trimEnd[id] ?? duration) - minDuration)
                    scrubTime = trimStart[id]
                } else {
                    trimEnd[id] = max(t, (trimStart[id] ?? 0) + minDuration)
                    scrubTime = trimEnd[id]
                }
            }
            .onEnded { _ in scrubTime = nil }
    }

    private func loadVideoMeta(id: UUID, url: URL, duration: Double) async {
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

    private func trimmed(_ id: UUID, duration: Double) -> Bool {
        (trimStart[id] ?? 0) > 0.05 || (trimEnd[id] ?? duration) < duration - 0.05
    }

    // MARK: - Mutations + send

    private func replace(_ id: UUID, with item: ApprovalMedia) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i] = item }
    }

    private func remove(_ i: Int) {
        guard items.indices.contains(i) else { return }
        items.remove(at: i)
        if items.isEmpty { dismiss(); return }
        if page >= items.count { page = items.count - 1 }
    }

    private func send() {
        let cap = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        exporting = true
        Task {
            var images: [UIImage] = []
            var videos: [URL] = []
            for item in items {
                switch item {
                case .image(_, let ui):
                    images.append(ui)
                case .video(let id, let url, _, let duration):
                    if trimmed(id, duration: duration),
                       let out = await Self.exportTrimmed(url: url,
                                                          start: trimStart[id] ?? 0,
                                                          end: trimEnd[id] ?? duration) {
                        videos.append(out)   // trimmed copy
                    } else {
                        videos.append(url)   // untrimmed (or export failed → send original)
                    }
                }
            }
            await MainActor.run {
                exporting = false
                onSend(images, videos, cap, hd)
                dismiss()
            }
        }
    }

    private static func exportTrimmed(url: URL, start: Double, end: Double) async -> URL? {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        session.outputURL = out
        session.outputFileType = .mp4
        session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                        end: CMTime(seconds: end, preferredTimescale: 600))
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }
        return session.status == .completed ? out : nil
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
