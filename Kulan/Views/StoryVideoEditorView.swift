import SwiftUI
import AVFoundation
import AVKit
import PhotosUI
import PencilKit

// Video-story editor — the video plays looping on the same rounded canvas card as the photo
// editor (muted poster-frame wash behind it, black frame above/below), with the same caption
// bar (40px) + NEXT (46px) layout. Tools: text, pen and trim, plus the mute toggle up top and the
// + inside the caption bar. NO CROP here — that is a photo tool (owner, 2026-08-04).
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
    // No KeyboardWatcher: the bottom bar is a sibling of the canvas and SwiftUI's own avoidance
    // lifts it. Same change as the photo editor, same reason.
    // One AVQueuePlayer + looper for the whole editor session.
    @State private var player = AVQueuePlayer()
    @State private var looper: AVPlayerLooper?
    /// PAUSED ON ARRIVAL (owner 2026-08-06: "when I go to the video story editor page, please make
    /// the video paused by default"). It opened playing and looping, which means the first thing the
    /// screen does is move — you cannot read the frame you are about to edit, and the pen and the
    /// text tools are placed against a picture that will not hold still. Tapping the preview starts
    /// it, as it always has.
    @State private var playing = false
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
        /// The pinch. Per-clip like every other edit — it used to be one screen-wide value, so
        /// zooming clip 1 silently showed clip 2 zoomed as well — and, worse, it never reached the
        /// export at all: the posted clip was the original framing. `burnIn(for:)` turns it into
        /// the crop rectangle now.
        var zoom: CGFloat = 1
    }

    @State private var clips: [Clip] = []
    @State private var index = 0

    // The live tool state for the clip on screen. Parked onto its Clip when you switch away.
    @State private var drawing = PKDrawing()
    @State private var overlays: [TextOverlay] = []
    @State private var selectedID: UUID?
    @State private var editingID: UUID?
    @State private var isDrawing = false
    @State private var strokeInFlight = false
    @State private var penHue: Double = 0
    @State private var penWidth: CGFloat = 8
    @State private var isHighlighter = false
    // Trim's own working state. It lives HERE, not in a pushed screen, because trimming is a mode of
    // this editor now rather than a page you travel to — see `trimOverlay`.
    @State private var trimThumbs: [UIImage] = []
    @State private var trimPlayhead: Double = 0
    @State private var trimScrub: Double?
    @State private var trimDragging = false
    @State private var trimOpenedStart: Double = 0   // what X puts back
    @State private var trimOpenedEnd: Double = 0
    @State private var showAddPicker = false
    @State private var canvasSize: CGSize = .zero
    /// The post, packed for StoryEditorView, when a picture joins a video-first post. See the
    /// picker sheet below for why the composer takes over at that moment.
    @State private var handOff: HandOffPost?

    struct HandOffPost: Identifiable {
        let id = UUID()
        let items: [StoryEditorView.DraftItem]
        let caption: String
    }

    private var currentURL: URL { clips.indices.contains(index) ? clips[index].url : url }

    /// One more video from OUR picker joins the strip — the same work the old PhotosPicker handler
    /// did, minus the transferable dance (the grid resolves the asset and hands a file URL).
    private func appendClip(_ url: URL) async {
        var c = Clip(url: url)
        let asset = AVURLAsset(url: url)
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
        await MainActor.run {
            stashCurrent()
            clips.append(c)
            index = max(0, clips.count - 1)
            restoreCurrent()
        }
    }

    /// A picture joined the post: pack EVERYTHING for the composer. Each clip travels with its own
    /// trim, mute, drawing and text (DraftItem holds all four beside the file, same as Clip does),
    /// the caption rides along, and the new picture lands at the end, selected. Nothing here is
    /// mutated — if the composer is X-closed without posting, this screen is still exactly as it
    /// was, clips intact, under the picker.
    @MainActor private func beginHandOff(adding ui: UIImage) {
        stashCurrent()
        player.pause(); playing = false
        var seed: [StoryEditorView.DraftItem] = clips.map { c in
            var d = StoryEditorView.DraftItem(image: c.poster ?? UIImage(),
                                              videoURL: c.url, duration: c.duration)
            d.muted = c.muted
            d.trimStart = c.trimStart
            d.trimEnd = c.trimEnd
            d.drawing = c.drawing
            d.overlays = c.overlays
            d.zoom = c.zoom   // the pinch survives the hand-off, like every other edit
            return d
        }
        // Opened straight from the camera or a single pick, before `load()` has built clips[0]:
        // the live top-level state IS the one clip. Pack it the same way.
        if seed.isEmpty {
            var d = StoryEditorView.DraftItem(image: thumbnail ?? UIImage(),
                                              videoURL: url, duration: duration)
            d.muted = muted
            d.trimStart = trimStart
            d.trimEnd = trimEnd
            d.drawing = drawing
            d.overlays = overlays
            d.zoom = zoom
            seed.append(d)
        }
        seed.append(StoryEditorView.DraftItem(image: ui))
        handOff = HandOffPost(items: seed, caption: caption)
    }

    /// Park the live tools back onto the clip they belong to.
    @MainActor private func stashCurrent() {
        guard clips.indices.contains(index) else { return }
        clips[index].drawing = drawing
        clips[index].overlays = overlays
        clips[index].trimStart = trimStart
        clips[index].trimEnd = trimEnd
        clips[index].muted = muted
        clips[index].zoom = zoom
    }

    /// The mirror image: put a clip's edits back on the tools, and put the clip on the player.
    @MainActor private func restoreCurrent() {
        guard clips.indices.contains(index) else { return }
        let c = clips[index]
        drawing = c.drawing
        overlays = c.overlays
        trimStart = c.trimStart
        trimEnd = c.trimEnd
        muted = c.muted
        duration = c.duration
        thumbnail = c.poster
        thumbnailData = c.posterData
        zoom = c.zoom
        baseZoom = max(1, c.zoom)
        selectedID = nil; editingID = nil; isDrawing = false; strokeInFlight = false
        player.isMuted = muted
        // BOTH LINES MATTER. Dropping the looper stops it re-queueing, but the items it has ALREADY
        // queued are sitting in the player and would keep the previous clip playing over the new
        // one — so the queue is emptied before the new looper is allowed to fill it.
        looper = nil
        player.removeAllItems()
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: c.url))
        // Loading a clip does not start it. Switching clips inside the editor keeps whatever the
        // person had chosen — if they had it running, it keeps running; on arrival it stays still.
        if playing { player.play() } else { player.pause() }
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
        // Same two-layer split as the photo editor, and for the same reason: the canvas must never
        // move for the keyboard (the pen bakes strokes against `geo`), while the bar must move with
        // it exactly. Making them siblings lets SwiftUI's own avoidance lift the bar on the system's
        // curve instead of a hand-computed padding arriving a beat late. See StoryEditorView.body.
        ZStack {
            videoCanvasLayer
            if !showTrim, editingID == nil {
                bottomStack
                    .animation(.easeInOut(duration: 0.3), value: showTrim)
            }
        }
        // ALWAYS DARK, whatever the phone is set to. This is the screen he photographed rendering
        // light: grey wash, pale glass, the pen bar washed out. Not `.preferredColorScheme` — see
        // the note in StoryEditorView.body — and not the environment value alone either, which
        // leaves the UIKit chrome light. See `DarkPresentation`.
        .storyAlwaysDark()
    }

    private var videoCanvasLayer: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                // THE SAME RECTANGLE THE PHOTO EDITOR USES, from the same function (owner
                // 2026-08-06: "make the Story Video Editor use the exact same frame, sizing,
                // spacing and layout as the Story Image Editor").
                //
                // It was `geo.height - 8 - 44`: the photo editor's OLD numbers, left behind when
                // that screen moved to a 58pt tool band and then to the story's own 9:16 rule. So
                // the two editors drew different frames, and the video one was the taller of the
                // two — which is why his bottom buttons sat over the video and not under it.
                let cardTop: CGFloat = 8
                let card = StoryEditorView.cardSize(in: geo.size, top: cardTop)
                let cardH = card.height
                // TRIM ZOOMS THE VIDEO OUT, it does not cover it (owner 2026-08-04: "user never feel
                // new page… just zoom out then trim appearing"). The card shrinks toward the TOP so
                // every pixel it gives up appears at the bottom, which is where the strip arrives.
                //
                // It gives up as LITTLE as it can (0.9, was 0.78): in his reference the picture is
                // still the screen, with the buttons floating on it and only the filmstrip below.
                // Shrinking it further left a black margin all round, which is most of what made the
                // old screen look like a separate page.
                canvas(geo: geo, cardTop: cardTop, cardH: cardH)
                    .scaleEffect(showTrim ? 0.9 : 1, anchor: .top)
                    .offset(y: showTrim ? 10 : 0)

                // NOTHING FLOATS OVER THE TEXT EDITOR (owner 2026-08-04: "when keyboad opened pkz
                // hide caption bar and all buttons"). Aa opens a full-screen editor with the keyboard
                // up, and the caption bar and the tool capsule were still sitting there underneath
                // it. The caption already stood aside for its OWN keyboard; this is the other one.
                if !showTrim, editingID == nil {
                    topControls
                }
                // `bottomStack` used to sit HERE. It is a sibling of this whole layer now, in `body`,
                // which is what lets the keyboard lift it without touching the canvas.
                trimOverlay
            }
            .animation(.easeInOut(duration: 0.3), value: showTrim)
            .coordinateSpace(name: "canvas")
            // THE CARD IS THE CANVAS, not the whole screen. Same correction the photo editor got:
            // the flatten and the burn-in measure against `canvasSize`, so handing them a rectangle
            // bigger than the one on screen means the posted frame is not the seen frame.
            .onAppear { canvasSize = StoryEditorView.cardSize(in: geo.size, top: 8) }
            .onChange(of: geo.size) { _, sz in canvasSize = StoryEditorView.cardSize(in: sz, top: 8) }
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
        // Trim's filmstrip. Keyed on the clip, so switching clips inside trim redraws it in place —
        // and it only runs while trim is actually open, since ten frame grabs is not free.
        .task(id: showTrim ? currentURL.absoluteString : "") {
            guard showTrim else { return }
            await loadTrimThumbs()
        }
        // ONE PLACE DECIDES WHETHER THE VIDEO IS RUNNING. The trim strip drives `playing` directly
        // (its play button, and it stops playback when you grab a handle), so the player has to
        // follow the flag rather than only being told by togglePlay.
        .onChange(of: playing) { _, on in on ? player.play() : player.pause() }
        // Scrubbing: the handle drag and the playhead drag both report through `trimScrub`.
        .onChange(of: trimScrub) { _, t in
            guard let t else { return }
            player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
        // + opens OUR library picker, and it offers BOTH types, always (owner 2026-08-05: "The
        // media type should never be restricted by the previously selected item"). Another video
        // joins the clip strip exactly as before. A PICTURE cannot live here — this screen's model
        // is a list of `Clip`s, each of which IS a video — so a picture is the moment the whole
        // post moves to StoryEditorView, the multi-item composer that carries photos and videos
        // side by side. That is the "real repair" the old comment here promised: the composer is
        // presented from INSIDE the picker sheet (a cover asked for while a sheet is dismissing
        // silently never appears — AddStorySheet learned that the hard way), seeded with every
        // clip's trim, mute, drawing and text, plus the caption, plus the new picture.
        .sheet(isPresented: $showAddPicker) {
            StoryLibraryPicker(
                onImage: { ui in beginHandOff(adding: ui) },
                // A VIDEO pick closes the picker and lands back HERE with the new clip selected
                // and playing (owner 2026-08-05: "the app should return directly to the Story
                // Editor... not back to the Photo Picker"). It used to stay open — picking an
                // image visibly opened the composer over it, picking a video visibly did nothing.
                onVideo: { url in
                    showAddPicker = false
                    Task { await appendClip(url) }
                })
            .fullScreenCover(item: $handOff) { post in
                StoryEditorView(source: post.items.first?.image ?? UIImage(),
                                onPosted: { onPosted(); dismiss() },
                                seedItems: post.items,
                                seedCaption: post.caption)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
        .onDisappear { player.pause() }
    }

    /// X on the left, the split notice and mute on the right.
    ///
    /// ALL OF IT HIDES WHILE THE PEN IS DOWN and comes back when the finger lifts — his instruction
    /// on the photo editor, and the same rule has to hold here or the two screens behave differently.
    ///
    /// Out of `body` for the same reason `canvas` is: this file hit "unable to type-check this
    /// expression in reasonable time" twice, and naming a piece is the cure both times.
    private var topControls: some View {
        VStack {
            HStack {
                // 40pt, his call (2026-08-06). The glyph comes down with the circle so the
                // proportion inside it is unchanged — shrinking only the button would leave an
                // oversized X rattling around in a smaller disc.
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .shadow(color: .black.opacity(0.35), radius: 2)
                        .frame(width: 40, height: 40).contentShape(Circle()).liquidGlass(Circle())
                }
                Spacer()
                // NOTHING IS THROWN AWAY ANY MORE, so the notice stopped being a warning and became a
                // fact: a long video posts as several stories that play one after another. It used to
                // read "First 30s will be shared", which was the app telling you it was about to
                // discard the rest.
                if segmentCount > 1 {
                    Text("Posts as \(segmentCount) stories")
                        .font(.footnote.weight(.medium)).foregroundStyle(.primary)
                        .padding(.horizontal, 12).frame(height: 32)
                        .liquidGlass(Capsule())
                }
                Button { muted.toggle(); player.isMuted = muted } label: {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 40, height: 40).contentShape(Circle()).liquidGlass(Circle())
                }
            }
            .padding(.horizontal, 16).padding(.top, max(windowSafeTop - 22, 10))
            Spacer()
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .opacity(strokeInFlight ? 0 : 1)
    }

    /// The caption bar and NEXT, or the pen palette while drawing.
    ///
    /// Nothing here measures the keyboard any more. It is a sibling of the canvas layer, so SwiftUI
    /// lifts it on the keyboard's own curve; the hand-computed lift that used to live here is the
    /// jump the owner reported. The PEN bar keeps ignoring the keyboard because a drawing screen has
    /// none, and a canvas that shifted under a stroke would put the line off the finger.
    private var bottomStack: some View {
        VStack {
            Spacer()
            if isDrawing {
                penBar.ignoresSafeArea(.keyboard, edges: .bottom)
            } else {
                bottomBar
            }
        }
        .opacity(strokeInFlight ? 0 : 1)
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
                    // THE PEN DRAWS IN SCREEN SPACE, exactly like the photo editor's, and NOT in the
                    // card's space (owner 2026-08-04: pen on a video, "when i click done is not
                    // working").
                    //
                    // The canvas used to be the CARD — width by cardH, sitting 8pt down the screen —
                    // so a stroke's coordinates were card coordinates. Both the things that redraw
                    // those strokes afterwards read them as SCREEN coordinates: the still image below
                    // renders `geo.size` worth of drawing and then squeezes it into cardH, and
                    // `burnIn` composes at the full canvas size for the export. So the moment you
                    // tapped the tick your marks jumped up and squashed by the height of the two gaps,
                    // and the exported video disagreed with both. Nothing was wrong with the button.
                    //
                    // One space for everything now, which is the rule this editor already states for
                    // text: what you draw on a clip lands where you drew it, on screen and in the file.
                    .frame(width: geo.size.width, height: geo.size.height)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            } else if !drawing.bounds.isEmpty {
                Image(uiImage: drawing.image(from: CGRect(origin: .zero, size: geo.size), scale: UIScreen.main.scale))
                    .resizable()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
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
                HStack(spacing: 6) {
                    addMoreButton
                    TextField("", text: $caption, prompt: Text("Add a caption…").foregroundColor(Color.white.opacity(0.6)), axis: .vertical)
                        .foregroundStyle(.white).focused($captionFocused)
                        // ...and the text itself carries a hairline shadow so it reads on white.
                        .shadow(color: .black.opacity(0.45), radius: 1.5)
                        .lineLimit(1...5)
                        // The text carries its own breathing room; one line is then shorter than the
                        // 40 the + pins, so the bar rests at exactly 40 and still grows for a long
                        // caption. Same fix as the photo editor.
                        .padding(.vertical, 6)
                        .onChange(of: caption) { _, v in
                            if v.count > Limits.storyCaptionChars { caption = String(v.prefix(Limits.storyCaptionChars)) }
                        }
                }
                // EXACTLY 40 AT REST (owner spec). It measured 50: the + is a 32pt square and the bar
                // added 9pt above and below it, so `minHeight: 40` never bit.
                .padding(.leading, 6).padding(.trailing, 18).frame(minHeight: 40)
                // Liquid Glass, tinted dark (owner 2026-08-04). Plain glass goes pale over a bright
                // frame and swallows the white placeholder, which is the bug the flat pill was
                // covering for; the tint is Apple's own, so this is real glass that still gives
                // white text something to sit on. The text keeps its hairline shadow for the same
                // reason.
                // Rounder, on his word (2026-08-04). Not a Capsule: this bar GROWS to five lines
                // when the caption is long, and a capsule's ends become huge lozenges as it does.
                // 26 reads as a pill at resting height and still looks deliberate when it is tall.
                .liquidGlass(RoundedRectangle(cornerRadius: 26, style: .continuous),
                             tint: .black.opacity(0.28))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)

                if captionFocused { compactSendButton }
            }
            // ⚠️ 14, AND THE ARITHMETIC IS THE POINT — this is the second attempt at it.
            //
            // The two editors stack differently. The photo editor's caption is its OWN layer with
            // `cardBottomGap + 14` under it, which lands its bottom edge 72pt above the safe area
            // when the 9:16 card fits (58 + 14). THIS editor keeps the caption and the tool row in
            // one stack pinned to the bottom, so the tool row (46) and the stack's spacing (12)
            // already lift it 58 — and the pill needs the remaining 14 to reach the same 72.
            //
            // Last round I gave it `toolZoneHeight + 14` here, which is the photo editor's WHOLE
            // number added on top of a 58 this layout had already supplied. That double-count is the
            // gap under the caption he photographed. Copying the number was wrong because the two
            // layouts do not measure from the same place; copying the RESULT is what he asked for.
            //
            // Focused, the tool row is gone and the keyboard is the floor, so 8 — the photo
            // editor's focused value, not the 10 this file used to carry.
            .padding(.bottom, captionFocused ? 8 : 14)

            if !captionFocused {
                HStack(spacing: 14) {
                    // THREE TOOLS: text, pen, trim. Two went on the owner's word, 2026-08-04.
                    //
                    // CROP is gone from the VIDEO editor and stays in the photo one ("Remove Crop
                    // feature in video story editor… only video").
                    //
                    // THE SECOND + is gone. It did the same job as the + inside the caption bar,
                    // which he keeps: "one is working same plz remove buttom one. Dont tuch ine in
                    // side caption bar".
                    HStack(spacing: 20) {
                        tool("textformat") { addTextOverlay() }
                        // THE VIDEO HOLDS STILL WHILE YOU DRAW, the way it already does for trim
                        // (owner 2026-08-04: "plz play and pause fix"). It used to keep playing and
                        // looping under your hand, and you could not stop it, because every tap on
                        // the picture belongs to the pen while the pen is out. Tapping the tick
                        // gives you the video back, running, where you left it.
                        tool(isDrawing ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle",
                             active: isDrawing) { setDrawing(!isDrawing) }
                        tool("scissors", active: isTrimmed) { openTrim() }
                    }
                    .padding(.horizontal, 18).frame(height: 46)
                    .liquidGlass(Capsule())

                    Spacer(minLength: 8)
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
                // ONE LINE, ALWAYS (owner 2026-08-04: it was breaking as "NE / XT"). The tool capsule
                // beside it was winning the width argument and NEXT was told to wrap to fit. A word
                // this short must never wrap: it is a label, not a paragraph. `lineLimit` alone only
                // stops the second line from DRAWING — `fixedSize` is what stops the layout from
                // squeezing the button below the width the word needs in the first place.
                Text("NEXT").font(.system(size: 16, weight: .semibold))
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 22).frame(height: 46)
            .layoutPriority(1)   // the tools capsule gives way, not the word
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
            // HIS OWN DRAWING (2026-08-06), and the SAME one on both editors. The photo editor used
            // `plus.square.on.square` and the video editor a bare `plus` — two different marks for
            // one action on two screens that are meant to be the same screen.
            //
            // Template-rendered, so `.foregroundStyle` tints it. The SVG's `currentColor` was
            // replaced with a literal black: a template asset takes its colour from the caller, and
            // `currentColor` has nothing to resolve against inside an asset catalogue — it renders
            // as nothing at all. Same trap as the icon batch on 2026-08-01.
            Image("ic_add_media")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 19, height: 19)
                .foregroundStyle(.white)
                // 40 tall on purpose: this is what sets the caption bar's resting height, and it
                // gives the button the whole height of the bar to be tapped in.
                .frame(width: 38, height: 40)
                .contentShape(Rectangle())
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

    // CROP LIVED HERE. Removed from the video editor on the owner's word, 2026-08-04 ("Remove Crop
    // feature in video story editor… only video"). The photo editor keeps its cropper, and
    // ChatCropView, which both of them borrowed, is untouched.

    // MARK: Trim, in place

    /// TRIM IS A MODE OF THIS SCREEN, NOT A SCREEN (owner 2026-08-04, on the cover that used to slide
    /// up from the bottom: "user never feel new page… just zoom out then trim appearing").
    ///
    /// It is built the way CROP already is on this same editor — an overlay in the same ZStack, shown
    /// inside a `withAnimation` — so the two tools that take over the screen behave alike instead of
    /// one sliding a page in and the other not.
    ///
    /// THE VIDEO UNDERNEATH IS THE EDITOR'S OWN PLAYER, still playing the same item at the same
    /// moment. The old screen carried a SECOND AVPlayer on the same file, so opening trim re-loaded
    /// the video and seeked it, and the picture jumped at the cut. Nothing reloads now; the card just
    /// gets smaller.
    ///
    /// Only the chrome is drawn here. The middle is deliberately empty so the shrinking card shows
    /// through it — a background would put the "new page" straight back.
    @ViewBuilder private var trimOverlay: some View {
        if showTrim {
            VStack(spacing: 0) {
                trimHeader
                Spacer(minLength: 0)
                // THE CLIPS SIT IN THE BOTTOM-RIGHT CORNER OF THE PICTURE, over it, small, the way
                // his reference draws them (2026-08-04: "make it like image 2"). They used to be a
                // full-width row pinned under the title bar, which is what made the screen read as a
                // file browser with a video in it rather than a video with its clips in the corner.
                if clips.count > 1 {
                    trimPeerStrip
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 12)
                        .padding(.bottom, 12)
                }
                VideoTrimStrip(duration: duration, thumbnails: trimThumbs,
                               trimStart: $trimStart, trimEnd: $trimEnd,
                               playhead: $trimPlayhead, scrubTime: $trimScrub,
                               playing: $playing, draggingPlayhead: $trimDragging)
                    .frame(height: 56)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                    // Reserve the slot rather than let a late strip shove the layout (same reason the
                    // old screen did it).
                    .opacity(trimThumbs.isEmpty ? 0 : 1)
            }
            .transition(.opacity)
            .zIndex(20)
        }
    }

    private var trimHeader: some View {
        HStack {
            // X puts the handles back where they were. Done keeps them. Neither may leave half a cut.
            Button { closeTrim(keep: false) } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 48, height: 48).contentShape(Circle()).liquidGlass(Circle())
            }
            .buttonStyle(.plain)

            // NO LENGTH PILL IN THE MIDDLE. It said the same thing the clips now say for themselves,
            // one number per clip on its own thumbnail, which is where his reference puts it — and a
            // pill floating over the picture between two buttons is what made this bar look busy.
            Spacer()

            Button { closeTrim(keep: true) } label: {
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

    /// The post's clips, so each can be trimmed without leaving (owner: "trimming multiple videos
    /// from a single trim screen"), drawn to his reference: SQUARE cards in the bottom-right corner
    /// of the picture, each carrying its own length, the one you are trimming ringed in blue with an
    /// X to drop it.
    ///
    /// A plain HStack, not a ScrollView. It sits in a corner over the video now, and a scroll view
    /// there would have an invisible edge you could flick — with 10 clips the row is 740pt wide and
    /// simply runs off, which is the honest failure and not one worth a scroller in the corner.
    private var trimPeerStrip: some View {
        HStack(spacing: 8) {
            ForEach(Array(clips.enumerated()), id: \.element.id) { i, c in
                Group {
                    if let p = c.poster { Image(uiImage: p).resizable().scaledToFill() }
                    else { Color(white: 0.15) }
                }
                .frame(width: 62, height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                // The clip's own length, bottom-left on the picture, as his reference has it.
                .overlay(alignment: .bottomLeading) {
                    Text(trimClock(clipLength(i)))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(4)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(i == index ? Color(.systemBlue) : .white.opacity(0.25),
                                      lineWidth: i == index ? 2.5 : 1)
                }
                // The X drops this clip, and only on the one you are trimming — an X on every
                // thumbnail turns a row of pictures into a row of buttons. Same rule the photo
                // editor's strip already follows.
                .overlay(alignment: .topTrailing) {
                    if i == index, clips.count > 1 {
                        Button { remove(i) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 17))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.65))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 6, y: -6)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onTapGesture {
                    guard i != index else { return }
                    // ORDER MATTERS: select() runs restoreCurrent(), which loads the new clip's
                    // handles AND starts it playing. Pausing first would be undone a line later,
                    // and the opened-values snapshot has to be taken after the handles change or
                    // X would restore the WRONG clip's trim.
                    select(i)
                    playing = false
                    trimOpenedStart = trimStart
                    trimOpenedEnd = trimEnd
                }
            }
        }
    }

    /// What this clip will actually post as. The one on screen reads the LIVE handles, because its
    /// trim has not been parked back onto it yet; the others read their stored cut.
    private func clipLength(_ i: Int) -> Double {
        guard clips.indices.contains(i) else { return 0 }
        if i == index { return trimmedLength > 0 ? trimmedLength : duration }
        let c = clips[i]
        let kept = c.trimEnd - c.trimStart
        return kept > 0 ? kept : c.duration
    }

    /// Entering and leaving the pen. The clip freezes for it and starts again when you are done,
    /// which is what crop and trim have always done — the pen was the one tool that left the video
    /// running under a hand that had no way to stop it.
    ///
    /// It also clears `strokeInFlight`. That flag hides the chrome while a stroke is in progress and
    /// is cleared by PencilKit's end-of-stroke callback; if that callback is ever missed, the flag
    /// stays set and the tick is invisible at opacity 0 — a Done button you cannot see is a Done
    /// button that does not work, and this makes leaving the tool always put it back.
    private func setDrawing(_ on: Bool) {
        isDrawing = on
        strokeInFlight = false
        playing = !on   // the onChange above is the one place that starts and stops the player
    }

    private func openTrim() {
        playing = false
        if trimEnd <= 0 { trimEnd = duration }   // the trim starts as "all of it"
        trimOpenedStart = trimStart
        trimOpenedEnd = trimEnd
        withAnimation(.easeInOut(duration: 0.3)) { showTrim = true }
    }

    private func closeTrim(keep: Bool) {
        if !keep { trimStart = trimOpenedStart; trimEnd = trimOpenedEnd }
        stashCurrent()
        trimThumbs = []
        withAnimation(.easeInOut(duration: 0.3)) { showTrim = false }
    }

    private func trimClock(_ s: Double) -> String {
        let t = Int(s.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    /// Ten frames across the clip — the same filmstrip recipe the trim screen and VideoApprovalView
    /// have always used.
    private func loadTrimThumbs() async {
        let asset = AVURLAsset(url: currentURL)
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
        await MainActor.run { trimThumbs = imgs }
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
                Button { setDrawing(false) } label: {
                    Image(systemName: "checkmark").font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .liquidGlass(Circle(), interactive: true, tint: Color(.systemBlue))
                        // The 44pt frame was LAYOUT only. A bare Image takes touches on the glyph it
                        // actually draws, so this button was a 17pt tick in a 44pt hole — the owner
                        // circled it. Every other control in this bar already had its contentShape.
                        .contentShape(Circle())
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
        // THE PINCH REACHES THE EXPORT NOW. A zoomed clip looked reframed on this screen and then
        // uploaded at its original framing — the owner's "displays the original, unedited frame"
        // report. Zoom becomes the transcoder's crop rectangle below.
        let reframed = c.zoom > 1.001
        guard hasArt || reframed else { return nil }
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
        // The pinch's crop. The zoom is centred (this screen's pinch has no pan), so the kept
        // piece is the centred fraction of the clip that still fits the card at that zoom: fit the
        // clip into the CARD it plays in on screen (the canvas minus the 8pt top and the 44pt
        // band — videoCanvasLayer's own numbers), see how much of it the card can show at zoom z,
        // and take that same centred slice out of the clip's aspect-fit footprint in the export
        // canvas. Bands outside the picture are cropped away, so the viewer letterboxes a reframed
        // clip with its live blur exactly like an untouched one.
        var crop: CGRect?
        if reframed, let ps = c.poster?.size, ps.width > 0, ps.height > 0 {
            let card = CGSize(width: size.width, height: max(1, size.height - 8 - 44))
            let fitS = min(card.width / ps.width, card.height / ps.height)
            let fx = min(1, card.width / (ps.width * fitS * c.zoom))
            let fy = min(1, card.height / (ps.height * fitS * c.zoom))
            let canvasAspect = size.width / size.height
            let clipAspect = ps.width / ps.height
            // The clip's aspect-fit footprint inside the export canvas, normalised.
            let f0 = clipAspect >= canvasAspect
                ? CGSize(width: 1, height: (size.width / clipAspect) / size.height)
                : CGSize(width: (size.height * clipAspect) / size.width, height: 1)
            crop = CGRect(x: (1 - f0.width * fx) / 2, y: (1 - f0.height * fy) / 2,
                          width: f0.width * fx, height: f0.height * fy)
            // Text and pen were drawn over the ZOOMED clip; the export paints them onto the
            // unzoomed canvas and then magnifies the kept rectangle. Re-projected into that
            // rectangle, they come back out where and as big as this screen showed them.
            if let a = art, let cr = crop {
                let target = CGRect(x: cr.minX * size.width, y: cr.minY * size.height,
                                    width: cr.width * size.width, height: cr.height * size.height)
                let fmt = UIGraphicsImageRendererFormat()
                fmt.scale = a.scale; fmt.opaque = false
                art = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
                    a.draw(in: target)
                }
            }
        }
        return StoryBurnIn(overlay: art, cropRect: crop,
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
        // Deliberately NOT `play()`. The editor opens on a still frame — see `playing`.
        player.pause()
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
