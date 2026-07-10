import SwiftUI

// Interactive crop screen: drag the corner handles to resize the crop frame, drag inside to move it,
// pick an aspect preset (Free / 1:1 / 4:5 / 16:9) or rotate 90°, then Done crops the photo to the
// selected region. Full-screen, dimmed outside the frame, rule-of-thirds grid — the standard crop UX.
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

    init(image: UIImage, onDone: @escaping (UIImage) -> Void) {
        self.image = image; self.onDone = onDone
        _img = State(initialValue: Self.normalized(image))
    }

    private let minSize: CGFloat = 64
    private let hit: CGFloat = 32

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                Image(uiImage: img).resizable().scaledToFit()
                    .frame(width: imageFrame.width, height: imageFrame.height)
                    .position(x: imageFrame.midX, y: imageFrame.midY)

                // Dim everything outside the crop frame (even-odd fill).
                Path { p in p.addRect(CGRect(origin: .zero, size: geo.size)); p.addRect(crop) }
                    .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)

                // Rule-of-thirds grid + border.
                cropChrome
                // Move the frame by dragging inside it.
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

    // MARK: Layout

    private func layout(_ size: CGSize) {
        container = size
        let s = min(size.width / img.size.width, (size.height - 200) / img.size.height)
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

    // MARK: Chrome

    private var cropChrome: some View {
        ZStack {
            Rectangle().stroke(.white, lineWidth: 1)
            ForEach(1...2, id: \.self) { i in
                Path { p in
                    let x = crop.width * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: crop.height))
                }.stroke(.white.opacity(0.4), lineWidth: 0.5)
                Path { p in
                    let y = crop.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: crop.width, y: y))
                }.stroke(.white.opacity(0.4), lineWidth: 0.5)
            }
        }
        .frame(width: crop.width, height: crop.height)
        .position(x: crop.midX, y: crop.midY)
        .allowsHitTesting(false)
    }

    private var cornerHandles: some View {
        ForEach(Corner.allCases, id: \.self) { c in
            ZStack { Circle().fill(.white).frame(width: 16, height: 16) }
                .frame(width: hit, height: hit)
                .contentShape(Circle())
                .gesture(cornerGesture(c))
                .position(point(c))
        }
    }

    private func controls(_ geo: GeometryProxy) -> some View {
        VStack {
            HStack {
                Button { dismiss() } label: { chromeLabel(Image(systemName: "xmark")) }
                Spacer()
                Button { rotate() } label: { chromeLabel(Image(systemName: "rotate.left")) }
            }
            .padding(.horizontal, 16).padding(.top, geo.safeAreaInsets.top + 6)
            Spacer()
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    aspectChip("Free", nil)
                    aspectChip("1:1", 1)
                    aspectChip("4:5", 4.0/5.0)
                    aspectChip("16:9", 16.0/9.0)
                }
                Button { apply() } label: {
                    Text("Done").font(.system(size: 17, weight: .semibold)).foregroundStyle(.black)
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .background(Color.white, in: Capsule())
                }
                .padding(.horizontal, 40)
            }
            .padding(.bottom, geo.safeAreaInsets.bottom + 10)
        }
    }

    private func chromeLabel(_ icon: Image) -> some View {
        icon.font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 44, height: 44).background(.black.opacity(0.4), in: Circle())
    }
    private func aspectChip(_ label: String, _ ratio: CGFloat?) -> some View {
        Button { setAspect(ratio, animated: true) } label: {
            Text(label).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(aspect == ratio ? .black : .white)
                .padding(.horizontal, 14).frame(height: 34)
                .background(aspect == ratio ? Color.white : Color.white.opacity(0.15), in: Capsule())
        }
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
            let newH = r.width / a
            if c == .topLeft || c == .topRight { r.origin.y = r.maxY - newH } // bottom fixed
            r.size.height = newH
            r = r.intersection(imageFrame).isNull ? r : r
        }
        return r
    }

    // MARK: Apply / rotate

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
