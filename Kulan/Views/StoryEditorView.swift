import SwiftUI
import PencilKit
import CoreImage
import CoreImage.CIFilterBuiltins

// Photo-story editor — matches the in-chat photo editor (image 212): the picked photo fits on a
// black canvas; X top-left; a caption bar + @ and a crop / draw / adjust / HD tool row at the
// bottom with a green send. Send flattens the edits and opens the audience sheet, which posts the
// story via StoriesService. Every tool is real.
struct StoryEditorView: View {
    let source: UIImage
    var onPosted: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    @State private var caption = ""
    @State private var drawing = PKDrawing()
    @State private var isDrawing = false
    @State private var filterIndex = 0
    @State private var croppedSource: UIImage?   // result of the interactive crop (nil = uncropped)
    @State private var showCrop = false
    @State private var editedCache: UIImage?         // filtered+cropped; recomputed only on tool change
    @State private var canvasSize: CGSize = .zero
    // Pinch-zoom + pan the photo directly on the canvas (baked WYSIWYG into the post). Driven by UIKit
    // recognizers (PinchPanGestureView) using Telegram's accumulate-and-reset pattern — see below.
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
    @State private var pendingShare: StoryShareData?
    @FocusState private var captionFocused: Bool
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
    private var edited: UIImage { editedCache ?? source }
    private func recomputeEdited() {
        // Filter applies on top of the (interactively) cropped source.
        editedCache = Self.apply(Self.filters[filterIndex].ci, to: croppedSource ?? source)
        updateIconContrast()   // re-sample brightness so the controls stay readable on this photo
    }

    // The photo's aspect-fit size inside the frame (Signal "always-cover" clamp basis).
    private func fittedSize(in frame: CGSize) -> CGSize {
        let s = edited.size
        guard s.width > 0, s.height > 0 else { return frame }
        let scale = min(frame.width / s.width, frame.height / s.height)
        return CGSize(width: s.width * scale, height: s.height * scale)
    }
    // Clamp the pan so the photo edge can reach the frame edge but never past it (no gaps / floating).
    // offset ∈ ±(scaledSize − frameSize)/2  — exactly Signal's ImageEditorTransform.normalize math.
    private func clampedOffset(_ off: CGSize, zoom: CGFloat, in frame: CGSize) -> CGSize {
        let fit = fittedSize(in: frame)
        let maxX = max(0, (fit.width * zoom - frame.width) / 2)
        let maxY = max(0, (fit.height * zoom - frame.height) / 2)
        return CGSize(width: min(maxX, max(-maxX, off.width)),
                      height: min(maxY, max(-maxY, off.height)))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                // Story canvas CARD (user reference, "image 2"): a FULL-WIDTH rounded canvas
                // between the status area and the bottom controls, filled with a heavily muted,
                // near-solid wash of the photo (big blur + desaturation + dark veil — NOT the
                // earlier vivid full-screen blur, which was rejected). Black frames it above
                // and below. Editor-only look; the posted image is untouched.
                // User-tuned (round 3): the STATUS BAR is visible in the editor (reference look),
                // so the card starts just below it; bottom leaves clear room for the controls.
                let cardTop: CGFloat = 8
                let cardBottomGap: CGFloat = 44
                let cardH = geo.size.height - cardTop - cardBottomGap
                let boxed = !imageFillsCanvas(geo.size)
                if boxed, cardH > 0 {
                    Image(uiImage: edited).resizable().scaledToFill()
                        .frame(width: geo.size.width, height: cardH)
                        .blur(radius: 90, opaque: true)
                        .saturation(0.4)
                        .overlay(Color.black.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
                        .position(x: geo.size.width / 2, y: cardTop + cardH / 2)
                        .allowsHitTesting(false)
                }
                // Photo: SQUARE-EDGED, full canvas width, lying on the card (the floating
                // rounded-thumbnail look was rejected). Zoom/pan applied DIRECTLY to a
                // UIImageView's transform in UIKit (no SwiftUI @State write per touch ->
                // zero re-render mid-pinch -> butter smooth, anchored between the fingers).
                // The final scale/offset sync back to photoZoom/photoOffset on release for the WYSIWYG flatten.
                ZoomableImageView(image: edited, scale: $photoZoom, offset: $photoOffset,
                                  maxScale: 4, interactive: !isDrawing && editingID == nil,
                                  onTap: { captionFocused = false; selectedID = nil })
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    // Zoomed/panned photo stays STRICTLY inside the card (user's final spec:
                    // "when I zoom, the image should not go outside the frame"). A MASK only —
                    // the pinch mechanics, pan limits, and the posted photo are untouched.
                    .mask {
                        if boxed, cardH > 0 {
                            Rectangle().fill(.black)
                                .frame(width: geo.size.width, height: cardH)
                                .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
                                .position(x: geo.size.width / 2, y: cardTop + cardH / 2)
                        } else {
                            Rectangle().fill(.black)
                        }
                    }

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
                    // Must live in the SAME space (geo) as the photo + overlays + the flatten capture rect,
                    // otherwise strokes bake shifted down by the top inset and the bottom band is clipped.
                    DrawingCanvas(drawing: $drawing, isActive: true)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else if !drawing.bounds.isEmpty {
                    // Bug fix: after "Done", keep the markup VISIBLE in the preview (it used to vanish because
                    // the canvas only existed in edit mode). Render the saved strokes as a static image, same
                    // space + on top, so it persists and matches the flattened export exactly.
                    Image(uiImage: drawing.image(from: CGRect(origin: .zero, size: geo.size), scale: UIScreen.main.scale))
                        .resizable()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .allowsHitTesting(false)
                }

                // Center alignment guides + trash zone (only while dragging an overlay).
                if draggingID != nil {
                    if guideV { Rectangle().fill(.yellow.opacity(0.9)).frame(width: 1).frame(maxHeight: .infinity).position(x: geo.size.width / 2, y: geo.size.height / 2) }
                    if guideH { Rectangle().fill(.yellow.opacity(0.9)).frame(height: 1).frame(maxWidth: .infinity).position(x: geo.size.width / 2, y: geo.size.height / 2) }
                    Image(systemName: "trash.fill")
                        .font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(trashHot ? Color.red : .black.opacity(0.5), in: Circle())
                        .scaleEffect(trashHot ? 1.25 : 1)
                        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: trashHot)
                        .position(trashCenter)
                }

                // Top controls — stay put when the keyboard opens (don't ride up with it).
                VStack {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)   // always white; glass + shadow carry contrast
                                .shadow(color: .black.opacity(0.35), radius: 2)
                                .frame(width: 48, height: 48).contentShape(Circle()).liquidGlass(Circle())
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
                .opacity(draggingID == nil && editingID == nil ? 1 : 0)
                .ignoresSafeArea(.keyboard, edges: .bottom)

                // Bottom bar — ONLY this rises above the keyboard (caption docks above it, toolbar hides).
                // While DRAWING, hide it entirely so the PencilKit pen palette owns the bottom (no overlap
                // with the caption pill / Aa / crop / send). The top "Done" exits drawing.
                if !isDrawing {
                    VStack {
                        Spacer()
                        bottomBar
                            // User-tuned (round 3): the Aa/crop/draw + NEXT row sinks a bit further
                            // down (it was overlapping the card's bottom edge), toward the indicator.
                            .padding(.bottom, captionFocused ? 8 : -14)
                    }
                    .opacity(draggingID == nil && editingID == nil ? 1 : 0)   // hide chrome while dragging text (trash owns the bottom)
                }
            }
            .coordinateSpace(name: "canvas")
            .onAppear { canvasSize = geo.size; recomputeEdited() }
            .onChange(of: geo.size) { _, s in canvasSize = s }
            .onChange(of: filterIndex) { _, _ in recomputeEdited() }
            .overlay {
                if let id = editingID, let idx = overlays.firstIndex(where: { $0.id == id }) {
                    TextEditorOverlay(
                        draft: $overlays[idx],
                        onCancel: { trimEmpty(id); editingID = nil },
                        onDone: { trimEmpty(id); editingID = nil }
                    )
                }
            }
        }
        .statusBarHidden(false)   // user round 3: the clock/battery must stay visible above the card
        .alert("Couldn't share", isPresented: $postError) { Button("OK", role: .cancel) {} }
        .sheet(item: $pendingShare) { s in
            // Detents/drag-indicator are set INSIDE ShareStorySheet now, so both the photo and text
            // flows get the same compact fitted sheet.
            ShareStorySheet(image: s.data, caption: s.caption, onPosted: { onPosted(); dismiss() })
        }
        .fullScreenCover(isPresented: $showCrop) {
            // Crop from the current cropped result if present, so re-opening crop refines instead of
            // resetting to the original (TOCropViewController, TimOliver — proven crop engine).
            TOCropView(image: croppedSource ?? source,
                       onDone: { cropped in croppedSource = cropped; showCrop = false; recomputeEdited() },
                       onCancel: { showCrop = false })
                .ignoresSafeArea()
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {   // user spec: 12px between the caption bar and the tool row
            // Caption bar — dark pill. While typing, Send sits beside it so you can post without
            // dismissing the keyboard (it used to hide with the toolbar → no way to send).
            HStack(alignment: .bottom, spacing: 10) {
                HStack(spacing: 10) {
                    // Grows with the text (up to 5 lines) instead of staying a single truncated line.
                    TextField("", text: $caption, prompt: Text("Add a caption…").foregroundColor(Color(.systemGray3)), axis: .vertical)
                        .foregroundStyle(.white).focused($captionFocused)
                        .lineLimit(1...5)
                        .onChange(of: caption) { _, v in if v.count > 700 { caption = String(v.prefix(700)) } }  // cap like the text composer
                }
                .padding(.horizontal, 18).padding(.vertical, 9).frame(minHeight: 40)   // user spec: 40px
                // Real Apple Liquid Glass pill (matches the toolbar buttons) instead of a flat dark fill.
                .liquidGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))

                // While typing, a SMALL round send button (not the wide NEXT pill) so the caption
                // field keeps most of the width.
                if captionFocused { compactSendButton }
            }

            // Tool row hides while typing a caption (IG/WA: only the caption field stays, above the keyboard).
            if !captionFocused {
                HStack(spacing: 14) {
                    // Aa / crop / draw grouped in ONE dark capsule (target design), not separate circles.
                    HStack(spacing: 22) {
                        capsuleTool("textformat", active: false) { addTextOverlay() }   // Aa — add text on the photo
                        capsuleTool("crop", active: croppedSource != nil) { showCrop = true }
                        capsuleTool(isDrawing ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle", active: isDrawing) { isDrawing.toggle() }
                    }
                    .padding(.horizontal, 20).frame(height: 46)   // user spec: 46px
                    .liquidGlass(Capsule())   // real Apple Liquid Glass capsule (not a flat dark fill)

                    Spacer()
                    sendButton
                }
            }
        }
        .padding(.horizontal, 16)
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
        Button { Task { await send() } } label: {
            Group {
                if posting { ProgressView().tint(.white) }
                else { Image(systemName: "arrow.up").font(.system(size: 18, weight: .bold)) }
            }
            .foregroundStyle(.white)
            .frame(width: 46, height: 46)
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

    // MARK: - Send
    private func send() async {
        posting = true
        let data = await flatten()
        posting = false
        guard !data.isEmpty else { postError = true; return }   // never hand off a zero-byte (broken) image
        // Caption travels as TEXT (rendered as a Telegram overlay in the viewer), NOT baked into the photo —
        // baking it clipped the text when the image was cropped to fit.
        pendingShare = StoryShareData(data: data, caption: caption.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @MainActor private func flatten() async -> Data {
        let base = edited
        let quality: CGFloat = 0.9
        // No drawing AND no text overlays AND no real zoom/pan → post the full-resolution edited image
        // (caption is no longer baked, so it doesn't force the lossy path). Use near-identity.
        let zoomed = abs(photoZoom - 1) > 0.001 || abs(photoOffset.width) > 0.5 || abs(photoOffset.height) > 0.5
        if drawing.bounds.isEmpty && overlays.isEmpty && !zoomed {
            return base.jpegData(compressionQuality: quality) ?? Data()
        }
        let size = canvasSize == .zero ? UIScreen.main.bounds.size : canvasSize
        let composed = ZStack(alignment: .bottom) {
            Color.black   // Signal/WhatsApp lobby = photo on black (no blurred self-background)
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
            // (Caption is NOT baked here — it's posted as text and drawn as a Telegram-style overlay.)
        }
        .frame(width: size.width, height: size.height)
        let r = ImageRenderer(content: composed); r.scale = UIScreen.main.scale
        return r.uiImage?.jpegData(compressionQuality: quality) ?? (base.jpegData(compressionQuality: quality) ?? Data())
    }

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

// MARK: - Text-on-photo overlay (Telegram/Instagram style)

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

// Full-screen text editor (Telegram image 220): focused field + font/color/align/bg controls.
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
        for g in [pinch, pan, tap] as [UIGestureRecognizer] { g.delegate = context.coordinator; container.addGestureRecognizer(g) }
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

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool {
            !(g is UITapGestureRecognizer || o is UITapGestureRecognizer)
        }
    }
}

// PencilKit drawing surface.
struct DrawingCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    let isActive: Bool
    func makeUIView(context: Context) -> PKCanvasView {
        let v = PKCanvasView()
        v.drawingPolicy = .anyInput
        v.backgroundColor = .clear
        v.isOpaque = false
        v.tool = PKInkingTool(.pen, color: .white, width: 6)
        v.delegate = context.coordinator
        context.coordinator.toolPicker.addObserver(v)   // native PencilKit tool palette
        return v
    }
    func updateUIView(_ v: PKCanvasView, context: Context) {
        if v.drawing != drawing { v.drawing = drawing }
        v.isUserInteractionEnabled = isActive
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
    }
}

// Real interactive crop, Telegram style: pan/zoom the image inside a fixed frame, surroundings DIMMED
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
