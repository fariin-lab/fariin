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
    /// Whose wallpaper this is — the slice uses it to find the chat's live anchor view, because the
    /// state outlives any one visit to the chat (it is cached) and a view reference must not.
    let cid: String
    let id: UInt

    private static var counter: UInt = 0

    fileprivate init(image: UIImage, frame: CGRect, cid: String) {
        self.image = image
        self.frame = frame
        self.cid = cid
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
    private static var backdropCache: [String: UIUserInterfaceStyle] = [:]

    /// THE INTERFACE STYLE THE HEADER'S TEXT NEEDS over this chat's wallpaper: `.dark` (light text)
    /// when the band under the navigation bar is dark, `.light` when it is bright, `.unspecified`
    /// when there is no wallpaper and the app's own appearance is the right answer.
    ///
    /// ⛔ THE NAME VANISHED ON A BLACK WALLPAPER — owner, 2026-08-25, screenshot: "name and subtitle
    /// like last seen, if I use a black wallpaper no one can see". The header carries the reference
    /// app's mechanism for this, a 10pt glass probe behind the avatar whose light/dark trait is meant
    /// to follow the picture beneath and flip the labels; on his phone it did not fire, and a
    /// mechanism that answers "sometimes" is not an answer for the one label a chat cannot do
    /// without. This is the deterministic one: read the picture, measure the band the header sits
    /// on, decide. The probe stays as the fallback for a chat with no wallpaper.
    ///
    /// Relative luminance with the gamma undone (the number contrast is actually defined on, see
    /// `ProfilePalette`), averaged over the top 150pt: the status bar, the bar, the header. The whole
    /// band rather than a point, so a dark picture with one bright highlight does not flip the text.
    /// Cached per chat, theme and wallpaper version like the blur itself.
    static func headerBackdrop(for cid: String, dark: Bool) -> UIUserInterfaceStyle {
        let store = WallpaperStore.shared
        guard store.hasWallpaper(for: cid) else { return .unspecified }
        let frame = windowFrame
        guard frame.width > 1, frame.height > 1 else { return .unspecified }
        let key = "hdr|\(cid)|\(dark)|\(store.version)"
        if let hit = backdropCache[key] { return hit }
        guard let picture = renderWallpaper(cid: cid, dark: dark, size: frame.size) else { return .unspecified }
        let band = CGRect(x: 0, y: 0, width: picture.size.width, height: min(150, picture.size.height))
        let style: UIUserInterfaceStyle = averageLuminance(of: picture, in: band) < 0.4 ? .dark : .light
        if backdropCache.count >= 8 { backdropCache.removeAll() }
        backdropCache[key] = style
        return style
    }

    /// Mean relative luminance of `rect` in `image`, 0 (black) to 1 (white). The band is drawn down
    /// into a 4×4 bitmap with high-quality interpolation, which is a box average of the pixels, then
    /// the sixteen samples are linearised and averaged. Cheap enough to run once per wallpaper.
    private static func averageLuminance(of image: UIImage, in rect: CGRect) -> CGFloat {
        guard let cg = image.cgImage else { return 0.5 }
        let scale = CGFloat(cg.width) / max(1, image.size.width)
        let pixelRect = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                               width: rect.width * scale, height: rect.height * scale)
        guard let band = cg.cropping(to: pixelRect) else { return 0.5 }
        let n = 4
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0.5 }
        ctx.interpolationQuality = .high
        ctx.draw(band, in: CGRect(x: 0, y: 0, width: n, height: n))
        func lin(_ v: UInt8) -> CGFloat {
            let c = CGFloat(v) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        var total: CGFloat = 0
        for i in 0..<(n * n) {
            let r = lin(px[i * 4]), g = lin(px[i * 4 + 1]), b = lin(px[i * 4 + 2])
            total += 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        return total / CGFloat(n * n)
    }

    /// ⛔ **BACK ON — OWNER, 2026-09-02, SAME DAY IT WAS SWITCHED OFF: "Plz restore my custom blur i
    /// dont like it apple type".**
    ///
    /// This flag existed for exactly one working day. The system-material version shipped in build
    /// 724 that morning, he saw it on his phone, and he wanted this back. **That is the answer to a
    /// question this file's neighbours have now flipped THREE times** — do not offer him a material
    /// again without a fresh screenshot from him asking for one.
    ///
    /// ⚠️ **THIS FLAG AND THE RETURN IN `Theme.receivedSurface` ARE A PAIR.** On alone changes
    /// nothing you can see, because the surface decision would not ask for a slice. The other on
    /// alone gives every bubble the flat grey, because it would ask and be handed nil. Both, or
    /// neither. That is why it was left as a flag rather than deleted, and it is what made the
    /// restore a two-line change instead of a revert.
    ///
    /// ⚠️ **WHAT DID NOT COME BACK WITH IT: the rim.** His words were "dont tuch stack thin Line
    /// only Restore the custom blur" — the white-in-both-themes stroke from the morning STAYS. The
    /// surface and the stroke were one commit and are two decisions, and he kept one of them.
    static let enabled = true

    /// The state for this chat, or nil when no picture is wanted: no wallpaper, or Reduce
    /// Transparency on (theirs shows the plain theme background then, and so do we — see
    /// `Theme.receivedSurface`). Cached per chat, theme, size and wallpaper version; the first ask
    /// after any of those changes pays for one render and one blur, on the main thread, exactly as
    /// theirs does. A 390×844 image at radius 20 is a few tens of milliseconds once per chat open.
    static func state(for cid: String, dark: Bool, frame: CGRect) -> WallpaperBlurState? {
        guard enabled else { return nil }
        let store = WallpaperStore.shared
        // The wallpaper going AWAY is the same staleness the other way round: an off-screen bubble
        // would go on showing a slice of a picture the chat no longer has. Same broadcast, emptied.
        guard !UIAccessibility.isReduceTransparencyEnabled,
              store.hasWallpaper(for: cid),
              frame.width > 1, frame.height > 1
        else {
            WallpaperBlurSliceView.clear(cid)
            return nil
        }
        let key = "\(cid)|\(dark)|\(Int(frame.width))x\(Int(frame.height))|\(store.version)"
        if let hit = cache[key] {
            // ⛔ A CACHE HIT MUST BROADCAST TOO, AND NOT DOING SO IS THE LIGHT/DARK BUG — owner,
            // 2026-08-24: "I change light mode to dark, the bubbles and the pin, time and
            // disappearing badges don't understand which mode I picked until I leave the page and
            // come back."
            //
            // ⚠️ IT ONLY BIT ON THE WAY BACK, WHICH IS WHY IT LOOKED RANDOM. Going light → dark is a
            // MISS: a picture is rendered and `adopt` below hands it to every slice already on
            // screen. Going dark → light again is a HIT, and this line used to return the old picture
            // straight to the caller without telling a single live slice about it — so every badge
            // and every incoming bubble went on wearing the wash of the mode he had just left.
            // Leaving the chat and coming back rebuilt them all, which is exactly the workaround he
            // described.
            //
            // The note under `adopt` already says a row is NOT rebuilt merely because its signature
            // changed, and that broadcasting is what covers the rows nobody rebuilds. That reasoning
            // applies whether the picture was made just now or half a minute ago.
            WallpaperBlurSliceView.adopt(hit)
            return hit
        }
        guard let source = renderWallpaper(cid: cid, dark: dark, size: frame.size),
              let blurred = blurred(source, dark: dark) else { return nil }
        let state = WallpaperBlurState(image: blurred, frame: frame, cid: cid)
        // One chat is open at a time and the official channel is the other; anything past a
        // handful is a theme flip or a rotation that will not come back soon.
        if cache.count >= 4 { cache.removeAll() }
        cache[key] = state
        // ⛔ EVERY LIVE SLICE OF THIS CHAT TAKES THE NEW PICTURE AT ONCE — his 2026-08-23 "I change
        // the wallpaper and some bubbles still have the old one", with two teal bubbles left over
        // from the previous wallpaper among a screenful of correct ones.
        //
        // ⚠️ A ROW IS NOT REBUILT JUST BECAUSE ITS SIGNATURE CHANGED. `NativeMessageList` diffs the
        // signatures against `indexPathsForVisibleItems` and refreshes only those — then writes
        // `lastRowSigs = rowSignatures` for ALL of them, so a row that was off screen at that instant
        // is recorded as up to date without ever having been rebuilt, and nothing asks again. Its
        // bubble goes on holding the state it was born with, which is the old picture.
        //
        // Broadcasting is the right shape here rather than a fix to that diff: the picture is a
        // SINGLETON per chat, so "every slice of this cid shows this image" is simply true, and it
        // holds however a given slice got on screen. A slice whose cell IS rebuilt gets the same
        // object through `updateUIView` anyway, so the two paths cannot disagree.
        WallpaperBlurSliceView.adopt(state)
        return state
    }

    // MARK: - The anchor

    /// ⛔ THE SLICES ARE POSITIONED AGAINST THIS VIEW, NOT AGAINST THE WINDOW — his 2026-08-23
    /// "profile → All Media → back and the bubbles lose their colour" screenshot, and a shortcut of
    /// mine the reference app deliberately does not take.
    ///
    /// Converting from the window is only right while the chat is sitting still AT the window's
    /// origin. Coming back from a pushed screen, the chat re-enters the hierarchy mid-slide; every
    /// slice repositions at that moment (`didMoveToWindow`), bakes the transition's offset into its
    /// frame, and nothing runs afterwards to correct it because nothing scrolled. The image ends up
    /// shifted sideways: short bubbles fall entirely outside it and go CLEAR — his "using background
    /// color" — and wide ones show a displaced dark patch beside themselves.
    ///
    /// The reference converts from a reference view INSIDE the conversation screen
    /// (`convert(referenceView.bounds, from: referenceView)`), so the bubble and the wallpaper slide
    /// together and the conversion cancels the slide at every instant. `WallpaperAnchor` is ours: an
    /// inert view laid exactly over the chat's wallpaper, registered per chat. Weak values, so a
    /// closed chat cleans up after itself.
    private static let anchors = NSMapTable<NSString, UIView>(keyOptions: .copyIn,
                                                              valueOptions: .weakMemory)

    static func registerAnchor(_ view: UIView, for cid: String) {
        anchors.setObject(view, forKey: cid as NSString)
    }

    static func anchor(for cid: String) -> UIView? {
        anchors.object(forKey: cid as NSString)
    }

    /// Where a full-screen chat's wallpaper sits once settled: the window. `ChatWallpaperBackground`
    /// is drawn `.ignoresSafeArea()` behind the whole screen. This is the SIZE the picture is made
    /// at, and the positioning fallback for a slice whose chat has no live anchor.
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
        // `pictureSize` is the size being rendered at, so this picture is cropped exactly the way
        // the chat's own wallpaper is — the slices the bubbles show are cut from the picture that
        // is actually on screen. Passing it explicitly rather than letting the container decide is
        // what keeps the two in step if either size ever changes.
        let view = ChatWallpaperBackground(cid: cid, includesScrim: false, pictureSize: size)
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
///
/// ⚠️ **AND THAT TRADE IS NOW GOING THE OTHER WAY — OWNER, 2026-09-02.** He asked for the system's
/// own blur, which means the lift is a snapshot of a `UIVisualEffectView` again. The mechanism is
/// `NativeMessageList.bubbleSource`, `resizableSnapshotView(afterScreenUpdates: false)`. It was
/// reported once before, when the material shipped the first time, and it was never proven — the
/// note in the memory file says do not fix it blind, and it is still unfixed. If an incoming bubble
/// lifts with no background under a long press, this is why, and the fix is at that call site, not
/// here.
@MainActor final class WallpaperBlurSliceView: UIView {
    private static let live = NSHashTable<WallpaperBlurSliceView>.weakObjects()

    /// Called per scroll tick by whoever owns the scrolling — see the note above.
    static func repositionAll() {
        for v in live.allObjects { v.reposition() }
    }

    /// The picture for a chat changed: every live slice of THAT chat takes it, on screen or not.
    /// See the note at the call site in `WallpaperBlur.state(for:dark:frame:)` for why this is a
    /// broadcast and not something each row is trusted to pick up.
    static func adopt(_ new: WallpaperBlurState) {
        for v in live.allObjects where v.state?.cid == new.cid && v.state !== new {
            v.state = new
        }
    }

    /// This chat has no picture any more — wallpaper removed, or Reduce Transparency switched on.
    static func clear(_ cid: String) {
        for v in live.allObjects where v.state?.cid == cid { v.state = nil }
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
            // With no picture there is nothing to rim either: the bubble is a flat colour now and
            // the surface underneath it will say so on the next rebuild.
            strokeShape.isHidden = state == nil || maskPath == nil
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
        strokeShape.lineWidth = 2 * Theme.bubbleRimWidth
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
        // Against the chat's own anchor when it is live and on this window — transition-proof, see
        // `WallpaperBlur.registerAnchor`. The window fallback only serves a slice drawn somewhere
        // its chat's wallpaper is not (which today is nowhere: the previews take the material).
        if let ref = WallpaperBlur.anchor(for: state.cid), ref.window === window {
            imageView.frame = convert(ref.bounds, from: ref)
        } else {
            imageView.frame = convert(state.frame, from: nil)
        }
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

// MARK: - The anchor view

/// Inert and invisible; its only job is to BE somewhere — laid exactly over a chat's wallpaper so
/// the slices have a coordinate space that travels with the screen. Registered on every window
/// attach (a nav pop re-adds the chat's view), and each attach repositions every live slice, so the
/// first frame after a return is already right.
private final class WallpaperAnchorView: UIView {
    var cid: String = "" {
        didSet { if window != nil { WallpaperBlur.registerAnchor(self, for: cid) } }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !cid.isEmpty else { return }
        WallpaperBlur.registerAnchor(self, for: cid)
        WallpaperBlurSliceView.repositionAll()
    }
}

/// Rides as an overlay on the chat's `ChatWallpaperBackground` — and ONLY the chat's. The previews
/// draw the same wallpaper view elsewhere at other sizes; anchoring one of those would point every
/// slice in the real chat at it.
struct WallpaperAnchor: UIViewRepresentable {
    let cid: String

    func makeUIView(context: Context) -> UIView {
        let v = WallpaperAnchorView()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        v.isAccessibilityElement = false
        v.cid = cid
        return v
    }

    func updateUIView(_ v: UIView, context: Context) {
        (v as? WallpaperAnchorView)?.cid = cid
    }
}
