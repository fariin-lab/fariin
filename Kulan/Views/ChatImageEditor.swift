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
    // Presented INLINE (fade overlay, e.g. the multi pager's Pen) → close via onClose; dismiss() would
    // pop the PRESENTING screen instead. Mirrors ChatCropView's inline mode.
    var inline: Bool = false
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    private func close() { if inline { onClose?() } else { dismiss() } }

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
        GeometryReader { geo in editorBody(geo.size) }
    }

    // Extracted from `body` so the type-checker isn't overloaded (the ZStack + gesture + 5 onChange
    // modifiers inline blew the expression limit).
    private func editorBody(_ size: CGSize) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // FULL-SCREEN image (matches the multi-image editor): the photo fills the screen and the
            // tools/caption float over it. Canvas, drawing layer, and flatten all share this rect.
            canvasView(canvasArea(size))
            chromeOverlay
            cropOverlay
        }
        // Swipe DOWN anywhere on the canvas closes the keyboard (reads the drag without consuming it).
        .simultaneousGesture(
            DragGesture(minimumDistance: 18)
                .onChanged { g in if captionFocused, g.translation.height > 24 { captionFocused = false } }
        )
        .onAppear {
            canvasSize = canvasArea(size)
            recomputeEdited()
            if startDrawing { isDrawing = true }
        }
        .onChange(of: size) { _, s in canvasSize = canvasArea(s) }
        .onChange(of: bottomChromeH) { _, _ in canvasSize = canvasArea(size) }
        .onChange(of: filterIndex) { _, _ in recomputeEdited() }
        .onChange(of: aspectIndex) { _, _ in recomputeEdited() }
    }

    // Chrome INSIDE the native safe area (no manual inset math). The canvas ignores the keyboard, so
    // opening the caption keyboard lifts ONLY this bottom bar — the photo and top X stay put.
    private var chromeOverlay: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    // In the PEN page (draw mode entered from the editor's scribble tool): X = CANCEL →
                    // discard the current strokes and return to the EDITOR page, not dismiss everything.
                    // (editOnly opens straight into draw with no editor behind it, so there X dismisses.)
                    if isDrawing && !editOnly {
                        drawing = PKDrawing()
                        isDrawing = false
                    } else {
                        close()   // inline overlay → onClose; presented cover → dismiss
                    }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .liquidGlass(Circle(), interactive: true)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                Spacer()
                if isDrawing {
                    Button { bakeDrawing(); isDrawing = false } label: {
                        Text("Done").font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary)
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
            // Live-measure the bottom chrome so the image area excludes exactly its height (Signal
            // queries toolbar heights at runtime). Skipped while the keyboard is up so the canvas
            // never resizes with the keyboard.
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { if !captionFocused { bottomChromeH = g.size.height } }
                        .onChange(of: g.size.height) { _, h in if !captionFocused { bottomChromeH = h } }
                }
            )
        }
        .animation(.easeInOut(duration: 0.2), value: captionFocused)
    }

    // Crop presented INLINE with a cross-fade (Signal's in-place crop feel).
    @ViewBuilder private var cropOverlay: some View {
        if showCrop {
            ChatCropView(image: source, inline: true,
                         onClose: { withAnimation(.easeInOut(duration: 0.28)) { showCrop = false } }) { cropped in
                editedCache = Self.filtered(cropped, filterIndex)
            }
            .transition(.opacity)
            .zIndex(20)
        }
    }

    // Image area = the FULL screen (user request: match the multi-image editor, where the photo fills
    // the screen and the tools/caption float OVER it — the old inset-above-the-chrome canvas read as a
    // "half screen" editor). Canvas, drawing layer, and flatten all share this rect.
    private func canvasArea(_ s: CGSize) -> CGSize { s }

    // The photo aspect-FITS the canvas area — fully visible, letterboxed on black, one uniform rule
    // for every ratio (1:1, 4:5, 3:4, 2:3, 4:3, 3:2, 16:9, 9:16, 19.5:9, 20:9). Pinch zoom keeps
    // min = fit. Strokes are BAKED into the image when draw mode ends (see bakeDrawing) — they live
    // in the image's own pixels, so zoom/pan can never desync an annotation from the photo.
    @ViewBuilder private func canvasView(_ area: CGSize) -> some View {
        ZStack {
            if isDrawing {
                Image(uiImage: edited)
                    .resizable().scaledToFit()
                    .frame(width: area.width, height: area.height)
                // Signal-style brush: OUR palette slider drives the ink (no PKToolPicker chrome).
                DrawingCanvas(drawing: $drawing, isActive: true,
                              penColor: penHue == 0 ? .white : UIColor(hue: penHue, saturation: 1, brightness: 1, alpha: 1),
                              showsToolPicker: false,
                              inkType: isHighlighter ? .marker : .pen,
                              penWidth: penWidth)
                    .frame(width: area.width, height: area.height)
            } else if isTallMedia {
                // LONG PORTRAIT (9:16 or taller, user spec): zoomed out to fully fit (unchanged) with
                // ROUNDED CORNERS on the IMAGE ITSELF — the zoom view is sized to the fitted image rect
                // and clipped, so the corners hug the photo, never the full-screen container. Pinch zoom
                // works normally inside (min = fit; zooming in fills the rounded box).
                let fit = Self.fittedSize(for: edited.size, in: area)
                ZoomImageView(image: edited, onSingleTap: { captionFocused = false },
                              onDim: { _ in }, onDismiss: {}, allowsDismissPan: false)
                    .frame(width: fit.width, height: fit.height)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .frame(width: area.width, height: area.height)   // centered in the canvas
            } else {
                ZoomImageView(image: edited, onSingleTap: { captionFocused = false },
                              onDim: { _ in }, onDismiss: {}, allowsDismissPan: false)
                    .frame(width: area.width, height: area.height)
            }
        }
        // Full-screen canvas like the multi-image editor: centered, no rounded card, chrome floats over.
        .frame(width: area.width, height: area.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // 9:16 or taller → the long-portrait presentation (rounded, fully visible). Standard ratios unchanged.
    private var isTallMedia: Bool {
        edited.size.width > 0 && edited.size.height >= edited.size.width * (16.0 / 9.0) - 1
    }
    private static func fittedSize(for img: CGSize, in area: CGSize) -> CGSize {
        guard img.width > 0, img.height > 0 else { return area }
        let s = min(area.width / img.width, area.height / img.height)
        return CGSize(width: img.width * s, height: img.height * s)
    }

    // Composite the current strokes INTO the image (at the exact rect they were drawn in) and clear
    // the live drawing. After this, annotations are pixels of the photo itself — zooming/panning the
    // editor (or the recipient's viewer) moves them in perfect sync, permanently anchored.
    @MainActor private func bakeDrawing() {
        guard !drawing.bounds.isEmpty else { return }
        let size = canvasSize == .zero ? UIScreen.main.bounds.size : canvasSize
        let composed = ZStack {
            Image(uiImage: edited).resizable().scaledToFit().frame(width: size.width, height: size.height)
            Image(uiImage: drawing.image(from: CGRect(origin: .zero, size: size), scale: UIScreen.main.scale)).resizable()
        }
        .frame(width: size.width, height: size.height)
        let r = ImageRenderer(content: composed)
        r.scale = UIScreen.main.scale
        if let baked = r.uiImage {
            editedCache = baked
            drawing = PKDrawing()
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
                Button { if editOnly { returnEdited() } else { bakeDrawing(); isDrawing = false } } label: {
                    Image(systemName: "checkmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(.primary)
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
                .foregroundStyle(active ? Color(hex: 0x3DA1FD) : .primary)
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
                    tool("scribble", active: isDrawing) { if isDrawing { bakeDrawing() }; isDrawing.toggle() }
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
            // .bottom-aligned so the send button hugs the bottom of a tall multi-line caption (iMessage).
            HStack(alignment: .bottom, spacing: 10) {
                // .bottom-aligned inner row too, so the ① toggle STAYS at the bottom (next to the last
                // line + send) as the caption grows — it was floating UP with the first line.
                HStack(alignment: .bottom, spacing: 8) {
                    if viewOnce {
                        // Centered in the field — same vertical padding as the TextField line, so the
                        // label sits dead-center in the capsule (it was riding low/off-center).
                        Text("View Once Media")
                            .foregroundStyle(Color(.systemGray3))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 9)
                    } else {
                        // Multi-line caption (Signal): 1 → ~7 lines, then scrolls.
                        TextField("", text: $caption, prompt: Text("Add a caption…").foregroundColor(Color(.systemGray3)),
                                  axis: .vertical)
                            .lineLimit(1...7)
                            .foregroundStyle(.white).focused($captionFocused)
                            .padding(.vertical, 9)   // vertical centering for a single line
                    }
                    Button {
                        viewOnce.toggle()
                        if viewOnce { caption = ""; captionFocused = false }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Image(systemName: viewOnce ? "1.circle.fill" : "1.circle")
                            .font(.system(size: 20))
                            .foregroundStyle(viewOnce ? Color(hex: 0x3DA1FD) : .primary)
                            .frame(width: 40, height: 40)   // matches the 40px bar; bottom-aligned
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 16).padding(.trailing, 4).frame(minHeight: 40)
                .liquidGlass(RoundedRectangle(cornerRadius: 20, style: .continuous), interactive: true)
                Button { send() } label: {
                    Image(systemName: "arrow.up").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 40, height: 40)   // 40px send button (user spec)
                        .background(Color(hex: 0x3DA1FD), in: Circle())
                }
                .buttonStyle(StoryPressStyle())
            }
            }   // end else (non-edit-only caption+send)
        }
        .padding(.horizontal, 16)
    }

    // Round glass tool button (crop · pen · HD): 40pt (user spec), white glyph, accent when active.
    @ViewBuilder
    private func tool(_ icon: String, active: Bool, label: String? = nil, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let label {
                    Text(label).font(.system(size: 12, weight: .bold))
                } else {
                    Image(systemName: icon).font(.system(size: 16, weight: .medium))
                }
            }
            .foregroundStyle(active ? Color(hex: 0x3DA1FD) : .primary)
            .frame(width: 40, height: 40)
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
        close()   // inline overlay → onClose; presented cover → dismiss
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
