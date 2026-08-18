import SwiftUI

// Interactive crop screen (standard photo-crop behaviour, my own code). Clean, minimalist layout:
//   • top bar  — Reset, alone
//   • image band — the photo in a fixed WINDOW with a crop frame over it: eight handles (four
//                  corners and four sides) resize, a drag inside moves the frame, a pinch zooms the
//                  photo and a drag in the dimmed part slides it, thirds grid, outside dimmed
//   • straighten — a degree wheel that turns the PHOTO while the frame stays square to the screen
//   • bottom bar — ✕ · one glass capsule (rotate 90° · flip · resize) · ✓, the aspect ratios in a
//                  menu behind the resize icon (his 2026-08-14 design)
// Nothing overlaps the photo; the frame never leaves the window; the photo always covers the window
// (`zoomFloor`); ✓ redraws exactly what is inside the frame, whatever combination of zoom, turn and
// slide put it there.
struct ChatCropView: View {
    let image: UIImage
    var inline: Bool = false              // true = presented INLINE (fade) → close via onClose, NOT dismiss
    var onClose: () -> Void = {}          // inline close (dismiss() would drop the whole editor to the chat)
    var onDone: (UIImage) -> Void
    /// The same crop, as a NORMALISED rectangle (0-1) of the source. A photo can simply be handed the
    /// cropped picture; a video cannot be cropped into an image, so it needs the rectangle instead and
    /// applies it during its export. Optional, so nothing that only wants the picture has to care.
    var onRect: ((CGRect) -> Void)? = nil
    /// WHERE THE PICTURE ALREADY IS ON SCREEN, in GLOBAL coordinates, so this screen can open as a
    /// continuation of it rather than as a new page.
    ///
    /// Their `ImageEditorCropViewController.initialContentInsets`, and their comment says what it is
    /// for in one line: "Presenting view controller will set those before presenting. The intent is
    /// to position image in the same position and with the same size as in the review screen."
    ///
    /// Nil = the old behaviour, byte for byte: the chat editor and the media approval screen hand
    /// nothing in and get the layout and the entry they already had.
    var initialContentRect: CGRect? = nil
    /// The corner radius the picture is wearing at `initialContentRect`. Theirs animates from
    /// `ImageEditorView.defaultCornerRadius` to 0 over the same window as the resize.
    var initialCornerRadius: CGFloat = 0
    @Environment(\.dismiss) private var dismiss

    @State private var img: UIImage
    @State private var container: CGSize = .zero
    /// Where this canvas sits on the screen, as of the last pass that measured it — see `layout`.
    @State private var canvasTopLeft: CGPoint = .zero
    @State private var imageFrame: CGRect = .zero   // displayed (aspect-fit) image rect in the container
    @State private var crop: CGRect = .zero         // crop frame in container coords
    @State private var start: CGRect = .zero        // crop at gesture-begin
    @State private var aspect: CGFloat? = nil        // locked w/h, nil = free
    @State private var edited = false                // any change made → show Reset

    // MARK: The picture's own transform, inside the window
    //
    // `imageFrame` is the WINDOW: the fitted rectangle the picture is shown in, and the rectangle the
    // crop frame is allowed to live in. It does not move. What moves is the picture inside it —
    // scaled by `zoom`, turned by `angle`, slid by `pan` — and the window clips it. That split is
    // what lets a straighten and a zoom exist at all without every crop clamp having to be rewritten,
    // and it is why the picture can never be dragged out from under the crop frame: `zoomFloor` and
    // `clampPan` keep the window covered at every angle.

    /// Pinch, 1 = fits the window. Never below `zoomFloor`, which the straighten raises.
    @State private var zoom: CGFloat = 1
    @State private var zoomStart: CGFloat = 1
    /// The picture's slide inside the window, in canvas points.
    @State private var pan: CGSize = .zero
    @State private var panStart: CGSize = .zero
    /// Straighten, in degrees, positive clockwise. The crop frame stays square to the screen.
    @State private var angle: Double = 0
    @State private var angleStart: Double = 0

    init(image: UIImage, inline: Bool = false, onClose: @escaping () -> Void = {},
         onRect: ((CGRect) -> Void)? = nil,
         initialContentRect: CGRect? = nil, initialCornerRadius: CGFloat = 0,
         onDone: @escaping (UIImage) -> Void) {
        self.image = image; self.inline = inline; self.onClose = onClose
        self.onRect = onRect; self.onDone = onDone
        self.initialContentRect = initialContentRect
        self.initialCornerRadius = initialCornerRadius
        _img = State(initialValue: Self.normalized(image))
        // Opened FROM a picture already on screen → start folded onto it. Opened any other way →
        // start already arrived, which is every caller that hands nothing in.
        _entryProgress = State(initialValue: initialContentRect == nil ? 1 : 0)
        _chrome = State(initialValue: initialContentRect == nil ? 1 : 0)
        _frameChrome = State(initialValue: initialContentRect == nil ? 1 : 0)
    }

    /// THE ENTRY, WHICH IS A RESIZE AND NOT A CROSS-FADE.
    ///
    /// ⚠️ THIS IS THEIRS, AND THE PART WORTH WRITING DOWN IS HOW LITTLE OF IT THERE IS. There is no
    /// transition object, no snapshot and no dissolve anywhere in `ImageEditorCropViewController`.
    /// The screen is laid out at the review screen's own rect with its controls hidden
    /// (`transitionUI(toState: .initial, animated: false)` in `viewDidLoad`), and then in
    /// `viewDidAppear` it animates itself to the crop layout over 0.15s while a `CABasicAnimation`
    /// takes the picture's corner radius to zero. One picture, resizing.
    ///
    /// ⚠️ AND THE REASON IT CAN BE A PURE SCALE: their two layout guides share a centre —
    /// "Seamlessness is achieved when image center stays the same in both screens" — so nothing has
    /// to travel. `layout(_:canvasOrigin:)` seats the fitted picture on the handed-in rect's centre
    /// for the same reason, which leaves exactly one number between the two states.
    /// HOW FAR THROUGH THE FLIGHT WE ARE, 0 on the card and 1 arrived. The ONE animated number.
    ///
    /// ⚠️ IT USED TO BE A SCALE AND A CAPTURED OFFSET, AND THAT IS HIS "the image goes down first,
    /// then starts the zoom".
    ///
    /// Both were computed ONCE, against the `imageFrame` that existed at `onAppear`, and then
    /// animated to their finished values. But `layout` runs again whenever the canvas is re-measured
    /// — and it is, right after appearing, because the top bar and the bottom controls are
    /// `safeAreaInset`s whose heights are not known until they have been laid out. The second pass
    /// moves `imageFrame`; the picture is positioned FROM `imageFrame`, while the delta it was flying
    /// along had been measured against the old one. So the picture jumped to its new seat and only
    /// then travelled: a drop, and then the zoom.
    ///
    /// Derived per render from the LIVE `imageFrame` instead, so a re-measurement moves the
    /// destination and the flight simply keeps pointing at it. There is nothing left to go stale.
    @State private var entryProgress: CGFloat
    /// The card this screen was opened from, in THIS canvas's coordinates. Written by `layout`,
    /// which is the one place that knows where the canvas sits on the screen.
    ///
    /// ⛔ THE DROP, THIRD REPORT, AND THE THIRD CAUSE — 2026-08-18. READ THIS BEFORE TOUCHING `layout`.
    ///
    /// `entryFrom` and `imageFrame` are both in THIS CANVAS'S coordinates, and the canvas MOVES: its
    /// two `safeAreaInset` bars do not know their heights on the first pass, so the second pass puts
    /// the whole canvas about a bar's height further down the screen. Both rectangles are re-derived
    /// against the new origin in the same breath, so on screen the two moves cancel EXACTLY and the
    /// picture does not shift by a point — the drawn centre is `canvasOrigin + entryFrom.mid` at the
    /// start of the flight and that product is the card's rect on the screen whatever the origin is.
    ///
    /// ⚠️ THE CANCELLATION ONLY HOLDS IF BOTH SIDES MOVE IN THE SAME FRAME. `d69bde49` put the seat
    /// writes inside a 0.3s `withAnimation` so that a pass landing mid-flight would "move the seat on
    /// the flight's own curve rather than snap to it" — but the canvas's own re-origin is a LAYOUT
    /// change and layout does not ease. So the canvas dropped a bar's height instantly while the
    /// picture's `.position` inside it eased back up over 0.3s: a picture that falls, then rises and
    /// shrinks. That is his "the image goes down, after that the zoom out starts", and it is that
    /// commit's own repair rather than the fault it was aimed at. `DispatchQueue.main.async` all but
    /// guarantees it fires: the deferred `runEntry` runs before SwiftUI's second layout pass, so the
    /// settle almost always lands with the flight already up.
    ///
    /// So the seat is written PLAINLY, in one frame, and it must stay that way. Snapping is not a
    /// compromise here, it is the only thing that is invisible: a re-measure moves the DESTINATION by
    /// a few points and the drawn picture by `progress` times that, while easing it moves the drawn
    /// picture by the whole distance the canvas travelled.
    @State private var entryFrom: CGRect = .zero

    /// One number for the move, so the flight and the chrome behind it cannot run on two clocks.
    private static let entryDuration: Double = 0.3

    /// The scale that puts the fitted picture back at the card's size, eased out by the progress.
    private var entryScale: CGFloat {
        guard entryProgress < 1, entryFrom.width > 1, imageFrame.width > 1 else { return 1 }
        let startScale = max(0.05, entryFrom.width / imageFrame.width)
        return startScale + (1 - startScale) * entryProgress
    }
    /// ...and what is left of the difference between the two centres. Zero on arrival by
    /// construction rather than by having been animated to it.
    private var entryOffset: CGSize {
        guard entryProgress < 1, entryFrom.width > 1, imageFrame.width > 1 else { return .zero }
        let rest = 1 - entryProgress
        return CGSize(width: (entryFrom.midX - imageFrame.midX) * rest,
                      height: (entryFrom.midY - imageFrame.midY) * rest)
    }
    /// What is left of the difference between the two rectangles once the scale has taken the size —
    /// see `runEntry`. Zero whenever the fitted picture could be seated on the card's own centre,
    /// which is most of the time; a tall card is the case that needs it.
    /// STAGE ONE: the black behind, the Reset button and the bottom button row, faded in over the
    /// 0.3s the picture is moving. That is `_buttonsWrapperView.alpha` in
    /// `TGPhotoCropController.transitionIn`, on their duration.
    @State private var chrome: CGFloat
    /// STAGE TWO: the crop frame, the grid, the corner brackets, the dim outside the frame and the
    /// straighten ruler — AFTER the picture has finished moving, not with it.
    ///
    /// ⚠️ THIS SPLIT IS HIS "just original image make zoom out, after that appearing crop controls",
    /// AND IT IS LITERALLY WHAT THEIR CODE DOES. `TGPhotoCropView.animateTransitionIn` sets
    /// `_areaView.alpha`, `_rotationView.alpha` and the scroll view to ZERO for the whole flight —
    /// the frame and the ruler are not on screen while the picture is moving. They come back in
    /// `transitionInFinishedAnimated:`, which the tab controller calls from the COMPLETION BLOCK of
    /// the 0.3s move, over **0.35s ease-in-out** of their own.
    ///
    /// One number for both stages is what made this read as a page arriving: the frame drawn around a
    /// picture that is still travelling announces the new screen before the picture has become part
    /// of it.
    @State private var frameChrome: CGFloat

    // Inline: close via onClose only (dismiss() would pop the whole editor to the chat). Cover: dismiss().
    private func close() { if inline { onClose() } else { dismiss() } }

    private let minSize: CGFloat = 64
    private let hit: CGFloat = 34
    private var originalRatio: CGFloat { img.size.width / max(1, img.size.height) }

    /// THE SMALLEST ZOOM THAT STILL COVERS THE WINDOW AT THIS ANGLE.
    ///
    /// Turning a rectangle inside a rectangle of the same size uncovers its corners, which is where
    /// every straighten tool's automatic zoom comes from — without it the crop frame would contain
    /// empty black wedges the moment the wheel leaves zero. A W×H rectangle turned by θ covers a w×h
    /// window when it is scaled by the larger of the two ratios below; here the window IS the fitted
    /// picture, so w,h are its own size.
    private var zoomFloor: CGFloat {
        let r = abs(angle) * .pi / 180
        let c = abs(cos(r)), s = abs(sin(r))
        let w = imageFrame.width, h = imageFrame.height
        guard w > 1, h > 1 else { return 1 }
        return max(1, max((w * c + h * s) / w, (w * s + h * c) / h))
    }

    /// What the picture actually occupies on screen before it is turned: the window, scaled about its
    /// own centre and slid by `pan`. The rotation is applied around this rectangle's centre, by the
    /// view and by the export, from this one definition.
    private var displayFrame: CGRect {
        let z = max(zoom, zoomFloor)
        let w = imageFrame.width * z, h = imageFrame.height * z
        return CGRect(x: imageFrame.midX - w / 2 + pan.width,
                      y: imageFrame.midY - h / 2 + pan.height,
                      width: w, height: h)
    }

    /// Keep the window covered. The bound is the turned picture's bounding box against the window, so
    /// at exactly `zoomFloor` there is nothing to give and the picture cannot be slid at all.
    private func clampPan(_ p: CGSize) -> CGSize {
        let r = abs(angle) * .pi / 180
        let c = abs(cos(r)), s = abs(sin(r))
        let z = max(zoom, zoomFloor)
        let w = imageFrame.width * z, h = imageFrame.height * z
        let coveredW = w * c + h * s, coveredH = w * s + h * c
        let slackX = max(0, (coveredW - imageFrame.width) / 2)
        let slackY = max(0, (coveredH - imageFrame.height) / 2)
        return CGSize(width: min(max(-slackX, p.width), slackX),
                      height: min(max(-slackY, p.height), slackY))
    }

    var body: some View {
        // The crop CANVAS lives between native safe-area bars: the top bar (X / Reset) sits just below the
        // status bar and the controls just above the home indicator — placed by .safeAreaInset, not by
        // hard-coded top padding (which mis-positioned the buttons into the notch in a fullScreenCover).
        GeometryReader { geo in
            ZStack {
                // THE PICTURE, TURNED AND SCALED INSIDE ITS WINDOW.
                //
                // Clipped to the window, so the window stays the whole of what this screen shows
                // however far it is zoomed, and so the crop frame's clamps — every one of which is
                // against `imageFrame` — stay exactly as they were before any of this existed.
                // ⚠️ `offset` INSIDE A FIXED FRAME, NOT A SECOND `position`. A `.position` makes a
                // view fill its parent and place its content at that point; putting a `.frame`
                // AFTER one re-parents what was just placed, so the point it was placed at now
                // means something else. That is the picture he photographed sitting low in the
                // frame with black above it, and it arrived with the zoom.
                //
                // A frame centres its content by default, so the window-sized frame below puts the
                // picture's centre on the window's centre and `pan` moves it from there — which is
                // exactly what `displayFrame` says (window centre + pan), so the export and the
                // screen are computing one thing in two places and cannot disagree.
                Image(uiImage: img).resizable().scaledToFit()
                    .frame(width: displayFrame.width, height: displayFrame.height)
                    .rotationEffect(.degrees(angle))
                    .offset(x: pan.width, y: pan.height)
                    .frame(width: imageFrame.width, height: imageFrame.height)
                    .clipped()
                    // ⚠️ THE CORNER IS DIVIDED BY THE SCALE, so what is on screen is the radius the
                    // card was actually wearing at every point of the flight rather than a number
                    // shrinking with the picture. Theirs animates the layer's own `cornerRadius`
                    // against an untransformed view, which is the same on-screen result.
                    .clipShape(RoundedRectangle(cornerRadius: initialCornerRadius * (1 - chrome)
                                                / max(entryScale, 0.05), style: .continuous))
                    // ONE NUMBER, ABOUT THE SHARED CENTRE. See `runEntry`: the rect we were opened
                    // from and the fitted rect have the same centre and the same aspect, so a
                    // uniform scale is the entire difference between them. Nothing translates, which
                    // is why this cannot drift the way a hand-built path would.
                    .scaleEffect(entryScale)
                    // The leftover translation, after `.scaleEffect` so it is read in canvas points
                    // rather than in the scaled picture's own. `.offset` draws, it does not lay out,
                    // so the `.position` below still seats the picture on its true crop rect and this
                    // only moves what is drawn there back onto the card for the length of the flight.
                    .offset(entryOffset)
                    .position(x: imageFrame.midX, y: imageFrame.midY)
                // Slide the picture: in the dimmed part, because inside the frame a one-finger drag
                // belongs to the frame and always has. Below the crop's own views in this stack, so
                // it can only ever get what they did not want.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(imagePanGesture)

                // Dim everything outside the crop frame (even-odd fill).
                Path { p in p.addRect(CGRect(origin: .zero, size: geo.size)); p.addRect(crop) }
                    .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
                    .opacity(frameChrome)

                // ⚠️ THE FRAME ARRIVES AFTER THE PICTURE HAS LANDED, NOT WITH IT. See `frameChrome`:
                // theirs holds `_areaView` at alpha 0 for the whole of the move and brings it back
                // from the move's completion block.
                gridAndBorder.opacity(frameChrome)
                brackets.opacity(frameChrome)
                // Move the whole frame by dragging inside it.
                Color.clear.frame(width: crop.width, height: crop.height).position(x: crop.midX, y: crop.midY)
                    .contentShape(Rectangle())
                    .gesture(moveGesture)
                frameHandles
            }
            // A FIXED coordinate space for the crop gestures. The corner/move handles are placed with
            // .position(from crop), so they MOVE as you drag — measuring the drag in the handle's own
            // (.local) space fed its movement back into the translation → the crop "shook". Measuring in
            // this stable canvas space instead means translation = pure finger movement, no feedback.
            // ⚠️ THE PINCH BELONGS TO THE WHOLE CANVAS, AND THAT IS WHY IT DID NOTHING. It was on a
            // layer UNDERNEATH the crop frame's own views — and the frame covers the entire picture
            // the moment this screen opens, so there was nowhere left to put two fingers. A
            // simultaneous gesture on the canvas itself is heard wherever they land, and a
            // magnification never competes with the frame's one-finger drags.
            .simultaneousGesture(pinchGesture)
            .coordinateSpace(name: "cropCanvas")
            // ⚠️ NOTHING ON THIS CANVAS ANSWERS A FINGER UNTIL THE FLIGHT HAS LANDED. Theirs does
            // this by construction — `animateTransitionIn` sets `_scrollView.hidden = true` and the
            // area view to alpha 0, and a hidden UIKit view takes no touches. A SwiftUI view at
            // `.opacity(0)` still does, so a pan, a pinch or a grab at a corner during the 0.3s move
            // would be fighting the animation that is placing the picture.
            .allowsHitTesting(frameChrome > 0.01)
            .onAppear {
                // `.global` because the rect we were handed is the presenter's, measured on the
                // screen. This canvas sits under a bar it does not know the height of.
                layout(geo.size, canvasOrigin: geo.frame(in: .global).origin)
                // ⚠️ ONE RUNLOOP TURN LATER, WHICH IS THE ORDERING UIKit HANDS THEIRS FOR NOTHING.
                // `viewDidLoad` seats their picture on the rect it was handed and the whole layout is
                // settled by the time `viewDidAppear` starts the animation. Ours is asked to fly on
                // the first pass, and the canvas is still moving then: the two `safeAreaInset` bars
                // do not know their own heights until they have been laid out, so the pass after this
                // one is a different rectangle. Every state read below goes through the property
                // wrapper's storage, so this closure sees whatever the last pass wrote rather than the
                // numbers captured with it.
                //
                // ⚠️ IT DOES NOT ACTUALLY OUTRUN THE SETTLE, AND IT DOES NOT HAVE TO. This block runs
                // at the end of the current runloop turn, while SwiftUI's next layout pass is a render
                // cycle away, so the settle usually lands with the flight already up — which is fine,
                // and the note on `entryFrom` is why: the seat and the canvas move in the same frame,
                // so a pass landing mid-flight is invisible. It only stopped being invisible when the
                // seat was given an animation of its own.
                DispatchQueue.main.async { runEntry() }
            }
            // ⚠️ THE WHOLE FRAME, NOT JUST THE SIZE. The canvas can be re-seated without being
            // resized — a bar above it growing and one below it shrinking by the same amount moves
            // the origin and nothing else — and `entryFrom` is expressed in this canvas's own
            // coordinates, so an origin nobody told us about puts the card's rect in the wrong place
            // by exactly the distance the canvas moved.
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { f in
                layout(f.size, canvasOrigin: f.origin)
            }
        }
        // ⚠️ THE ONE PLACE THIS DIVERGES FROM THEIRS, AND IT IS A UIKit-VERSUS-SwiftUI DIFFERENCE
        // RATHER THAN A CHOICE.
        //
        // Their crop screen's background is opaque black from the first frame, and it can be: the
        // picture is constrained to the review screen's rect in `viewDidLoad`, before the view is
        // ever on screen, so there is no frame where the black is up and the picture is not.
        //
        // Ours cannot lay out until a `GeometryReader` has reported a size, which is at least one
        // render. Opaque black would therefore paint a full-screen black frame over the editor
        // before the picture arrived — the pop this whole change exists to remove, moved one frame
        // earlier. Fading it with the rest of the chrome means that frame shows the editor's own
        // card instead, which is the same picture in the same place.
        //
        // Callers that hand no rect in keep the opaque background exactly as before.
        .background(Color.black.opacity(initialContentRect == nil ? 1 : chrome).ignoresSafeArea())
        // The bars ride the same fade as the frame. Theirs is `footerView.alpha` and
        // `toolbar.setControlsHidden(_:)` inside the one animation block, for the same reason: a
        // control that is already there while the picture is still the size it was on the last
        // screen announces the new screen before the picture has become part of it.
        .safeAreaInset(edge: .top, spacing: 0) { topBar.opacity(chrome) }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomControls.opacity(chrome) }
    }

    // MARK: Layout — fit the photo into the canvas area (already inset by the safe-area bars).

    /// ⚠️ THE ORIGIN IS REMEMBERED, AND `.zero` USED TO BE THE DEFAULT FOR CALLERS WHO SIMPLY DID NOT
    /// HAVE IT. Rotate, flip and Reset all re-seat the picture through here long after the geometry
    /// callback that knew where this canvas sits, and they passed nothing — so the seat was computed
    /// as if the canvas began at the very top of the phone, `wanted` came out a bar's height too
    /// large, and the clamp walked the picture down. One turn of the picture, one step down the
    /// screen. Handed an origin, this records it; handed none, it uses the one it was last told.
    private func layout(_ size: CGSize, canvasOrigin: CGPoint? = nil) {
        let canvasOrigin = canvasOrigin ?? canvasTopLeft
        canvasTopLeft = canvasOrigin
        container = size
        let availW = size.width - 32
        let availH = size.height - 24
        let s = min(availW / img.size.width, availH / img.size.height)
        let w = img.size.width * s, h = img.size.height * s
        // ⚠️ THE CENTRE COMES FROM WHERE THE PICTURE ALREADY IS, WHEN WE ARE TOLD.
        //
        // Their `finalStateContentLayoutGuide` is constrained `centerYAnchor == initialState...
        // centerYAnchor`: the crop layout picks its own width and its own height, and inherits the
        // review screen's vertical centre. That is what makes the opening a pure resize with nothing
        // travelling, and it is the whole of "seamless" in their comment.
        //
        // Clamped so a card sitting high or low on its own screen cannot push the fitted picture off
        // this one. With nothing handed in this is the centred rect it always was.
        var y = (size.height - h) / 2
        if let r = initialContentRect {
            let wanted = (r.midY - canvasOrigin.y) - h / 2
            y = min(max(12, wanted), max(12, size.height - h - 12))
        }
        let seat = CGRect(x: (size.width - w) / 2, y: y, width: w, height: h)
        // ⚠️ RE-RECORDED ON EVERY PASS, IN THIS CANVAS'S OWN COORDINATES. The flight is derived from
        // this and `imageFrame` together (see `entryProgress`), so when the canvas is re-measured
        // — which it is, right after appearing, once the two `safeAreaInset` bars know their own
        // heights — both ends move together and the picture keeps travelling to the right place
        // instead of jumping to a new seat first.
        let from: CGRect? = initialContentRect.map {
            CGRect(x: $0.minX - canvasOrigin.x, y: $0.minY - canvasOrigin.y,
                   width: $0.width, height: $0.height)
        }
        // ⚠️ BOTH IN ONE FRAME, PLAINLY, NEVER INSIDE A TRANSACTION — the long note on `entryFrom` is
        // why, and it is his 2026-08-18 drop. These two rectangles and the canvas they are measured in
        // move together; easing them apart from the canvas is what makes the picture fall.
        imageFrame = seat
        if let from { entryFrom = from }
        setAspect(aspect, animated: false)
    }

    /// Fold onto the picture we were opened from, then unfold. Called once, on the first layout pass
    /// that knows where this canvas is.
    ///
    /// ⚠️ `min(1, …)` USED TO BE ON THAT FIRST LINE AND IT IS WHY NOTHING EVER MOVED. The card is the
    /// full width of the screen and the fitted picture is narrower than it — the crop canvas is inset
    /// and the bars eat the height — so the ratio is ALWAYS above 1 here. Clamped to 1 it meant
    /// "already arrived": the picture appeared at its final size in one frame and only the chrome
    /// faded, which is his "the page is suddenly replaced". A zoom OUT is the only direction this
    /// screen is ever entered in, and it was the one direction the clamp forbade.
    ///
    /// ⚠️ AND THE NUMBERS ARE THE OTHER APP'S NOW, NOT THE FIRST ONE'S. `TGPhotoEditorTabController`
    /// animates the picture's frame from where it was to where the crop layout wants it over
    /// **0.3s, ease-in-out**, and `TGPhotoCropController.transitionIn` fades the crop controls in over
    /// **0.3s** alongside it — one picture moving, the controls arriving on top of it. 0.15s was the
    /// other app's figure and it is half as long as this screen's own canvas step-back, so even when
    /// it did move, two halves of one motion ran on two clocks.
    private func runEntry() {
        guard initialContentRect != nil, imageFrame.width > 1, entryProgress < 1,
              entryFrom.width > 1 else { return }
        withAnimation(.easeInOut(duration: Self.entryDuration)) {
            entryProgress = 1
            chrome = 1
        }
        // AND ONLY THEN THE FRAME. Their completion block, expressed as a delay: `.delay(0.3)` is the
        // move's own duration, and 0.35 is the figure `transitionInFinishedAnimated:` animates the
        // area view and the rotation view back with.
        withAnimation(.easeInOut(duration: 0.35).delay(0.3)) {
            frameChrome = 1
        }
    }

    // Reset the crop to a centered rect of `ratio` (or the whole image if free) within imageFrame.
    private func setAspect(_ ratio: CGFloat?, animated: Bool) {
        aspect = ratio
        var r = imageFrame
        if let ratio {
            if imageFrame.width / imageFrame.height > ratio {
                let w = imageFrame.height * ratio
                r = CGRect(x: imageFrame.midX - w / 2, y: imageFrame.minY, width: w, height: imageFrame.height)
            } else {
                let h = imageFrame.width / ratio
                r = CGRect(x: imageFrame.minX, y: imageFrame.midY - h / 2, width: imageFrame.width, height: h)
            }
        }
        if animated { withAnimation(.easeInOut(duration: 0.2)) { crop = r } } else { crop = r }
    }

    // MARK: Frame chrome

    private var gridAndBorder: some View {
        // Drawn with ABSOLUTE crop coordinates (like the dim overlay + brackets) so the border, grid and
        // corners all move as ONE during a drag. (Frame/position updated a beat off from the Paths, so the
        // border desynced and looked like a shaking duplicate line.)
        ZStack {
            Path { $0.addRect(crop) }
                .stroke(.white.opacity(0.9), lineWidth: 1)
            Path { p in
                for i in 1...2 {
                    let x = crop.minX + crop.width * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: crop.minY)); p.addLine(to: CGPoint(x: x, y: crop.maxY))
                    let y = crop.minY + crop.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: crop.minX, y: y)); p.addLine(to: CGPoint(x: crop.maxX, y: y))
                }
            }
            .stroke(.white.opacity(0.35), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }

    // Heavier white L-brackets at each corner (standard crop look).
    private var brackets: some View {
        Path { p in
            let l: CGFloat = 22
            p.move(to: CGPoint(x: crop.minX, y: crop.minY + l)); p.addLine(to: CGPoint(x: crop.minX, y: crop.minY)); p.addLine(to: CGPoint(x: crop.minX + l, y: crop.minY))
            p.move(to: CGPoint(x: crop.maxX - l, y: crop.minY)); p.addLine(to: CGPoint(x: crop.maxX, y: crop.minY)); p.addLine(to: CGPoint(x: crop.maxX, y: crop.minY + l))
            p.move(to: CGPoint(x: crop.minX, y: crop.maxY - l)); p.addLine(to: CGPoint(x: crop.minX, y: crop.maxY)); p.addLine(to: CGPoint(x: crop.minX + l, y: crop.maxY))
            p.move(to: CGPoint(x: crop.maxX - l, y: crop.maxY)); p.addLine(to: CGPoint(x: crop.maxX, y: crop.maxY)); p.addLine(to: CGPoint(x: crop.maxX, y: crop.maxY - l))
        }
        .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        .allowsHitTesting(false)
    }

    /// EVERY SIDE IS A HANDLE, NOT ONLY THE FOUR CORNERS — his 2026-08-14 report, with the four
    /// corners circled: "the white squares only is working when i use corners".
    ///
    /// The corners are laid down AFTER the edges on purpose. They overlap at every join, and in a
    /// `ZStack` the last view is the one the touch reaches — so a finger in a corner gets the corner,
    /// which is the one that can move two sides at once.
    private var frameHandles: some View {
        ZStack {
            ForEach(Handle.edges, id: \.self) { e in
                Color.clear
                    .frame(width: edgeSize(e).width, height: edgeSize(e).height)
                    .contentShape(Rectangle())
                    .gesture(handleGesture(e))
                    .position(point(e))
            }
            ForEach(Handle.corners, id: \.self) { c in
                Color.clear
                    .frame(width: hit, height: hit)
                    .contentShape(Rectangle())
                    .gesture(handleGesture(c))
                    .position(point(c))
            }
        }
    }

    /// A side's grab area: as thick as a corner, and as long as what is left of that side once the
    /// two corners have taken their share. Never negative on a crop squeezed down to `minSize`.
    private func edgeSize(_ e: Handle) -> CGSize {
        switch e {
        case .top, .bottom: return CGSize(width: max(1, crop.width - hit), height: hit)
        case .left, .right: return CGSize(width: hit, height: max(1, crop.height - hit))
        default:            return CGSize(width: hit, height: hit)
        }
    }

    // MARK: Controls

    // Top bar: Reset, alone on the right.
    //
    // ⚠️ THE ✕ IS NOT MISSING FROM HERE, IT MOVED. His 2026-08-14 design puts the two decisions —
    // leave without cropping, and take the crop — at the two ends of the bottom bar, where the
    // thumb already is, with the tools between them. A second ✕ up here would be the same decision
    // offered twice, so the top corner keeps only the thing that is neither: Reset.
    private var topBar: some View {
        HStack {
            Spacer()
            Button { reset() } label: {
                Text("Reset").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(edited ? .white : .white.opacity(0.35))
                    .frame(height: 44).padding(.horizontal, 16)
                    .liquidGlass(Capsule(), interactive: true)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!edited)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    // Bottom bar, his 2026-08-14 design: ✕ · one tool group · ✓, in one row.
    //
    // It was three stacked rows — two labelled icons, a permanent scroller of seven ratio chips, and
    // a full-width white Done — which is most of the height of a phone's bottom third spent on a
    // screen whose subject is the picture. Now the tools are ONE capsule (the same 46pt glass
    // capsule the story toolbar uses, so the two screens read as one app), and the ratios live
    // behind the resize icon instead of standing open. Nothing is gone: every chip is one tap away
    // and the tap is on the icon that means shape.
    private var bottomControls: some View {
        VStack(spacing: 14) {
            // The ruler is their `_rotationView`, which is held at zero for the whole of the move and
            // comes back with the crop frame — not with the buttons beside it. See `frameChrome`.
            straightenWheel
                .opacity(frameChrome)
                // ⚠️ AND DEAF WHILE IT IS INVISIBLE. A SwiftUI view at `.opacity(0)` still takes
                // touches; a UIKit view at `alpha = 0` does not, which is why theirs needs no such
                // line. Without it a finger already resting where the ruler will be could straighten
                // the picture during a flight that has not put the ruler on screen yet.
                .allowsHitTesting(frameChrome > 0.01)
            HStack(spacing: 12) {
                // Leave with the picture untouched.
                Button { close() } label: {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .liquidGlass(Circle(), interactive: true)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 8)

                HStack(spacing: 22) {
                    toolButton("rotate.left", active: false) { rotate() }
                    toolButton("arrow.left.and.right", active: false) { flipH() }
                    // THE RATIOS ARE A MENU NOW, not a row of chips — his 2026-08-14 ask, in his
                    // words: "when i click Resize button plz show me Context menu". A menu is the
                    // right shape for it as well as the asked-for one: seven mutually exclusive
                    // choices with one of them current is exactly what a menu with a checkmark says,
                    // and it says it without spending a band of the screen on a scroller you have to
                    // push sideways to see the end of.
                    Menu {
                        aspectItem("Original", originalRatio)
                        aspectItem("Free", nil)
                        aspectItem("Square", 1)
                        aspectItem("4:5", 4.0/5.0)
                        aspectItem("3:4", 3.0/4.0)
                        aspectItem("16:9", 16.0/9.0)
                        aspectItem("9:16", 9.0/16.0)
                    } label: {
                        Image(systemName: "aspectratio").font(.system(size: 20, weight: .medium))
                            .foregroundStyle(aspect == nil ? .white : Color(hex: 0x3DA1FD))
                            .frame(width: 32, height: 32).contentShape(Rectangle())
                    }
                }
                .padding(.horizontal, 20).frame(height: 46)   // the story toolbar's own capsule
                .liquidGlass(Capsule())

                Spacer(minLength: 8)

                // Take the crop. Blue-tinted glass rather than a flat fill — the app's one shape for
                // a prominent round action (see the composer's send).
                Button { apply() } label: {
                    Image(systemName: "checkmark").font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .liquidGlass(Circle(), interactive: true, tint: Color(.systemBlue))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // Plain icon inside the tool capsule — no background of its own, the capsule is the background.
    private func toolButton(_ icon: String, active: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 20, weight: .medium))
                .foregroundStyle(active ? Color(hex: 0x3DA1FD) : .white)
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(StoryPressStyle())
    }

    /// One line of the resize menu. The tick is the menu's own, so which ratio is on reads the way it
    /// reads everywhere else in iOS rather than as a filled pill this screen invented.
    @ViewBuilder
    private func aspectItem(_ label: String, _ ratio: CGFloat?) -> some View {
        Button {
            edited = true
            setAspect(ratio, animated: true)
        } label: {
            if aspect == ratio { Label(label, systemImage: "checkmark") } else { Text(label) }
        }
    }

    /// THE STRAIGHTEN WHEEL — the thing he sent a picture of rather than a name for.
    ///
    /// A ruler you drag: 60pt of travel to the degree band's edge in each direction, the reading
    /// above it, and a green mark at the middle so zero can be found without looking at the number.
    /// It turns the PICTURE and never the crop frame, which stays square to the screen — that is what
    /// straightening is, and it is why `zoomFloor` exists: a turned picture has to grow to keep the
    /// frame covered.
    ///
    /// ±45°. Past that a straighten is not a straighten any more, it is the 90° button beside it.
    private var straightenWheel: some View {
        VStack(spacing: 4) {
            Text(angle == 0 ? "0" : String(format: "%.0f", angle))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(angle == 0 ? .white.opacity(0.55) : .white)
                .monospacedDigit()
            GeometryReader { geo in
                let w = geo.size.width
                ZStack {
                    // One tick per 2°, taller every 10, so the eye has something to count by.
                    HStack(spacing: 0) {
                        ForEach(-45...45, id: \.self) { d in
                            if d % 2 == 0 {
                                Rectangle()
                                    .fill(.white.opacity(d % 10 == 0 ? 0.75 : 0.3))
                                    .frame(width: 1, height: d % 10 == 0 ? 16 : 9)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .frame(width: w)
                    // Where the reading is taken. Green, because it is the only mark on this ruler
                    // that means "here" rather than "a degree".
                    Rectangle().fill(Color.green).frame(width: 2, height: 20)
                        .offset(x: CGFloat(angle) / 45 * (w / 2))
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { g in
                            edited = true
                            let perPoint = 45.0 / Double(max(1, w / 2))
                            var v = angleStart + Double(g.translation.width) * perPoint
                            v = min(45, max(-45, v))
                            // A degree either side of straight IS straight. Without this, zero is a
                            // value you can only hit by accident.
                            angle = abs(v) < 1 ? 0 : v
                            pan = clampPan(pan)
                        }
                        .onEnded { _ in angleStart = angle }
                )
            }
            .frame(height: 22)
        }
        .padding(.horizontal, 20)
    }

    // MARK: Gestures

    private var moveGesture: some Gesture {
        DragGesture(coordinateSpace: .named("cropCanvas"))
            .onChanged { g in
                if start == .zero { start = crop }
                var r = start.offsetBy(dx: g.translation.width, dy: g.translation.height)
                r.origin.x = min(max(imageFrame.minX, r.minX), imageFrame.maxX - r.width)
                r.origin.y = min(max(imageFrame.minY, r.minY), imageFrame.maxY - r.height)
                crop = r
            }
            .onEnded { _ in start = .zero }
    }

    private func handleGesture(_ h: Handle) -> some Gesture {
        DragGesture(coordinateSpace: .named("cropCanvas"))
            .onChanged { g in
                if start == .zero { start = crop }
                edited = true
                crop = resized(start, handle: h, by: g.translation)
            }
            .onEnded { _ in start = .zero }
    }

    /// Pinch to zoom. Floored by the straighten's coverage, ceilinged at 6, and the slide is
    /// re-clamped on every step because a zoom OUT takes away the room a slide was using.
    /// ⚠️ THE START VALUE IS TAKEN WHEN THE LAST GESTURE ENDED, NOT WHEN THIS ONE BEGINS. Both of
    /// these gestures report a value measured from their OWN beginning — 1 for a pinch, zero for a
    /// drag — so the anchor has to be whatever the state was left at. Reading it inside `onChanged`
    /// instead, behind an "is it still untouched" test, is the shape that accelerates: the test
    /// passes on every frame the state happens to be at its default and the anchor moves with it.
    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { v in
                edited = true
                zoom = min(6, max(zoomFloor, zoomStart * v))
                pan = clampPan(pan)
            }
            .onEnded { _ in zoomStart = zoom }
    }

    /// Slide the picture under the window. In the dimmed part only: inside the frame the drag
    /// belongs to the frame, which is where it has always belonged.
    private var imagePanGesture: some Gesture {
        DragGesture(coordinateSpace: .named("cropCanvas"))
            .onChanged { g in
                edited = true
                pan = clampPan(CGSize(width: panStart.width + g.translation.width,
                                      height: panStart.height + g.translation.height))
            }
            .onEnded { _ in panStart = pan }
    }

    /// Resize `rect` by moving one side or one corner, clamped to the window and the minimum size,
    /// honouring a locked ratio.
    ///
    /// ⚠️ WRITTEN FROM WHICH SIDES MOVE, NOT FROM WHICH CORNER WAS GRABBED. The old version tested
    /// the four corners by name, so adding the four sides to it would have meant eight names in
    /// every one of the four lines. A handle answers "do you move the left edge" and the arithmetic
    /// stays exactly what it was.
    private func resized(_ rect: CGRect, handle h: Handle, by t: CGSize) -> CGRect {
        var minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
        if h.movesLeft   { minX = min(maxX - minSize, max(imageFrame.minX, rect.minX + t.width)) }
        if h.movesRight  { maxX = max(minX + minSize, min(imageFrame.maxX, rect.maxX + t.width)) }
        if h.movesTop    { minY = min(maxY - minSize, max(imageFrame.minY, rect.minY + t.height)) }
        if h.movesBottom { maxY = max(minY + minSize, min(imageFrame.maxY, rect.maxY + t.height)) }
        var r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        if let a = aspect {
            // A locked ratio needs the other axis to follow. A side handle only moves one axis, so
            // which one follows depends on which was dragged: a left/right handle sets the width and
            // the height follows about the frame's own middle, and a top/bottom handle the reverse.
            // A corner keeps the old rule — the width leads and the grabbed corner stays put.
            switch h {
            case .left, .right:
                let newH = min(r.width / a, imageFrame.height)
                r.origin.y = min(max(imageFrame.minY, r.midY - newH / 2), imageFrame.maxY - newH)
                r.size.height = newH
            case .top, .bottom:
                let newW = min(r.height * a, imageFrame.width)
                r.origin.x = min(max(imageFrame.minX, r.midX - newW / 2), imageFrame.maxX - newW)
                r.size.width = newW
            default:
                let newH = min(r.width / a, imageFrame.height)
                if h.movesTop { r.origin.y = r.maxY - newH }   // the fixed side stays fixed
                r.size.height = newH
            }
        }
        return r
    }

    // MARK: Apply / transforms

    /// TAKE WHAT IS INSIDE THE FRAME — by DRAWING what the screen is drawing, into the frame.
    ///
    /// ⚠️ THIS IS NO LONGER A PIXEL CROP, AND IT CANNOT BE. `cgImage.cropping(to:)` takes an
    /// axis-aligned rectangle of the original pixels, which is exactly right for a picture that is
    /// only ever fitted and never turned. A straightened picture puts the frame's four corners on a
    /// TURNED rectangle in the source, and no axis-aligned rectangle of source pixels is that.
    ///
    /// So the export replays the screen instead of trying to invert it: the same window, the same
    /// zoom, the same angle, the same slide, drawn into a canvas the size of the crop frame. What
    /// comes out is what he was looking at, to the pixel, whatever combination of the three he used.
    /// The unturned, unzoomed case lands on the identical rectangle it always did.
    private func apply() {
        // Source pixels per canvas point, so the export keeps the resolution it had rather than the
        // resolution of the screen it was framed on.
        let ppp = (img.size.width * img.scale) / max(1, displayFrame.width)
        let outPx = CGSize(width: max(1, crop.width * ppp), height: max(1, crop.height * ppp))
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1                      // `outPx` is already in pixels
        fmt.opaque = false
        let out = UIGraphicsImageRenderer(size: outPx, format: fmt).image { ctx in
            let c = ctx.cgContext
            // Canvas points → output pixels, with the crop's own origin at zero.
            c.scaleBy(x: ppp, y: ppp)
            c.translateBy(x: -crop.minX, y: -crop.minY)
            // …then exactly what the view does: turn about the picture's centre and draw it there.
            c.translateBy(x: displayFrame.midX, y: displayFrame.midY)
            c.rotate(by: CGFloat(angle) * .pi / 180)
            c.translateBy(x: -displayFrame.midX, y: -displayFrame.midY)
            img.draw(in: displayFrame)
        }
        // ⚠️ THE NORMALISED RECTANGLE IS ONLY OFFERED WHEN IT IS TRUE. It exists for VIDEO, which
        // cannot be handed a cropped picture and is given the rectangle to apply during its own
        // export — and a rectangle can say "this part of the frame" and nothing else. A turned crop
        // is not expressible as one, so rather than hand over a lie (the bounding box, which is not
        // what he framed) this stays silent and the caller keeps the crop it already had.
        if angle == 0 {
            let ptsPerPoint = img.size.width / max(1, displayFrame.width)
            let inImage = CGRect(x: (crop.minX - displayFrame.minX) * ptsPerPoint,
                                 y: (crop.minY - displayFrame.minY) * ptsPerPoint,
                                 width: crop.width * ptsPerPoint, height: crop.height * ptsPerPoint)
            onRect?(CGRect(x: inImage.minX / img.size.width, y: inImage.minY / img.size.height,
                           width: inImage.width / img.size.width, height: inImage.height / img.size.height))
        }
        onDone(out)
        close()
    }

    private func rotate() {
        edited = true
        let newSize = CGSize(width: img.size.height, height: img.size.width)
        let f = UIGraphicsImageRendererFormat.default(); f.scale = img.scale
        img = UIGraphicsImageRenderer(size: newSize, format: f).image { ctx in
            ctx.cgContext.translateBy(x: newSize.width / 2, y: newSize.height / 2)
            ctx.cgContext.rotate(by: -.pi / 2)
            img.draw(in: CGRect(x: -img.size.width / 2, y: -img.size.height / 2, width: img.size.width, height: img.size.height))
        }
        aspect = aspect.map { 1 / $0 }
        layout(container)
    }

    private func flipH() {
        edited = true
        let f = UIGraphicsImageRendererFormat.default(); f.scale = img.scale
        img = UIGraphicsImageRenderer(size: img.size, format: f).image { ctx in
            ctx.cgContext.translateBy(x: img.size.width, y: 0)
            ctx.cgContext.scaleBy(x: -1, y: 1)
            img.draw(in: CGRect(origin: .zero, size: img.size))
        }
        layout(container)
    }

    private func reset() {
        img = Self.normalized(image)
        aspect = nil
        edited = false
        // The picture's own transform is part of "as it arrived" and has to go back with it. Left
        // behind, Reset would put the frame back over a picture that was still turned and zoomed.
        angle = 0; angleStart = 0
        zoom = 1; zoomStart = 1
        pan = .zero; panStart = .zero
        layout(container)
    }

    private func point(_ h: Handle) -> CGPoint {
        switch h {
        case .topLeft:     return CGPoint(x: crop.minX, y: crop.minY)
        case .topRight:    return CGPoint(x: crop.maxX, y: crop.minY)
        case .bottomLeft:  return CGPoint(x: crop.minX, y: crop.maxY)
        case .bottomRight: return CGPoint(x: crop.maxX, y: crop.maxY)
        case .top:         return CGPoint(x: crop.midX, y: crop.minY)
        case .bottom:      return CGPoint(x: crop.midX, y: crop.maxY)
        case .left:        return CGPoint(x: crop.minX, y: crop.midY)
        case .right:       return CGPoint(x: crop.maxX, y: crop.midY)
        }
    }

    /// The eight places the frame can be grabbed. A handle is described by the sides it moves, which
    /// is the only thing the arithmetic ever asks it.
    private enum Handle: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight, top, bottom, left, right

        static let corners: [Handle] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        static let edges: [Handle] = [.top, .bottom, .left, .right]

        var movesLeft: Bool   { self == .topLeft || self == .bottomLeft || self == .left }
        var movesRight: Bool  { self == .topRight || self == .bottomRight || self == .right }
        var movesTop: Bool    { self == .topLeft || self == .topRight || self == .top }
        var movesBottom: Bool { self == .bottomLeft || self == .bottomRight || self == .bottom }
    }

    // Redraw with .up orientation so pixel-space cropping is correct.
    private static func normalized(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let f = UIGraphicsImageRendererFormat.default(); f.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: f).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}
