import SwiftUI
import UIKit

/// Setting your profile photo: move and scale it once, and check it as BOTH shapes before you
/// commit — the round avatar the app shows in every list, and the poster header at the top of your
/// profile.
///
/// ONE CROP, TWO PREVIEWS. The circle is inscribed in the square, so a single square crop serves
/// both and there is nothing to keep in sync — the tabs change the mask, never the picture. That is
/// also why the backend is untouched: what gets uploaded is still one square photo at one url.
///
/// The pan and the pinch are UIScrollView's own, not gestures written by hand. This is Apple's
/// move-and-scale, which is the same machinery every cropper on the platform is built on, and this
/// app has been bitten before by hand-rolled gesture code.
struct ProfilePhotoCropper: View {
    let image: UIImage
    var onDone: (UIImage) -> Void
    var onCancel: () -> Void

    /// The square that actually gets saved. While `Flags.profileCropShapePreview` is off there is no
    /// switch on screen and this never changes, so the window is always the poster's square — which
    /// is the only crop there has ever been. The circle is inscribed in it.
    @State private var shape: CropShape = .poster
    @State private var source: UIImage?
    @State private var controller = MoveAndScaleController()

    enum CropShape: String, CaseIterable, Identifiable {
        case avatar, poster
        var id: String { rawValue }
        var title: String { self == .avatar ? "Avatar" : "Poster" }
    }

    var body: some View {
        GeometryReader { geo in
            // The window is the full screen width, square — exactly the shape the poster header
            // draws, so what you frame here is what lands there, pixel for pixel.
            let side = geo.size.width
            let hole = CGRect(x: 0, y: (geo.size.height - side) / 2, width: side, height: side)
            ZStack {
                Color.black.ignoresSafeArea()
                if let source {
                    MoveAndScaleView(image: source, controller: controller)
                        .frame(width: side, height: side)
                        .position(x: hole.midX, y: hole.midY)
                }
                // Everything outside the window goes quiet. An even-odd fill, so the picture keeps
                // showing through underneath instead of being hidden — you can see what you are
                // cutting off.
                CutoutShape(hole: hole, radius: shape == .avatar ? side / 2 : 0)
                    .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                chrome
            }
        }
        .task {
            // A library photo often carries an orientation flag rather than rotated pixels, and the
            // crop maths below works in pixels. Straighten it once, here, so nothing downstream has
            // to think about it.
            source = Self.straightened(image)
        }
        .animation(.spring(duration: 0.32), value: shape)
    }

    private var chrome: some View {
        VStack {
            HStack {
                circleButton("xmark") { onCancel() }
                Spacer(minLength: 8)
                // HIDDEN, not removed. With one layout for everyone there is no type of picture to
                // choose, and the switch only ever previewed the same crop as two shapes. `shape`
                // stays on .poster, which is the square that gets saved either way.
                if Flags.profileCropShapePreview { shapeToggle }
                Spacer(minLength: 8)
                circleButton("checkmark") {
                    guard let cropped = controller.crop() else { onCancel(); return }
                    onDone(cropped)
                }
            }
            .padding(.horizontal, 16)
            // This screen is presented ignoring the safe area, so SwiftUI reports zero insets
            // inside it and the status bar has to be cleared from the window's own measurement —
            // the same thing the profile photo viewer does for its close button.
            .padding(.top, winInsets.top + 4)
            Spacer()
        }
    }

    /// Real window safe-area insets, since the view's own are zero here.
    private var winInsets: UIEdgeInsets {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets }
            .max(by: { $0.top < $1.top }) ?? .zero
    }

    /// The Avatar / Poster switch, as real Liquid Glass rather than the system segmented control,
    /// which drew a flat dark pill with a solid white thumb and looked nothing like the rest of iOS
    /// 26 (owner's screenshot).
    ///
    /// THE SELECTED PILL IS ONE VIEW THAT MOVES. It is never rebuilt inside whichever half is
    /// chosen. A hand-built segmented bar in this app has already lost its active pill once by doing
    /// exactly that, and it was reverted; a single capsule sliding to a fixed offset has nothing to
    /// vanish. The offsets are arithmetic on a stated width, so there is no measurement to be late.
    ///
    /// The pill is a translucent fill on the glass, not a second sheet of glass on top of the first:
    /// stacking glass on glass muddies both, and Apple's own selected segment is a lighter face on
    /// the bar rather than another pane. Lighter, not darker as in the reference drawing — darker
    /// disappears against the black this screen shows behind a photo.
    private var shapeToggle: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(.white.opacity(0.22))
                .overlay(Capsule().strokeBorder(.white.opacity(0.30), lineWidth: 0.5))
                .frame(width: toggleWidth / 2 - 8, height: toggleHeight - 8)
                .offset(x: shape == .avatar ? 4 : toggleWidth / 2 + 4)
            HStack(spacing: 0) {
                ForEach(CropShape.allCases) { s in
                    Text(s.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: toggleHeight)
                        .contentShape(Rectangle())
                        .onTapGesture { shape = s }
                }
            }
        }
        .frame(width: toggleWidth, height: toggleHeight)
        .liquidGlass(Capsule())
    }

    private let toggleWidth: CGFloat = 210
    private let toggleHeight: CGFloat = 44

    /// Glass, matching the switch between them, so the three read as one set. This screen was
    /// deliberately kept off glass at first — it is reserved for the five actions on the profile
    /// page — but the owner asked for this bar to be glass, and a frosted circle beside a glass
    /// capsule looks like a mistake.
    private func circleButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .liquidGlass(Circle(), interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    /// Redraw with the orientation baked in, so `cgImage` and `size` finally agree.
    private static func straightened(_ img: UIImage) -> UIImage {
        guard img.imageOrientation != .up else { return img }
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = img.scale
        return UIGraphicsImageRenderer(size: img.size, format: fmt).image { _ in
            img.draw(in: CGRect(origin: .zero, size: img.size))
        }
    }
}

/// The dimming with a hole in it. One rounded rect whose radius carries the whole animation: at
/// zero it is the poster's square, at half the side it IS a circle, and in between the two shapes
/// melt into each other — which is the clearest way to say "these are the same crop".
private struct CutoutShape: Shape {
    var hole: CGRect
    var radius: CGFloat

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path(rect)
        p.addRoundedRect(in: hole, cornerSize: CGSize(width: radius, height: radius), style: .continuous)
        return p
    }
}

/// Holds the live scroll view so the Done button can ask it what is currently framed.
/// Only ever touched from the main thread — it is created, filled and read inside view code.
final class MoveAndScaleController {
    fileprivate weak var scroll: UIScrollView?
    fileprivate var image: UIImage?

    /// The square currently inside the window, as a new image.
    func crop() -> UIImage? {
        guard let scroll, let image, let cg = image.cgImage, scroll.zoomScale > 0 else { return nil }
        let z = scroll.zoomScale
        // What the window shows, in the image view's own points…
        let visible = CGRect(x: scroll.contentOffset.x / z,
                             y: scroll.contentOffset.y / z,
                             width: scroll.bounds.width / z,
                             height: scroll.bounds.height / z)
        // …then in pixels, which is what CGImage cropping speaks.
        let s = image.scale
        let px = CGRect(x: visible.minX * s, y: visible.minY * s,
                        width: visible.width * s, height: visible.height * s)
        // Clamped: a pinch can overshoot for a frame, and a rect that leaves the image returns nil
        // from `cropping` — which would read to the user as Done doing nothing.
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: CGFloat(cg.height))
        guard let cut = cg.cropping(to: px.intersection(bounds).integral) else { return nil }
        return Self.capped(UIImage(cgImage: cut, scale: image.scale, orientation: .up))
    }

    /// A profile photo is drawn at most one screen wide. Anything past that is upload time and
    /// storage nobody sees, so the crop comes down to a sane edge before it leaves.
    private static func capped(_ img: UIImage, maxPx: CGFloat = 1280) -> UIImage {
        let w = img.size.width * img.scale
        guard w > maxPx else { return img }
        let side = maxPx / img.scale
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = img.scale
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: fmt).image { _ in
            img.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
    }
}

/// Apple's move-and-scale: a scroll view the size of the crop window, holding the photo, zoomed so
/// the photo can never be smaller than the window. `clipsToBounds` is off so the picture spills past
/// the window and the dimming above shows what is being cut away.
private struct MoveAndScaleView: UIViewRepresentable {
    let image: UIImage
    let controller: MoveAndScaleController

    func makeUIView(context: Context) -> CropScrollView {
        let scroll = CropScrollView(image: image)
        scroll.delegate = context.coordinator
        context.coordinator.imageView = scroll.imageView
        controller.scroll = scroll
        controller.image = image
        return scroll
    }

    // Nothing to push in: the photo never changes while this screen is up, and the framing belongs
    // to the finger. The one-time setup lives in the view's own first layout instead, because
    // `updateUIView` is not guaranteed to run again once the size is finally known — the pass that
    // discovers the size is a layout pass, not a state change.
    func updateUIView(_ scroll: CropScrollView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var imageView: UIImageView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    }
}

/// The scroll view configures itself the first time it has a real size.
private final class CropScrollView: UIScrollView {
    let imageView: UIImageView
    private var configured = false

    init(image: UIImage) {
        imageView = UIImageView(image: image)
        super.init(frame: .zero)
        imageView.contentMode = .scaleAspectFill
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)

        clipsToBounds = false     // the picture spills; the dimming above says what is cut
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        backgroundColor = .clear
        contentInsetAdjustmentBehavior = .never
        // No bounce: a bounce parks empty space inside the window, and a profile photo with a
        // transparent corner is not something to leave to a race between the finger and the crop.
        bounces = false
        bouncesZoom = false
    }

    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = bounds.width
        guard !configured, side > 0, let size = imageView.image?.size,
              size.width > 0, size.height > 0 else { return }
        configured = true

        imageView.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        // The photo must always COVER the window, so the smallest allowed zoom is whichever edge
        // runs out first. Anything below that could frame empty space.
        let fit = max(side / size.width, side / size.height)
        minimumZoomScale = fit
        maximumZoomScale = fit * 4
        zoomScale = fit
        // Open centred on the middle of the photo, which is where a face usually is.
        contentOffset = CGPoint(x: (size.width * fit - side) / 2,
                                y: (size.height * fit - side) / 2)
    }
}
