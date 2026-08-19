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
    let key: String
    /// THE EXTRACTED COLOUR ITSELF, kept exactly as it came off the photograph. Nothing draws this
    /// raw — it is the seed every surface below is derived from, and it is worth keeping honest so
    /// a wrong-looking page can always be traced back to what was actually read.
    let base: UIColor

    private let hue: CGFloat
    private let sat: CGFloat
    private let val: CGFloat

    fileprivate init?(key: String, base: UIColor) {
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        guard base.getHue(&h, saturation: &s, brightness: &v, alpha: &a) else { return nil }
        self.key = key
        self.base = base
        self.hue = h
        self.sat = s
        self.val = v
    }

    // MARK: The surfaces

    /// ⚠️ **A PROFILE IS ALWAYS DARK MODE.** Owner, 2026-08-19: "dont use light mode in profile
    /// always use dark mode" — and 2026-08-08 before that, on the same screen. There is one family
    /// of surfaces here and one colour of text on them, so a pale photograph can never hand the
    /// page a white background: it hands it a rich mid-tone instead.

    /// THE PAGE: the extracted colour, kept at ITS OWN lightness, clamped only at the two ends.
    ///
    /// ⚠️ **DO NOT DARKEN THIS AGAIN.** The first version dragged every photo down to a 0.085-0.17
    /// brightness band, and the verdict was immediate: "the colour looks different and it is too
    /// dark". The reference contact page he sent does the opposite — a grey cat gives a MID grey
    /// page, a violet avatar a bright violet one, a photograph of night mountains a near-black one.
    /// The value it read IS the answer. All that is enforced here is a floor, so a black photograph
    /// still shows some of its colour, and a luminance ceiling, so white text keeps its footing.
    ///
    /// ⚠️ ONE PROPERTY, TWO READERS, and it has to stay that way. The page paints this and the
    /// header fades its photo to this. The moment the two are computed apart, a line appears where
    /// they meet — which this screen has been reported for three separate times.
    var page: UIColor {
        let s = min(sat, 0.62)
        let v = min(max(val, 0.16), 0.90)
        return ProfilePalette.grounded(UIColor(hue: hue, saturation: s, brightness: v, alpha: 1))
    }

    /// A CARD: the same colour, lifted. Not a material, not a translucency, not a blur — a flat
    /// opaque fill made of the page's own colour, which is how one rule gives an olive card on an
    /// olive page and a violet card on a violet one without either being written down.
    ///
    /// Lifted by brightness and DAMPED by saturation, both on purpose. A card that gains colour as
    /// it rises reads as a painted panel; a card that gains light reads as a surface above the
    /// page, which is the whole difference between this and the tinted-plastic look.
    var card: UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        let p = page
        guard p.getHue(&h, saturation: &s, brightness: &v, alpha: &a) else { return p }
        return UIColor(hue: h, saturation: s * 0.92, brightness: min(0.95, v + 0.075), alpha: 1)
    }

    /// The hairline round a card — light, because everything on this page is.
    var edge: UIColor { UIColor(white: 1, alpha: 0.08) }

    /// A separator INSIDE a card, which cannot be the system's own: that one is resolved against
    /// the system background, and on a tinted card it reads as a scratch.
    var separator: UIColor { UIColor(white: 1, alpha: 0.14) }

    // MARK: Contrast

    /// Hold a surface below the lightness where white text starts to fail.
    ///
    /// A CEILING, NOT A TARGET — the difference matters. Chasing a fixed contrast ratio is what made
    /// the first version look nothing like the photograph: it dragged a mid grey down to near-black
    /// to win a number nobody asked for. This lets a page be as light as the picture is and only
    /// steps in at the top.
    ///
    /// ⚠️ **0.25 IS MEASURED OFF THE REFERENCE, NOT CHOSEN.** Their lightest contact page is the one
    /// under the grey kitten, and that grey is 0.254 relative luminance — white text on it is about
    /// 3.4:1. Their violet page is 0.17, their slate blue 0.11, their night mountains near zero. So
    /// the whole family lives under a quarter, and a page that goes past it is not "brighter", it is
    /// off the design. Relative luminance, NOT HSB brightness: a mid grey is 0.54 bright and 0.25
    /// luminous, and using the wrong one of those two numbers here makes every warm colour glow.
    private static func grounded(_ colour: UIColor) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        guard colour.getHue(&h, saturation: &s, brightness: &v, alpha: &a) else { return colour }
        var out = colour
        var steps = 0
        while luminance(out) > 0.25, steps < 45 {
            v = max(0, v - 0.02)
            out = UIColor(hue: h, saturation: s, brightness: v, alpha: 1)
            steps += 1
        }
        return out
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

    /// THE COLOUR OF SOMEBODY WHOSE PICTURE IS NOT HERE.
    ///
    /// ⚠️ This is not a nicety, it is the fix for a real report (owner, 2026-08-19, on a preview
    /// build): a page whose top was a bright orange letter avatar and whose bottom was black. The
    /// header falls back to the person's own two-colour gradient when it has no bitmap — a photo
    /// still downloading, a cold launch, no signal — and the page had nothing to read, so it stayed
    /// the plain system colour and the screen was two unrelated halves.
    ///
    /// The letter's gradient is what is ON SCREEN in that moment, so it is the honest thing to take
    /// the colour from. When the real photo lands the palette changes under the page and it washes,
    /// which is the same movement as walking from one person to another.
    static func forName(_ name: String) -> ProfilePalette? {
        let key = "name:\(name)"
        if let hit = cache.object(forKey: key as NSString) { return hit }
        let pair = AvatarPalette.gradient(for: name)
        guard let top = pair.first, let bottom = pair.last else { return nil }
        guard let made = ProfilePalette(key: key, base: mix(UIColor(top), UIColor(bottom))) else { return nil }
        cache.setObject(made, forKey: key as NSString)
        return made
    }

    private static func mix(_ a: UIColor, _ b: UIColor) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: (r1 + r2) / 2, green: (g1 + g2) / 2, blue: (b1 + b2) / 2, alpha: 1)
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
