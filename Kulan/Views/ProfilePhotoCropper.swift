import SwiftUI
import UIKit

/// Setting your profile photo, in TWO framings of the same picture.
///
/// The circle and the tall header are not two views of one crop, and pretending they were is what
/// this replaces. A face centred for a full-width header is not centred for a 40pt circle in a chat
/// list, and the circle is what people actually see — in the chat list, on stories, in the message
/// header, in group members. Owner: "the user is never shown the circular avatar that is used
/// throughout the app."
///
/// So: frame the CIRCLE first, tick, then frame the HEADER, tick. Two images come out and both are
/// saved.
///
/// ONE scroll view across both stages, not one each. It used to be rebuilt on the tick, which meant
/// the picture you had just framed was thrown away and replaced by a fresh one at its own zoom — a
/// hard cut, and the owner's "the animation is not looks good". The window now MORPHS from the circle
/// to the tall rectangle while the photo underneath keeps the same point centred, zooming only as far
/// as it must to cover the bigger window. What you framed in the circle is where the header opens.
///
/// The pan and the pinch are UIScrollView's own, not gestures written by hand. This is Apple's
/// move-and-scale, the machinery every cropper on the platform is built on, and this app has been
/// bitten before by hand-rolled gesture code.
struct ProfilePhotoCropper: View {
    let image: UIImage
    /// (avatar, poster) — the circle for every list in the app, the tall one for the profile header.
    var onDone: (UIImage, UIImage) -> Void
    var onCancel: () -> Void

    enum Stage { case avatar, poster }

    @State private var stage: Stage = .avatar
    @State private var avatarResult: UIImage?
    @State private var source: UIImage?
    @State private var controller = MoveAndScaleController()

    var body: some View {
        GeometryReader { geo in
            // AVATAR: a circle, as big as the screen allows. POSTER: full width, taller than wide,
            // the exact shape the header draws — `PosterGeometry.aspect`, shared with it rather than
            // repeated, so what you frame cannot be a different shape from what lands.
            let w = geo.size.width
            let circle = min(w - 48, geo.size.height - 200)
            let size = stage == .avatar
                ? CGSize(width: circle, height: circle)
                : CGSize(width: w, height: min(w * PosterGeometry.aspect, geo.size.height))
            let hole = CGRect(x: (geo.size.width - size.width) / 2,
                              y: (geo.size.height - size.height) / 2,
                              width: size.width, height: size.height)
            ZStack {
                Color.black.ignoresSafeArea()
                if let source {
                    // NO `.id` PER STAGE. Changing it destroys the scroll view and builds another,
                    // which is what made the tick jump: a new one opens centred at its own zoom with
                    // no memory of what you framed. It survives the stage change now and re-derives
                    // its zoom floor from its own bounds, so it can be resized instead of replaced.
                    MoveAndScaleView(image: source, controller: controller)
                        .frame(width: size.width, height: size.height)
                        .position(x: hole.midX, y: hole.midY)
                }
                // Everything outside the window goes quiet. An even-odd fill, so the picture keeps
                // showing through underneath instead of being hidden — you can see what you are
                // cutting off.
                CutoutShape(hole: hole, radius: stage == .avatar ? size.width / 2 : 0)
                    .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                if stage == .poster {
                    blurBand(in: hole).transition(.opacity)
                }
                chrome
            }
            // ONE animation for the whole change, so the window, the dimming, the photo and the two
            // lines of title move together. A spring rather than a curve: the window is growing into
            // a shape, and a shape that settles reads as a thing arriving instead of a screen swap.
            .animation(.snappy(duration: 0.42, extraBounce: 0.06), value: stage)
        }
        .task {
            // A library photo often carries an orientation flag rather than rotated pixels, and the
            // crop maths below works in pixels. Straighten it once, here, so nothing downstream has
            // to think about it.
            source = Self.straightened(image)
        }
    }

    private var title: String {
        stage == .avatar ? "Avatar" : "Profile photo"
    }

    private var subtitle: String {
        stage == .avatar
            ? "Shown in chats, stories and groups"
            : "Shown at the top of your profile"
    }

    /// The tick. On the avatar stage it keeps the circle and moves on; on the poster stage it hands
    /// both images back. Nothing is uploaded here — Edit Profile holds them until Save.
    private func advance() {
        guard let cropped = controller.crop() else { return }
        if stage == .avatar {
            avatarResult = cropped
            stage = .poster
        } else if let avatar = avatarResult {
            onDone(avatar, cropped)
        }
    }

    /// X on the first stage, back arrow on the second — see the button. From the poster stage it
    /// steps BACK to the circle rather than throwing the whole thing away: you are two taps in and
    /// losing both for one wrong move is the kind of thing that makes people stop changing their
    /// photo.
    private func back() {
        if stage == .poster {
            avatarResult = nil
            stage = .avatar
        } else {
            onCancel()
        }
    }

    /// Shows WHICH PART OF THE PICTURE WILL BE BLURRED, before you commit to it (owner: "also User
    /// Tell Ares It woll be blur like image 3").
    ///
    /// The profile header softens the photo from the top of the name downwards, so the bottom of
    /// what you frame here is not what anyone will actually see. Marking it is the difference between
    /// a crop you chose and a crop you were surprised by — you can move a face out of this band.
    ///
    /// Its top edge comes from `PosterGeometry.blurStart`, the same function the header blurs from,
    /// so this is a promise the header keeps rather than a drawing that resembles it. Only on the
    /// Poster shape: the round avatar shows the middle of the crop and is never blurred.
    @ViewBuilder private func blurBand(in hole: CGRect) -> some View {
        if stage == .poster {
            let startY = hole.minY + hole.height * PosterGeometry.blurStart(width: hole.width)
            VStack(spacing: 0) {
                Rectangle().fill(.white.opacity(0.28)).frame(height: 0.5)
                ZStack {
                    Color.black.opacity(0.18)
                    Text("Blur")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 4)
                }
            }
            .frame(width: hole.width, height: max(0, hole.maxY - startY))
            .position(x: hole.midX, y: startY + max(0, hole.maxY - startY) / 2)
            .allowsHitTesting(false)   // never steals a pan from the photo underneath
        }
    }

    private var chrome: some View {
        VStack {
            HStack {
                // THE GLYPH TELLS THE TRUTH ABOUT WHERE THE BUTTON GOES (owner 2026-08-03: "now it
                // showing X but is Back button, make it arrow"). On the first stage it closes the
                // cropper, so it is an X. On the second it steps back to the circle you just framed,
                // and an X there promises you are about to lose the picture — which is exactly the
                // fear that stops people finishing.
                circleButton(stage == .poster ? "chevron.left" : "xmark") { back() }
                Spacer(minLength: 8)
                // Says which of the two you are framing AND where it will be seen. Without the second
                // line "Avatar" is our word for it, and the whole reason this screen has two steps is
                // that people did not know the circle existed.
                VStack(spacing: 1) {
                    Text(title).font(.system(size: 17, weight: .semibold))
                    Text(subtitle).font(.system(size: 12)).opacity(0.7)
                }
                // Crossfades the words instead of swapping them on a frame, which is the one part of
                // the change the eye lands on while the window is still moving.
                .contentTransition(.opacity)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 4)
                Spacer(minLength: 8)
                circleButton("checkmark") { advance() }
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

/// The dimming with a hole in it. One rounded rect that carries the whole animation: at a radius of
/// half its side it IS a circle, at zero it is the poster's rectangle, and in between the two shapes
/// melt into each other — which is the clearest way to say "these are the same crop".
///
/// The RECT animates as well as the radius. Radius alone left the hole jumping to its new size and
/// position on the first frame and only rounding down from there, so the melt never happened.
private struct CutoutShape: Shape {
    var hole: CGRect
    var radius: CGFloat

    var animatableData: AnimatablePair<CGRect.AnimatableData, CGFloat> {
        get { AnimatablePair(hole.animatableData, radius) }
        set {
            hole.animatableData = newValue.first
            radius = newValue.second
        }
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
        guard w > maxPx, img.size.width > 0 else { return img }
        // ASPECT PRESERVED. This used to redraw into a square, which was right while the crop was
        // square and would have quietly squashed every photo the moment it became 4:5.
        let scale = maxPx / w
        let size = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = img.scale
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            img.draw(in: CGRect(origin: .zero, size: size))
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

/// The scroll view configures itself the first time it has a real size, and RE-configures whenever
/// that size changes — which is what the stage change is, once the view stopped being rebuilt.
private final class CropScrollView: UIScrollView {
    let imageView: UIImageView
    private var configured = false
    private var lastSize: CGSize = .zero

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
        guard bounds.width > 0, bounds.height > 0,
              let size = imageView.image?.size, size.width > 0, size.height > 0 else { return }

        // The photo must always COVER the window, so the smallest allowed zoom is whichever edge runs
        // out first. BOTH edges: this used to measure height against the window's WIDTH, which was
        // harmless while the crop was square and left the tall poster window short of photo the
        // moment it became 4:5.
        let fit = max(bounds.width / size.width, bounds.height / size.height)

        if !configured {
            configured = true
            imageView.frame = CGRect(origin: .zero, size: size)
            contentSize = size
            minimumZoomScale = fit
            maximumZoomScale = fit * 4
            zoomScale = fit
            // Open centred on the middle of the photo, which is where a face usually is.
            center(on: CGPoint(x: size.width / 2, y: size.height / 2))
            lastSize = bounds.size
            return
        }

        // A pinch or a pan relayouts too. Only a change of WINDOW is our business.
        guard bounds.size != lastSize else { return }
        lastSize = bounds.size

        // Keep whatever is in the middle in the middle. Read it BEFORE touching the zoom, or it is
        // measured against the number we are about to change. This runs on every frame of the morph,
        // so the photo tracks the growing window instead of being re-placed once at the end.
        let held = imageCenter()
        minimumZoomScale = fit
        maximumZoomScale = max(fit * 4, zoomScale)
        // Only ever zoom IN, and only as far as covering the new window demands. Snapping back to
        // `fit` would throw away a zoom the user chose in the circle.
        if zoomScale < fit { zoomScale = fit }
        center(on: held)
    }

    /// The point of the PHOTO currently under the middle of the window, in the photo's own points.
    private func imageCenter() -> CGPoint {
        let z = max(zoomScale, 0.0001)
        return CGPoint(x: (contentOffset.x + bounds.width / 2) / z,
                       y: (contentOffset.y + bounds.height / 2) / z)
    }

    /// Put that point back under the middle, without letting the edge of the photo into the window.
    private func center(on point: CGPoint) {
        guard let size = imageView.image?.size else { return }
        let z = zoomScale
        let maxX = max(0, size.width * z - bounds.width)
        let maxY = max(0, size.height * z - bounds.height)
        contentOffset = CGPoint(x: min(max(0, point.x * z - bounds.width / 2), maxX),
                                y: min(max(0, point.y * z - bounds.height / 2), maxY))
    }
}
