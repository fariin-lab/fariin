import SwiftUI
import PencilKit
import CoreImage
import CoreImage.CIFilterBuiltins
import AVFoundation
import PhotosUI
import StoryUI   // StoryCanvas: the one sampler + drawer for a story's backdrop

// Photo-story editor — matches the in-chat photo editor (image 212): the picked photo fits on a
// black canvas; X top-left; a caption bar + @ and a crop / draw / adjust / HD tool row at the
// bottom with a green send. Send flattens the edits and opens the audience sheet, which posts the
// story via StoriesService. Every tool is real.
// Publishes the live keyboard height. The editor opts OUT of SwiftUI's automatic keyboard
// avoidance (it was squishing the canvas and desyncing button hit-tests) and instead lifts
// only the bottom bar by this measured height.
final class KeyboardWatcher: ObservableObject {
    @Published var height: CGFloat = 0
    private var tokens: [NSObjectProtocol] = []
    init() {
        tokens.append(NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] n in
                guard let f = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
                self?.height = max(0, UIScreen.main.bounds.height - f.origin.y)
        })
        tokens.append(NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
                self?.height = 0
        })
    }
    deinit { tokens.forEach { NotificationCenter.default.removeObserver($0) } }
}

struct StoryEditorView: View {
    let source: UIImage
    var onPosted: () -> Void = {}
    /// A WHOLE POST ARRIVING FROM THE VIDEO EDITOR. When a picture joins a video-first post, that
    /// screen cannot hold it (its model is a list of clips, each of which IS a video), so it hands
    /// everything here — each clip with its trim, mute, drawing and text, then the new picture.
    /// Empty means the normal single-photo start via `source`.
    var seedItems: [DraftItem] = []
    var seedCaption: String = ""
    @Environment(\.dismiss) private var dismiss

    @State private var caption = ""
    @State private var drawing = PKDrawing()
    @State private var isDrawing = false
    @State private var filterIndex = 0
    @State private var croppedSource: UIImage?   // result of the interactive crop (nil = uncropped)
    @State private var showCrop = false
    // Trim's working state for the video item on screen, mirrored back into the item on Done. It
    // lives here rather than in a pushed screen because trimming is a mode of this editor, the same
    // call he made on the video editor.
    @State private var showTrim = false
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0
    @State private var trimOpenedStart: Double = 0   // what X puts back
    @State private var trimOpenedEnd: Double = 0
    @State private var trimThumbs: [UIImage] = []
    // THE COMPOSER HAD NO PLAYER AT ALL, which is why the play mark did nothing and why trim was a
    // filmstrip you dragged blind. A video item drew its poster and a decorative `play.fill`.
    //
    // One AVPlayer, built when a clip needs previewing and torn down when you leave it. It is not
    // built up front: most posts are photos, and an idle AVPlayer per composer session is a decoder
    // held open for nothing.
    @State private var previewPlayer: AVPlayer?
    @State private var previewPlaying = false
    @State private var trimPlayhead: Double = 0
    @State private var trimScrub: Double?
    @State private var trimDragging = false
    @State private var cropRect: CGRect? = nil   // live crop as a rectangle — see DraftItem.cropRect
    // Our own pen palette, the same three controls ChatImageEditor drives PencilKit with. Defaults
    // match it too, so a pen is a pen wherever you pick one up in this app.
    @State private var penHue = 0.01             // 0 = white end of the track; 0.01 = red
    @State private var penWidth: CGFloat = 6
    @State private var isHighlighter = false
    /// A stroke is under the finger right now. Everything on top of the photo gets out of the way
    /// while it is true (owner 2026-08-03: "when i start to use pen all buttons hide, when i remove
    /// my finger show again") — you cannot draw across a corner your own toolbar is sitting on.
    @State private var strokeInFlight = false
    @State private var editedCache: UIImage?         // filtered+cropped; recomputed only on tool change
    /// Telegram's two canvas colours for the picture as it stands. Held rather than derived on each
    /// layout pass, and rewritten by `recomputeEdited` — a filter changes the picture, so it changes
    /// the canvas made from it.
    @State private var canvasCache: (top: UIColor, bottom: UIColor)?
    @State private var canvasSize: CGSize = .zero
    // Pinch-zoom + pan the photo directly on the canvas (baked WYSIWYG into the post). Driven by UIKit
    // recognizers (PinchPanGestureView) using the standard accumulate-and-reset pattern — see below.
    @State private var photoZoom: CGFloat = 1
    @State private var photoOffset: CGSize = .zero
    // Real device safe-area top from the window (the editor's GeometryReader under-reports it because the
    // status bar is hidden). Used to place the close button 12pt below the Dynamic Island / notch.
    private var windowSafeTop: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.top }
            .first ?? 47
    }
    @State private var posting = false
    @State private var postError = false
    /// The black band under the card where the tool capsule and NEXT live. A CONSTANT, not a
    /// measured height: the card's frame used to be inset by the bottom bar's measured size, and
    /// anything that changed the bar (focusing the caption, opening Aa — both raise the keyboard)
    /// re-measured the canvas and visibly shrank the photo. His rule: the preview NEVER resizes.
    /// Geometry that cannot move is geometry derived from nothing that moves.
    static let toolZoneHeight: CGFloat = 58

    /// THE CARD, BY THE VIEWER'S OWN RULE. `StoryDetailView.cardHeight` is `min(9:16, the room
    /// there is)`, and this must be the same shape or the composer is framing a picture for a
    /// rectangle that does not exist.
    ///
    /// It was `available` on its own, which on his phone is 430 x 782 — aspect 1.8196 against the
    /// story card's 1.7778, so a picture pinched to exactly fill the composer arrived at the story
    /// 2.4% too tall. Proved from his own post: the uploaded file is 2638x4800, aspect 1.8196, the
    /// composer's shape to three decimals, and 1.8196 in a 1.778 card leaves the 1.15%-a-side band
    /// he drew lines down.
    ///
    /// `ceil` and 1.77778 are copied from the viewer deliberately. Two rectangles that have to agree
    /// to the pixel must be the same arithmetic, not arithmetic that happens to match.
    static func cardSize(in space: CGSize, top: CGFloat) -> CGSize {
        let available = max(1, space.height - top - toolZoneHeight)
        return CGSize(width: space.width, height: min(ceil(space.width * 1.77778), available))
    }
    /// How far the card's bottom edge sits above the bottom of this screen. `toolZoneHeight` when the
    /// 9:16 card fits in the room available, more when it does not — and the caption pill hangs off
    /// THIS rather than off the constant, or it drops through the floor of a shortened card.
    @State private var cardBottomGap: CGFloat = StoryEditorView.toolZoneHeight
    @State private var pendingShare: StoryShareData?
    @State private var pendingExtras: [StoryExtra] = []
    @FocusState private var captionFocused: Bool
    // No KeyboardWatcher here any more: the bottom bar is a sibling of the canvas and SwiftUI's own
    // avoidance lifts it. The class stays because the video editor and the text composer still use it.
    // Adaptive control contrast: dark icons over a light photo region, light over dark (so buttons are
    // never invisible on a white background). Sampled per-region (top = X, bottom = tools).
    @State private var topIconDark = false
    @State private var bottomIconDark = false

    // Text-on-photo overlays
    @State private var overlays: [TextOverlay] = []
    @State private var selectedID: UUID?
    @State private var editingID: UUID?
    @State private var draggingID: UUID?
    @State private var trashHot = false
    @State private var guideV = false
    @State private var guideH = false

    private static let ciContext = CIContext()
    private static let filters: [(name: String, ci: String?)] = [
        ("Original", nil), ("Vivid", "CIPhotoEffectChrome"), ("Mono", "CIPhotoEffectMono"),
        ("Fade", "CIPhotoEffectFade"), ("Noir", "CIPhotoEffectNoir"),
    ]
    // MARK: - More than one item

    /// One thing queued for this post. A video carries its file; its `image` is the poster, which is
    /// what the thumbnail strip and the canvas show — a video's own bytes decode to nothing as an
    /// image, and every strip in this app already learned that the hard way.
    struct DraftItem: Identifiable {
        let id = UUID()
        /// The ORIGINAL, never overwritten. Every edit is re-applied to this, which is what makes
        /// them undoable — baking them in was the old model and it made a crop permanent the moment
        /// you looked at another item.
        var image: UIImage
        var videoURL: URL? = nil
        var duration: Double = 0
        var isVideo: Bool { videoURL != nil }

        // The edits, held BESIDE the picture rather than burnt into it, so switching away and back
        // returns you to exactly what you had, still adjustable (owner 2026-08-04).
        var cropped: UIImage? = nil       // the interactive crop's result, re-derivable from `image`
        /// THE SAME CROP, AS A RECTANGLE (normalised 0-1). A photo can carry its crop as a cropped
        /// picture; a video has no picture to crop, so it needs the rectangle and applies it during
        /// the export. Both are kept because both are needed: the poster in the strip is the image,
        /// the frames that get uploaded are the rectangle.
        var cropRect: CGRect? = nil
        var filterIndex = 0
        var drawing = PKDrawing()
        var overlays: [TextOverlay] = []
        var zoom: CGFloat = 1
        var offset: CGSize = .zero

        // VIDEO-ONLY, and they are the whole of the owner's report that a video thumbnail brought up
        // the photo tools. A clip has two things a picture does not: a soundtrack you may not want,
        // and a length you may want less of. `StoryVideoPayload` has carried both since the video
        // editor was built; this screen simply never offered them or filled them in.
        //
        // `trimEnd == 0` means "not trimmed" rather than "zero length", so an untouched clip needs no
        // knowledge of its own duration to be correct.
        var muted = false
        var trimStart: Double = 0
        var trimEnd: Double = 0
        var isTrimmed: Bool { trimStart > 0.05 || (trimEnd > 0 && trimEnd < duration - 0.05) }
        /// The range to keep, in seconds, or nil for the whole clip — the shape the payload wants.
        var trimRange: ClosedRange<Double>? {
            guard isTrimmed else { return nil }
            let end = trimEnd > 0 ? trimEnd : duration
            guard end > trimStart else { return nil }
            return trimStart...end
        }
    }

    /// Everything in this post, in order, with `index` pointing at the one on the canvas.
    ///
    /// SWITCHING BAKES. The item you are leaving keeps its crop, filter, drawing and text by having
    /// them flattened into its image, and the tools reset for the one you arrive at. Per-item live
    /// edit state would mean five parallel copies of every tool's state on a screen that is already
    /// device-verified, and the risk of that is not worth being able to un-crop something you left.
    @State private var items: [DraftItem] = []
    @State private var index = 0
    @State private var showAddPicker = false

    /// Everything a pick from OUR library grid needs to become an item. The same work the old
    /// PhotosPicker handler did, minus the transferable dance — the grid resolves the asset itself
    /// and hands over a UIImage or a file URL.
    /// ⚠️ `restoreCurrent()`, NOT `recomputeEdited()`. This is what made a picked photo look like
    /// nothing had happened.
    ///
    /// The tools are held OUTSIDE the item — croppedSource, cropRect, filterIndex, drawing,
    /// overlays, photoZoom, photoOffset — and `select(_:)` has always been stash, move, restore.
    /// These two append paths did stash, move, and then `recomputeEdited`, which is the last line of
    /// restore without the restore. So the new picture arrived wearing the PREVIOUS one's tools, and
    /// `recomputeEdited` reads `croppedSource ?? current` — meaning if the item before it had been
    /// cropped, the editor recomputed from that old cropped bitmap and drew the OLD PHOTO on the new
    /// item. He picked a second image and the screen did not change.
    @MainActor private func appendPicked(image ui: UIImage) {
        stashCurrent()
        items.append(DraftItem(image: ui))
        index = max(0, items.count - 1)
        restoreCurrent()   // a fresh item has clean tools; this ends in recomputeEdited()
    }

    private func appendPicked(video url: URL) async {
        let asset = AVURLAsset(url: url)
        let dur = (try? await asset.load(.duration).seconds) ?? 0
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1200, height: 1200)
        let t = CMTime(seconds: min(0.1, max(0.01, dur / 2)), preferredTimescale: 600)
        // A poster that cannot be decoded must NOT drop the video on the floor — a `guard return`
        // here made a picked clip silently never appear ("i chose video, is not working"). The item
        // joins with a black poster instead; the clip itself is fine and the export never reads
        // this bitmap.
        let poster: UIImage
        if let cg = try? await gen.image(at: t).image {
            poster = UIImage(cgImage: cg)
        } else {
            let side = CGSize(width: 1080, height: 1920)
            poster = UIGraphicsImageRenderer(size: side).image { ctx in
                UIColor.black.setFill(); ctx.fill(CGRect(origin: .zero, size: side))
            }
        }
        await MainActor.run {
            stashCurrent()
            items.append(DraftItem(image: poster, videoURL: url, duration: dur))
            index = max(0, items.count - 1)
            restoreCurrent()   // same fix as the image path above — see its note
        }
    }

    private var current: UIImage { items.indices.contains(index) ? items[index].image : source }
    private var currentIsVideo: Bool { items.indices.contains(index) && items[index].isVideo }

    private var edited: UIImage { editedCache ?? current }
    private func recomputeEdited() {
        // Filter applies on top of the (interactively) cropped source.
        editedCache = Self.apply(Self.filters[filterIndex].ci, to: croppedSource ?? current)
        updateIconContrast()   // re-sample brightness so the controls stay readable on this photo
        // ...and re-read the canvas, because a filter changes the colours the canvas is made of.
        // It is sampled HERE rather than derived in `cardContent` because that runs on every layout
        // pass and this reads pixels. Same reason, same shape, as the video editor's `canvasBackdrop`.
        canvasCache = StoryCanvas.colours(of: edited)
    }
    /// The canvas colours for the picture as it stands, through the one sampler the post and the
    /// story viewer also read. Falls back to the untouched source for the instant before
    /// `recomputeEdited` first runs, so the card never draws a frame of the wrong backdrop.
    private var canvasColours: (top: UIColor, bottom: UIColor) {
        canvasCache ?? StoryCanvas.colours(of: current)
    }

    // The photo's aspect-fit size inside the frame ("always-cover" clamp basis).
    private func fittedSize(in frame: CGSize) -> CGSize {
        let s = edited.size
        guard s.width > 0, s.height > 0 else { return frame }
        let scale = min(frame.width / s.width, frame.height / s.height)
        return CGSize(width: s.width * scale, height: s.height * scale)
    }
    // Clamp the pan so the photo edge can reach the frame edge but never past it (no gaps / floating).
    // offset ∈ ±(scaledSize − frameSize)/2  — the standard image-transform normalize math.
    private func clampedOffset(_ off: CGSize, zoom: CGFloat, in frame: CGSize) -> CGSize {
        let fit = fittedSize(in: frame)
        let maxX = max(0, (fit.width * zoom - frame.width) / 2)
        let maxY = max(0, (fit.height * zoom - frame.height) / 2)
        return CGSize(width: min(maxX, max(-maxX, off.width)),
                      height: min(maxY, max(-maxY, off.height)))
    }

    var body: some View {
        // TWO LAYERS, AND THE SPLIT IS THE POINT. The canvas ignores the keyboard so it can never be
        // squished or re-measured (the pen bakes strokes against `geo`, so a canvas that moves puts
        // the line somewhere other than the finger). The bottom bar is a SIBLING of it, outside that
        // ignore, so SwiftUI's own keyboard avoidance lifts it — on the system's exact curve, on the
        // system's exact frame, because it is the system doing it.
        //
        // It used to be one layer with `.ignoresSafeArea(.keyboard)` over everything and a hand-
        // computed `.padding(.bottom, ...)` from a KeyboardWatcher. That is the jump the owner
        // reported, and it was TWO jumps: focusing the field tore the thumbnail strip and the tool
        // row out of the stack, which dropped the bar DOWN, and then the keyboard notification
        // arrived and shoved it UP. Two state changes, two moments, neither animated with the
        // keyboard. Nothing here computes a keyboard height any more.
        ZStack {
            Color.black.ignoresSafeArea()
            canvasLayer
                // THE CARD'S FRAME IS FIXED (owner: "the Story preview must never shrink, resize,
                // or change its scale"). It was inset by the bottom bar's MEASURED height, and the
                // keyboard reached the canvas through that wrapper — focusing the caption or
                // opening Aa visibly shrank the photo. The card is `Self.cardSize` now — screen
                // geometry and a constant, nothing measured and nothing that moves — and the canvas
                // ignores the keyboard outright. Fixed still means fixed; it just is not the same
                // number it was, because it is the STORY's rectangle now (see cardSize).
                //
                // TRIM ZOOMS THE MEDIA OUT, exactly as the single-video editor does — same 0.9,
                // same top anchor, same 10pt nudge, same 0.3 curve.
                //
                // CROP DOES IT TOO NOW (owner 2026-08-06: "the story image should smoothly zoom out
                // first, then the crop controls and buttons should fade or slide into view"). It was
                // a bare cross-fade between two full screens, which is the "sudden jump" — nothing
                // connected the picture he was looking at to the picture he landed on. This is the
                // motion trim already uses and that he already signed off ("user never feel new
                // page… just zoom out then trim appearing"), so the two tools in the same bar now
                // open the same way as each other.
                .scaleEffect(showTrim || showCrop ? 0.9 : 1, anchor: .top)
                .offset(y: showTrim || showCrop ? 10 : 0)
                .animation(.easeInOut(duration: 0.3), value: showTrim)
                .animation(.easeInOut(duration: 0.3), value: showCrop)
            // Bottom chrome. While DRAWING, our pen bar takes the bottom instead; it stays pinned
            // because a drawing screen has no keyboard and the canvas must not move under a stroke.
            if isDrawing {
                VStack { Spacer(); penBar.padding(.bottom, 8) }
                    .ignoresSafeArea(.keyboard, edges: .bottom)
                    // OPACITY, not an `if`: removing the bar from the tree mid-stroke would relayout
                    // the screen the canvas is measured against, and the canvas has to stay exactly
                    // where it is or the line lands somewhere other than the finger.
                    .opacity(strokeInFlight ? 0 : 1)
            } else if !showTrim {
                // TWO SEPARATE LAYERS, because they answer to different masters. The tool row is
                // pinned to the screen bottom and never moves for the keyboard; the caption pill
                // sits ON the card (the reference layout) and rides the keyboard when focused.
                // GONE DURING A TRIM, not merely faded — the filmstrip lands where they were.
                toolRowLayer
                captionLayer
            }
            // Aa's editor is a SIBLING of the canvas, not an overlay inside it: it needs the
            // keyboard avoidance the canvas must never have. Its own dim backdrop covers the
            // screen; the card underneath does not move a pixel.
            if let id = editingID, let idx = overlays.firstIndex(where: { $0.id == id }) {
                TextEditorOverlay(
                    draft: $overlays[idx],
                    onCancel: { trimEmpty(id); editingID = nil },
                    onDone: { trimEmpty(id); editingID = nil }
                )
                .zIndex(30)
            }
            // Above the bars, and keyboard-proof: neither cropping nor trimming has a keyboard, and
            // both must cover everything under them.
            cropOverlay
                .ignoresSafeArea(.keyboard)
            trimOverlay
                .ignoresSafeArea(.keyboard)
        }
        // Closing the composer must not leave a decoder and an audio session running behind it.
        .onDisappear { stopPreview() }
        // ALWAYS DARK, whatever the phone is set to (owner: "all story buttons always use dark mode
        // no light mode"). A story is white text and glass over somebody's photo; in light mode the
        // materials go pale and the controls wash out, which he photographed on the pen screen.
        //
        // NOT `.preferredColorScheme(.dark)`: KulanApp sets preferredColorScheme OUTSIDE RootView,
        // and an outer one always wins, so a pin inside a screen is dead code — five of them in the
        // auth flow never did anything. See [[kulan-preferredcolorscheme-trap]].
        //
        // `storyAlwaysDark` is BOTH halves: the environment value the materials read, and the UIKit
        // trait everything else reads. The environment on its own left this screen's alerts and any
        // system sheet it raises resolving light on a light-mode phone — the same split he
        // photographed on the picker. See the note on `DarkPresentation`.
        .storyAlwaysDark()
    }

    private var canvasLayer: some View {
        GeometryReader { geo in
            // THE CARD IS THE STORY FRAME (owner: "use the real Story frame… the editor accurately
            // matches the final Story layout"). Full width, from just under the status bar down to
            // the tool band — a CONSTANT of screen geometry, so nothing that appears or disappears
            // around it (keyboard, bars, Aa) can ever resize the preview. Everything WYSIWYG —
            // the photo, the pen, the text, the flatten — lives in the CARD's coordinate space
            // now, not the whole screen's, which is what makes the posted frame the seen frame.
            let cardTop: CGFloat = 8
            let card = Self.cardSize(in: geo.size, top: cardTop)
            let cardH = card.height
            ZStack {
                Color.black.ignoresSafeArea()
                cardContent(card: card)
                    .frame(width: card.width, height: card.height)
                    // The card ALWAYS has the rounded story shape (reference). Display-only:
                    // the flatten renders the same space unrounded, and the viewer rounds its
                    // own card exactly like this.
                    .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
                    .position(x: geo.size.width / 2, y: cardTop + cardH / 2)

                // Top controls — stay put when the keyboard opens (don't ride up with it).
                VStack {
                    HStack {
                        Button { dismiss() } label: {
                            // 40pt, his call (2026-08-06), matching the video editor's. The glyph
                            // comes down with the circle so the proportion inside it is unchanged.
                            Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.primary)   // always white; glass + shadow carry contrast
                                .shadow(color: .black.opacity(0.35), radius: 2)
                                .frame(width: 40, height: 40).contentShape(Circle()).liquidGlass(Circle())
                        }
                        Spacer()
                        if isDrawing {
                            Button("Done") { isDrawing = false }.foregroundStyle(.white).fontWeight(.semibold)
                        }
                    }
                    // HIG: inside the safe area, 16pt leading, 12pt below the Dynamic Island / notch.
                    // Higher up, into the top-left corner (clear of the centred Dynamic Island) per request.
                    .padding(.horizontal, 16).padding(.top, max(windowSafeTop - 22, 10))
                    Spacer()
                }
                // …and out of the way while a stroke is under the finger, same as the pen bar below.
                // The X and Done are in the top corners, which is exactly where a drawing runs off.
                // AND DURING TRIM: the trim overlay carries its own X/✓ in the same corners, and
                // the composer's X kept drawing UNDER it — his screenshot showed the two close
                // buttons stacked on top of each other.
                .opacity(draggingID == nil && editingID == nil && !strokeInFlight && !showTrim ? 1 : 0)
                .ignoresSafeArea(.keyboard, edges: .bottom)

                // The bottom bars and the crop overlay are siblings of the canvas, in `body`,
                // which is what lets the keyboard move one without touching the other.
            }
            .onAppear {
                canvasSize = card
                cardBottomGap = max(Self.toolZoneHeight, geo.size.height - cardTop - card.height)
                if items.isEmpty {
                    if seedItems.isEmpty {
                        items = [DraftItem(image: source)]
                    } else {
                        // A hand-off from the video editor: the whole post arrives, the just-picked
                        // picture last — that is the one you continue on. restoreCurrent puts the
                        // arriving item's own state on the tools (a fresh picture: clean tools).
                        items = seedItems
                        index = max(0, items.count - 1)
                        caption = seedCaption
                        restoreCurrent()
                    }
                }
                recomputeEdited()
            }
            .onChange(of: geo.size) { _, s in
                let c = Self.cardSize(in: s, top: cardTop)
                canvasSize = c
                cardBottomGap = max(Self.toolZoneHeight, s.height - cardTop - c.height)
            }
            .onChange(of: filterIndex) { _, _ in recomputeEdited() }
        }
        // THE CANVAS never resizes for the keyboard, and that part was always right: automatic
        // avoidance squished it (user bug 1) and desynced the compact send button's visual frame from
        // its tappable one (user bug 2, taps landed on nothing). What changed is that the BAR is no
        // longer in here with it, so it can be lifted natively instead of by hand. Both old bugs stay
        // fixed and the jump goes with the hand-computed padding. See `body`.
        .ignoresSafeArea(.keyboard)
        .statusBarHidden(false)   // user round 3: the clock/battery must stay visible above the card
        .alert("Couldn't share", isPresented: $postError) { Button("OK", role: .cancel) {} }
        // OUR OWN PICKER, images AND videos, always (owner 2026-08-05: "The + button should always
        // open our custom media picker… Never fall back to Apple's Photo Picker"). It stays open
        // while you tap — each pick lands in the strip behind it — and the X brings you back.
        .sheet(isPresented: $showAddPicker) {
            StoryLibraryPicker(
                // BOTH KINDS CLOSE THE PICKER NOW (owner 2026-08-06: "I chose other image but photo
                // picker still I see it, it most go back Story image editor page"). Video has done
                // this since 2026-08-05; images were deliberately left open for multi-pick, which he
                // had called working at the time. He has changed that — a pick takes you back to the
                // picture you are about to edit, whichever kind it was.
                onImage: { ui in
                    showAddPicker = false
                    appendPicked(image: ui)
                },
                onVideo: { url in
                    showAddPicker = false
                    Task { await appendPicked(video: url) }
                },
                // TICK SEVERAL, ADD ONCE. His 2026-08-07 report: adding one at a time is "soo hard".
                // The batch lands in tap order, and each item goes through the SAME append the single
                // path uses — so every one of them gets `restoreCurrent`'s clean tools rather than
                // the previous picture's crop, which is the trap `759546c` was written for.
                allowsMultiple: true,
                onBatch: { picks in
                    showAddPicker = false
                    Task {
                        for p in picks {
                            switch p {
                            case .image(let ui): await MainActor.run { appendPicked(image: ui) }
                            case .video(let url): await appendPicked(video: url)
                            }
                        }
                    }
                })
        }
        .sheet(item: $pendingShare) { s in
            // Detents/drag-indicator are set INSIDE ShareStorySheet now, so both the photo and text
            // flows get the same compact fitted sheet.
            ShareStorySheet(image: s.data, caption: s.caption, video: s.video, extras: pendingExtras,
                            onPosted: { onPosted(); dismiss() })
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    /// Everything ON the card, built in the CARD's own coordinate space — the same space the
    /// flatten renders, the pen bakes against and the text overlays position in. One space for the
    /// seen and the posted picture is the whole WYSIWYG contract of this screen.
    @ViewBuilder private func cardContent(card: CGSize) -> some View {
        let boxed = !imageFillsCanvas(card)
        ZStack {
            Color.black
            // ⚠️ THE CANVAS THE POST WILL BAKE, not a blur of the photo. WYSIWYG is the whole
            // contract of this screen, and it was broken here in exactly the way the video editor's
            // was: this wash was a big blur + desaturation + dark veil, `flatten` baked a downscaled
            // wash, and the story viewer drew a third thing over the posted file. Three backdrops
            // for one picture, and he framed his photo against whichever one he happened to see.
            //
            // Same sampler and same drawer as `flatten` and as the story viewer — `StoryCanvas` —
            // so what he frames here is the file that lands.
            if boxed {
                LinearGradient(colors: [Color(uiColor: canvasColours.top),
                                        Color(uiColor: canvasColours.bottom)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(width: card.width, height: card.height)
                    .allowsHitTesting(false)
            }
            // Photo: full card width, aspect-fit on the wash. Zoom/pan applied DIRECTLY to a
            // UIImageView's transform in UIKit (no SwiftUI @State write per touch -> zero
            // re-render mid-pinch -> butter smooth, anchored between the fingers). The final
            // scale/offset sync back to photoZoom/photoOffset on release for the WYSIWYG flatten.
            // The UIKit container clips to its own bounds, so a zoomed photo never leaves the card.
            ZoomableImageView(image: edited, scale: $photoZoom, offset: $photoOffset,
                              maxScale: 4, interactive: !isDrawing && editingID == nil,
                              onTap: { captionFocused = false; selectedID = nil },
                              onSwipe: { step in
                                  // ZOOMED IN = a horizontal drag is panning the PICTURE, never
                                  // a page turn (owner 2026-08-05: "if I make zoom, block swipe
                                  // — if I want to swipe I can click thumbnail"). The thumbnails
                                  // remain the way to switch while zoomed.
                                  guard photoZoom <= 1.01 else { return }
                                  // The strip and the swipe are the same move, so they go through
                                  // the same door: select() parks this picture's edits and brings
                                  // the next one's back. Ends of the post simply do not move.
                                  guard items.count > 1, !isDrawing, editingID == nil,
                                        draggingID == nil else { return }
                                  let next = index + step
                                  guard items.indices.contains(next) else { return }
                                  captionFocused = false
                                  withAnimation(.snappy(duration: 0.22)) { select(next) }
                              })
                .frame(width: card.width, height: card.height)

            clipPreview(size: card)
            videoMark

            // Text overlays — above the photo, below the drawing canvas + controls.
            ForEach($overlays) { $o in
                TextOverlayView(
                    overlay: $o,
                    isSelected: selectedID == o.id,
                    canvasSize: canvasSize,
                    interactive: !isDrawing && editingID == nil,
                    onTap: { selectedID = o.id; editingID = o.id },
                    onDragChange: { live in
                        draggingID = o.id
                        let hot = isOverTrash(live)
                        if hot != trashHot { trashHot = hot; if hot { UIImpactFeedbackGenerator(style: .medium).impactOccurred() } }
                    },
                    onDragEnd: { live in
                        if isOverTrash(live) { overlays.removeAll { $0.id == o.id }; selectedID = nil }
                        draggingID = nil; trashHot = false; guideV = false; guideH = false
                    },
                    onSnap: { v, h in
                        if v && !guideV { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                        if h && !guideH { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                        guideV = v; guideH = h
                    }
                )
                .opacity(editingID == o.id ? 0 : 1)   // hide the one being edited (it lives in the editor)
            }

            if isDrawing {
                // Must live in the SAME space (the card) as the photo + overlays + the flatten
                // capture rect, otherwise strokes bake shifted and the bottom band is clipped.
                //
                // OUR PEN, NOT APPLE'S PALETTE (owner 2026-08-03: "use my owner pen"). PencilKit still
                // draws the strokes — it is the drawing engine, not a look — but its tool picker is off
                // and the ink comes from our own bar, exactly as ChatImageEditor has always done it.
                DrawingCanvas(drawing: $drawing, isActive: true,
                              penColor: penHue == 0 ? .white
                                                    : UIColor(hue: penHue, saturation: 1, brightness: 1, alpha: 1),
                              showsToolPicker: false,
                              inkType: isHighlighter ? .marker : .pen,
                              penWidth: penWidth,
                              onStroke: { drawing in
                                  withAnimation(.easeInOut(duration: 0.15)) { strokeInFlight = drawing }
                              })
                    .frame(width: card.width, height: card.height)
            } else if !drawing.bounds.isEmpty {
                // Bug fix: after "Done", keep the markup VISIBLE in the preview (it used to vanish because
                // the canvas only existed in edit mode). Render the saved strokes as a static image, same
                // space + on top, so it persists and matches the flattened export exactly.
                Image(uiImage: drawing.image(from: CGRect(origin: .zero, size: card), scale: UIScreen.main.scale))
                    .resizable()
                    .frame(width: card.width, height: card.height)
                    .allowsHitTesting(false)
            }

            // Center alignment guides + trash zone (only while dragging an overlay).
            if draggingID != nil {
                if guideV { Rectangle().fill(.yellow.opacity(0.9)).frame(width: 1).frame(maxHeight: .infinity).position(x: card.width / 2, y: card.height / 2) }
                if guideH { Rectangle().fill(.yellow.opacity(0.9)).frame(height: 1).frame(maxWidth: .infinity).position(x: card.width / 2, y: card.height / 2) }
                Image(systemName: "trash.fill")
                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(trashHot ? Color.red : .black.opacity(0.5), in: Circle())
                    .scaleEffect(trashHot ? 1.25 : 1)
                    .animation(.spring(response: 0.25, dampingFraction: 0.6), value: trashHot)
                    .position(trashCenter)
            }
        }
        .coordinateSpace(name: "canvas")
    }

    /// The items in this post, bottom right above the caption bar, exactly as he drew them: the one
    /// on screen has a blue frame and an X, the others are plain and switch to when tapped.
    ///
    /// Only when there is more than one. A single thumbnail of the picture already filling the
    /// screen is a picture of what you are looking at.
    /// A video item shows its POSTER here, not moving frames — this editor is built around a picture
    /// and the clip is only played once it reaches the video editor. Without a mark that reads as a
    /// still photo, and you would only find out it was a clip after posting it. The strip already
    /// carries the same badge, so the two agree.
    ///
    /// Its own property, not another branch inside `body`: that ZStack is one branch away from the
    /// type-checker giving up, which is exactly what happened to the video editor's.
    @ViewBuilder private var videoMark: some View {
        if currentIsVideo, !isDrawing, editingID == nil {
            // A REAL BUTTON NOW. It was `allowsHitTesting(false)` — a picture of a play button on a
            // screen with nothing to play, which is exactly what the owner reported. It hides while
            // the clip is running so it does not sit over the video you asked to watch.
            Button { togglePreview() } label: {
                Image(systemName: previewPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 72, height: 72)
                    .background(.black.opacity(0.35), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(previewPlaying ? 0 : 1)
            .animation(.easeInOut(duration: 0.18), value: previewPlaying)
            .transition(.opacity)
        }
    }

    /// The clip itself, over its poster, once there is something to play. Absent for a photo and
    /// absent before the first press, so nothing is decoded until it is wanted.
    @ViewBuilder private func clipPreview(size: CGSize) -> some View {
        if currentIsVideo, let p = previewPlayer {
            ClipPreviewLayer(player: p)
                .frame(width: size.width, height: size.height)
                // THE MOVING PICTURE SITS EXACTLY WHERE THE POSTER SITS. The poster carries the
                // pinch's transform in UIKit; without the same one here, pressing play on a
                // zoomed clip visibly snapped back to 1x — a preview of a framing that was not
                // the one being posted. Same scale-then-offset order as the poster's transform.
                .scaleEffect(photoZoom)
                .offset(photoOffset)
                .allowsHitTesting(false)   // the play/pause button and the canvas keep their taps
                .transition(.opacity)
        }
    }

    /// The player for the clip on screen, built on first need. Returns nil for a photo.
    @discardableResult
    private func ensurePreviewPlayer() -> AVPlayer? {
        if let previewPlayer { return previewPlayer }
        guard items.indices.contains(index), let url = items[index].videoURL else { return nil }
        let p = AVPlayer(url: url)
        p.actionAtItemEnd = .pause
        previewPlayer = p
        return p
    }

    private func togglePreview() {
        guard items.indices.contains(index), let url = items[index].videoURL else { return }
        if previewPlayer == nil {
            let p = AVPlayer(url: url)
            p.actionAtItemEnd = .pause
            previewPlayer = p
            // Back to the start when it finishes, so a second press replays rather than doing nothing.
            NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                   object: p.currentItem, queue: .main) { _ in
                p.seek(to: .zero)
                previewPlaying = false
            }
        }
        if previewPlaying { previewPlayer?.pause() } else { previewPlayer?.play() }
        previewPlaying.toggle()
    }

    /// Leaving a clip, or the screen. An AVPlayer left running behind a photo keeps its audio session
    /// and its decoder, which is the kind of thing that only shows up as a battery complaint.
    private func stopPreview() {
        previewPlayer?.pause()
        previewPlayer = nil
        previewPlaying = false
    }

    @ViewBuilder private var itemStrip: some View {
        if items.count > 1 {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                    Button { select(i) } label: {
                        // SMALLER, AND SQUARE (owner 2026-08-04: "make small… make it also 1:1").
                        // A 52x66 portrait thumb is a small copy of the picture; a square one is a
                        // marker for it, which is what a strip of these is for. scaledToFill still
                        // centre-crops, so nothing stretches.
                        Image(uiImage: it.image)
                            .resizable().scaledToFill()
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(alignment: .bottomLeading) {
                                if it.isVideo {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                        .padding(4)
                                }
                            }
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(i == index ? Color(.systemBlue) : .clear, lineWidth: 2))
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .topTrailing) {
                        // The X removes, and only on the one you are on — an X on every thumbnail
                        // turns a row of pictures into a row of buttons.
                        if i == index {
                            Button { remove(i) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 17))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .offset(x: 6, y: -6)
                        }
                    }
                }
            }
            .padding(.trailing, 4)
            .padding(.bottom, 8)
        }
    }

    /// Add more pictures or videos to this post. Inside the caption bar on the left, where he put it.
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
                // gives the button the full height of the bar as a touch target rather than 19 of it.
                .frame(width: 38, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(StoryPressStyle())
        .accessibilityLabel("Add more photos or videos")
    }

    /// The caption pill (and the thumbnail strip above it), floating ON the card near its bottom
    /// edge — the reference layout ("move the caption bar to the same position shown in the second
    /// reference image"). Its own layer so it can ride the keyboard while the canvas, which ignores
    /// the keyboard, never moves a pixel.
    private var captionLayer: some View {
        VStack(spacing: 12) {
            Spacer()
            if !captionFocused { itemStrip }
            // Caption bar — dark pill. While typing, Send sits beside it so you can post without
            // dismissing the keyboard (it used to hide with the toolbar → no way to send).
            HStack(alignment: .bottom, spacing: 10) {
                captionBar
                // While typing, a SMALL round send button (not the wide NEXT pill) so the caption
                // field keeps most of the width.
                if captionFocused { compactSendButton }
            }
        }
        .padding(.horizontal, 16)
        // At rest the pill sits INSIDE the card, 14pt up from its bottom edge. It used to add 14 to
        // the CONSTANT `toolZoneHeight`, which was the same thing only while the card was always
        // exactly that far off the floor. Now that the card takes the viewer's 9:16 rule it can end
        // higher than that, and a pill measured from the screen would hang below it on the black.
        // Focused, the keyboard is the floor and a small gap is enough.
        .padding(.bottom, captionFocused ? 8 : cardBottomGap + 14)
        .opacity(draggingID == nil && editingID == nil ? 1 : 0)   // trash owns the bottom while dragging text
    }

    /// Aa / crop-or-clip tools + NEXT, on the black band UNDER the card. Pinned: the keyboard never
    /// moves it (it hides while typing instead), so nothing here can push on the canvas.
    private var toolRowLayer: some View {
        VStack {
            Spacer()
            HStack(spacing: 14) {
                // THE TOOLS BELONG TO THE ITEM YOU ARE LOOKING AT, not to the screen.
                //
                // Owner: with a photo on thumbnail 1 and a video on thumbnail 2, tapping the
                // video still brought up the photo's controls. Crop is the one that was actually
                // wrong to offer, and he already ruled on it himself when he had the video editor
                // built: "NO CROP here — that is a photo tool". A clip gets what a clip has
                // instead: its sound, and its length.
                //
                // Aa and the pen stay for both, because they already work on a video — they
                // travel to the export and are composited into the frames there (see
                // `videoBurnIn`). Removing them would take away something that works.
                HStack(spacing: 22) {
                    capsuleTool("textformat", active: false) { addTextOverlay() }   // Aa — add text on either
                    if currentIsVideo {
                        capsuleTool(items[index].muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                    active: items[index].muted) {
                            items[index].muted.toggle()
                        }
                        capsuleTool("scissors", active: items[index].isTrimmed) { openTrim() }
                    } else {
                        capsuleTool("crop", active: croppedSource != nil) {
                            withAnimation(.easeInOut(duration: 0.28)) { showCrop = true }
                        }
                    }
                    capsuleTool(isDrawing ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle", active: isDrawing) { isDrawing.toggle() }
                    // NO EXTRA TOOL beyond these. It used to carry a second "add another
                    // picture", kept on the reasoning that two doors to one action beat two doors
                    // to two different ones. He has now seen both and called it: "remove the
                    // bottom Upload Story button because it is a duplicate. Keep the one in the
                    // caption bar exactly as it is."
                }
                .padding(.horizontal, 20).frame(height: 46)   // user spec: 46px
                .liquidGlass(Capsule())   // real Apple Liquid Glass capsule (not a flat dark fill)

                Spacer()
                sendButton
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .opacity(!captionFocused && draggingID == nil && editingID == nil ? 1 : 0)
    }

    /// The caption field in its glass pill, exactly as it was inside the old bottom bar.
    private var captionBar: some View {
        HStack(spacing: 6) {
            addMoreButton
            // Grows with the text (up to 5 lines) instead of staying a single truncated line.
            TextField("", text: $caption, prompt: Text("Add a caption…").foregroundColor(Color.white.opacity(0.6)), axis: .vertical)
                .foregroundStyle(.white).focused($captionFocused)
                // ...and the text itself carries a hairline shadow so it reads on white.
                .shadow(color: .black.opacity(0.45), radius: 1.5)
                .lineLimit(1...5)
                // The text carries its own breathing room instead of the bar padding it. One
                // line is then 34 tall, under the 40 the + pins, so the resting bar is exactly
                // 40 and a long caption still grows from there.
                .padding(.vertical, 6)
                .onChange(of: caption) { _, v in if v.count > 700 { caption = String(v.prefix(700)) } }  // cap like the text composer
        }
        // EXACTLY 40 AT REST (owner spec). It was 50: the + is a 32pt square and the bar
        // added 9pt of its own padding above and below it, so `minHeight: 40` never bit —
        // the content was already taller than the floor it was being held to. The + now
        // measures 40 itself, which sets the height and keeps a full-height touch target.
        .padding(.leading, 6).padding(.trailing, 18).frame(minHeight: 40)
        // LIQUID GLASS, TINTED DARK (owner 2026-08-03: "in story caption bar make it liquid
        // glass"). Plain glass was here once and came back off: on a bright photo it went pale
        // and the white placeholder disappeared into it, which he photographed. `tint` is
        // Apple's own glass tint, so this is still real glass and not a dark pill pretending —
        // it just carries enough of its own darkness that white text always has something to
        // sit on. The text keeps its hairline shadow for the same reason.
        // Rounder, on his word (2026-08-04). Not a Capsule: this bar GROWS to five lines
        // when the caption is long, and a capsule's ends become huge lozenges as it does.
        // 26 reads as a pill at resting height and still looks deliberate when it is tall.
        .liquidGlass(RoundedRectangle(cornerRadius: 26, style: .continuous),
                     tint: .black.opacity(0.28))
        // Light photos made the white caption text invisible (user screenshot: white-on-
        // white). A soft bar shadow lifts the pill off bright backgrounds...
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }

    /// TRIM, for a video item in a multi-item post. Reuses `VideoTrimStrip`, which is the same strip
    /// the video editor and VideoApprovalView drive — his standing instruction was "do not build a
    /// new trim system", and there is nothing here a second one would do better.
    ///
    /// It does not preview frames while you drag, because this screen has no player: a video item
    /// shows its poster with a play mark. The filmstrip and the handles are real, and the cut is
    /// applied once at post time by the same export path the video editor uses. If he wants the live
    /// scrub as well, that means an AVPlayer on this screen, which is a bigger piece and is worth
    /// asking about rather than assuming.
    @ViewBuilder private var trimOverlay: some View {
        if showTrim, items.indices.contains(index), items[index].isVideo {
            let dur = max(0.1, items[index].duration)
            VStack {
                HStack {
                    // X puts the handles back where they were; Done keeps them. Neither may leave
                    // half a cut behind, which is the rule the video editor's trim already follows.
                    Button { closeTrim(keep: false) } label: {
                        Image(systemName: "xmark").font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white).frame(width: 44, height: 44)
                            .contentShape(Circle()).liquidGlass(Circle())
                    }
                    Spacer()
                    Button { closeTrim(keep: true) } label: {
                        Image(systemName: "checkmark").font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white).frame(width: 44, height: 44)
                            .liquidGlass(Circle(), interactive: true, tint: Color(.systemBlue))
                            .contentShape(Circle())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, max(windowSafeTop - 22, 10))
                Spacer()
                // REAL BINDINGS NOW, not `.constant`. Dragging a handle seeks the clip, so you can
                // see the frame you are cutting on — which is the whole reason a trim screen has a
                // picture above it. It was blind because the composer had no player; it has one.
                VideoTrimStrip(duration: dur, thumbnails: trimThumbs,
                               trimStart: $trimStart, trimEnd: $trimEnd,
                               playhead: $trimPlayhead, scrubTime: $trimScrub,
                               playing: $previewPlaying, draggingPlayhead: $trimDragging)
                    .frame(height: 56)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 28)
                    // Reserve the slot rather than let a late filmstrip shove the layout up.
                    .opacity(trimThumbs.isEmpty ? 0 : 1)
            }
            .background(Color.black.opacity(0.55).ignoresSafeArea())
            .transition(.opacity)
            .task(id: items[index].id) { await loadTrimThumbs() }
            // The strip reports where the finger is; the clip goes there. `.zero` tolerance because a
            // scrub that lands on "somewhere near" is a scrub you cannot trust to cut on.
            .onChange(of: trimScrub) { _, t in
                guard let t, let p = ensurePreviewPlayer() else { return }
                p.pause(); previewPlaying = false
                p.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                       toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
    }

    private func openTrim() {
        guard items.indices.contains(index), items[index].isVideo else { return }
        trimStart = items[index].trimStart
        trimEnd = items[index].trimEnd > 0 ? items[index].trimEnd : items[index].duration
        trimOpenedStart = trimStart
        trimOpenedEnd = trimEnd
        withAnimation(.easeInOut(duration: 0.28)) { showTrim = true }
    }

    private func closeTrim(keep: Bool) {
        if keep, items.indices.contains(index) {
            items[index].trimStart = trimStart
            items[index].trimEnd = trimEnd
        } else {
            trimStart = trimOpenedStart; trimEnd = trimOpenedEnd
        }
        trimThumbs = []
        withAnimation(.easeInOut(duration: 0.28)) { showTrim = false }
    }

    /// Ten frames across the clip — the same filmstrip recipe the video editor's trim uses.
    private func loadTrimThumbs() async {
        guard items.indices.contains(index), let u = items[index].videoURL else { return }
        let dur = max(0.1, items[index].duration)
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: u))
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .positiveInfinity
        gen.maximumSize = CGSize(width: 160, height: 160)
        let count = 10
        var imgs: [UIImage] = []
        for i in 0..<count {
            let t = CMTime(seconds: dur * Double(i) / Double(count - 1), preferredTimescale: 600)
            if let cg = try? await gen.image(at: t).image { imgs.append(UIImage(cgImage: cg)) }
        }
        let done = imgs
        await MainActor.run { trimThumbs = done }
    }

    /// Crop, presented INLINE with a cross-fade — the chat editor's own `cropOverlay`, move for move
    /// (owner 2026-08-03: "make the animation like when i stay edit page then i click crop").
    ///
    /// It was a fullScreenCover, which slides up from the bottom like a new screen; cropping is not
    /// somewhere you go, it is something you do to the picture in front of you, and a cross-fade in
    /// place says that.
    ///
    /// AND IT FIXES THE X IN THE STATUS BAR, which is the same report. The cover carried an
    /// `.ignoresSafeArea()` left over from the library cropper that used to live there and wanted
    /// full bleed. ChatCropView paints its own black to the edges and places its X and its Done with
    /// `safeAreaInset`, so telling it to ignore the safe area drove the top bar under the clock.
    /// Inline, it sits in this screen's own safe area exactly as it does inside the chat.
    @ViewBuilder private var cropOverlay: some View {
        if showCrop {
            // From the CURRENT cropped result when there is one, so re-opening crop refines instead
            // of resetting to the original.
            ChatCropView(image: croppedSource ?? current, inline: true,
                         onClose: { withAnimation(.easeInOut(duration: 0.28)) { showCrop = false } },
                         onRect: { r in
                             // Re-cropping refines the crop you already have, so the new rectangle is
                             // read INSIDE the old one rather than against the original — otherwise a
                             // second pass would jump back out to the full frame and lose the first.
                             if let old = cropRect {
                                 cropRect = CGRect(x: old.minX + r.minX * old.width,
                                                   y: old.minY + r.minY * old.height,
                                                   width: r.width * old.width,
                                                   height: r.height * old.height)
                             } else {
                                 cropRect = r
                             }
                         }) { cropped in
                croppedSource = cropped
                recomputeEdited()
            }
            // THE SECOND HALF OF THE MOVE: the controls arrive AFTER the picture has started
            // getting out of the way. The delay is what makes it read as one gesture instead of two
            // things happening at once — 0.10s in, which is a third of the zoom, so the crop frame
            // lands while the canvas is still settling rather than after it has stopped.
            //
            // Asymmetric on purpose: closing has nothing to wait for, so it goes at once and the
            // canvas grows back underneath it.
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .center))
                    .animation(.easeOut(duration: 0.26).delay(0.10)),
                removal: .opacity.animation(.easeIn(duration: 0.16))))
            .zIndex(20)
        }
    }

    /// OUR pen bar, the same one the chat's image editor uses: a colour track, undo, pen vs
    /// highlighter, a width that cycles, and a tick to finish. Nothing here is Apple's palette.
    private var penBar: some View {
        let currentColor = penHue == 0 ? Color.white : Color(hue: penHue, saturation: 1, brightness: 1)
        return VStack(spacing: 14) {
            GradientSlider(value: $penHue, track: LinearGradient(
                colors: [.white] + stride(from: 0.02, through: 1.0, by: 0.08).map { Color(hue: $0, saturation: 1, brightness: 1) },
                startPoint: .leading, endPoint: .trailing))
                .padding(.horizontal, 20)
            HStack(spacing: 12) {
                penTool("arrow.uturn.backward") {
                    var strokes = drawing.strokes
                    if !strokes.isEmpty { strokes.removeLast(); drawing = PKDrawing(strokes: strokes) }
                }
                penTool("pencil.tip", active: !isHighlighter) { isHighlighter = false }
                penTool("highlighter", active: isHighlighter) { isHighlighter = true }
                Button { penWidth = penWidth >= 16 ? 4 : penWidth + 6 } label: {
                    Circle().fill(currentColor).frame(width: min(penWidth + 6, 26), height: min(penWidth + 6, 26))
                        .frame(width: 44, height: 44)
                        .liquidGlass(Circle(), interactive: true).contentShape(Circle())
                }
                .buttonStyle(.plain)
                Spacer()
                Button { isDrawing = false } label: {
                    Image(systemName: "checkmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                        .environment(\.colorScheme, .dark)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
        }
    }

    private func penTool(_ icon: String, active: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 17, weight: .medium))
                .foregroundStyle(active ? Color(hex: 0x3DA1FD) : .primary)
                .frame(width: 44, height: 44)
                .liquidGlass(Circle(), interactive: true).contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // Plain icon button inside the dark tool capsule (no per-button background — the capsule is the bg).
    @ViewBuilder
    private func capsuleTool(_ icon: String, active: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 20, weight: .medium))
                .foregroundStyle(active ? .green : .white)
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(StoryPressStyle())
    }

    // Shared green Send — used in the toolbar (idle) AND beside the caption (while typing).
    // Compact round send used beside the caption while the keyboard is open (keeps the field wide).
    private var compactSendButton: some View {
        Button {
            // Presenting the share sheet WHILE the keyboard is dismissing silently failed
            // (tap closed the keyboard, no sheet). Resign first, let it settle, then send.
            captionFocused = false
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                await send()
            }
        } label: {
            Group {
                if posting { ProgressView().tint(.white) }
                else { Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold)) }
            }
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .liquidGlass(Circle(), interactive: true, tint: Color(.systemBlue))
        }
        .buttonStyle(StoryPressStyle()).disabled(posting)
    }

    private var sendButton: some View {
        Button { Task { await send() } } label: {
            HStack(spacing: 4) {
                if posting {
                    ProgressView().tint(.white)
                } else {
                    Text("NEXT").font(.system(size: 16, weight: .semibold))
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 22).frame(height: 46)   // user spec: 46px
            // Blue-tinted real Liquid Glass (prominent action), not a flat blue fill.
            .liquidGlass(Capsule(), interactive: true, tint: Color(.systemBlue))
            // WHOLE PILL tappable (user: only the "NEXT" text responded). Without an explicit
            // contentShape, SwiftUI hit-tests only the opaque text/chevron, not the padded capsule.
            .contentShape(Capsule())
        }
        .buttonStyle(StoryPressStyle()).disabled(posting)
    }

    // MARK: - Text overlays
    private var trashCenter: CGPoint { CGPoint(x: canvasSize.width / 2, y: canvasSize.height - 110) }
    private func isOverTrash(_ p: CGPoint) -> Bool { hypot(p.x - trashCenter.x, p.y - trashCenter.y) < 64 }
    private func addTextOverlay() {
        captionFocused = false
        let o = TextOverlay(center: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2))
        overlays.append(o)
        selectedID = o.id
        editingID = o.id   // open the editor immediately
    }
    private func trimEmpty(_ id: UUID) {
        if let idx = overlays.firstIndex(where: { $0.id == id }),
           overlays[idx].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            overlays.remove(at: idx); selectedID = nil
        }
    }

    // MARK: - Items

    /// Park the live tool state back on the item it belongs to. NOTHING IS FLATTENED: the picture is
    /// left as it came in and the edits are stored next to it, so coming back finds the crop still a
    /// crop you can change and the strokes still strokes you can undo.
    @MainActor private func stashCurrent() {
        guard items.indices.contains(index) else { return }
        items[index].cropped = croppedSource
        items[index].cropRect = cropRect
        items[index].filterIndex = filterIndex
        items[index].drawing = drawing
        items[index].overlays = overlays
        items[index].zoom = photoZoom
        items[index].offset = photoOffset
    }

    /// The mirror image: put an item's edits back on the tools.
    @MainActor private func restoreCurrent() {
        guard items.indices.contains(index) else { return }
        let it = items[index]
        croppedSource = it.cropped
        cropRect = it.cropRect
        filterIndex = it.filterIndex
        drawing = it.drawing
        overlays = it.overlays
        photoZoom = it.zoom
        photoOffset = it.offset
        selectedID = nil; editingID = nil
        recomputeEdited()
    }

    private func select(_ i: Int) {
        guard i != index, items.indices.contains(i) else { return }
        // The player belongs to the clip you were on. Carrying it to the next item would leave a
        // video playing under somebody else's photo, with its audio still going.
        stopPreview()
        stashCurrent()
        index = i
        restoreCurrent()
    }

    private func remove(_ i: Int) {
        guard items.count > 1, items.indices.contains(i) else { return }
        items.remove(at: i)
        if index >= items.count { index = items.count - 1 }
        else if i < index { index -= 1 }
        recomputeEdited()
    }

    // MARK: - Send
    private func send() async {
        posting = true
        stashCurrent()
        let keep = index

        // EVERY item is rendered HERE, at post time, from the edits stored beside it — which is what
        // being able to un-crop after switching costs: the work moves from "on the way out of an
        // item" to "once, when you actually post". `flatten` composes from the tool state rather
        // than from what is on screen, so restoring an item is enough to render it correctly.
        var rendered: [(data: Data, video: URL?, burn: StoryBurnIn?, muted: Bool, trim: ClosedRange<Double>?)] = []
        for i in items.indices {
            index = i
            restoreCurrent()
            if let u = items[i].videoURL {
                // A VIDEO'S EDITS ARE NOT DISCARDED ANY MORE (owner 2026-08-04). Aa, crop and pen were
                // offered on a video and then silently dropped at post time, which is worse than not
                // offering them. They cannot be flattened into a picture, so they travel as far as the
                // export and are composited into the frames there — see VideoTranscoder.burnIn.
                let burn = await videoBurnIn()
                rendered.append((items[i].image.jpegData(compressionQuality: 0.72) ?? Data(), u, burn,
                                 items[i].muted, items[i].trimRange))
                continue
            }
            rendered.append((await flatten(), nil, nil, false, nil))
        }
        index = keep
        restoreCurrent()
        posting = false

        let data = rendered.first?.data ?? Data()
        guard !data.isEmpty else { postError = true; return }   // never hand off a zero-byte (broken) image

        var extras: [StoryExtra] = []
        for r in rendered.dropFirst() {
            if let u = r.video {
                extras.append(StoryExtra(video: StoryVideoPayload(url: u, thumbnail: r.data,
                                                                 muted: r.muted, trim: r.trim, burn: r.burn)))
            } else {
                extras.append(StoryExtra(photo: r.data))
            }
        }
        // THE FIRST ITEM'S CLIP IS NO LONGER THROWN AWAY. `StoryShareData` carried only `data`, which
        // for a video is its poster, so a post whose first item was a video posted a still of it.
        // Reachable today: pick a photo, add a video, delete the photo with the X on the strip.
        let leadVideo = rendered.first.flatMap { r -> StoryVideoPayload? in
            guard let u = r.video else { return nil }
            return StoryVideoPayload(url: u, thumbnail: r.data, muted: r.muted, trim: r.trim, burn: r.burn)
        }
        // Caption travels as TEXT (rendered as an overlay in the viewer), NOT baked into the photo —
        // baking it clipped the text when the image was cropped to fit.
        pendingShare = StoryShareData(data: data,
                                      caption: caption.trimmingCharacters(in: .whitespacesAndNewlines),
                                      video: leadVideo)
        pendingExtras = extras
    }

    /// Everything drawn on top of a VIDEO, in one transparent image the size of the canvas it was
    /// drawn on, plus the crop rectangle.
    ///
    /// Deliberately the same builder and the same transforms as `flatten` uses for a photo, so the two
    /// cannot drift apart and have text land in one place on a picture and another on a clip. What it
    /// does NOT draw is the picture itself — the frames are the picture, and painting the poster in
    /// would freeze the first frame over the whole video.
    @MainActor private func videoBurnIn() async -> StoryBurnIn? {
        let size = canvasSize == .zero ? UIScreen.main.bounds.size : canvasSize
        // THE PINCH IS THE VIDEO'S CROP TOOL. A zoomed/panned clip LOOKED reframed in here and
        // then uploaded with its original framing — photoZoom/photoOffset were never read on this
        // path, only the photo flatten's. That was the owner's report word for word: "the Story
        // displays the original, unedited frame." The zoom becomes the transcoder's crop rectangle
        // below, which is the mechanism it has always had for exactly this.
        let reframed = photoZoom > 1.001 || abs(photoOffset.width) > 0.5 || abs(photoOffset.height) > 0.5
        let hasArt = !drawing.bounds.isEmpty || !overlays.isEmpty
        guard hasArt || cropRect != nil || reframed else { return nil }

        var art: UIImage?
        if hasArt {
            let composed = ZStack(alignment: .bottom) {
                Color.clear
                if !drawing.bounds.isEmpty {
                    Image(uiImage: drawing.image(from: CGRect(origin: .zero, size: size), scale: UIScreen.main.scale))
                        .resizable()
                }
                ForEach(overlays) { o in
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

        var crop = cropRect   // legacy path: the tool that could set this is no longer offered on video
        if reframed {
            // The same maths the photo flatten uses, ending in the transcoder's terms. The export
            // canvas is geometrically similar to this card (same aspect travels below) and fits the
            // clip exactly as scaledToFit does, so the poster's fitted rect here IS the clip's
            // fitted rect there, normalised. The kept piece is the editor viewport, intersected
            // with the clip's own zoomed footprint — the black bands outside the picture are
            // cropped away, the same call the photo flatten already makes, so the viewer letterboxes
            // a reframed clip with its live blur exactly like an untouched one.
            let z = max(1, photoZoom)
            let fit = photoFitSize(in: size)
            let fitRect = CGRect(x: (size.width - fit.width) / 2, y: (size.height - fit.height) / 2,
                                 width: fit.width, height: fit.height)
            let vRect = CGRect(x: size.width / 2 + photoOffset.width - fit.width * z / 2,
                               y: size.height / 2 + photoOffset.height - fit.height * z / 2,
                               width: fit.width * z, height: fit.height * z)
            let visible = vRect.intersection(CGRect(origin: .zero, size: size))
            if visible.width > 1, visible.height > 1 {
                // The viewport, mapped back onto the UNZOOMED clip inside the canvas.
                let inCanvas = CGRect(x: fitRect.minX + (visible.minX - vRect.minX) / z,
                                      y: fitRect.minY + (visible.minY - vRect.minY) / z,
                                      width: visible.width / z, height: visible.height / z)
                crop = CGRect(x: inCanvas.minX / size.width, y: inCanvas.minY / size.height,
                              width: inCanvas.width / size.width, height: inCanvas.height / size.height)
                // Text and pen were drawn over the ZOOMED clip, but the export paints them onto the
                // unzoomed canvas and then magnifies the kept rectangle. Re-project the art into
                // that rectangle so it comes back out exactly where — and exactly as big as — the
                // editor showed it. Without this, a caption on a zoomed clip drifted and doubled in
                // size on upload.
                if let a = art {
                    let fmt = UIGraphicsImageRendererFormat()
                    fmt.scale = a.scale; fmt.opaque = false
                    art = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
                        a.draw(in: inCanvas)
                    }
                }
            }
        }
        return StoryBurnIn(overlay: art, cropRect: crop,
                           canvasAspect: size.height > 0 ? size.width / size.height : nil)
    }

    @MainActor private func flatten() async -> Data {
        let base = edited
        let quality: CGFloat = 0.9
        let size = canvasSize == .zero ? UIScreen.main.bounds.size : canvasSize
        // THE FAST PATH IS NOW ALSO A "DOES IT FILL" TEST. Nothing to draw, nothing to type, no
        // zoom AND the photo already fills the frame → post it untouched at full resolution, which
        // keeps a 9:16 photo off the renderer and out of a re-encode.
        //
        // A photo that does NOT fill can no longer take that path, and that is the whole change on
        // this side: it goes through the composition below so the CANVAS IS BAKED INTO THE POSTED
        // FILE. Telegram exports every story as a full 1080x1920 frame with the gradient already in
        // it, which is why their viewer never has to invent a background and never gets it wrong.
        // Ours posted the bare photo and left the viewer to letterbox it live at watch time — that
        // live backdrop is the thing that tore while he scrolled, and a file that fills the frame
        // never asks for one.
        let zoomed = abs(photoZoom - 1) > 0.001 || abs(photoOffset.width) > 0.5 || abs(photoOffset.height) > 0.5
        if drawing.bounds.isEmpty && overlays.isEmpty && !zoomed && imageFillsCanvas(size) {
            return base.jpegData(compressionQuality: quality) ?? Data()
        }
        // BAKED AT THE CARD'S OWN SIZE, which is the space the pen drew in and the text overlays are
        // positioned in, so what he framed is byte-for-byte what lands. On every full-size phone the
        // card IS 9:16 and so is this file, which is the whole point — it fills a story frame and no
        // viewer ever has to invent a background for it.
        //
        // On a short phone the card is `min(9:16, the room there is)` and the file comes out
        // slightly squat, so a 9:16 viewer still draws a canvas behind it. That is fine, and it is
        // fine only because of the one-sampler rule: the canvas the viewer draws is the SAME
        // gradient from the SAME two colours this bake would have used, so the two are
        // indistinguishable. Forcing the file to 9:16 instead would buy nothing visible and would
        // cost this editor its WYSIWYG on exactly the devices with the least room to spare.
        let colours = canvasColours
        let composed = ZStack(alignment: .bottom) {
            LinearGradient(colors: [Color(uiColor: colours.top), Color(uiColor: colours.bottom)],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: size.width, height: size.height)
            // Foreground photo with the SAME fit + zoom + pan as the editor → WYSIWYG.
            Image(uiImage: base).resizable().scaledToFit()
                .scaleEffect(photoZoom).offset(photoOffset)
                .frame(width: size.width, height: size.height).clipped()
            if !drawing.bounds.isEmpty {
                Image(uiImage: drawing.image(from: CGRect(origin: .zero, size: size), scale: UIScreen.main.scale)).resizable()
            }
            // Bake the text overlays — same builder + transforms as on-screen → WYSIWYG.
            ForEach(overlays) { o in
                storyStyledText(o, maxWidth: size.width * 0.9)
                    .scaleEffect(o.scale)
                    .rotationEffect(o.rotation)
                    .position(o.center)
            }
            // (Caption is NOT baked here — it's posted as text and drawn as an overlay.)
        }
        .frame(width: size.width, height: size.height)
        let r = ImageRenderer(content: composed); r.scale = UIScreen.main.scale
        // The render is the story. There is no crop-back any more (see the note below), so the only
        // fallback left is the untouched photo, for a renderer that returned nothing at all.
        return r.uiImage?.jpegData(compressionQuality: quality)
            ?? base.jpegData(compressionQuality: quality) ?? Data()
    }

    // `flattenBackdrop` lived here: the photo aspect-filled into an eighth-size canvas and darkened
    // by 0.38, which is a blur by downscale. It is gone with the rest of the blur system. The posted
    // file's backdrop is `StoryCanvas`'s gradient now, drawn straight into the composition above
    // from the same two colours the editor card shows and the story viewer would draw.
    //
    // The CROP-BACK went with it, and that is the more important half. The bake used to be undone
    // for anything except a pinched-out photo: the canvas was rendered, then cut back to the
    // photo's own rectangle, so the posted file was the bare picture again and the viewer had to
    // invent a background for it at watch time. Every story now lands as a full frame, which is
    // Telegram's model and the reason their viewer has no backdrop code to go wrong.

    // The picture's aspect-fit size within the canvas — the photo frame's real footprint.
    private func photoFitSize(in canvas: CGSize) -> CGSize {
        let iw = edited.size.width, ih = edited.size.height
        guard iw > 0, ih > 0 else { return canvas }
        let s = min(canvas.width / iw, canvas.height / ih)
        return CGSize(width: iw * s, height: ih * s)
    }
    // Edge-to-edge photos keep the plain full-bleed canvas (no backdrop, no rounding).
    private func imageFillsCanvas(_ canvas: CGSize) -> Bool {
        let f = photoFitSize(in: canvas)
        return f.width >= canvas.width - 1 && f.height >= canvas.height - 1
    }

    // MARK: - Image ops
    private static func apply(_ filterName: String?, to image: UIImage) -> UIImage {
        guard let filterName, let ci = CIImage(image: image),
              let filter = CIFilter(name: filterName) else { return image }
        filter.setValue(ci, forKey: kCIInputImageKey)
        guard let out = filter.outputImage, let cg = ciContext.createCGImage(out, from: out.extent) else { return image }
        return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
    }

    // Sample the edited photo's top + bottom bands so the controls flip dark over a light region.
    private func updateIconContrast() {
        let img = edited
        topIconDark = Self.regionIsLight(img, top: true)
        bottomIconDark = Self.regionIsLight(img, top: false)
    }
    private static func regionIsLight(_ image: UIImage, top: Bool) -> Bool {
        guard let cg = image.cgImage else { return false }
        let w = cg.width, h = cg.height
        let band = max(1, h / 4)
        let rect = top ? CGRect(x: 0, y: 0, width: w, height: band)
                       : CGRect(x: 0, y: h - band, width: w, height: band)
        guard let crop = cg.cropping(to: rect) else { return false }
        let ci = CIImage(cgImage: crop)
        guard let f = CIFilter(name: "CIAreaAverage",
                               parameters: [kCIInputImageKey: ci, kCIInputExtentKey: CIVector(cgRect: ci.extent)]),
              let out = f.outputImage else { return false }
        var px = [UInt8](repeating: 0, count: 4)
        ciContext.render(out, toBitmap: &px, rowBytes: 4,
                         bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let lum = 0.299 * Double(px[0]) + 0.587 * Double(px[1]) + 0.114 * Double(px[2])
        return lum > 150   // light region → dark icons
    }
}

// MARK: - Text-on-photo overlay (modern style)

struct TextOverlay: Identifiable, Equatable {
    let id = UUID()
    var text: String = ""
    var center: CGPoint                 // in canvasSize coordinates → WYSIWYG with flatten
    var scale: CGFloat = 1
    var rotation: Angle = .zero
    var color: Color = .white
    var alignment: TextAlignment = .center
    var font: FontStyle = .rounded
    var background: BgStyle = .plain
    var baseSize: CGFloat = 34

    enum FontStyle: String, CaseIterable, Equatable {
        case rounded, classic, serif, mono
        var design: Font.Design {
            switch self {
            case .rounded: return .rounded
            case .classic: return .default
            case .serif:   return .serif
            case .mono:    return .monospaced
            }
        }
    }
    enum BgStyle: String, CaseIterable, Equatable { case plain, semi, solid }
}

// Shared styled text — used BOTH on-screen and in flatten() so export == screen.
@ViewBuilder
func storyStyledText(_ o: TextOverlay, maxWidth: CGFloat) -> some View {
    Text(o.text.isEmpty ? " " : o.text)
        .font(.system(size: o.baseSize, weight: .semibold, design: o.font.design))
        .multilineTextAlignment(o.alignment)
        .foregroundStyle(o.background == .solid ? Color.black : o.color)
        .padding(.horizontal, o.background == .plain ? 6 : 14)
        .padding(.vertical, o.background == .plain ? 2 : 8)
        .background {
            switch o.background {
            case .plain: Color.clear
            case .semi:  RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.38))
            case .solid: RoundedRectangle(cornerRadius: 10).fill(o.color)
            }
        }
        .shadow(color: .black.opacity(o.background == .plain ? 0.55 : 0), radius: 3, y: 1)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: maxWidth)
}

// One draggable / pinchable / rotatable / tappable text overlay.
struct TextOverlayView: View {
    @Binding var overlay: TextOverlay
    let isSelected: Bool
    let canvasSize: CGSize
    let interactive: Bool
    var onTap: () -> Void
    var onDragChange: (CGPoint) -> Void
    var onDragEnd: (CGPoint) -> Void
    var onSnap: (Bool, Bool) -> Void

    @GestureState private var dragT: CGSize = .zero
    @GestureState private var gScale: CGFloat = 1
    @GestureState private var gRot: Angle = .zero

    private func snappedPure(_ p: CGPoint) -> CGPoint {
        let cx = canvasSize.width / 2, cy = canvasSize.height / 2, t: CGFloat = 12
        var out = p
        if abs(p.x - cx) < t { out.x = cx }
        if abs(p.y - cy) < t { out.y = cy }
        return out
    }
    private var liveCenter: CGPoint {
        snappedPure(CGPoint(x: overlay.center.x + dragT.width, y: overlay.center.y + dragT.height))
    }
    private var liveScale: CGFloat { max(0.3, overlay.scale * gScale) }
    private var liveRot: Angle { overlay.rotation + gRot }

    var body: some View {
        storyStyledText(overlay, maxWidth: canvasSize.width * 0.9)
            .scaleEffect(liveScale)
            .rotationEffect(liveRot)
            // (No dashed selection border — removed per request; the text just shows plainly while editing.)
            .position(liveCenter)
            .allowsHitTesting(interactive)
            .highPriorityGesture(TapGesture().onEnded { onTap() })
            .gesture(transform, including: interactive ? .all : .none)
    }

    private var transform: some Gesture {
        let drag = DragGesture(minimumDistance: 2, coordinateSpace: .named("canvas"))
            .updating($dragT) { v, s, _ in s = v.translation }
            .onChanged { v in
                let raw = CGPoint(x: overlay.center.x + v.translation.width, y: overlay.center.y + v.translation.height)
                let cx = canvasSize.width / 2, cy = canvasSize.height / 2, t: CGFloat = 12
                onSnap(abs(raw.x - cx) < t, abs(raw.y - cy) < t)
                onDragChange(snappedPure(raw))
            }
            .onEnded { v in
                let nc = snappedPure(CGPoint(x: overlay.center.x + v.translation.width, y: overlay.center.y + v.translation.height))
                overlay.center = nc
                onDragEnd(nc)
            }
        let mag = MagnifyGesture()
            .updating($gScale) { v, s, _ in s = v.magnification }
            .onEnded { v in overlay.scale = max(0.3, overlay.scale * v.magnification) }
        let rot = RotateGesture()
            .updating($gRot) { v, s, _ in s = v.rotation }
            .onEnded { v in overlay.rotation += v.rotation }
        return SimultaneousGesture(drag, SimultaneousGesture(mag, rot))
    }
}

// Full-screen text editor: focused field + font/color/align/bg controls.
struct TextEditorOverlay: View {
    @Binding var draft: TextOverlay
    var onCancel: () -> Void
    var onDone: () -> Void
    @FocusState private var focused: Bool

    private let palette: [Color] = [.white, .black, .red, .orange, .yellow, .green, .blue, .purple, .pink]
    private func nextAlign(_ a: TextAlignment) -> TextAlignment { a == .leading ? .center : a == .center ? .trailing : .leading }
    private func alignIcon(_ a: TextAlignment) -> String { a == .leading ? "text.alignleft" : a == .center ? "text.aligncenter" : "text.alignright" }
    private func nextBg(_ b: TextOverlay.BgStyle) -> TextOverlay.BgStyle { b == .plain ? .semi : b == .semi ? .solid : .plain }

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea().onTapGesture { onDone() }
            VStack {
                HStack {
                    Button("Cancel") { onCancel() }.foregroundStyle(.white)
                    Spacer()
                    Button { draft.alignment = nextAlign(draft.alignment) } label: {
                        Image(systemName: alignIcon(draft.alignment)).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 44, height: 44).background(.white.opacity(0.16), in: Circle()).contentShape(Circle())
                    }
                    Button { draft.background = nextBg(draft.background) } label: {
                        Image(systemName: "a.square").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.white.opacity(draft.background == .plain ? 0.16 : 0.34), in: Circle()).contentShape(Circle())
                    }
                    Spacer()
                    Button("Done") { onDone() }.foregroundStyle(.white).fontWeight(.semibold)
                }
                .padding()
                Spacer()
                TextField("", text: $draft.text, prompt: Text("Type…").foregroundColor(.white.opacity(0.5)), axis: .vertical)
                    .focused($focused)
                    .multilineTextAlignment(draft.alignment)
                    .font(.system(size: draft.baseSize, weight: .semibold, design: draft.font.design))
                    .foregroundStyle(draft.background == .solid ? Color.black : draft.color)
                    .tint(.white)
                    .padding(draft.background == .plain ? 6 : 14)
                    .background {
                        switch draft.background {
                        case .plain: Color.clear
                        case .semi:  RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.38))
                        case .solid: RoundedRectangle(cornerRadius: 10).fill(draft.color)
                        }
                    }
                    .frame(maxWidth: 320)
                    .contentShape(Rectangle())          // tap anywhere on the text block, not just the glyphs
                    .onTapGesture { focused = true }
                Spacer()
                VStack(spacing: 14) {
                    HStack(spacing: 14) {
                        ForEach(TextOverlay.FontStyle.allCases, id: \.self) { fs in
                            Text("Aa").font(.system(size: 16, weight: .semibold, design: fs.design))
                                .foregroundStyle(draft.font == fs ? Color.black : .white)
                                .frame(width: 42, height: 30)
                                .background(draft.font == fs ? Color.white : Color.white.opacity(0.15), in: Capsule())
                                .onTapGesture { draft.font = fs }
                        }
                    }
                    HStack(spacing: 12) {
                        ForEach(palette, id: \.self) { c in
                            Circle().fill(c).frame(width: 28, height: 28)
                                .overlay(Circle().strokeBorder(.white, lineWidth: draft.color == c ? 3 : 1))
                                .onTapGesture { draft.color = c }
                        }
                    }
                }
                .padding(.bottom, 24)
            }
        }
        .onAppear { focused = true }
    }
}

// Springy press feedback for the story-editor controls.
/// An AVPlayerLayer sized to its view. Deliberately tiny: the composer needs to SEE the clip, and a
/// full `AVPlayerViewController` would bring its own controls, its own gestures and its own idea of
/// full screen to a canvas that already has three tools competing for the same touches.
struct ClipPreviewLayer: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.backgroundColor = .clear
        v.playerLayer.videoGravity = .resizeAspect   // the poster underneath is aspect-fit too
        v.playerLayer.player = player
        return v
    }

    func updateUIView(_ v: LayerView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
    }
}

struct StoryPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// Smooth editor zoom/pan: a UIImageView pinned to fill the container (Auto Layout) whose layer TRANSFORM
// is updated DIRECTLY inside the gesture handlers — no SwiftUI @State write per touch, so there is no body
// re-render mid-pinch (that re-render is what caused the violent shake). Pinch + pan recognize together and
// accumulate-then-reset; the pinch anchors between the fingers. On release it springs to the clamped value
// and syncs the final scale/offset back to the bindings so the WYSIWYG flatten matches exactly.
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    @Binding var scale: CGFloat
    @Binding var offset: CGSize
    var maxScale: CGFloat = 4
    var minScale: CGFloat = 1
    var interactive: Bool = true
    var onTap: () -> Void = {}
    /// SWIPE TO THE NEXT PICTURE, +1 forward and -1 back (owner 2026-08-04: "when i swipe touching
    /// screen nothing happens… it most work swipe to next image").
    ///
    /// It belongs HERE and not on a SwiftUI gesture over the top, because this view's own pan
    /// recogniser is what was eating the swipe. Nothing to do with the strip.
    var onSwipe: (Int) -> Void = { _ in }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.clipsToBounds = true
        container.backgroundColor = .clear
        let iv = UIImageView(image: image)
        iv.contentMode = .scaleAspectFit
        iv.isUserInteractionEnabled = false
        iv.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(iv)
        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            iv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            iv.topAnchor.constraint(equalTo: container.topAnchor),
            iv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        context.coordinator.container = container
        context.coordinator.imageView = iv

        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 2
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        // Left and right flicks, the same recogniser Signal's camera uses to change mode. A discrete
        // swipe, so it can never fight the pinch or the pan for the picture itself.
        let swipeLeft = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSwipe(_:)))
        swipeLeft.direction = .left
        let swipeRight = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSwipe(_:)))
        swipeRight.direction = .right
        for g in [pinch, pan, tap, swipeLeft, swipeRight] as [UIGestureRecognizer] {
            g.delegate = context.coordinator; container.addGestureRecognizer(g)
        }
        context.coordinator.pinch = pinch; context.coordinator.pan = pan
        return container
    }

    func updateUIView(_ v: UIView, context: Context) {
        let c = context.coordinator
        c.parent = self
        if c.imageView?.image !== image { c.imageView?.image = image }
        c.pinch?.isEnabled = interactive
        c.pan?.isEnabled = interactive
        if !c.active {   // adopt external scale/offset (e.g. a reset) only when not mid-gesture
            c.curScale = scale
            c.curOffset = CGPoint(x: offset.width, y: offset.height)
            c.applyTransform()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: ZoomableImageView
        weak var container: UIView?
        weak var imageView: UIImageView?
        var pinch: UIPinchGestureRecognizer?
        var pan: UIPanGestureRecognizer?
        var curScale: CGFloat
        var curOffset: CGPoint
        var active = false

        init(_ p: ZoomableImageView) {
            parent = p
            curScale = p.scale
            curOffset = CGPoint(x: p.offset.width, y: p.offset.height)
        }

        func applyTransform() {
            imageView?.transform = CGAffineTransform(translationX: curOffset.x, y: curOffset.y).scaledBy(x: curScale, y: curScale)
        }

        private func clampOffset() {
            guard let c = container, let img = imageView?.image else { return }
            let b = c.bounds.size
            guard b.width > 1, img.size.width > 1 else { return }
            let fitScale = min(b.width / img.size.width, b.height / img.size.height)
            let fit = CGSize(width: img.size.width * fitScale, height: img.size.height * fitScale)
            let maxX = max(0, (fit.width * curScale - b.width) / 2)
            let maxY = max(0, (fit.height * curScale - b.height) / 2)
            curOffset.x = min(maxX, max(-maxX, curOffset.x))
            curOffset.y = min(maxY, max(-maxY, curOffset.y))
        }

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            switch g.state {
            case .began: active = true
            case .changed:
                curScale = min(parent.maxScale * 1.15, max(parent.minScale * 0.9, curScale * g.scale))
                g.scale = 1
                applyTransform()   // direct transform — no SwiftUI write, no re-render, no shake
            case .ended, .cancelled:
                active = false
                curScale = min(parent.maxScale, max(parent.minScale, curScale))
                clampOffset()
                UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0.3,
                               options: [.allowUserInteraction]) { self.applyTransform() }
                parent.scale = curScale
                parent.offset = CGSize(width: curOffset.x, height: curOffset.y)
            default: break
            }
        }
        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            switch g.state {
            case .began: active = true
            case .changed:
                let t = g.translation(in: container)
                g.setTranslation(.zero, in: container)
                curOffset.x += t.x; curOffset.y += t.y
                applyTransform()
            case .ended, .cancelled:
                active = false
                clampOffset()
                UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0.3,
                               options: [.allowUserInteraction]) { self.applyTransform() }
                parent.offset = CGSize(width: curOffset.x, height: curOffset.y)
            default: break
            }
        }
        @objc func handleTap(_ g: UITapGestureRecognizer) { parent.onTap() }

        @objc func handleSwipe(_ g: UISwipeGestureRecognizer) {
            parent.onSwipe(g.direction == .left ? 1 : -1)
        }

        /// THE PAN IS WHY SWIPING DID NOTHING, and this one line is the fix.
        ///
        /// It was live at every zoom level, so a one-finger drag across the picture was always
        /// claimed by it — and at 1x `clampOffset` pins the offset to zero, so the picture could not
        /// move either. The drag was swallowed and then thrown away: you touched the screen and
        /// nothing happened, exactly as reported.
        ///
        /// A pan only has work to do when the picture is bigger than its frame. Below that it does
        /// not begin at all, and the swipe is free to recognise. Zoomed in, the pan begins as before
        /// and the swipe stays out of the way, which is right — a drag on a zoomed photo is a pan.
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard g === pan else { return true }
            // Zooming out from 1x and moving in the SAME motion still works: while the pinch is
            // live the pan is let through regardless, or that one gesture would lose its second half.
            if let p = pinch, p.state == .began || p.state == .changed { return true }
            return curScale > 1.01
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool {
            !(g is UITapGestureRecognizer || o is UITapGestureRecognizer)
        }
    }
}

// PencilKit drawing surface.
struct DrawingCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    let isActive: Bool
    var penColor: UIColor? = nil          // set (with showsToolPicker false) → external palette
    var showsToolPicker: Bool = true
    var inkType: PKInkingTool.InkType = .pen   // pen vs marker/highlighter
    var penWidth: CGFloat = 6
    /// True while a stroke is being drawn. The editor uses it to clear its chrome out of the way.
    var onStroke: (Bool) -> Void = { _ in }
    func makeUIView(context: Context) -> PKCanvasView {
        let v = PKCanvasView()
        v.drawingPolicy = .anyInput
        v.backgroundColor = .clear
        v.isOpaque = false
        v.tool = PKInkingTool(inkType, color: penColor ?? .white, width: penWidth)
        v.delegate = context.coordinator
        if showsToolPicker { context.coordinator.toolPicker.addObserver(v) }   // native PencilKit tool palette
        return v
    }
    func updateUIView(_ v: PKCanvasView, context: Context) {
        if v.drawing != drawing { v.drawing = drawing }
        v.isUserInteractionEnabled = isActive
        if let penColor { v.tool = PKInkingTool(inkType, color: penColor, width: penWidth) }   // external palette drives the ink
        guard showsToolPicker else { return }
        // Show Apple's PKToolPicker (pens/marker/eraser/colors/undo) while drawing is active.
        let picker = context.coordinator.toolPicker
        picker.setVisible(isActive, forFirstResponder: v)
        if isActive { DispatchQueue.main.async { v.becomeFirstResponder() } }
        else { v.resignFirstResponder() }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    // Done removes this view from the hierarchy — hide the tool picker FIRST, or it lingers on screen.
    static func dismantleUIView(_ uiView: PKCanvasView, coordinator: Coordinator) {
        coordinator.toolPicker.setVisible(false, forFirstResponder: uiView)
        uiView.resignFirstResponder()
    }
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let parent: DrawingCanvas
        let toolPicker = PKToolPicker()
        init(_ p: DrawingCanvas) { parent = p }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) { parent.drawing = canvasView.drawing }

        // PencilKit's own "a stroke is happening" pair. Reporting it is what lets the editor get its
        // buttons out of the way while the finger is down — the alternative, a gesture recogniser of
        // our own on the canvas, would have to compete with the one drawing the line.
        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) { parent.onStroke(true) }
        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) { parent.onStroke(false) }
    }
}

// Real interactive crop: pan/zoom the image inside a fixed frame, surroundings DIMMED
// (you see what you're cropping out), rotation dial (-45°…45°) with auto-zoom so corners never gap,
// rotate-90, flip, aspect MENU, grid that fades in during a gesture, corner handles, Reset.
// Done renders exactly what's inside the frame. Body split into sub-views for the type-checker.
struct CropView: View {
    let source: UIImage
    var onDone: (UIImage) -> Void
    var onCancel: () -> Void

    @State private var scale: CGFloat = 1
    @GestureState private var gScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var gOffset: CGSize = .zero
    @State private var angle: Double = 0          // fine rotation from the dial
    @GestureState private var dialDrag: CGFloat = 0
    @State private var quarter: Int = 0           // rotate-90 steps
    @State private var flipped = false
    @State private var aspectIdx = 0

    private var aspects: [(name: String, ratio: CGFloat)] {
        [("Original", source.size.height == 0 ? 1 : source.size.width / source.size.height),
         ("Square", 1), ("2:3", 2.0 / 3.0), ("3:5", 3.0 / 5.0), ("3:4", 3.0 / 4.0),
         ("4:5", 4.0 / 5.0), ("5:7", 5.0 / 7.0), ("9:16", 9.0 / 16.0)]
    }
    private var liveScale: CGFloat { max(1, scale * gScale) }
    private var liveOffset: CGSize { CGSize(width: offset.width + gOffset.width, height: offset.height + gOffset.height) }
    private var liveAngle: Double { min(45, max(-45, angle - Double(dialDrag) / 6)) }
    private var isEdited: Bool { angle != 0 || quarter != 0 || flipped || scale != 1 || offset != .zero }
    private var interacting: Bool { gScale != 1 || gOffset != .zero || dialDrag != 0 }

    // Min extra zoom so the (possibly rotated) image always covers the frame — no corner gaps.
    private func coverScale(_ angleDeg: Double, _ w: CGFloat, _ h: CGFloat) -> CGFloat {
        let r = angleDeg * .pi / 180
        let c = abs(CGFloat(cos(r))), s = abs(CGFloat(sin(r)))
        guard w > 0, h > 0 else { return 1 }
        return max((w * c + h * s) / w, (w * s + h * c) / h)
    }

    var body: some View {
        GeometryReader { geo in
            let ratio = aspects[aspectIdx].ratio
            let frameW: CGFloat = min(geo.size.width - 32, geo.size.height * 0.5 * ratio)
            let frameH: CGFloat = frameW / ratio
            ZStack {
                Color.black.ignoresSafeArea()
                cropArea(frameW: frameW, frameH: frameH)
                controls(geo: geo, frameW: frameW, frameH: frameH)
            }
        }
        .statusBarHidden()
    }

    private func cropArea(frameW: CGFloat, frameH: CGFloat) -> some View {
        ZStack {
            framedPhoto(frameW: frameW, frameH: frameH, live: true, clip: false)   // overflow shown
            Color.black.opacity(0.5).ignoresSafeArea()                              // dim the surroundings
                .reverseMask { RoundedRectangle(cornerRadius: 1).frame(width: frameW, height: frameH) }
                .allowsHitTesting(false)
            thirdsGrid.frame(width: frameW, height: frameH)
                .opacity(interacting ? 1 : 0).animation(.easeInOut(duration: 0.2), value: interacting)
                .allowsHitTesting(false)
            CropCorners().stroke(.white, lineWidth: 3).frame(width: frameW + 4, height: frameH + 4)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .gesture(SimultaneousGesture(zoomGesture, panGesture))
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture().updating($gScale) { v, s, _ in s = v }.onEnded { v in scale = max(1, scale * v) }
    }
    private var panGesture: some Gesture {
        DragGesture().updating($gOffset) { v, s, _ in s = v.translation }
            .onEnded { v in offset.width += v.translation.width; offset.height += v.translation.height }
    }

    private func controls(geo: GeometryProxy, frameW: CGFloat, frameH: CGFloat) -> some View {
        VStack {
            Spacer()
            Text("Reset")
                .font(.subheadline).foregroundStyle(.white.opacity(isEdited ? 1 : 0.4))
                .onTapGesture { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { resetAll() } }
            rotationDial.frame(height: 40).padding(.vertical, 6)
            HStack {
                circleButton("xmark", bg: Color.white.opacity(0.18)) { onCancel() }
                Spacer()
                HStack(spacing: 26) {
                    Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { quarter = (quarter + 1) % 4 } } label: {
                        Image(systemName: "rotate.left").font(.title3).foregroundStyle(.white)
                    }
                    Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { flipped.toggle() } } label: {
                        Image(systemName: "arrow.left.and.right").font(.title3).foregroundStyle(flipped ? .green : .white)
                    }
                    Menu {
                        ForEach(aspects.indices, id: \.self) { i in
                            Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { aspectIdx = i } } label: {
                                if aspectIdx == i { Label(aspects[i].name, systemImage: "checkmark") } else { Text(aspects[i].name) }
                            }
                        }
                    } label: {
                        Image(systemName: "aspectratio").font(.title3).foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 20).frame(height: 48).background(Color.white.opacity(0.14), in: Capsule())
                Spacer()
                circleButton("checkmark", bg: Color.blue) { onDone(render(frameW: frameW, frameH: frameH)) }
            }
            .padding(.horizontal, 16).padding(.bottom, geo.safeAreaInsets.bottom + 14)
        }
    }

    private func circleButton(_ icon: String, bg: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 48, height: 48).background(bg, in: Circle())
        }
    }

    // Photo: scaled-to-fill the frame, with rotation (+auto cover-zoom) + flip + zoom + pan.
    // clip=false for the on-screen view (overflow shows under the dim); clip=true for the output render.
    private func framedPhoto(frameW: CGFloat, frameH: CGFloat, live: Bool, clip: Bool) -> some View {
        let a: Double = (live ? liveAngle : angle) + Double(quarter) * 90
        let base: CGFloat = live ? liveScale : max(1, scale)
        let s: CGFloat = base * coverScale(a, frameW, frameH)
        let o: CGSize = live ? liveOffset : offset
        return Image(uiImage: source)
            .resizable().scaledToFill()
            .rotationEffect(.degrees(a))
            .scaleEffect(x: flipped ? -s : s, y: s)
            .offset(o)
            .frame(width: frameW, height: frameH)
            .allowsHitTesting(false)
            .modifier(ClipIf(clip: clip))
    }

    private var thirdsGrid: some View {
        GeometryReader { g in
            Path { p in
                for i in 1...2 {
                    let x = g.size.width * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: g.size.height))
                    let y = g.size.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: g.size.width, y: y))
                }
            }.stroke(.white.opacity(0.5), lineWidth: 0.5)
        }
    }

    private var rotationDial: some View {
        GeometryReader { g in
            ZStack {
                HStack(spacing: 7) {
                    ForEach(-45...45, id: \.self) { d in
                        Rectangle()
                            .fill(.white.opacity(d % 15 == 0 ? 0.9 : 0.35))
                            .frame(width: d % 15 == 0 ? 2 : 1, height: d % 15 == 0 ? 18 : 11)
                    }
                }
                .frame(maxHeight: .infinity)
                .offset(x: -CGFloat(liveAngle) * 9)
                Image(systemName: "triangle.fill").font(.system(size: 9)).foregroundStyle(.green)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(width: g.size.width)
            .contentShape(Rectangle())
            .gesture(
                DragGesture().updating($dialDrag) { v, s, _ in s = v.translation.width }
                    .onEnded { v in angle = min(45, max(-45, angle - Double(v.translation.width) / 6)) }
            )
        }
    }

    private func resetAll() { scale = 1; offset = .zero; angle = 0; quarter = 0; flipped = false }

    @MainActor private func render(frameW: CGFloat, frameH: CGFloat) -> UIImage {
        let content = framedPhoto(frameW: frameW, frameH: frameH, live: false, clip: true)
        let r = ImageRenderer(content: content)
        r.scale = UIScreen.main.scale
        return r.uiImage ?? source
    }
}

// Conditionally clip a view to its frame (used so the crop's display shows overflow but the render doesn't).
private struct ClipIf: ViewModifier {
    let clip: Bool
    func body(content: Content) -> some View { clip ? AnyView(content.clipped()) : AnyView(content) }
}

extension View {
    // Punch a hole in `self` the shape of `mask` (used to dim everything except the crop frame).
    func reverseMask<M: View>(@ViewBuilder _ mask: () -> M) -> some View {
        self.mask {
            Rectangle().overlay(mask().blendMode(.destinationOut)).compositingGroup()
        }
    }
}

// L-shaped corner brackets for the crop frame.
struct CropCorners: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let len: CGFloat = 22
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + len)); p.addLine(to: CGPoint(x: rect.minX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.minX + len, y: rect.minY))
        p.move(to: CGPoint(x: rect.maxX - len, y: rect.minY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + len))
        p.move(to: CGPoint(x: rect.maxX, y: rect.maxY - len)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)); p.addLine(to: CGPoint(x: rect.maxX - len, y: rect.maxY))
        p.move(to: CGPoint(x: rect.minX + len, y: rect.maxY)); p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY)); p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - len))
        return p
    }
}
