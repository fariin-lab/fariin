import SwiftUI

// Interactive crop screen (Signal / iOS Photos behaviour, my own code). Clean, minimalist layout:
//   • top bar  — Cancel (✕) · Reset
//   • image band — the photo with a crop frame: corner brackets to resize, drag inside to move,
//                  thirds grid, everything outside the frame dimmed
//   • controls  — rotate 90° · flip horizontal, a scrollable aspect-ratio row, then Done
// Nothing overlaps the photo; the frame never leaves the image; Done crops to the selected region.
struct ChatCropView: View {
    let image: UIImage
    var inline: Bool = false              // true = presented INLINE (fade) → close via onClose, NOT dismiss
    var onClose: () -> Void = {}          // inline close (dismiss() would drop the whole editor to the chat)
    var onDone: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var img: UIImage
    @State private var container: CGSize = .zero
    @State private var imageFrame: CGRect = .zero   // displayed (aspect-fit) image rect in the container
    @State private var crop: CGRect = .zero         // crop frame in container coords
    @State private var start: CGRect = .zero        // crop at gesture-begin
    @State private var aspect: CGFloat? = nil        // locked w/h, nil = free
    @State private var edited = false                // any change made → show Reset

    init(image: UIImage, inline: Bool = false, onClose: @escaping () -> Void = {}, onDone: @escaping (UIImage) -> Void) {
        self.image = image; self.inline = inline; self.onClose = onClose; self.onDone = onDone
        _img = State(initialValue: Self.normalized(image))
    }

    // Inline: close via onClose only (dismiss() would pop the whole editor to the chat). Cover: dismiss().
    private func close() { if inline { onClose() } else { dismiss() } }

    private let minSize: CGFloat = 64
    private let hit: CGFloat = 34
    private var originalRatio: CGFloat { img.size.width / max(1, img.size.height) }

    var body: some View {
        // The crop CANVAS lives between native safe-area bars: the top bar (X / Reset) sits just below the
        // status bar and the controls just above the home indicator — placed by .safeAreaInset, not by
        // hard-coded top padding (which mis-positioned the buttons into the notch in a fullScreenCover).
        GeometryReader { geo in
            ZStack {
                Image(uiImage: img).resizable().scaledToFit()
                    .frame(width: imageFrame.width, height: imageFrame.height)
                    .position(x: imageFrame.midX, y: imageFrame.midY)

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
                cornerHandles
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

    // Heavier white L-brackets at each corner (Photos/Signal look).
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

    private var cornerHandles: some View {
        ForEach(Corner.allCases, id: \.self) { c in
            Color.clear
                .frame(width: hit, height: hit)
                .contentShape(Rectangle())
                .gesture(cornerGesture(c))
                .position(point(c))
        }
    }

    // MARK: Controls

    // Top bar: Cancel (✕) left · Reset right — native circular glass buttons, placed in the safe area.
    private var topBar: some View {
        HStack {
            Button { close() } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .liquidGlass(Circle(), interactive: true)   // real native Liquid Glass
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
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

    // Bottom controls: rotate/flip tool row · aspect presets · Done — placed in the bottom safe area.
    private var bottomControls: some View {
        VStack(spacing: 18) {
            HStack(spacing: 40) {
                toolButton("rotate.left", "Rotate") { rotate() }
                toolButton("arrow.left.and.right", "Flip") { flipH() }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    aspectChip("Original", originalRatio)
                    aspectChip("Free", nil)
                    aspectChip("1:1", 1)
                    aspectChip("4:5", 4.0/5.0)
                    aspectChip("3:4", 3.0/4.0)
                    aspectChip("16:9", 16.0/9.0)
                    aspectChip("9:16", 9.0/16.0)
                }
                .padding(.horizontal, 20)
            }
            Button { apply() } label: {
                Text("Done").font(.system(size: 17, weight: .semibold)).foregroundStyle(.black)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(Color.white, in: Capsule())
            }
            .padding(.horizontal, 40)
        }
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private func toolButton(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 20, weight: .medium))
                Text(label).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private func aspectChip(_ label: String, _ ratio: CGFloat?) -> some View {
        let on = aspect == ratio
        return Button { edited = true; setAspect(ratio, animated: true) } label: {
            Text(label).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(on ? .black : .white)
                .padding(.horizontal, 16).frame(height: 34)
                .background(on ? Color.white : Color.white.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
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

    private func cornerGesture(_ c: Corner) -> some Gesture {
        DragGesture(coordinateSpace: .named("cropCanvas"))
            .onChanged { g in
                if start == .zero { start = crop }
                edited = true
                crop = resized(start, corner: c, by: g.translation)
            }
            .onEnded { _ in start = .zero }
    }

    // Resize `rect` by moving one corner, clamped to imageFrame + min size, honoring the locked aspect.
    private func resized(_ rect: CGRect, corner c: Corner, by t: CGSize) -> CGRect {
        var minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
        if c == .topLeft || c == .bottomLeft { minX = min(maxX - minSize, max(imageFrame.minX, rect.minX + t.width)) }
        if c == .topRight || c == .bottomRight { maxX = max(minX + minSize, min(imageFrame.maxX, rect.maxX + t.width)) }
        if c == .topLeft || c == .topRight { minY = min(maxY - minSize, max(imageFrame.minY, rect.minY + t.height)) }
        if c == .bottomLeft || c == .bottomRight { maxY = max(minY + minSize, min(imageFrame.maxY, rect.maxY + t.height)) }
        var r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        if let a = aspect {   // keep the ratio, anchored to the fixed corner
            let newH = min(r.width / a, imageFrame.height)
            if c == .topLeft || c == .topRight { r.origin.y = r.maxY - newH } // bottom fixed
            r.size.height = newH
        }
        return r
    }

    // MARK: Apply / transforms

    private func apply() {
        let scale = img.size.width / imageFrame.width
        let inImage = CGRect(x: (crop.minX - imageFrame.minX) * scale,
                             y: (crop.minY - imageFrame.minY) * scale,
                             width: crop.width * scale, height: crop.height * scale)
        let px = CGRect(x: inImage.minX * img.scale, y: inImage.minY * img.scale,
                        width: inImage.width * img.scale, height: inImage.height * img.scale)
        guard let cg = img.cgImage?.cropping(to: px) else { close(); return }
        onDone(UIImage(cgImage: cg, scale: img.scale, orientation: .up))
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
        layout(container)
    }

    private func point(_ c: Corner) -> CGPoint {
        switch c {
        case .topLeft:     return CGPoint(x: crop.minX, y: crop.minY)
        case .topRight:    return CGPoint(x: crop.maxX, y: crop.minY)
        case .bottomLeft:  return CGPoint(x: crop.minX, y: crop.maxY)
        case .bottomRight: return CGPoint(x: crop.maxX, y: crop.maxY)
        }
    }

    private enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }

    // Redraw with .up orientation so pixel-space cropping is correct.
    private static func normalized(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let f = UIGraphicsImageRendererFormat.default(); f.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: f).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}
