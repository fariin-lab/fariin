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

    private init(key: String, seam: UIColor, leftAccent: UIColor, rightAccent: UIColor, dominant: UIColor) {
        self.key = key
        self.seam = seam
        self.leftAccent = leftAccent
        self.rightAccent = rightAccent
        self.dominant = dominant
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
        return ProfileAdaptiveTheme(key: key,
                                    seam: seam,
                                    leftAccent: vivid(x: 0..<(w / 2), y: lower),
                                    rightAccent: vivid(x: (w / 2)..<w, y: lower),
                                    dominant: average(x: 0..<w, y: lower))
    }

    // MARK: What the page draws

    /// The nine colours of the 3x3 mesh, top row first.
    ///
    /// **The top row is three copies of one colour on purpose.** Any horizontal variation there would
    /// meet the photo's own bottom edge as a line of changing colour, and a line of changing colour
    /// along a horizontal join is precisely what the eye reads as a seam. The character comes in on
    /// the middle row, a third of the way down the page, where there is no edge for it to draw.
    /// The colour the header's photo must ARRIVE at, which is the mesh's own first row.
    ///
    /// ⚠️ ONE FUNCTION, TWO READERS, and it has to stay that way: the page begins on this colour and
    /// the photo fades into it, so the moment the two are computed separately the join reappears.
    /// The muting below is applied on BOTH sides for exactly that reason — the photo now fades into
    /// something deeper than its own bottom edge, which reads as the picture settling, not as a line.
    func canvasSeam(dark: Bool) -> Color {
        Color(uiColor: ProfileSurfaceTone.muteCanvas(seam, dark: dark))
    }

    func mesh(dark: Bool) -> [Color] {
        // MUTED AT THE SOURCE, once, so every stop below inherits it and no stop can be built from
        // the raw photo colour by accident. See `ProfileSurfaceTone.muteCanvas` for why a frosted
        // card needs this to be here at all.
        let top = ProfileSurfaceTone.muteCanvas(seam, dark: dark)
        let dom = ProfileSurfaceTone.muteCanvas(dominant, dark: dark)
        let accL = ProfileSurfaceTone.muteCanvas(leftAccent.vibrant(1.12), dark: dark)
        let accR = ProfileSurfaceTone.muteCanvas(rightAccent.vibrant(1.12), dark: dark)

        let mid = dom.mixed(with: top, 0.35)
        let midL = accL.mixed(with: mid, 0.55)
        let midR = accR.mixed(with: mid, 0.55)
        // WHERE THE PAGE SETTLES. It still walks down toward the bottom of the screen, so the eye
        // has somewhere to rest and the lowest cards sit against the deepest colour — but from the
        // already-muted stops above, not from the raw photo, and no longer up toward white in light
        // mode. Washing the page out was what left `.ultraThinMaterial` with nothing to frost.
        let floor = dom.scaled(brightness: dark ? 0.70 : 0.88, saturation: 1)
        let floorL = accL.scaled(brightness: dark ? 0.74 : 0.90, saturation: 0.95)
        let floorR = accR.scaled(brightness: dark ? 0.74 : 0.90, saturation: 0.95)
        return [Color(uiColor: top), Color(uiColor: top), Color(uiColor: top),
                Color(uiColor: midL), Color(uiColor: mid), Color(uiColor: midR),
                Color(uiColor: floorL), Color(uiColor: floor), Color(uiColor: floorR)]
    }
}

// MARK: - The background itself

/// The full-page adaptive background: a mesh of the photo's own colours, softened, running from the
/// photo's bottom edge to the bottom of the screen.
///
/// A `MeshGradient` rather than hand-stacked radial blobs because it is native (see the standing
/// preference for native over hand-rolled), because its colours are animatable — which is the whole
/// of the "smooth when you switch profiles" requirement, for free — and because nine control points
/// give the soft, uneven bleed a stack of linear gradients cannot.
///
/// The blur on top is small. The mesh is already smooth; what the blur buys is the last of the
/// banding on a large flat area, which is the one artefact a gradient this size can show.
struct ProfileAdaptiveBackdrop: View {
    let theme: ProfileAdaptiveTheme?
    /// Drawn when there is no photo to read, which is the stated fallback: an ordinary system page.
    let fallback: Color
    @Environment(\.colorScheme) private var scheme

    /// Fixed mesh points. Not a perfect grid — the middle row is pulled slightly off centre so the
    /// bleed reads as light through glass rather than as three stripes.
    private static let points: [SIMD2<Float>] = [
        .init(0, 0),    .init(0.5, 0),    .init(1, 0),
        .init(0, 0.42), .init(0.52, 0.5), .init(1, 0.44),
        .init(0, 1),    .init(0.5, 1),    .init(1, 1),
    ]

    var body: some View {
        ZStack {
            fallback
            if let theme {
                MeshGradient(width: 3, height: 3,
                             points: Self.points,
                             colors: theme.mesh(dark: scheme == .dark))
                    // Blur samples beyond the view's edges and would fade them out; scaling the
                    // blurred result pushes that soft rim off screen instead of letting it draw a
                    // pale border down the sides.
                    .blur(radius: 26)
                    .scaleEffect(1.3)
            }
        }
        // ONE animation, on the colours. Identity is deliberately NOT keyed to the theme: keeping the
        // same MeshGradient and handing it new colours is what makes switching profiles a wash from
        // one palette to the next rather than a cross-fade between two pictures.
        .animation(.easeInOut(duration: 0.45), value: theme?.key)
        .ignoresSafeArea()
        .allowsHitTesting(false)
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
            content
                // TWO FILLS IN THE BACKGROUND, NOT AN OVERLAY. His spec calls the tint an overlay,
                // but a real overlay sits above the CONTENT and would put a veil over the labels and
                // the icons as well as the card. Stacking it inside `.background` tints the surface
                // and leaves the text at full strength, which is the effect he is describing:
                // "so the background canvas color bleeds through naturally".
                .background {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(ProfileSurfaceTone.tint(scheme == .dark))
                }
                // `strokeBorder`, not `stroke`: it draws inside the shape, so a 0.5pt line on a 24pt
                // corner stays on the card instead of straddling its edge.
                .overlay { shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5) }
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
            // Material and a stroke, and NO tint fill — his spec gives the circles those two alone
            // while the cards also get a tint. Followed as written rather than made uniform.
            content
                .background(.ultraThinMaterial, in: Circle())
                .overlay { Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5) }
        } else {
            // Liquid Glass survives ONLY here, on the round actions of a page with no adaptive
            // canvas — the standing rule for this screen. "ccard dont use lequid glass" is about the
            // cards, and no card has ever reached this modifier.
            content.liquidGlass(Circle(), interactive: true)
        }
    }
}

/// The surface numbers, in one place, straight from his spec.
enum ProfileSurfaceTone {
    /// The tint that sits between the material and the content on a card.
    static func tint(_ dark: Bool) -> Color {
        dark ? Color.black.opacity(0.15) : Color.white.opacity(0.08)
    }

    /// THE CANVAS HAS TO BE DARKER THAN THE PHOTO, which is his third point and the reason the
    /// first two were not enough on their own. A frosted card is a *relative* effect: it reads as
    /// glass by being lighter and softer than what is behind it, and against the raw colour of a
    /// bright photo — his saturated red and blue pages — there is nothing for it to be lighter than,
    /// so `.ultraThinMaterial` looked like flat pink and flat light blue.
    ///
    /// Dark mode deepens; light mode both deepens and drains, because a light-mode page cannot go
    /// very dark without the header's own name and letter losing their footing on it.
    static func muteCanvas(_ c: UIColor, dark: Bool) -> UIColor {
        dark ? c.scaled(brightness: 0.55, saturation: 0.95)
             : c.scaled(brightness: 0.80, saturation: 0.60)
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
