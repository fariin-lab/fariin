import SwiftUI
import UIKit

// MARK: - The switch

/// The adaptive profile background: the page behind a profile takes its colours from that person's
/// photo instead of being the flat grouped grey, and the cards on it become glass so they sample it.
///
/// **OFF by default, and off means UNCHANGED.** Every call site below is written as an either/or, and
/// the sampling that feeds it never runs while the switch is off, so a profile with this turned off
/// draws exactly the view tree it drew before this file existed. That is the point of shipping it on
/// a switch (owner, 2026-08-08: "add button in privacy settings, when I make on I can use that
/// design, when I off I see my original design").
enum ProfileBackgroundStyle {
    static let storageKey = "profileAdaptiveBackground"

    /// For code that is not a View. Views use `@AppStorage` so they redraw when it is flipped.
    static var isOn: Bool { UserDefaults.standard.bool(forKey: storageKey) }
}

extension Notification.Name {
    /// A photo finished sampling. The page that is on screen re-reads the cache and cross-fades in.
    ///
    /// A notification rather than an observable store because the sampling happens inside the header
    /// — which owns the download — while the background belongs to the PAGE. This is the same shape
    /// the story flight already uses to talk across that boundary.
    static let profileAdaptiveThemeReady = Notification.Name("profileAdaptiveThemeReady")
}

// MARK: - The palette taken off a photo

/// The colours of one profile photo, sampled once and kept.
///
/// **`seam` is the load-bearing one.** It is the average of the bottom band of the photo AS THE
/// HEADER DRAWS IT — same aspect-fill, same crop — so the colour the photo dissolves into and the
/// colour the page begins on are the same colour by construction. Every seam this screen has ever
/// been reported for came from two layers meeting at slightly different colours; this one cannot,
/// because there is only one number and both sides read it.
///
/// The accents are what stop the page being a flat wash: the most saturated colour in the left half
/// of the picture and the most saturated in the right half, which is why the blue side of a photo
/// stays on the blue side of the page.
final class ProfileAdaptiveTheme {
    /// The photo url, so a view can tell one person's palette from another's and animate between.
    let key: String
    let seam: UIColor
    let leftAccent: UIColor
    let rightAccent: UIColor
    let dominant: UIColor
    /// THE PAGE ITSELF: the photo, cropped the way the header crops it and downscaled to 160x200.
    ///
    /// His reference (Nextgram, 2026-08-08) does not paint a colour behind a profile at all — it
    /// keeps the PHOTO going down the whole screen, blurred. Every colour-only approximation before
    /// this one was rejected, and this is why: a flat field has no texture for a translucent panel
    /// to sit on, so the cards read as painted shapes however the colour is chosen.
    ///
    /// 160x200 because it is only ever seen through a heavy blur — the same reason the poster's own
    /// wash is 32x48. Keeping the full-size bitmap alive per profile would be the expensive way to
    /// get an image nobody can see the detail of.
    let canvas: UIImage

    private init(key: String, seam: UIColor, leftAccent: UIColor, rightAccent: UIColor,
                 dominant: UIColor, canvas: UIImage) {
        self.key = key
        self.seam = seam
        self.leftAccent = leftAccent
        self.rightAccent = rightAccent
        self.dominant = dominant
        self.canvas = canvas
    }

    // MARK: Cache

    private static let cache = NSCache<NSString, ProfileAdaptiveTheme>()

    /// Already sampled? Answers synchronously, which is what lets a re-opened profile draw its
    /// colours on frame one instead of flashing grey and then tinting.
    static func cached(for url: String?) -> ProfileAdaptiveTheme? {
        guard let url, !url.isEmpty else { return nil }
        return cache.object(forKey: url as NSString)
    }

    /// Sample a decoded photo. Called from the header's load path, which already holds the bitmap —
    /// nothing here downloads anything.
    @discardableResult
    static func sample(_ image: UIImage, for url: String) -> ProfileAdaptiveTheme? {
        if let hit = cache.object(forKey: url as NSString) { return hit }
        guard let theme = build(image, key: url) else { return nil }
        cache.setObject(theme, forKey: url as NSString)
        // ON MAIN, ALWAYS. This can be reached from a download that finished off the main thread, and
        // the only listener is a SwiftUI page that sets @State when it hears it. The cache is written
        // above and NSCache is thread-safe, so by the time the page reads it the palette is there.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .profileAdaptiveThemeReady, object: url)
        }
        return theme
    }

    /// For a page that opens with the photo already on disk: try the palette cache, then the image
    /// cache. Never fetches — if the photo is not here yet the header is fetching it, and the
    /// notification above is what brings the colours in.
    static func resolve(url: String?) async -> ProfileAdaptiveTheme? {
        guard let url, !url.isEmpty else { return nil }
        if let hit = cached(for: url) { return hit }
        if let warm = DiskImageCache.shared.smallImageSync(url) { return sample(warm, for: url) }
        if let disk = await DiskImageCache.shared.image(for: url) { return sample(disk, for: url) }
        return nil
    }

    // MARK: Sampling

    /// A 12x15 draw of the photo — the same 0.8 aspect the poster header shows, so the bands sampled
    /// here are the bands that are actually on screen. 180 pixels is enough for colour and cheap
    /// enough to do on the main thread once per photo.
    private static func build(_ image: UIImage, key: String) -> ProfileAdaptiveTheme? {
        let w = 12, h = 15
        guard let cg = image.cgImage else { return nil }

        // Centre aspect-fill crop, matching `scaledToFill` in a `photoSide x photoSide * 1.25` box.
        let sw = CGFloat(cg.width), sh = CGFloat(cg.height)
        let want = CGFloat(w) / CGFloat(h)
        let src = (sw / sh > want)
            ? CGRect(x: (sw - sh * want) / 2, y: 0, width: sh * want, height: sh)
            : CGRect(x: 0, y: (sh - sw / want) / 2, width: sw, height: sw / want)
        guard let crop = cg.cropping(to: src.integral) else { return nil }

        // Our own buffer, not `&array`: a pointer taken with & is only valid for the call it is
        // passed to, and CGContext keeps it for its whole life. (Same trap as PosterTone.)
        let count = w * h * 4
        let px = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        px.initialize(repeating: 0, count: count)
        defer { px.deallocate() }

        guard let ctx = CGContext(data: px, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Row 0 of a bitmap context's buffer is the TOP row of the image it draws.
        func rgb(_ x: Int, _ y: Int) -> (CGFloat, CGFloat, CGFloat) {
            let i = (y * w + x) * 4
            return (CGFloat(px[i]) / 255, CGFloat(px[i + 1]) / 255, CGFloat(px[i + 2]) / 255)
        }
        func average(x: Range<Int>, y: Range<Int>) -> UIColor {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
            var n: CGFloat = 0
            for yy in y {
                for xx in x {
                    let c = rgb(xx, yy)
                    r += c.0; g += c.1; b += c.2; n += 1
                }
            }
            guard n > 0 else { return .gray }
            return UIColor(red: r / n, green: g / n, blue: b / n, alpha: 1)
        }
        /// The most saturated pixel in a region, which is the colour a person would name if you
        /// asked them what colour the photo is on that side. A plain average of a photograph is
        /// always some kind of brown.
        func vivid(x: Range<Int>, y: Range<Int>) -> UIColor {
            var best = UIColor.gray
            var bestScore = -1.0
            for yy in y {
                for xx in x {
                    let c = rgb(xx, yy)
                    let maxc = max(c.0, max(c.1, c.2)), minc = min(c.0, min(c.1, c.2))
                    let sat = maxc <= 0 ? 0 : (maxc - minc) / maxc
                    // Saturation first, but a black pixel is not a colour and a blown-out white one
                    // is not either, so both ends are damped.
                    let score = Double(sat) * (0.35 + Double(maxc) * (1 - Double(maxc) * 0.45))
                    if score > bestScore { bestScore = score; best = UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1) }
                }
            }
            return best
        }

        // The bottom fifth: the strip the photo's blur has already turned to mush, which is exactly
        // the colour the page has to start on.
        let seam = average(x: 0..<w, y: (h - 3)..<h)
        // Accents come from the lower two thirds — the top of a portrait is usually sky or ceiling,
        // and letting that decide the page's colour is how you get a grey background under a
        // colourful photo.
        let lower = (h / 3)..<h

        // THE PAGE'S OWN PICTURE, from the SAME crop the colours came from, so the background and
        // the numbers describing it can never be of two different framings.
        guard let canvas = downscale(crop, to: CGSize(width: 160, height: 200)) else { return nil }

        return ProfileAdaptiveTheme(key: key,
                                    seam: seam,
                                    leftAccent: vivid(x: 0..<(w / 2), y: lower),
                                    rightAccent: vivid(x: (w / 2)..<w, y: lower),
                                    dominant: average(x: 0..<w, y: lower),
                                    canvas: canvas)
    }

    /// A small opaque copy of the crop. Opaque on purpose: the page behind it is the plain system
    /// background, and a bitmap with an alpha channel would let that grey through the blur at the
    /// edges.
    private static func downscale(_ cg: CGImage, to size: CGSize) -> UIImage? {
        let f = UIGraphicsImageRendererFormat.default()
        f.opaque = true
        f.scale = 1
        let img = UIGraphicsImageRenderer(size: size, format: f).image { _ in
            UIImage(cgImage: cg).draw(in: CGRect(origin: .zero, size: size))
        }
        return img
    }

    // MARK: What the page draws

    /// The colour the header's photo must ARRIVE at, which is the colour the page begins with.
    ///
    /// ⚠️ ONE FUNCTION, TWO READERS, and it has to stay that way: the page holds this colour solid
    /// across the whole region the header covers, and the header fades its photo into it. The moment
    /// the two are computed separately, a line appears where they meet — which this screen has been
    /// reported for three times.
    func canvasSeam() -> Color {
        Color(uiColor: ProfileSurfaceTone.muteCanvas(seam))
    }
}

// MARK: - The background itself

/// The full-page adaptive background: the person's own photo, blurred, running the whole screen.
///
/// THE PICTURE, NOT A PALETTE. This was a `MeshGradient` of extracted colours through four rounds of
/// his verdicts and it was rejected every time, in four different ways. His Nextgram reference
/// (2026-08-08) shows why: that app does not paint a colour behind a profile at all, it keeps the
/// PHOTO going down the whole screen under a heavy blur. You can still see the shape of the sea in
/// his screenshot. A flat field, however cleverly its colours are chosen, gives a translucent panel
/// nothing to sit on — which is the whole of "cards look painted" and why every fill, tint and
/// material tried on top of the mesh read as a shape rather than as glass.
struct ProfileAdaptiveBackdrop: View {
    let theme: ProfileAdaptiveTheme?
    /// Drawn when there is no photo to read, which is the stated fallback: an ordinary system page.
    let fallback: Color
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            fallback
            if let theme {
                Color.clear
                    .overlay {
                        Image(uiImage: theme.canvas)
                            .resizable()
                            .scaledToFill()
                            // HEAVY, because none of the picture is meant to be legible down here —
                            // only its colours, roughly where they were. `opaque: true` keeps the
                            // blur from pulling transparency in at the edges of the bitmap.
                            .blur(radius: 44, opaque: true)
                            // Scaled AFTER the blur, so the soft rim a blur always leaves is pushed
                            // off screen instead of drawing a pale border down both sides.
                            .scaleEffect(1.25)
                    }
                    .clipped()
                    .overlay(seamVeil(theme))
                    .overlay(settle)
            }
        }
        // ONE animation, on the colours, so moving from one person to the next is a wash rather than
        // a cut. Identity is deliberately not keyed to the theme.
        .animation(.easeInOut(duration: 0.45), value: theme?.key)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// ⚠️ THE JOIN, AND WHY IT CANNOT SHOW.
    ///
    /// The header's photo fades into `canvasSeam` at its own bottom edge, which lands a little under
    /// halfway down the screen. So the page holds that SAME colour, solid, to 45% — comfortably past
    /// wherever the header actually ends on any device — and only then dissolves into the blurred
    /// picture underneath, finishing at 85%. Two consequences worth keeping: the crossover happens
    /// between a colour and itself, and every pixel of the blurred photo that is revealed is well
    /// below the join, in the region where the cards live and the texture is wanted.
    private func seamVeil(_ theme: ProfileAdaptiveTheme) -> some View {
        let seam = theme.canvasSeam()
        return LinearGradient(stops: [
            .init(color: seam, location: 0),
            .init(color: seam, location: 0.45),
            .init(color: seam.opacity(0), location: 0.85),
        ], startPoint: .top, endPoint: .bottom)
    }

    /// The page settles toward the bottom so the lowest cards keep their contrast and the picture
    /// does not simply stop. Down toward black in dark mode, up toward white in light.
    private var settle: some View {
        LinearGradient(stops: [
            .init(color: Color.black.opacity(0), location: 0.45),
            .init(color: Color.black.opacity(0.30), location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Cards and buttons on that background

/// Are the cards and the round actions on this page drawing as tints of the adaptive background?
///
/// An environment value rather than a parameter because `PosterActionIcon` is used from three
/// screens and only one of them has an adaptive page; threading a flag through every call site would
/// put the decision in six places instead of one.
private struct ProfileAdaptiveSurfaceKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var profileAdaptiveSurface: Bool {
        get { self[ProfileAdaptiveSurfaceKey.self] }
        set { self[ProfileAdaptiveSurfaceKey.self] = newValue }
    }
}

/// THE ONE SURFACE BOTH THE CARDS AND THE BUTTONS WEAR, so they read as one system.
///
/// **This has now been asked for three times and answered three different ways, so the history
/// matters.** It began as `.ultraThinMaterial` because his written spec asked for glassmorphism on
/// "cards, action buttons, and details sections". He rejected that on sight — "cards dont add liquid
/// glass remove plz" — so the cards went back to the ordinary opaque grouped-list card. He rejected
/// THAT too, with Apple's own contact card as the reference: "I want like image 2 and 3 like tahy it
/// most Use color backgroud". White cards on a coloured page were never what he meant; he meant the
/// cards should be MADE OF the page's colour.
///
/// So: a plain translucent white, composited over whatever the mesh is painting underneath. Not a
/// material, which is what he refused twice — nothing here samples or blurs anything. A flat fill at
/// a fraction lets the page's own colour through, which is exactly how Apple's contact card gets an
/// olive card on an olive page and a teal card on a teal one without knowing either colour.
///
/// Lighter in light mode because the page there is already pale, and a 12% veil on a pale page is
/// invisible.
struct ProfileAdaptiveSurface: ViewModifier {
    /// Drawn instead of the tint when the adaptive background is off — the ordinary card colour.
    let plain: Color
    let radius: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.profileAdaptiveSurface) private var adaptive

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }

    @ViewBuilder
    func body(content: Content) -> some View {
        if adaptive {
            // LIQUID GLASS, AND HE PICKED IT BY POINTING AT IT. 2026-08-08, with the Back and Edit
            // buttons ringed in red: "I want them to look exactly like the Back button and Edit
            // button… use that same appearance and material style consistently for the buttons and
            // cards". Those two are TOOLBAR buttons, which iOS 26 renders with `glassEffect` on its
            // own — so the look he has chosen is Liquid Glass, seen on the real thing, in context.
            //
            // This supersedes "cards dont add liquid glass" from earlier the same day. That verdict
            // was passed on `.ultraThinMaterial` over a FLAT mesh, where a panel had nothing behind
            // it to refract. The page is a blurred photograph now, and he has since picked the look
            // himself off two live buttons rather than off a written spec.
            content.liquidGlass(shape)
        } else {
            content.background(plain, in: shape)
        }
    }
}

/// The round actions wear the SAME surface as the cards while the adaptive page is on, which is what
/// makes the two read as one system in his reference (the buttons there are the page's colour too,
/// just a shade lighter). With it off they keep Liquid Glass, which is this page's standing rule.
struct ProfileAdaptiveCircleSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.profileAdaptiveSurface) private var adaptive

    @ViewBuilder
    func body(content: Content) -> some View {
        if adaptive {
            // The same glass the cards wear, which is what "consistently for the buttons and cards"
            // asks for — and what these circles wore before this feature existed.
            content.liquidGlass(Circle(), interactive: true)
        } else {
            content.liquidGlass(Circle(), interactive: true)
        }
    }
}

/// The surface numbers, in one place, straight from his spec.
enum ProfileSurfaceTone {
    /// THE CANVAS HAS TO BE DARKER THAN THE PHOTO, which is his third point and the reason the
    /// first two were not enough on their own. A frosted card is a *relative* effect: it reads as
    /// glass by being lighter and softer than what is behind it, and against the raw colour of a
    /// bright photo — his saturated red and blue pages — there is nothing for it to be lighter than,
    /// so `.ultraThinMaterial` looked like flat pink and flat light blue.
    ///
    /// Dark mode deepens; light mode both deepens and drains, because a light-mode page cannot go
    /// very dark without the header's own name and letter losing their footing on it.
    /// ⚠️ ONE SET OF NUMBERS, ALWAYS THE DARK ONES. His instruction, 2026-08-08: "when am using
    /// full color please always use the dark-mode colors". A profile on this background renders in
    /// dark mode whatever the phone is set to, so there is no light variant left to choose and no
    /// `dark` argument that can be passed wrongly.
    static func muteCanvas(_ c: UIColor) -> UIColor {
        c.scaled(brightness: 0.55, saturation: 0.95)
    }
}

extension View {
    /// The one place a profile card decides what it sits on. Reads the environment, so a card never
    /// has to be told twice.
    func profileSurface(plain: Color, radius: CGFloat = 24) -> some View {
        modifier(ProfileAdaptiveSurface(plain: plain, radius: radius))
    }
}

// MARK: - Colour arithmetic

private extension UIColor {
    var components: (r: CGFloat, g: CGFloat, b: CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b)
    }

    func mixed(with other: UIColor, _ t: CGFloat) -> UIColor {
        let a = components, b = other.components
        let k = max(0, min(1, t))
        return UIColor(red: a.r + (b.r - a.r) * k,
                       green: a.g + (b.g - a.g) * k,
                       blue: a.b + (b.b - a.b) * k, alpha: 1)
    }

    /// Multiply brightness and saturation in HSB, clamped. Keeps the hue, which is the only part of
    /// a photo's colour that has to survive being taken to the bottom of a page.
    func scaled(brightness: CGFloat, saturation: CGFloat) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
        return UIColor(hue: h, saturation: min(1, s * saturation), brightness: min(1, b * brightness), alpha: 1)
    }

    /// Lift a washed-out sample toward the colour a person would say the photo is, without letting a
    /// near-grey pixel turn into a colour it never was — the boost is on what is already there.
    func vibrant(_ boost: CGFloat) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
        return UIColor(hue: h, saturation: min(1, s * boost), brightness: min(1, max(b, 0.22)), alpha: 1)
    }
}
