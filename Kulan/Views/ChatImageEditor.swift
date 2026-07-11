import SwiftUI
import PencilKit
import CoreImage
import CoreImage.CIFilterBuiltins

// In-chat photo editor (WhatsApp-style): the picked image fills the screen with a caption bar
// and a tool row — crop (aspect), pen (draw), light (adjust filters), HD (full-quality). On send
// the edits are flattened into one image and handed back via onSend (+ an optional caption).
// Every button is real. Reuses DrawingCanvas (defined in StoryEditorView.swift).
struct ChatImageEditor: View {
    let source: UIImage
    var onSend: (_ image: Data, _ caption: String, _ hd: Bool, _ viewOnce: Bool) -> Void = { _, _, _, _ in }
    // Edit-only mode (used by the multi-image approval screen to edit ONE photo): no caption / view-once /
    // send — just crop + pen, and a Done button that returns the edited image via onReturn.
    var editOnly: Bool = false
    var startDrawing: Bool = false
    var onReturn: ((UIImage) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var viewOnce = false   // Signal-style: recipient can open the photo exactly once
    @State private var penHue = 0.0       // palette slider (0 = white end)
    @State private var isHighlighter = false
    @State private var penWidth: CGFloat = 6
    @State private var showCrop = false
    @State private var caption = ""
    @State private var drawing = PKDrawing()
    @State private var isDrawing = false
    @State private var filterIndex = 0
    @State private var aspectIndex = 0
    @State private var hd = false
    @State private var canvasSize: CGSize = .zero
    @State private var bottomChromeH: CGFloat = 118   // measured live from the actual bottom bars (Signal queries toolbar heights at runtime)
    @FocusState private var captionFocused: Bool

    private static let ctx = CIContext()
    private static let filters: [(String, String?)] = [
        ("Original", nil), ("Vivid", "CIPhotoEffectChrome"), ("Mono", "CIPhotoEffectMono"),
        ("Fade", "CIPhotoEffectFade"), ("Noir", "CIPhotoEffectNoir"),
    ]
    private static let aspects: [(String, CGFloat?)] = [("Original", nil), ("Square", 1), ("Portrait", 4.0/5.0)]

    // Memoized: filtering+cropping the FULL-RES image is expensive; recompute only when the filter
    // or aspect changes (onChange below), NOT on every caption keystroke / body re-eval.
    @State private var editedCache: UIImage?
    private var edited: UIImage { editedCache ?? source }
    private func recomputeEdited() {
        editedCache = Self.cropped(Self.filtered(source, filterIndex), aspect: Self.aspects[aspectIndex].1)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                // ZOOMABLE canvas (Signal's AttachmentPrep hosts its media in a ZoomableMediaView):
                // pinch to zoom in/out, pan while zoomed, double-tap to zoom. Preview-only zoom.
                // While drawing, the static image shows instead so the pencil owns the touches.
                // NB: image, drawing canvas AND the persistent overlay all live in the SAME geo.size space
                // (no .ignoresSafeArea) so a stroke stays exactly where it was drawn after Done. When the
                // canvas ignored the safe area but the overlay/flatten used geo.size, strokes shifted DOWN
                // by the top inset on Done — the reported bug.
                // The image area EXCLUDES the bottom chrome (Signal's approval layout: the image is
                // inset by the toolbar height + safe area, never hidden behind it) — the photo aspect-
                // FITS this area, fully visible and letterboxed on black, uniformly for every ratio.
                // The canvas, drawing layer and persistent overlay all share this SAME rect so a stroke
                // stays exactly where it was drawn after Done.
                let canvasArea = CGSize(width: geo.size.width,
                                        height: max(120, geo.size.height - bottomChromeH - 8))
                ZStack {
                    if isDrawing {
                        Image(uiImage: edited)
                            .resizable().scaledToFit()
                            .frame(width: canvasArea.width, height: canvasArea.height)
                        // Signal-style brush: OUR palette slider drives the ink (no PKToolPicker chrome).
                        DrawingCanvas(drawing: $drawing, isActive: true,
                                      penColor: penHue == 0 ? .white : UIColor(hue: penHue, saturation: 1, brightness: 1, alpha: 1),
                                      showsToolPicker: false,
                                      inkType: isHighlighter ? .marker : .pen,
                                      penWidth: penWidth)
                            .frame(width: canvasArea.width, height: canvasArea.height)
                    } else {
                        ZoomImageView(image: edited, onSingleTap: { captionFocused = false },
                                      onDim: { _ in }, onDismiss: {}, allowsDismissPan: false)
                            .frame(width: canvasArea.width, height: canvasArea.height)
                        // PERSISTENT drawing: after Done the strokes stay visible over the photo (the bug was
                        // the canvas only showing while actively drawing → the drawing "disappeared").
                        if !drawing.bounds.isEmpty {
                            Image(uiImage: drawing.image(from: CGRect(origin: .zero, size: canvasArea), scale: UIScreen.main.scale))
                                .resizable()
                                .frame(width: canvasArea.width, height: canvasArea.height)
                                .allowsHitTesting(false)
                        }
                    }
                }
                // Rounded canvas ONLY in draw mode (Signal's editor radius 18; plain review has none).
                .clipShape(RoundedRectangle(cornerRadius: isDrawing ? 18 : 0, style: .continuous))
                .frame(width: canvasArea.width, height: canvasArea.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                // Chrome INSIDE the native safe area (no manual inset math). The canvas above ignores
                // the keyboard entirely, so opening the caption keyboard lifts ONLY this bottom bar —
                // the photo and top X stay exactly where they are (Signal/Photos behaviour).
                VStack(spacing: 0) {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .liquidGlass(Circle(), interactive: true)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        if isDrawing {
                            Button { isDrawing = false } label: {
                                Text("Done").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                                    .padding(.horizontal, 18).frame(height: 44)
                                    .liquidGlass(Capsule(), interactive: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 4)
                    Spacer(minLength: 0)
                    Group {
                        if isDrawing { penBar.padding(.bottom, 8) }
                        else { bottomBar.padding(.bottom, 8) }
                    }
                    // Live-measure the bottom chrome so the image area excludes exactly its height
                    // (Signal queries its toolbar heights at runtime — no hardcoded constants). Skipped
                    // while the caption keyboard is up so the canvas never resizes with the keyboard.
                    .background(
                        GeometryReader { g in
                            Color.clear
                                .onAppear { if !captionFocused { bottomChromeH = g.size.height } }
                                .onChange(of: g.size.height) { _, h in if !captionFocused { bottomChromeH = h } }
                        }
                    )
                }
                .animation(.easeInOut(duration: 0.2), value: captionFocused)

                // Crop presented INLINE with a cross-fade (Signal's in-place crop feel) — the same image
                // stays put and the crop frame + controls fade in over it, instead of a modal slide-up.
                if showCrop {
                    ChatCropView(image: source, inline: true,
                                 onClose: { withAnimation(.easeInOut(duration: 0.28)) { showCrop = false } }) { cropped in
                        editedCache = Self.filtered(cropped, filterIndex)   // keep the current filter over the crop
                    }
                    .transition(.opacity)
                    .zIndex(20)
                }
            }
            // Swipe DOWN anywhere on the canvas closes the keyboard (native feel), in addition to the
            // tap-to-dismiss above. Reads the drag without consuming it, so zoom/pan still work.
            .simultaneousGesture(
                DragGesture(minimumDistance: 18)
                    .onChanged { g in if captionFocused, g.translation.height > 24 { captionFocused = false } }
            )
            // canvasSize feeds the flatten step — it MUST equal the rect the strokes were drawn in
            // (the canvas area, not the full screen), or strokes shift on send.
            .onAppear {
                canvasSize = CGSize(width: geo.size.width, height: max(120, geo.size.height - bottomChromeH - 8))
                recomputeEdited()
                if startDrawing { isDrawing = true }
            }
            .onChange(of: geo.size) { _, s in
                canvasSize = CGSize(width: s.width, height: max(120, s.height - bottomChromeH - 8))
            }
            .onChange(of: bottomChromeH) { _, h in
                canvasSize = CGSize(width: geo.size.width, height: max(120, geo.size.height - h - 8))
            }
            .onChange(of: filterIndex) { _, _ in recomputeEdited() }
            .onChange(of: aspectIndex) { _, _ in recomputeEdited() }
        }
    }

    // Brush bottom bar: color palette slider (white → rainbow), then undo · pen/highlighter · width · ✓.
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
                // Pen (solid) vs Highlighter (marker) — the active one shows a colored ring.
                penTool("pencil.tip", active: !isHighlighter) { isHighlighter = false }
                penTool("highlighter", active: isHighlighter) { isHighlighter = true }
                // Stroke width cycles thin → medium → thick.
                Button { penWidth = penWidth >= 16 ? 4 : penWidth + 6 } label: {
                    Circle().fill(currentColor).frame(width: min(penWidth + 6, 26), height: min(penWidth + 6, 26))
                        .frame(width: 44, height: 44)
                        .liquidGlass(Circle(), interactive: true).contentShape(Circle())
                }
                .buttonStyle(.plain)
                Spacer()
                // Edit-only (opened straight into pen from the multi-image screen): finishing the drawing
                // returns the photo immediately — no extra editor page in between.
                Button { if editOnly { returnEdited() } else { isDrawing = false } } label: {
                    Image(systemName: "checkmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 44, height: 44).liquidGlass(Circle(), interactive: true).contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
        }
    }

    private func penTool(_ icon: String, active: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 17, weight: .medium))
                .foregroundStyle(active ? Color(hex: 0x3DA1FD) : .white)
                .frame(width: 44, height: 44)
                .liquidGlass(Circle(), interactive: true).contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // Bottom chrome (Signal AttachmentApprovalToolbar): a row of round glass tool buttons, then the
    // caption capsule + round send. Minimal — no dead icons, everything works.
    private var bottomBar: some View {
        VStack(spacing: 12) {
            // Tool row: crop · draw · HD — HIDDEN while typing a caption (keyboard up). HD is album-level
            // in edit-only mode, so it's dropped there.
            if !captionFocused {
                HStack(spacing: 10) {
                    tool("crop", active: false) { withAnimation(.easeInOut(duration: 0.28)) { showCrop = true } }
                    tool("scribble", active: isDrawing) { isDrawing.toggle() }
                    if !editOnly { tool("", active: hd, label: "HD") { hd.toggle() } }
                    Spacer()
                }
                .transition(.opacity)
            }

            // Edit-only: a single Done button returns the edited photo (no caption/send).
            if editOnly {
                Button { returnEdited() } label: {
                    Text("Done").font(.system(size: 17, weight: .semibold)).foregroundStyle(.black)
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .background(Color.white, in: Capsule())
                }
                .buttonStyle(.plain)
            } else {

            // Caption + send (Signal's text toolbar). The ① toggle (Signal's viewOnceButton) sits in the
            // capsule; view-once media can't carry a caption, so the field becomes "View Once Media".
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    if viewOnce {
                        Text("View Once Media")
                            .foregroundStyle(Color(.systemGray3))
                            .frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        TextField("", text: $caption, prompt: Text("Add a caption…").foregroundColor(Color(.systemGray3)))
                            .foregroundStyle(.white).focused($captionFocused)
                    }
                    Button {
                        viewOnce.toggle()
                        if viewOnce { caption = ""; captionFocused = false }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Image(systemName: viewOnce ? "1.circle.fill" : "1.circle")
                            .font(.system(size: 20))
                            .foregroundStyle(viewOnce ? Color(hex: 0x3DA1FD) : .white)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16).frame(height: 46)
                .liquidGlass(Capsule(), interactive: true)
                Button { send() } label: {
                    Image(systemName: "arrow.up").font(.system(size: 19, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(Color(hex: 0x3DA1FD), in: Circle())
                }
                .buttonStyle(StoryPressStyle())
            }
            }   // end else (non-edit-only caption+send)
        }
        .padding(.horizontal, 16)
    }

    // Round glass tool button (Signal's .roundMedia button style): 44pt, white glyph, accent when active.
    @ViewBuilder
    private func tool(_ icon: String, active: Bool, label: String? = nil, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let label {
                    Text(label).font(.system(size: 13, weight: .bold))
                } else {
                    Image(systemName: icon).font(.system(size: 17, weight: .medium))
                }
            }
            .foregroundStyle(active ? Color(hex: 0x3DA1FD) : .white)
            .frame(width: 44, height: 44)
            .liquidGlass(Circle(), interactive: true)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func send() {
        let data = flatten()
        onSend(data, caption.trimmingCharacters(in: .whitespacesAndNewlines), hd, viewOnce)
        dismiss()
    }

    // Edit-only: hand the flattened (cropped + drawn) image back to the multi-image screen.
    @MainActor private func returnEdited() {
        onReturn?(UIImage(data: flatten()) ?? edited)
        dismiss()
    }

    @MainActor private func flatten() -> Data {
        let base = edited
        let quality: CGFloat = hd ? 0.95 : 0.85
        // No drawing overlay → send the FULL-RESOLUTION edited image. (The ImageRenderer path
        // below rasterizes at screen size, which silently downscaled every sent photo so the
        // "HD" toggle did nothing.) The drawing path must still composite at canvas size.
        if drawing.bounds.isEmpty {
            return base.jpegData(compressionQuality: quality) ?? Data()
        }
        let size = canvasSize == .zero ? UIScreen.main.bounds.size : canvasSize
        let composed = ZStack {
            Image(uiImage: base).resizable().scaledToFit().frame(width: size.width, height: size.height)
            if !drawing.bounds.isEmpty {
                Image(uiImage: drawing.image(from: CGRect(origin: .zero, size: size), scale: UIScreen.main.scale)).resizable()
            }
        }
        .frame(width: size.width, height: size.height)
        let r = ImageRenderer(content: composed); r.scale = UIScreen.main.scale
        return r.uiImage?.jpegData(compressionQuality: quality) ?? (base.jpegData(compressionQuality: quality) ?? Data())
    }

    // MARK: - Image ops
    private static func filtered(_ image: UIImage, _ idx: Int) -> UIImage {
        guard idx != 0, let name = filters[idx].1, let ci = CIImage(image: image),
              let f = CIFilter(name: name) else { return image }
        f.setValue(ci, forKey: kCIInputImageKey)
        guard let out = f.outputImage, let cg = ctx.createCGImage(out, from: out.extent) else { return image }
        return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
    }

    private static func cropped(_ image: UIImage, aspect: CGFloat?) -> UIImage {
        guard let aspect, let cg = image.cgImage else { return image }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        var cw = w, ch = h
        if w / h > aspect { cw = h * aspect } else { ch = w / aspect }
        let rect = CGRect(x: (w - cw) / 2, y: (h - ch) / 2, width: cw, height: ch)
        guard let cropped = cg.cropping(to: rect) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }
}
