import UIKit
import ImageIO

/// ⛔ PICTURE BUBBLE STYLES (owner 2026-11-07, "build and show in app"). A stretchable picture with
/// small art on its corners, cut into nine parts: the corners keep their size and the middle
/// stretches. The rules live in Documents/fariin-bubbles/SPEC.md, shared with the Android app.
///
/// The numbers below are the `bubbles/<id>.json` files, copied as a table so nothing is parsed at
/// launch. All four arrays are in PICTURE PIXELS, ordered [top, right, bottom, left]:
/// - `slice`: the cap insets (how much of each edge stays fixed).
/// - `bubble`: where the bubble's own outline is inside the picture. Right and bottom are
///   coordinates, not distances: right = 858 on an 860-wide picture is 2 px from the edge.
/// - `ins`: how far the text must stay clear of corner art that reaches inside the bubble.
///
/// ⚠️ Ids are file names and stay the same forever (SPEC section 8). Never reuse one for a new look.
struct PictureStyle: Equatable {
    let id: String
    let name: String
    let group: Pack
    let slice: [CGFloat]
    let bubble: [CGFloat]
    let ins: [CGFloat]
    let size: CGSize
    /// `text: light` in the json: white words on a dark picture.
    let lightText: Bool
    /// The bubble's own colour, for the earlier bubbles of a run (they draw no picture).
    let fill: UInt

    enum Pack: String, CaseIterable {
        case anime = "Anime", genZ = "Gen Z", cute = "Cute", careers = "Careers", sport = "Sport", everyday = "Everyday"
    }

    /// The words' colour: the mock's warm near-black on light pictures, white on dark ones.
    var textHex: UInt { lightText ? 0xFFFFFF : 0x2A1E18 }

    /// Display points per picture pixel (SPEC section 6): the parts of the top and bottom caps that
    /// sit INSIDE the bubble fit about 44pt together, so a one-word message stays one line tall.
    var scale: CGFloat {
        let inside = (slice[0] - bubble[0]) + (slice[2] - (size.height - bubble[2]))
        return min(0.24, 44 / max(inside, 1))
    }

    /// How far the picture reaches past the bubble's outline on each side, in points: the art
    /// above, beside and under the bubble.
    var art: UIEdgeInsets {
        let s = scale
        return UIEdgeInsets(top: bubble[0] * s, left: bubble[3] * s,
                            bottom: (size.height - bubble[2]) * s, right: (size.width - bubble[1]) * s)
    }

    /// The styles whose corner art touched the words in testing (SPEC section 6, "fix before ship"),
    /// in picture px. Lawyer, security and manga: 12 px more on each side that has art reaching in.
    /// Doctor: 85 px on the red-cross side (right), the number the Android app uses.
    private var clearance: (left: CGFloat, right: CGFloat) {
        var l = max(40, ins[3] + 6), r = max(40, ins[1] + 6)
        if ["lawyer", "security", "manga"].contains(id) {
            if ins[3] > 0 { l += 12 }
            if ins[1] > 0 { r += 12 }
        }
        if id == "doctor" { r = max(r, 85) }
        return (l, r)
    }

    /// Where the words sit inside the bubble's outline, in points: 40 px from each side (more where
    /// corner art reaches in), and 10pt above and below, the numbers the tested mocks use.
    var textInsets: UIEdgeInsets {
        let s = scale, c = clearance
        return UIEdgeInsets(top: 10, left: c.left * s, bottom: 10, right: c.right * s)
    }

    /// The smallest bubble (outline) the nine parts can make: both caps of each axis, less the art
    /// that sits outside the outline.
    var minBubble: CGSize {
        let s = scale, a = art
        return CGSize(width: max(0, (slice[1] + slice[3]) * s - a.left - a.right),
                      height: max(0, (slice[0] + slice[2]) * s - a.top - a.bottom))
    }
}

enum PictureStyles {
    private static func p(_ id: String, _ name: String, _ g: PictureStyle.Pack, slice: [CGFloat], bubble: [CGFloat],
                          ins: [CGFloat], size: [CGFloat], light: Bool, fill: UInt) -> PictureStyle {
        PictureStyle(id: id, name: name, group: g, slice: slice, bubble: bubble, ins: ins,
                     size: CGSize(width: size[0], height: size[1]), lightText: light, fill: fill)
    }

    /// The 35 styles, in picker order inside each group (README.md lists the groups).
    static let all: [PictureStyle] = [
        // Anime
        p("sakura", "Sakura", .anime, slice: [189, 125, 158, 208], bubble: [108, 710, 350, 1], ins: [0, 104, 0, 177], size: [721, 370], light: false, fill: 0xFED1DA),
        p("blush", "Blush", .anime, slice: [235, 187, 151, 92], bubble: [124, 886, 384, 22], ins: [0, 175, 0, 60], size: [888, 410], light: false, fill: 0xD8ECFE),
        p("manga", "Manga", .anime, slice: [240, 65, 133, 160], bubble: [127, 845, 395, 1], ins: [0, 12, 0, 149], size: [852, 397], light: false, fill: 0xFFFFFF),
        p("bunny", "Bunny", .anime, slice: [175, 196, 176, 81], bubble: [102, 886, 436, 1], ins: [0, 160, 0, 70], size: [888, 448], light: false, fill: 0xFECDE2),
        p("catgirl", "Cat Girl", .anime, slice: [241, 189, 172, 92], bubble: [113, 892, 435, 0], ins: [0, 173, 0, 82], size: [898, 437], light: false, fill: 0xE6D9FD),
        p("baddie", "Baddie", .anime, slice: [185, 81, 150, 188], bubble: [125, 858, 402, 1], ins: [0, 69, 0, 177], size: [860, 404], light: false, fill: 0xFEC8D6),
        // Gen Z
        p("skull", "Skull", .genZ, slice: [162, 107, 104, 172], bubble: [86, 925, 433, 0], ins: [0, 80, 0, 162], size: [942, 461], light: true, fill: 0x211F27),
        p("coolcamel", "Cool Camel", .genZ, slice: [182, 177, 207, 83], bubble: [113, 914, 430, 1], ins: [0, 0, 0, 72], size: [916, 466], light: true, fill: 0x251D30),
        p("fire", "Fire", .genZ, slice: [175, 83, 96, 226], bubble: [89, 882, 397, 32], ins: [0, 72, 0, 184], size: [883, 399], light: true, fill: 0x1C1B20),
        p("eyes", "Eyes", .genZ, slice: [155, 69, 158, 200], bubble: [88, 866, 396, 1], ins: [0, 0, 0, 0], size: [868, 397], light: true, fill: 0x0A0A0A),
        p("hood", "Hood", .genZ, slice: [173, 147, 153, 73], bubble: [101, 800, 430, 1], ins: [0, 0, 0, 0], size: [802, 431], light: true, fill: 0x13161E),
        p("crown", "Crown", .genZ, slice: [132, 103, 106, 137], bubble: [65, 908, 371, 49], ins: [0, 85, 0, 78], size: [916, 379], light: true, fill: 0x181818),
        // Cute
        p("camel", "Camel", .cute, slice: [245, 127, 187, 218], bubble: [125, 912, 454, 0], ins: [0, 115, 0, 193], size: [914, 456], light: false, fill: 0xFDE2B9),
        p("kitten", "Kitten", .cute, slice: [209, 181, 155, 131], bubble: [101, 853, 387, 0], ins: [0, 170, 0, 121], size: [854, 388], light: false, fill: 0xFEF9ED),
        p("bear", "Bear", .cute, slice: [167, 98, 107, 171], bubble: [113, 841, 362, 0], ins: [0, 67, 0, 161], size: [862, 383], light: false, fill: 0xFDD782),
        p("strawberry", "Strawberry", .cute, slice: [122, 122, 168, 101], bubble: [47, 859, 366, 14], ins: [0, 86, 0, 77], size: [885, 387], light: false, fill: 0xFFC3CA),
        p("glam", "Glam", .cute, slice: [189, 116, 159, 258], bubble: [41, 858, 360, 33], ins: [0, 72, 0, 206], size: [892, 372], light: false, fill: 0xFFFFFF),
        // Careers
        p("doctor", "Doctor", .careers, slice: [184, 79, 75, 165], bubble: [111, 884, 443, 0], ins: [0, 0, 0, 155], size: [890, 445], light: false, fill: 0xD0F1EB),
        p("nurse", "Nurse", .careers, slice: [169, 135, 170, 130], bubble: [97, 886, 426, 1], ins: [0, 123, 0, 0], size: [888, 444], light: false, fill: 0xD4EAFE),
        p("lawyer", "Lawyer", .careers, slice: [182, 131, 115, 123], bubble: [111, 876, 435, 26], ins: [0, 120, 0, 87], size: [877, 437], light: false, fill: 0xF9EDD5),
        p("engineer", "Engineer", .careers, slice: [247, 123, 91, 87], bubble: [111, 891, 434, 12], ins: [0, 43, 0, 65], size: [893, 454], light: false, fill: 0xE4E5E9),
        p("teacher", "Teacher", .careers, slice: [169, 144, 74, 159], bubble: [97, 873, 425, 0], ins: [0, 132, 0, 0], size: [875, 427], light: true, fill: 0x354E41),
        p("pilot", "Pilot", .careers, slice: [195, 152, 191, 182], bubble: [121, 922, 460, 1], ins: [0, 140, 0, 171], size: [924, 462], light: false, fill: 0xC1E9FE),
        p("chef", "Chef", .careers, slice: [181, 130, 174, 128], bubble: [119, 847, 404, 0], ins: [0, 106, 0, 69], size: [861, 441], light: false, fill: 0xFEF7EC),
        p("graduate", "Graduate", .careers, slice: [163, 179, 86, 88], bubble: [108, 827, 362, 6], ins: [0, 0, 0, 72], size: [843, 369], light: true, fill: 0x273973),
        p("baller", "Baller", .careers, slice: [187, 116, 105, 209], bubble: [127, 906, 401, 5], ins: [0, 100, 0, 0], size: [912, 407], light: true, fill: 0x3B2062),
        p("security", "Security", .careers, slice: [206, 165, 97, 89], bubble: [133, 913, 467, 0], ins: [0, 154, 0, 79], size: [914, 469], light: true, fill: 0x232834),
        // Sport
        p("football", "Football", .sport, slice: [125, 107, 106, 182], bubble: [67, 853, 331, 0], ins: [0, 79, 0, 172], size: [871, 353], light: false, fill: 0xB2E387),
        p("basketball", "Basketball", .sport, slice: [117, 117, 160, 110], bubble: [44, 820, 303, 1], ins: [0, 88, 0, 99], size: [839, 346], light: false, fill: 0xFEA34E),
        p("trophy", "Trophy", .sport, slice: [122, 56, 108, 115], bubble: [70, 845, 307, 6], ins: [0, 44, 0, 85], size: [847, 309], light: false, fill: 0xFFDC8B),
        p("racing", "Racing", .sport, slice: [239, 154, 162, 138], bubble: [77, 866, 424, 1], ins: [0, 142, 0, 0], size: [868, 425], light: false, fill: 0xDEDAE0),
        // Everyday
        p("coffee", "Coffee", .everyday, slice: [100, 126, 165, 90], bubble: [35, 836, 334, 25], ins: [0, 102, 0, 0], size: [850, 347], light: false, fill: 0xECCEB2),
        p("night", "Night", .everyday, slice: [131, 94, 102, 127], bubble: [28, 846, 357, 26], ins: [0, 74, 0, 91], size: [856, 359], light: true, fill: 0x2B395F),
        p("leaf", "Leaf", .everyday, slice: [187, 89, 112, 167], bubble: [43, 863, 354, 24], ins: [0, 56, 0, 115], size: [884, 375], light: false, fill: 0xD9E6CF),
        p("minimal", "Minimal", .everyday, slice: [140, 68, 82, 107], bubble: [23, 780, 280, 51], ins: [0, 38, 0, 0], size: [792, 306], light: false, fill: 0xFFFFFF),
    ]

    private static let byId: [String: PictureStyle] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    static func find(_ id: String?) -> PictureStyle? { id.flatMap { byId[$0] } }

    static func url(_ id: String) -> URL? {
        Bundle.main.url(forResource: id, withExtension: "webp", subdirectory: "BubbleArt")
    }
}

/// The pictures, decoded once at the size they are drawn and kept in a small cache (SPEC section 7:
/// about six styles; a 1:1 chat needs two). Decoding runs off the main thread; until a picture is
/// ready the cell draws the plain bubble in the style's colour.
///
/// Every picture is drawn with `pad` points of empty room around it, so the dark-mode rim (0.5pt of
/// white at 45%, SPEC section 6) is not cut off where the bubble's outline meets the picture's edge.
enum PictureArt {
    static let pad: CGFloat = 1

    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 8
        return c
    }()
    private static let queue = DispatchQueue(label: "fariin.bubble-art", qos: .userInitiated)
    /// Callers waiting for a picture already being decoded. Main thread only.
    private static var waiting: [String: [(UIImage?) -> Void]] = [:]

    static func key(_ s: PictureStyle, rim: Bool, scale: CGFloat) -> String { "\(s.id)|\(rim)|\(scale)" }

    /// The stretchable picture if it is decoded already.
    static func cached(_ s: PictureStyle, rim: Bool, scale: CGFloat) -> UIImage? {
        cache.object(forKey: key(s, rim: rim, scale: scale) as NSString)
    }

    /// Decode in the background, then call `done` on the main thread. Call from the main thread.
    static func load(_ s: PictureStyle, rim: Bool, scale: CGFloat, done: @escaping (UIImage?) -> Void) {
        let k = key(s, rim: rim, scale: scale)
        if let hit = cache.object(forKey: k as NSString) { done(hit); return }
        if waiting[k] != nil { waiting[k]?.append(done); return }
        waiting[k] = [done]
        queue.async {
            let img = render(s, rim: rim, scale: scale)
            DispatchQueue.main.async {
                if let img { cache.setObject(img, forKey: k as NSString) }
                let calls = waiting.removeValue(forKey: k) ?? []
                for c in calls { c(img) }
            }
        }
    }

    /// The picker's small tiles: the whole picture `width` points wide, in their own cache so a
    /// scroll through 35 tiles never pushes the chat's pictures out.
    private static let thumbs: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 12 * 1024 * 1024
        return c
    }()

    static func thumbnail(_ s: PictureStyle, width: CGFloat, scale: CGFloat, done: @escaping (UIImage?) -> Void) {
        let k = "\(s.id)|\(width)|\(scale)" as NSString
        if let hit = thumbs.object(forKey: k) { done(hit); return }
        queue.async {
            var img: UIImage?
            if let url = PictureStyles.url(s.id), let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: Int(ceil(width * scale)),
                ]
                if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                    img = UIImage(cgImage: cg, scale: scale, orientation: .up)
                }
            }
            DispatchQueue.main.async {
                if let img, let cg = img.cgImage { thumbs.setObject(img, forKey: k, cost: cg.bytesPerRow * cg.height) }
                done(img)
            }
        }
    }

    /// The picture at its display size (picture px times `PictureStyle.scale`), with `pad` around
    /// it, made stretchable along the json's cap insets.
    private static func render(_ s: PictureStyle, rim: Bool, scale: CGFloat) -> UIImage? {
        guard let url = PictureStyles.url(s.id),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let k = s.scale
        let drawn = CGSize(width: s.size.width * k, height: s.size.height * k)
        // Downsampled while decoding, so the full-size picture is never held in memory.
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(ceil(max(drawn.width, drawn.height) * scale)),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let base = UIImage(cgImage: cg)
        let full = CGSize(width: drawn.width + pad * 2, height: drawn.height + pad * 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let picture = UIGraphicsImageRenderer(size: full, format: format).image { r in
            let rect = CGRect(x: pad, y: pad, width: drawn.width, height: drawn.height)
            if rim {
                // The picture's own outline grown by half a point, in white, under the picture.
                let c = r.cgContext
                c.saveGState()
                c.setAlpha(0.45)
                c.beginTransparencyLayer(auxiliaryInfo: nil)
                let d: CGFloat = 0.5
                for (dx, dy) in [(-d, 0), (d, 0), (0, -d), (0, d), (-d, -d), (d, -d), (-d, d), (d, d)] {
                    base.draw(in: rect.offsetBy(dx: dx, dy: dy))
                }
                c.setBlendMode(.sourceIn)
                c.setFillColor(UIColor.white.cgColor)
                c.fill(CGRect(origin: .zero, size: full))
                c.endTransparencyLayer()
                c.restoreGState()
            }
            base.draw(in: rect)
        }
        let caps = UIEdgeInsets(top: s.slice[0] * k + pad, left: s.slice[3] * k + pad,
                                bottom: s.slice[2] * k + pad, right: s.slice[1] * k + pad)
        return picture.resizableImage(withCapInsets: caps, resizingMode: .stretch)
    }
}
