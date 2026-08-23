import CoreImage
import SwiftUI
import UIKit

// ⛔ THE SURFACE BEHIND AN INCOMING BUBBLE ON A WALLPAPER, AND IT IS NOT A MATERIAL.
//
// Read from the reference app's source on 2026-08-23, after two rounds of "the bubble colour and
// glass are not the same" that a live material could never have answered. Their `ConversationStyle`
// CHOOSES a blur effect for an incoming bubble on a wallpaper — but their message component never
// hands that effect to a visual-effect view. When the fill is `.blur`, the bubble becomes their
// `CVWallpaperBlurView`: one image of the whole wallpaper, rendered once, Gaussian-blurred, washed
// with colour, and every bubble shows the SLICE of that image that sits underneath it. The recipe
// is `WallpaperBlurProviderImpl.wallpaperBlurState`, ported below number for number.
//
// That is why theirs looks the way it does and a material does not: the +0.4 exposure and the two
// white washes in light mode make a bubble far whiter than `systemThinMaterial`, and the 80% black
// wash in dark mode makes one far darker and steadier than `systemUltraThinMaterial`. Same family
// of idea — the wallpaper showing through — different picture.
//
// ⚠️ NOT iOS 26 GLASS. Checked, because the header and composer in their screenshots clearly are:
// `UIGlassEffect` is on their header, bottom panel, input toolbar, toasts and pickers. No bubble
// file uses it. The bubble is this image on every iOS version.

/// One blurred-and-washed picture of the wallpaper, and where it sits on screen.
///
/// `frame` is in WINDOW coordinates — the wallpaper fills the window behind a chat, so every slice
/// is worked out by converting this frame into the bubble's own space. Identity is what the
/// Equatable compares: two states are the same picture only if they are the same object.
@MainActor final class WallpaperBlurState: Equatable {
    let image: UIImage
    let frame: CGRect
    let id: UInt

    private static var counter: UInt = 0

    fileprivate init(image: UIImage, frame: CGRect) {
        self.image = image
        self.frame = frame
        Self.counter &+= 1
        self.id = Self.counter
    }

    nonisolated static func == (l: WallpaperBlurState, r: WallpaperBlurState) -> Bool { l === r }
}

@MainActor enum WallpaperBlur {
    /// Their blur radius. Twenty at 1× — the image is rendered in points, not pixels, exactly as
    /// theirs is (`renderAsImage(opaque: true, scale: 1)`), so this number means the same thing.
    private static let radius: CGFloat = 20

    private static var cache: [String: WallpaperBlurState] = [:]

    /// The state for this chat, or nil when no picture is wanted: no wallpaper, or Reduce
    /// Transparency on (theirs shows the plain theme background then, and so do we — see
    /// `Theme.receivedSurface`). Cached per chat, theme, size and wallpaper version; the first ask
    /// after any of those changes pays for one render and one blur, on the main thread, exactly as
    /// theirs does. A 390×844 image at radius 20 is a few tens of milliseconds once per chat open.
    static func state(for cid: String, dark: Bool, frame: CGRect) -> WallpaperBlurState? {
        guard !UIAccessibility.isReduceTransparencyEnabled else { return nil }
        let store = WallpaperStore.shared
        guard store.hasWallpaper(for: cid), frame.width > 1, frame.height > 1 else { return nil }
        let key = "\(cid)|\(dark)|\(Int(frame.width))x\(Int(frame.height))|\(store.version)"
        if let hit = cache[key] { return hit }
        guard let source = renderWallpaper(cid: cid, dark: dark, size: frame.size),
              let blurred = blurred(source, dark: dark) else { return nil }
        let state = WallpaperBlurState(image: blurred, frame: frame)
        // One chat is open at a time and the official channel is the other; anything past a
        // handful is a theme flip or a rotation that will not come back soon.
        if cache.count >= 4 { cache.removeAll() }
        cache[key] = state
        return state
    }

    /// Where a full-screen chat's wallpaper sits: the window. `ChatWallpaperBackground` is drawn with
    /// `.ignoresSafeArea()` behind the whole screen, so its origin is the window's origin.
    static var windowFrame: CGRect {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
        return window?.bounds ?? UIScreen.main.bounds
    }

    // MARK: - Rendering

    /// The wallpaper as the chat draws it, at 1×, WITHOUT the photo scrim. Theirs blurs the
    /// undimmed content view and does the darkening in the wash below; blurring a scrim in first
    /// would darken twice.
    private static func renderWallpaper(cid: String, dark: Bool, size: CGSize) -> UIImage? {
        let view = ChatWallpaperBackground(cid: cid, includesScrim: false)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        renderer.isOpaque = true
        return renderer.uiImage
    }

    /// Their `withGaussianBlur(radius:colorOverlays:vibrancy:exposureAdjustment:)`, filter for
    /// filter, in the order they run it: clamp → blur → each wash → vibrance → exposure.
    private static func blurred(_ source: UIImage, dark: Bool) -> UIImage? {
        guard let cg = source.cgImage else { return nil }
        let input = CIImage(cgImage: cg)

        // Clamped first so the blur has pixels to read past the edge; without it the border of a
        // blurred image fades to transparent and every edge bubble goes pale.
        guard let clamp = CIFilter(name: "CIAffineClamp", parameters: [
            kCIInputImageKey: input,
            kCIInputTransformKey: NSValue(cgAffineTransform: .identity),
        ]), let clamped = clamp.outputImage else { return nil }

        guard let blur = CIFilter(name: "CIGaussianBlur", parameters: [
            kCIInputImageKey: clamped,
            kCIInputRadiusKey: radius,
        ]), var out = blur.outputImage else { return nil }

        // THE WASHES, AND THESE ARE THE NUMBERS THAT MAKE IT LOOK LIKE THEIRS.
        // Light: white at 40% laid over the top, then white at 16% as a lighten blend.
        // Dark: black at 80% laid over the top (their default, with the wallpaper dimmed), then a
        // mid grey at 4% as a darken blend. The second pass in each is small and deliberate.
        let washes: [(UIColor, String)] = dark
            ? [(UIColor(white: 0, alpha: 0.8), "CISourceAtopCompositing"),
               (UIColor(white: 0.5, alpha: 0.04), "CIDarkenBlendMode")]
            : [(UIColor(white: 1, alpha: 0.4), "CISourceAtopCompositing"),
               (UIColor(white: 1, alpha: 0.16), "CILightenBlendMode")]
        for (color, mode) in washes {
            guard let gen = CIFilter(name: "CIConstantColorGenerator", parameters: [
                kCIInputColorKey: CIColor(color: color),
            ]), let wash = gen.outputImage,
            let comp = CIFilter(name: mode, parameters: [
                kCIInputBackgroundImageKey: out,
                kCIInputImageKey: wash,
            ]), let next = comp.outputImage else { return nil }
            out = next
        }

        if let vib = CIFilter(name: "CIVibrance", parameters: [
            kCIInputImageKey: out, kCIInputAmountKey: 0.2,
        ]), let next = vib.outputImage { out = next }

        if let exp = CIFilter(name: "CIExposureAdjust", parameters: [
            kCIInputImageKey: out, kCIInputEVKey: 0.4,
        ]), let next = exp.outputImage { out = next }

        // Cropped back to the source's extent: the clamp made it infinite.
        let context = CIContext(options: nil)
        guard let result = context.createCGImage(out, from: input.extent) else { return nil }
        return UIImage(cgImage: result, scale: 1, orientation: .up)
    }
}

// MARK: - The slice

/// One bubble's window onto the blurred wallpaper. The image view inside is the size of the whole
/// wallpaper and is placed so that the part under THIS view is the part that shows, which is the
/// reference app's `imageViewFrame = convert(referenceView.bounds, from: referenceView)`.
///
/// ⚠️ REPOSITIONED ON EVERY SCROLL TICK, AND THAT IS NOT OPTIONAL. A cell that scrolls does not get
/// `layoutSubviews`; the list moves it by changing its own offset. Left alone, a slice would carry
/// the patch of wallpaper it was born over up and down the screen. Theirs calls
/// `updateScrollingContent` on every visible cell per scroll; `repositionAll()` is ours, called from
/// the message list's `scrollViewDidScroll`. Every live slice registers itself for it weakly.
///
/// Not a visual-effect view, and that is the other half of why this replaced one: an image view
/// SNAPSHOTS. The long-press lift copies the bubble with `snapshotView`, which cannot render a blur
/// and came up empty or dead over the previous approach; a slice comes up exactly as drawn.
@MainActor final class WallpaperBlurSliceView: UIView {
    private static let live = NSHashTable<WallpaperBlurSliceView>.weakObjects()

    /// Called per scroll tick by whoever owns the scrolling — see the note above.
    static func repositionAll() {
        for v in live.allObjects { v.reposition() }
    }

    private let imageView = UIImageView()
    private let maskShape = CAShapeLayer()
    /// Their `strokeLayer`, construction and all: the bubble path stroked at 2 hairlines, sitting
    /// inside the masked view so the outer half is clipped and ONE physical pixel of rim survives
    /// on the inside of the edge. Drawn only on the UIKit path (`maskPath != nil`) — the SwiftUI
    /// bubbles draw their rim as a `strokeBorder` overlay because only the site knows the shape.
    private let strokeShape = CAShapeLayer()

    var state: WallpaperBlurState? {
        didSet {
            guard state !== oldValue else { return }
            imageView.image = state?.image
            reposition()
        }
    }

    /// The bubble's outline in THIS view's coordinates. Nil leaves the slice unmasked, which is
    /// right for the SwiftUI bubbles: they clip the whole bubble themselves, background included.
    var maskPath: UIBezierPath? {
        didSet { applyMask() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isUserInteractionEnabled = false
        backgroundColor = .clear
        // The image is at 1× and the frame it is given is the wallpaper's own size, so this is an
        // identity draw; it is only named so a rounding error cannot ask for aspect fitting.
        imageView.contentMode = .scaleToFill
        addSubview(imageView)
        strokeShape.fillColor = nil
        strokeShape.lineWidth = 2 * Theme.hairline
        layer.addSublayer(strokeShape)   // added after the image view → above it; the mask clips both
        // The rim colour is baked to a CGColor, so a light↔dark switch has to re-resolve it by hand.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: WallpaperBlurSliceView, _) in
            self.applyStrokeColor()
        }
        Self.live.add(self)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func applyStrokeColor() {
        let dark = traitCollection.userInterfaceStyle == .dark
        strokeShape.strokeColor = UIColor(Theme.bubbleRim(dark)).cgColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        reposition()
        applyMask()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reposition()
    }

    func reposition() {
        guard let state, window != nil else { return }
        // No implicit animation: this runs every scroll frame, and a 0.25s ease on each would leave
        // the wallpaper lagging behind the bubble it is supposed to be under.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageView.frame = convert(state.frame, from: nil)
        CATransaction.commit()
    }

    private func applyMask() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let maskPath {
            maskShape.frame = bounds
            maskShape.path = maskPath.cgPath
            layer.mask = maskShape
            strokeShape.frame = bounds
            strokeShape.path = maskPath.cgPath
            applyStrokeColor()
            strokeShape.isHidden = false
        } else {
            layer.mask = nil
            strokeShape.isHidden = true
        }
        CATransaction.commit()
    }
}

/// The slice, for the SwiftUI bubbles. Sized by whatever `.background` hands it and clipped by the
/// bubble's own `clipShape` after, so it carries no mask of its own.
struct WallpaperBlurSlice: UIViewRepresentable {
    let state: WallpaperBlurState

    func makeUIView(context: Context) -> WallpaperBlurSliceView {
        let v = WallpaperBlurSliceView()
        v.state = state
        return v
    }

    func updateUIView(_ v: WallpaperBlurSliceView, context: Context) {
        v.state = state
        v.reposition()
    }
}
