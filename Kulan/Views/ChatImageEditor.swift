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
    var onSend: (_ image: Data, _ caption: String, _ hd: Bool, _ viewOnce: Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var viewOnce = false   // Signal-style: recipient can open the photo exactly once
    @State private var caption = ""
    @State private var drawing = PKDrawing()
    @State private var isDrawing = false
    @State private var filterIndex = 0
    @State private var aspectIndex = 0
    @State private var hd = false
    @State private var canvasSize: CGSize = .zero
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
                if isDrawing {
                    Image(uiImage: edited)
                        .resizable().scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                    DrawingCanvas(drawing: $drawing, isActive: true).ignoresSafeArea()
                } else {
                    ZoomImageView(image: edited, onDim: { _ in }, onDismiss: {}, allowsDismissPan: false)
                        .ignoresSafeArea()
                }

            }
            // NATIVE layout (HIG): chrome is placed by the system inside the safe areas — no manual
            // safeAreaInsets math (it misreports inside a fullScreenCover and floated the X mid-screen).
            // Adapts automatically to Dynamic Island / notch / home indicator on every device.
            .safeAreaInset(edge: .top) {
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
                .padding(.horizontal)          // standard system margins
                .padding(.vertical, 4)
            }
            .safeAreaInset(edge: .bottom) {
                bottomBar
                    .padding(.top, 8)          // standard spacing above the home-indicator inset
            }
            .onAppear { canvasSize = geo.size; recomputeEdited() }
            .onChange(of: geo.size) { _, s in canvasSize = s }
            .onChange(of: filterIndex) { _, _ in recomputeEdited() }
            .onChange(of: aspectIndex) { _, _ in recomputeEdited() }
        }
    }

    // Bottom chrome (Signal AttachmentApprovalToolbar): a row of round glass tool buttons, then the
    // caption capsule + round send. Minimal — no dead icons, everything works.
    private var bottomBar: some View {
        VStack(spacing: 12) {
            // Tool row: crop · draw · filters · HD (Signal's mediaToolbar spacing = 10).
            HStack(spacing: 10) {
                tool("crop", active: aspectIndex != 0) { aspectIndex = (aspectIndex + 1) % Self.aspects.count }
                tool("scribble", active: isDrawing) { isDrawing.toggle() }
                tool("slider.horizontal.3", active: filterIndex != 0) { filterIndex = (filterIndex + 1) % Self.filters.count }
                tool("", active: hd, label: "HD") { hd.toggle() }
                Spacer()
            }

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
