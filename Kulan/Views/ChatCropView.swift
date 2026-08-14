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
    @Environment(\.dismiss) private var dismiss

    @State private var img: UIImage
    @State private var container: CGSize = .zero
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
         onRect: ((CGRect) -> Void)? = nil, onDone: @escaping (UIImage) -> Void) {
        self.image = image; self.inline = inline; self.onClose = onClose
        self.onRect = onRect; self.onDone = onDone
        _img = State(initialValue: Self.normalized(image))
    }

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
                Image(uiImage: img).resizable().scaledToFit()
                    .frame(width: displayFrame.width, height: displayFrame.height)
                    .rotationEffect(.degrees(angle))
                    .position(x: displayFrame.midX, y: displayFrame.midY)
                    .frame(width: imageFrame.width, height: imageFrame.height)
                    .clipped()
                    .position(x: imageFrame.midX, y: imageFrame.midY)
                // THE PICTURE'S OWN GESTURES, UNDERNEATH THE CROP FRAME'S.
                //
                // A pinch anywhere zooms, and a drag in the dimmed part slides the picture. They sit
                // BELOW the crop's move and handle gestures in this stack, so a one-finger drag
                // inside the frame still moves the frame exactly as it always has: the crop's own
                // views are on top and claim it first. Nothing here is modal.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(SimultaneousGesture(pinchGesture, imagePanGesture))

                // Dim everything outside the crop frame (even-odd fill).
                Path { p in p.addRect(CGRect(origin: .zero, size: geo.size)); p.addRect(crop) }
                    .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)

                gridAndBorder
                brackets
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
            .coordinateSpace(name: "cropCanvas")
            .onAppear { layout(geo.size) }
            .onChange(of: geo.size) { _, s in layout(s) }
        }
        .background(Color.black.ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomControls }
    }

    // MARK: Layout — fit the photo into the canvas area (already inset by the safe-area bars).

    private func layout(_ size: CGSize) {
        container = size
        let availW = size.width - 32
        let availH = size.height - 24
        let s = min(availW / img.size.width, availH / img.size.height)
        let w = img.size.width * s, h = img.size.height * s
        imageFrame = CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
        setAspect(aspect, animated: false)
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
            straightenWheel
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
