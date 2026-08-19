import SwiftUI
import UIKit

extension Notification.Name {
    /// A photo finished being analysed. The profile that is on screen re-reads the cache and washes
    /// into its colours.
    ///
    /// A notification rather than an observable store because the analysis is fed by the HEADER —
    /// the one view that reliably holds a decoded profile photo — while the colours are worn by the
    /// PAGE. This is the same shape the story flight already uses to talk across that boundary.
    static let profilePaletteReady = Notification.Name("profilePaletteReady")
}

// MARK: - The colour a profile photo is actually made of

/// The theme of one profile, taken from that person's photograph.
///
/// **THE COLOUR IS EXTRACTED, NOT SUGGESTED.** `base` is the mean of the real pixels of the winning
/// cluster — the actual grey of a grey studio wall, the actual blue of an ocean — never a blur of
/// the picture, never a palette guess, never an average of everything (the average of a photograph
/// is always some kind of brown). Everything the page draws is derived from that one colour by
/// moving its brightness and its saturation only. **The hue is never touched**, because the hue is
/// the part a person recognises as "their" colour.
///
/// Surfaces come in two families and BOTH are computed, because the palette is cached per photo and
/// the phone can be flipped between light and dark while it is cached. Which family is worn is
/// decided at draw time by `isDark(scheme:)`.
final class ProfilePalette {
    /// Which family of surfaces the picture asks for.
    enum Polarity {
        /// A bright picture — a pale page with dark text, whatever the phone is set to.
        case light
        /// A dark picture — a deep page with light text, whatever the phone is set to.
        case dark
        /// A mid-toned picture. Either family reads well, so the phone's own setting decides and
        /// the profile stays in step with the rest of the app.
        case follow
    }

    let key: String
    /// THE EXTRACTED COLOUR ITSELF, kept exactly as it came off the photograph. Nothing draws this
    /// raw — it is the seed every surface below is derived from, and it is worth keeping honest so
    /// a wrong-looking page can always be traced back to what was actually read.
    let base: UIColor
    let polarity: Polarity

    private let hue: CGFloat
    private let sat: CGFloat
    private let val: CGFloat

    fileprivate init?(key: String, base: UIColor) {
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        guard base.getHue(&h, saturation: &s, brightness: &v, alpha: &a) else { return nil }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        base.getRed(&r, green: &g, blue: &b, alpha: &a)

        self.key = key
        self.base = base
        self.hue = h
        self.sat = s
        self.val = v

        // Perceived lightness, not HSB brightness: green reads far lighter than blue at the same
        // brightness, and getting that backwards is how a page ends up with white text on lime.
        let lum = 0.299 * r + 0.587 * g + 0.114 * b
        if lum > 0.62 { polarity = .light }
        else if lum < 0.24 { polarity = .dark }
        else { polarity = .follow }
    }

    /// The family to wear right now. A clearly bright or clearly dark photograph overrides the
    /// phone; everything in between follows it.
    func isDark(scheme: ColorScheme) -> Bool {
        switch polarity {
        case .light: return false
        case .dark: return true
        case .follow: return scheme == .dark
        }
    }

    // MARK: The surfaces

    /// THE PAGE: one flat colour, and the colour the header's photo dissolves into.
    ///
    /// ⚠️ ONE FUNCTION, TWO READERS, and it has to stay that way. The page paints this and the
    /// header fades its photo to this. The moment the two are computed apart, a line appears where
    /// they meet — which this screen has been reported for three separate times.
    ///
    /// The bands are deliberately narrow. A profile page is a reading surface before it is a mood,
    /// so brightness lands between 0.085 and 0.17 on the dark side and between 0.90 and 0.955 on
    /// the light one — near-black for a black photograph, near-white for a white one, and a deep or
    /// pale version of the real hue for everything else. Saturation is damped hard for the same
    /// reason: the page should read as "their blue", not as blue paint.
    func page(dark: Bool) -> UIColor {
        let c = dark
            ? UIColor(hue: hue, saturation: min(sat, 0.75) * 0.70, brightness: 0.085 + val * 0.085, alpha: 1)
            : UIColor(hue: hue, saturation: min(sat, 0.90) * 0.16, brightness: 0.900 + val * 0.055, alpha: 1)
        return ProfilePalette.readable(c, dark: dark)
    }

    /// A CARD: the same colour, lifted. Not a material, not a translucency, not a blur — a flat
    /// opaque fill that happens to be made of the page's colour, which is how a settings card ends
    /// up olive on an olive page and teal on a teal one without ever being told which.
    ///
    /// Lifted by brightness and DAMPED by saturation, both on purpose. A card that gains colour as
    /// it rises reads as a painted panel; a card that gains light reads as a surface above the
    /// page, which is the whole difference between this and the tinted-plastic look.
    func card(dark: Bool) -> UIColor {
        let p = page(dark: dark)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        guard p.getHue(&h, saturation: &s, brightness: &v, alpha: &a) else { return p }
        return dark
            ? UIColor(hue: h, saturation: s * 0.88, brightness: min(1, v + 0.075), alpha: 1)
            : UIColor(hue: h, saturation: s * 0.55, brightness: min(1, v + 0.050), alpha: 1)
    }

    /// The hairline round a card. It exists for the light family, where the card and the page are
    /// only five points of brightness apart and a shadow would be the wrong answer (this design has
    /// no shadows). On the dark family it is nearly invisible and that is correct — there the
    /// brightness step alone already separates them.
    func edge(dark: Bool) -> UIColor {
        dark ? UIColor(white: 1, alpha: 0.06) : UIColor(white: 0, alpha: 0.05)
    }

    /// A separator INSIDE a card, which cannot be the system's own: that one is resolved against
    /// the system background, and on a tinted card it reads as a scratch.
    func separator(dark: Bool) -> UIColor {
        dark ? UIColor(white: 1, alpha: 0.10) : UIColor(white: 0, alpha: 0.08)
    }

    // MARK: Contrast

    /// Nudge a surface until the text that will sit on it clears 7:1 — the AAA line for body text,
    /// which is the right target for a screen whose background is decided by somebody's photograph
    /// rather than by a designer. The bands above already clear it for almost every picture; this
    /// catches the ones that do not (a saturated yellow reads far lighter than its HSB brightness
    /// suggests) instead of leaving them to luck.
    private static func readable(_ colour: UIColor, dark: Bool) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        guard colour.getHue(&h, saturation: &s, brightness: &v, alpha: &a) else { return colour }
        let text = UIColor(white: dark ? 1 : 0, alpha: 1)
        var out = colour
        var steps = 0
        while contrast(out, text) < 7, steps < 14 {
            v = max(0, min(1, v + (dark ? -0.02 : 0.02)))
            // Saturation goes with it. Pulling brightness alone toward black leaves a muddy dark
            // hue that reads as a stain rather than as a colour.
            s = max(0, s - 0.015)
            out = UIColor(hue: h, saturation: s, brightness: v, alpha: 1)
            steps += 1
        }
        return out
    }

    private static func contrast(_ a: UIColor, _ b: UIColor) -> CGFloat {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Relative luminance, sRGB, gamma undone — the number a contrast ratio is actually defined on.
    private static func luminance(_ c: UIColor) -> CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        func lin(_ x: CGFloat) -> CGFloat { x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }
}

// MARK: - Reading the photograph

extension ProfilePalette {

    // MARK: Cache

    private static let cache = NSCache<NSString, ProfilePalette>()
    /// URLs being read right now. A profile page and its header both ask for the same photo within
    /// a frame of each other, and moving between profiles asks again — without this the same bitmap
    /// would be walked several times over.
    private static var inFlight = Set<String>()
    private static let lock = NSLock()
    /// Off the main thread, always, and SERIAL: the walk is cheap but it is not free, and running
    /// six of them at once would take the cores a scroll needs.
    private static let queue = DispatchQueue(label: "com.kulan.profile-palette", qos: .userInitiated)

    /// Already read? Answers synchronously, which is what lets a profile you have opened before
    /// draw its colours on frame one instead of flashing grey and then tinting.
    static func cached(for url: String?) -> ProfilePalette? {
        guard let url, !url.isEmpty else { return nil }
        return cache.object(forKey: url as NSString)
    }

    /// Read a photo the caller already holds. Returns immediately; the answer arrives as
    /// `.profilePaletteReady`.
    ///
    /// Called from the header's load path — the one place in the app that reliably has a profile
    /// photo decoded. Nothing here downloads anything, and nothing here runs on the main thread.
    static func extract(_ image: UIImage, for url: String) {
        guard !url.isEmpty, cache.object(forKey: url as NSString) == nil else { return }
        lock.lock()
        let busy = inFlight.contains(url)
        if !busy { inFlight.insert(url) }
        lock.unlock()
        guard !busy else { return }

        queue.async {
            let made = produce(image, key: url)
            lock.lock(); inFlight.remove(url); lock.unlock()
            guard made != nil else { return }
            // ON MAIN: the only listener is a SwiftUI page that sets @State when it hears this. The
            // cache is written first and NSCache is thread-safe, so the palette is already there by
            // the time the page reads it.
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .profilePaletteReady, object: url)
            }
        }
    }

    /// For a page opening on a photo that is already on the phone. Never fetches — if the picture is
    /// not here yet the header is fetching it, and the notification above is what brings the colours
    /// in behind it.
    static func resolve(url: String?) async -> ProfilePalette? {
        guard let url, !url.isEmpty else { return nil }
        if let hit = cached(for: url) { return hit }
        var image = DiskImageCache.shared.smallImageSync(url)
        if image == nil { image = await DiskImageCache.shared.image(for: url) }
        guard let image else { return nil }
        return await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: produce(image, key: url)) }
        }
    }

    private static func produce(_ image: UIImage, key: String) -> ProfilePalette? {
        if let hit = cache.object(forKey: key as NSString) { return hit }
        guard let colour = dominant(of: image),
              let made = ProfilePalette(key: key, base: colour) else { return nil }
        cache.setObject(made, forKey: key as NSString)
        return made
    }

    // MARK: The algorithm

    /// THE DOMINANT COLOUR, by clustering — not one pixel, and not the mean of the picture.
    ///
    /// The photo is drawn tiny, every pixel is dropped into a bucket of colours like itself, and the
    /// buckets compete. What wins a bucket the page is:
    ///
    ///   * **how much of the picture it is** — the honest starting point;
    ///   * **how coloured it is** — a photograph's identity lives in its colour, and a plain
    ///     population count on a photo of a person hands the page their skin or their hair;
    ///   * **how much of it touches the edges** — a background reaches the frame and a subject
    ///     usually does not, which is what picks the wall behind the cat rather than the cat;
    ///   * **minus the extremes** — the black of a shadow and the white of a blown highlight are in
    ///     every photograph and describe none of them, so both are damped. Damped, NOT removed: a
    ///     genuinely black-and-white or genuinely white picture has nothing else to offer and must
    ///     still come back with an honest near-black or near-white.
    ///
    /// The colour returned is the MEAN OF THE REAL PIXELS in the winning bucket, never the bucket's
    /// centre — the buckets decide which pixels belong together, they do not round their colour off
    /// to a grid.
    private static func dominant(of image: UIImage) -> UIColor? {
        guard let cg = image.cgImage else { return nil }

        // The same centre crop the header shows (0.8 wide-to-tall), so the colour read here comes
        // off the pixels that are actually on screen and not off a strip nobody sees.
        let sw = CGFloat(cg.width), sh = CGFloat(cg.height)
        guard sw > 0, sh > 0 else { return nil }
        let want: CGFloat = 0.8
        let src = (sw / sh > want)
            ? CGRect(x: (sw - sh * want) / 2, y: 0, width: sh * want, height: sh)
            : CGRect(x: 0, y: (sh - sw / want) / 2, width: sw, height: sw / want)
        guard let crop = cg.cropping(to: src.integral) else { return nil }

        // 44x55 = 2420 pixels. Enough that a small coloured background still forms a bucket, little
        // enough that the whole walk is well under a millisecond.
        let w = 44, h = 55
        let count = w * h * 4
        // Our own buffer, not `&array`: a pointer taken with & is only valid for the call it is
        // passed to, and CGContext keeps it for its whole life. (The same trap PosterTone hit.)
        let px = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        px.initialize(repeating: 0, count: count)
        defer { px.deallocate() }

        guard let ctx = CGContext(data: px, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        // Averaging on the way down is the point: it is what turns film grain and compression noise
        // into the colour underneath them before anything is counted.
        ctx.interpolationQuality = .medium
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))

        struct Bucket {
            var n = 0
            var r = 0.0, g = 0.0, b = 0.0
            var sat = 0.0, val = 0.0
            var edge = 0
        }
        var buckets: [Int: Bucket] = [:]
        buckets.reserveCapacity(96)

        let xEdge = Int(Double(w) * 0.18), yEdge = Int(Double(h) * 0.18)

        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let r = Double(px[i]) / 255, g = Double(px[i + 1]) / 255, b = Double(px[i + 2]) / 255
                let mx = max(r, max(g, b)), mn = min(r, min(g, b))
                let v = mx
                let s = mx <= 0 ? 0 : (mx - mn) / mx
                var hue = 0.0
                if mx > mn {
                    let d = mx - mn
                    if mx == r { hue = (g - b) / d + (g < b ? 6 : 0) }
                    else if mx == g { hue = (b - r) / d + 2 }
                    else { hue = (r - g) / d + 4 }
                    hue /= 6
                }

                // Greys keep their own buckets, split by lightness only — a hue read off a pixel
                // with no saturation is numerical noise, and letting it choose a bucket is how a
                // black-and-white portrait comes back faintly green.
                let key: Int
                if s < 0.10 || v < 0.06 {
                    key = 900 + Int(min(0.999, v) * 8)
                } else {
                    key = Int(min(0.999, hue) * 24) * 12 + Int(min(0.999, s) * 3) * 4 + Int(min(0.999, v) * 4)
                }

                let onEdge = x < xEdge || x >= w - xEdge || y < yEdge || y >= h - yEdge
                var bucket = buckets[key] ?? Bucket()
                bucket.n += 1
                bucket.r += r; bucket.g += g; bucket.b += b
                bucket.sat += s; bucket.val += v
                if onEdge { bucket.edge += 1 }
                buckets[key] = bucket
            }
        }

        let total = Double(w * h)
        var bestScore = -1.0
        var best: Bucket?

        for bucket in buckets.values {
            let n = Double(bucket.n)
            let share = n / total
            let meanSat = bucket.sat / n
            let meanVal = bucket.val / n
            let edgeShare = Double(bucket.edge) / n

            var score = share
            score *= 1 + 1.8 * meanSat                              // colour carries identity
            score *= 1 + 0.6 * edgeShare                            // a background reaches the frame
            if meanVal < 0.10 { score *= 0.45 }                     // shadow, not a colour
            if meanVal > 0.94 && meanSat < 0.12 { score *= 0.50 }   // blown highlight, not a colour
            if share < 0.02 { score *= 0.30 }                       // a speck is not a theme

            if score > bestScore { bestScore = score; best = bucket }
        }

        guard let win = best, win.n > 0 else { return nil }
        let n = Double(win.n)
        return UIColor(red: win.r / n, green: win.g / n, blue: win.b / n, alpha: 1)
    }
}
