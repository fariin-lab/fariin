import SwiftUI

// Interactive crop screen (Signal / iOS Photos behaviour, my own code). Clean, minimalist layout:
//   • top bar  — Cancel (✕) · Reset
//   • image band — the photo with a crop frame: corner brackets to resize, drag inside to move,
//                  thirds grid, everything outside the frame dimmed
//   • controls  — rotate 90° · flip horizontal, a scrollable aspect-ratio row, then Done
// Nothing overlaps the photo; the frame never leaves the image; Done crops to the selected region.
struct ChatCropView: View {
    let image: UIImage
    var onDone: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var img: UIImage
    @State private var container: CGSize = .zero
    @State private var imageFrame: CGRect = .zero   // displayed (aspect-fit) image rect in the container
    @State private var crop: CGRect = .zero         // crop frame in container coords
    @State private var start: CGRect = .zero        // crop at gesture-begin
    @State private var aspect: CGFloat? = nil        // locked w/h, nil = free
    @State private var edited = false                // any change made → show Reset

    init(image: UIImage, onDone: @escaping (UIImage) -> Void) {
        self.image = image; self.onDone = onDone
        _img = State(initialValue: Self.normalized(image))
    }

    private let minSize: CGFloat = 64
    private let hit: CGFloat = 34
    private let topReserve: CGFloat = 104
    private let bottomReserve: CGFloat = 210
    private var originalRatio: CGFloat { img.size.width / max(1, img.size.height) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

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

                controls(geo)
            }
            .onAppear { layout(geo.size) }
            .onChange(of: geo.size) { _, s in layout(s) }
        }
        .statusBarHidden()
    }

    // MARK: Layout — fit the photo into the band between the top bar and the controls (no overlap).

    private func layout(_ size: CGSize) {
        container = size
        let bandY = topReserve
        let bandH = max(80, size.height - topReserve - bottomReserve)
        let availW = size.width - 32
        let s = min(availW / img.size.width, bandH / img.size.height)
        let w = img.size.width * s, h = img.size.height * s
        imageFrame = CGRect(x: (size.width - w) / 2, y: bandY + (bandH - h) / 2, width: w, height: h)
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
        ZStack {
            Rectangle().stroke(.white.opacity(0.9), lineWidth: 1)
            ForEach(1...2, id: \.self) { i in
                Path { p in
                    let x = crop.width * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: crop.height))
                }.stroke(.white.opacity(0.35), lineWidth: 0.5)
                Path { p in
                    let y = crop.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: crop.width, y: y))
                }.stroke(.white.opacity(0.35), lineWidth: 0.5)
            }
        }
        .frame(width: crop.width, height: crop.height)
        .position(x: crop.midX, y: crop.midY)
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

    private func controls(_ geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                }
                Spacer()
                if edited {
                    Button { reset() } label: {
                        Text("Reset").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                            .frame(height: 44).padding(.horizontal, 8)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, geo.safeAreaInsets.top > 0 ? geo.safeAreaInsets.top : 44)

            Spacer()

            VStack(spacing: 18) {
                // Tool row: rotate 90° · flip horizontal.
                HStack(spacing: 40) {
                    toolButton("rotate.left", "Rotate") { rotate() }
                    toolButton("arrow.left.and.right", "Flip") { flipH() }
                }
                // Aspect-ratio presets (scrollable, minimalist chips).
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
            .padding(.bottom, geo.safeAreaInsets.bottom > 0 ? geo.safeAreaInsets.bottom : 16)
        }
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
        DragGesture()
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
        DragGesture()
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
        guard let cg = img.cgImage?.cropping(to: px) else { dismiss(); return }
        onDone(UIImage(cgImage: cg, scale: img.scale, orientation: .up))
        dismiss()
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
