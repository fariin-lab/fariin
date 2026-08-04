import SwiftUI
import AVFoundation
import AVKit
import PhotosUI
import PencilKit

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
    @State private var pendingExtras: [StoryExtra] = []
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

    // MARK: - More than one clip

    /// One video in this post. The edits are held BESIDE the clip rather than burnt into it, exactly
    /// as the photo editor holds them, so switching away and back returns you to what you had and it
    /// is all still adjustable. They are applied once, at export — see `VideoTranscoder.burnIn`.
    struct Clip: Identifiable {
        let id = UUID()
        let url: URL
        var duration: Double = 0
        var poster: UIImage? = nil
        var posterData: Data? = nil
        var trimStart: Double = 0
        var trimEnd: Double = 0
        var muted = false
        var drawing = PKDrawing()
        var overlays: [TextOverlay] = []
        var cropRect: CGRect? = nil
    }

    @State private var clips: [Clip] = []
    @State private var index = 0

    // The live tool state for the clip on screen. Parked onto its Clip when you switch away.
    @State private var drawing = PKDrawing()
    @State private var overlays: [TextOverlay] = []
    @State private var cropRect: CGRect? = nil
    @State private var selectedID: UUID?
    @State private var editingID: UUID?
    @State private var isDrawing = false
    @State private var strokeInFlight = false
    @State private var penHue: Double = 0
    @State private var penWidth: CGFloat = 8
    @State private var isHighlighter = false
    @State private var showCrop = false
    @State private var showAddPicker = false
    @State private var addPick: [PhotosPickerItem] = []
    @State private var canvasSize: CGSize = .zero

    private var currentURL: URL { clips.indices.contains(index) ? clips[index].url : url }

    /// Park the live tools back onto the clip they belong to.
    @MainActor private func stashCurrent() {
        guard clips.indices.contains(index) else { return }
        clips[index].drawing = drawing
        clips[index].overlays = overlays
        clips[index].cropRect = cropRect
        clips[index].trimStart = trimStart
        clips[index].trimEnd = trimEnd
        clips[index].muted = muted
    }

    /// The mirror image: put a clip's edits back on the tools, and put the clip on the player.
    @MainActor private func restoreCurrent() {
        guard clips.indices.contains(index) else { return }
        let c = clips[index]
        drawing = c.drawing
        overlays = c.overlays
        cropRect = c.cropRect
        trimStart = c.trimStart
        trimEnd = c.trimEnd
        muted = c.muted
        duration = c.duration
        thumbnail = c.poster
        thumbnailData = c.posterData
        selectedID = nil; editingID = nil; isDrawing = false
        player.isMuted = muted
        // BOTH LINES MATTER. Dropping the looper stops it re-queueing, but the items it has ALREADY
        // queued are sitting in the player and would keep the previous clip playing over the new
        // one — so the queue is emptied before the new looper is allowed to fill it.
        looper = nil
        player.removeAllItems()
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: c.url))
        playing = true
        player.play()
    }

    private func select(_ i: Int) {
        guard i != index, clips.indices.contains(i) else { return }
        stashCurrent()
        index = i
        restoreCurrent()
    }

    private func remove(_ i: Int) {
        guard clips.count > 1, clips.indices.contains(i) else { return }
        clips.remove(at: i)
        if index >= clips.count { index = clips.count - 1 }
        else if i < index { index -= 1 }
        restoreCurrent()
    }

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
                canvas(geo: geo, cardTop: cardTop, cardH: cardH)

                // Top controls: X (left), trim notice + mute (right). ALL OF IT HIDES WHILE THE PEN
                // IS DOWN and comes back when the finger lifts — his instruction on the photo editor,
                // and the same rule has to hold here or the two screens behave differently.
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
                .opacity(strokeInFlight ? 0 : 1)

                // Bottom bar — caption + NEXT, lifted manually above the keyboard (photo-editor math).
                VStack {
                    Spacer()
                    if isDrawing { penBar } else { bottomBar }
                        .padding(.bottom, keyboard.height > 0
                            ? max(8, geo.frame(in: .global).maxY - (UIScreen.main.bounds.height - keyboard.height) - 2)
                            : -14)
                }
                .opacity(strokeInFlight ? 0 : 1)

                cropOverlay
            }
            .coordinateSpace(name: "canvas")
            .onAppear { canvasSize = geo.size }
            .onChange(of: geo.size) { _, sz in canvasSize = sz }
            .overlay {
                if let id = editingID, let idx = overlays.firstIndex(where: { $0.id == id }) {
                    TextEditorOverlay(draft: $overlays[idx],
                                      onCancel: { trimEmpty(id); editingID = nil },
                                      onDone: { trimEmpty(id); editingID = nil })
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
                            extras: pendingExtras,
                            onPosted: { onPosted(); dismiss() })
        }
        .fullScreenCover(isPresented: $showTrim) {
            // ONE TRIM SCREEN FOR THE WHOLE POST (owner: "trimming multiple videos from a single trim
            // screen"). The strip travels with it, so switching clips happens inside trim rather than
            // by backing out to the editor and coming in again for each one.
            StoryTrimView(url: currentURL, duration: duration,
                          trimStart: $trimStart, trimEnd: $trimEnd,
                          clips: clips.map { StoryTrimView.Peer(id: $0.id, poster: $0.poster) },
                          currentIndex: index,
                          onSelect: { i in stashCurrent(); index = i; restoreCurrent() },
                          onClose: { showTrim = false; stashCurrent() })
        }
        // + adds more clips. Videos only: this is the video editor, and a picture dropped in here
        // would have nothing to play it.
        .photosPicker(isPresented: $showAddPicker, selection: $addPick,
                      maxSelectionCount: 10, matching: .videos)
        .onChange(of: addPick) { _, picks in
            guard !picks.isEmpty else { return }
            Task {
                for pick in picks {
                    guard let movie = try? await pick.loadTransferable(type: PickedMovie.self) else { continue }
                    var c = Clip(url: movie.url)
                    let asset = AVURLAsset(url: movie.url)
                    c.duration = (try? await asset.load(.duration))?.seconds ?? 0
                    c.trimEnd = c.duration
                    let gen = AVAssetImageGenerator(asset: asset)
                    gen.appliesPreferredTrackTransform = true
                    gen.maximumSize = CGSize(width: 1600, height: 1600)
                    if let cg = try? await gen.image(at: CMTime(seconds: min(0.1, c.duration / 2), preferredTimescale: 600)).image {
                        let img = UIImage(cgImage: cg)
                        c.poster = img
                        c.posterData = img.jpegData(compressionQuality: 0.72)
                    }
                    await MainActor.run { clips.append(c) }
                }
                await MainActor.run {
                    addPick = []
                    stashCurrent()
                    index = max(0, clips.count - 1)
                    restoreCurrent()
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
        .onDisappear { player.pause() }
    }

    /// THE CANVAS: the wash, the looping clip, the text, the pen and the play mark.
    ///
    /// Lifted out of `body` because the type-checker gave up on it — "unable to type-check this
    /// expression in reasonable time" is what a SwiftUI ZStack says when it has grown one branch too
    /// many, and the cure is to name a piece of it rather than to simplify what it draws.
    @ViewBuilder private func canvas(geo: GeometryProxy, cardTop: CGFloat, cardH: CGFloat) -> some View {
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

            // WHAT HE DREW, over the video. The same overlay views and the same transforms
            // the photo editor uses, so text placed on a clip sits where text placed on a
            // picture sits, and `videoBurnIn` re-renders this exact arrangement at export.
            ForEach($overlays) { $o in
                TextOverlayView(
                    overlay: $o,
                    isSelected: selectedID == o.id,
                    canvasSize: canvasSize,
                    interactive: !isDrawing && editingID == nil,
                    onTap: { selectedID = o.id; editingID = o.id },
                    onDragChange: { _ in },
                    onDragEnd: { _ in },
                    onSnap: { _, _ in }
                )
                .opacity(editingID == o.id ? 0 : 1)
            }

            if isDrawing {
                DrawingCanvas(drawing: $drawing, isActive: true,
                              penColor: penHue == 0 ? .white : UIColor(hue: penHue, saturation: 1, brightness: 1, alpha: 1),
                              showsToolPicker: false,
                              inkType: isHighlighter ? .marker : .pen,
                              penWidth: penWidth,
                              onStroke: { live in
                                  withAnimation(.easeInOut(duration: 0.15)) { strokeInFlight = live }
                              })
                    .frame(width: geo.size.width, height: cardH)
                    .position(x: geo.size.width / 2, y: cardTop + cardH / 2)
            } else if !drawing.bounds.isEmpty {
                Image(uiImage: drawing.image(from: CGRect(origin: .zero, size: geo.size), scale: UIScreen.main.scale))
                    .resizable()
                    .frame(width: geo.size.width, height: cardH)
                    .position(x: geo.size.width / 2, y: cardTop + cardH / 2)
                    .allowsHitTesting(false)
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
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {
            if !captionFocused { clipStrip }
            HStack(alignment: .bottom, spacing: 10) {
                HStack(spacing: 10) {
                    addMoreButton
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
                    // THE SAME FIVE TOOLS THE PHOTO EDITOR HAS, plus trim, which only a video has.
                    // Aa, crop and pen were photo-only because a video had nowhere to put them; they
                    // are burned into the frames at export now, so there is no longer a reason for
                    // this screen to offer less than that one.
                    HStack(spacing: 20) {
                        tool("textformat") { addTextOverlay() }
                        tool("crop", active: cropRect != nil) {
                            player.pause(); playing = false
                            withAnimation(.easeInOut(duration: 0.28)) { showCrop = true }
                        }
                        tool(isDrawing ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle",
                             active: isDrawing) { isDrawing.toggle() }
                        tool("scissors", active: isTrimmed) {
                            player.pause(); playing = false; showTrim = true
                        }
                        tool("plus.square.on.square") { showAddPicker = true }
                    }
                    .padding(.horizontal, 18).frame(height: 46)
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

    /// One tool in the capsule. Same box, same ink, same press feel as the photo editor's.
    private func tool(_ name: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(active ? .green : .white)
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(StoryPressStyle())
    }

    /// The clips in this post, above the caption bar, exactly as the photo editor draws them: the one
    /// on screen has a blue frame and an X, the others are plain and switch to when tapped.
    ///
    /// Only when there is more than one. A single thumbnail of the clip already filling the screen is
    /// a picture of what you are looking at.
    @ViewBuilder private var clipStrip: some View {
        if clips.count > 1 {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                ForEach(Array(clips.enumerated()), id: \.element.id) { i, c in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let poster = c.poster {
                                Image(uiImage: poster).resizable().scaledToFill()
                            } else {
                                Color(white: 0.15)
                            }
                        }
                        .frame(width: 48, height: 62)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(i == index ? Color.accentColor : .white.opacity(0.35),
                                              lineWidth: i == index ? 2 : 1)
                        }
                        .onTapGesture { select(i) }

                        if i == index {
                            Button { remove(i) } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.black)
                                    .frame(width: 18, height: 18)
                                    .background(.white, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .offset(x: 6, y: -6)
                        }
                    }
                }
            }
            .padding(.trailing, 2)
        }
    }

    /// Add another clip. The same button in the same place as the photo editor's, because reaching
    /// for it and finding nothing there is the kind of difference nobody forgives between two screens
    /// that are supposed to be the same screen.
    private var addMoreButton: some View {
        Button { showAddPicker = true } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(StoryPressStyle())
    }

    private func addTextOverlay() {
        captionFocused = false
        let o = TextOverlay(center: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2))
        overlays.append(o)
        selectedID = o.id
        editingID = o.id
    }

    private func trimEmpty(_ id: UUID) {
        if let idx = overlays.firstIndex(where: { $0.id == id }),
           overlays[idx].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            overlays.remove(at: idx); selectedID = nil
        }
    }

    /// Crop, in place, cross-faded — the chat editor's own cropper, the same one the photo story
    /// editor uses. It works on the poster because a rectangle is all the export needs; the clip
    /// itself is reframed during the burn-in.
    @ViewBuilder private var cropOverlay: some View {
        if showCrop, let poster = thumbnail {
            ChatCropView(image: poster, inline: true,
                         onClose: { withAnimation(.easeInOut(duration: 0.28)) { showCrop = false } },
                         onRect: { r in
                             // Re-cropping refines the crop you already have, so the new rectangle is
                             // read INSIDE the old one rather than against the original.
                             if let old = cropRect {
                                 cropRect = CGRect(x: old.minX + r.minX * old.width,
                                                   y: old.minY + r.minY * old.height,
                                                   width: r.width * old.width,
                                                   height: r.height * old.height)
                             } else {
                                 cropRect = r
                             }
                         }) { _ in }
                .transition(.opacity)
                .zIndex(20)
        }
    }

    /// OUR pen bar, the same one the photo editor and the chat's image editor use: a colour track,
    /// undo, pen vs highlighter, a width that cycles, and a tick to finish.
    private var penBar: some View {
        let live = penHue == 0 ? Color.white : Color(hue: penHue, saturation: 1, brightness: 1)
        return VStack(spacing: 14) {
            GradientSlider(value: $penHue, track: LinearGradient(
                colors: [.white] + stride(from: 0.02, through: 1.0, by: 0.08).map { Color(hue: $0, saturation: 1, brightness: 1) },
                startPoint: .leading, endPoint: .trailing))
                .padding(.horizontal, 20)
            HStack(spacing: 12) {
                tool("arrow.uturn.backward") {
                    var strokes = drawing.strokes
                    if !strokes.isEmpty { strokes.removeLast(); drawing = PKDrawing(strokes: strokes) }
                }
                tool("pencil.tip", active: !isHighlighter) { isHighlighter = false }
                tool("highlighter", active: isHighlighter) { isHighlighter = true }
                Button { penWidth = penWidth >= 16 ? 4 : penWidth + 6 } label: {
                    Circle().fill(live)
                        .frame(width: max(8, penWidth + 4), height: max(8, penWidth + 4))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(StoryPressStyle())
                Spacer()
                Button { isDrawing = false } label: {
                    Image(systemName: "checkmark").font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .liquidGlass(Circle(), interactive: true, tint: Color(.systemBlue))
                }
                .buttonStyle(StoryPressStyle())
            }
            .padding(.horizontal, 20)
        }
        .padding(.bottom, 14)
    }

    /// Everything drawn on top of THIS clip, in one transparent image the size of the canvas it was
    /// drawn on, plus the crop rectangle. The same builder and the same transforms the photo editor
    /// uses, so text placed on a clip lands where text placed on a picture lands.
    @MainActor private func burnIn(for c: Clip) -> StoryBurnIn? {
        let hasArt = !c.drawing.bounds.isEmpty || !c.overlays.isEmpty
        guard hasArt || c.cropRect != nil else { return nil }
        let size = canvasSize == .zero ? UIScreen.main.bounds.size : canvasSize

        var art: UIImage?
        if hasArt {
            let composed = ZStack(alignment: .bottom) {
                Color.clear
                if !c.drawing.bounds.isEmpty {
                    Image(uiImage: c.drawing.image(from: CGRect(origin: .zero, size: size), scale: UIScreen.main.scale))
                        .resizable()
                }
                ForEach(c.overlays) { o in
                    storyStyledText(o, maxWidth: size.width * 0.9)
                        .scaleEffect(o.scale)
                        .rotationEffect(o.rotation)
                        .position(o.center)
                }
            }
            .frame(width: size.width, height: size.height)
            let renderer = ImageRenderer(content: composed)
            renderer.scale = UIScreen.main.scale
            renderer.isOpaque = false          // black here would hide the whole video behind it
            art = renderer.uiImage
        }
        return StoryBurnIn(overlay: art, cropRect: c.cropRect,
                           canvasAspect: size.height > 0 ? size.width / size.height : nil)
    }

    private func payload(for c: Clip) -> StoryVideoPayload? {
        guard let data = c.posterData else { return nil }
        let cut = c.trimStart > 0.05 || (c.duration > 0 && c.trimEnd < c.duration - 0.05)
        return StoryVideoPayload(url: c.url, thumbnail: data, muted: c.muted,
                                 trim: cut ? c.trimStart...c.trimEnd : nil,
                                 burn: burnIn(for: c))
    }

    private func send() {
        stashCurrent()
        guard let first = clips.first, let head = payload(for: first) else { return }
        // The rest ride behind the first, in the order he arranged them, each carrying its own trim
        // and its own edits. The audience sheet is answered ONCE and they all inherit that answer.
        pendingExtras = clips.dropFirst().compactMap { payload(for: $0) }.map { StoryExtra(video: $0) }
        pendingShare = StoryVideoShare(payload: head,
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
        // The clip this editor was opened with becomes item ONE. Everything after it arrives through
        // the +, so there is only ever one list and the single-clip case is just a list of length 1.
        if clips.isEmpty {
            clips = [Clip(url: url, duration: dur, poster: thumbnail, posterData: thumbnailData,
                          trimStart: 0, trimEnd: dur, muted: muted)]
            index = 0
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
