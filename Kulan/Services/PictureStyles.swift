import UIKit
import ImageIO

/// ⛔ PICTURE BUBBLE STYLES (owner 2026-11-07, "build and show in app"). A stretchable picture with
/// small art on its corners, cut into nine parts: the corners keep their size and the middle
/// stretches. The rules live in Documents/fariin-bubbles/SPEC.md, shared with the Android app.
///
/// The numbers below are the v2 set's `bubbles_v2/<id>.json` files (corners redrawn round, owner
/// 2026-11-07: "near-square corners"), copied as a table so nothing is parsed at launch. The four
/// arrays are in PICTURE PIXELS, ordered [top, right, bottom, left]:
/// - `slice`: the cap insets (how much of each edge stays fixed).
/// - `bubble`: where the bubble's own outline is inside the picture. Right and bottom are
///   coordinates, not distances: right = 858 on an 860-wide picture is 2 px from the edge.
/// - `ins`: how far the words keep clear of corner art that reaches into the bubble, from the
///   outline's side, on the rows where that art is (see `sideRoom`).
/// - `radius`: the outline's corner radius, about 18pt at `scale`.
/// `art` is not in the json: the corner art inside the outline, measured from the v2 pictures and
/// checked by eye. It is the Android app's table (BubbleArt.kt), copied so both apps lay out the
/// same: `L(top, bottom, reach)` / `R(...)` is art on the left / right covering picture rows
/// top...bottom and reaching `reach` px in from that side. Art above or under the outline (the
/// security guard, the doctor's head) is not listed: it never meets the words.
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
    /// The outline's corner radius, in picture px.
    let radius: CGFloat
    /// The corner art inside the outline (see above).
    let artIn: [Art]
    /// `text: light` in the json: white words on a dark picture.
    let lightText: Bool
    /// The bubble's own colour, drawn while the picture is still decoding.
    let fill: UInt

    enum Pack: String, CaseIterable {
        case anime = "Anime", genZ = "Gen Z", cute = "Cute", careers = "Careers", sport = "Sport", everyday = "Everyday"
    }

    /// Art inside the outline on one side: picture rows `top`...`bottom`, reaching `reach` px in.
    struct Art: Equatable {
        let right: Bool
        let top: CGFloat
        let bottom: CGFloat
        let reach: CGFloat
    }

    /// The words' colour: the mock's warm near-black on light pictures, white on dark ones.
    var textHex: UInt { lightText ? 0xFFFFFF : 0x2A1E18 }

    /// Display points per picture pixel (SPEC section 6): the parts of the top and bottom caps that
    /// sit INSIDE the bubble fit about 44pt together, so a one-word message stays one line tall.
    var scale: CGFloat {
        let inside = (slice[0] - bubble[0]) + (slice[2] - (size.height - bubble[2]))
        return min(0.24, 44 / max(inside, 1))
    }

    /// The outline's corner radius in points, for the plain bubble drawn while the picture decodes.
    var cornerRadius: CGFloat { radius * scale }

    /// How far the picture reaches past the bubble's outline on each side, in points: the art
    /// above, beside and under the bubble.
    var art: UIEdgeInsets {
        let s = scale
        return UIEdgeInsets(top: bubble[0] * s, left: bubble[3] * s,
                            bottom: (size.height - bubble[2]) * s, right: (size.width - bubble[1]) * s)
    }

    /// The words stay 10pt under the top edge and over the bottom one, the tested mocks' number.
    static let edgePad: CGFloat = 10
    /// Art wholly in a top (or bottom) corner that ends this near the edge (hands resting on it)
    /// moves the words down (or up) a few points instead of taking room beside them.
    static let liftMax: CGFloat = 16
    /// And never nearer art inside the outline than this.
    static let artGap: CGFloat = 4

    /// A side with no art beside the words: 40 px and at least 11pt (the round corners).
    private var sideBase: CGFloat { max(40 * scale, 11) }

    /// ⛔ A side with `a` beside the words: 4pt past the art itself, nothing more (owner 2026-11-07:
    /// "words at normal bubble margins, corner art takes no room unless it meets the words"). The
    /// json's `ins` is a whole-height number from before the art was measured, so it is not used.
    private func artClear(_ a: Art) -> CGFloat {
        a.reach * scale + Self.artGap
    }

    /// How far into the outline a piece of art wholly in the top cap reaches from the top edge, or
    /// one wholly in the bottom cap from the bottom edge, in points; nil for art that stretches.
    private func edgeReach(_ a: Art) -> (top: Bool, depth: CGFloat)? {
        let s = scale
        if a.bottom <= slice[0] { return (true, (a.bottom - bubble[0]) * s) }
        if a.top >= size.height - slice[2] { return (false, (bubble[2] - a.top) * s) }
        return nil
    }

    /// The words' distance from the top and bottom edges: 10pt, or 4pt past shallow art on that edge.
    private var edgePads: (top: CGFloat, bottom: CGFloat) {
        var t = Self.edgePad, b = Self.edgePad
        for a in artIn {
            guard let e = edgeReach(a), e.depth + Self.artGap <= Self.liftMax else { continue }
            if e.top { t = max(t, ceil(e.depth + Self.artGap)) } else { b = max(b, ceil(e.depth + Self.artGap)) }
        }
        return (t, b)
    }

    /// Where picture row `row` lands, from the picture's top, in a picture drawn `drawnH` points
    /// tall: rows in the top or bottom cap keep their place from that edge, rows between stretch
    /// with the middle, as the nine parts are drawn.
    private func rowAt(_ row: CGFloat, drawnH: CGFloat) -> CGFloat {
        let s = scale, t = slice[0], b = slice[2]
        if row <= t { return row * s }
        if row >= size.height - b { return drawnH - (size.height - row) * s }
        return t * s + (row - t) * (drawnH - (t + b) * s) / max(1, size.height - t - b)
    }

    /// ⛔ SIDE ROOM PER ROW, NOT PER STYLE (owner 2026-11-07, build 1118: an empty block after the
    /// ticks in security, whose guard sits ABOVE the bubble). The room, from the outline's sides, for
    /// content whose top sits `top` points under the outline's top edge and whose bottom sits
    /// `bottom` points over its bottom edge, in an outline `height` points tall. A piece of art
    /// costs room only when its rows come within 4pt of the content's rows (the Android app's rule,
    /// BubbleArt.sideClearance), rounded up to whole points.
    func sideRoom(top: CGFloat, bottom: CGFloat, height: CGFloat) -> (left: CGFloat, right: CGFloat) {
        let a0 = art, drawnH = height + a0.top + a0.bottom
        let wordsTop = a0.top + top, wordsBottom = a0.top + height - bottom
        var l = sideBase, r = sideBase
        for a in artIn {
            let t = rowAt(a.top, drawnH: drawnH), b = rowAt(a.bottom, drawnH: drawnH)
            guard t < wordsBottom + Self.artGap, b > wordsTop - Self.artGap else { continue }
            if a.right { r = max(r, artClear(a)) } else { l = max(l, artClear(a)) }
        }
        return (ceil(l), ceil(r))
    }

    /// Where the words sit inside the bubble's outline, in points: `edgePads` above and below, and
    /// at the sides the most room a side can ever need (every art that can meet the words at some
    /// height; not art in a corner that ends before the words begin). The layout measures with
    /// these and gives back what the real rows do not need.
    var textInsets: UIEdgeInsets {
        let pads = edgePads
        func canMeet(_ a: Art) -> Bool {
            guard let e = edgeReach(a) else { return true }
            return e.depth + Self.artGap > (e.top ? pads.top : pads.bottom)
        }
        var l = sideBase, r = sideBase
        for a in artIn where canMeet(a) {
            if a.right { r = max(r, artClear(a)) } else { l = max(l, artClear(a)) }
        }
        return UIEdgeInsets(top: pads.top, left: ceil(l), bottom: pads.bottom, right: ceil(r))
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
                          ins: [CGFloat], size: [CGFloat], radius: CGFloat, light: Bool, fill: UInt,
                          art: [PictureStyle.Art]) -> PictureStyle {
        PictureStyle(id: id, name: name, group: g, slice: slice, bubble: bubble, ins: ins,
                     size: CGSize(width: size[0], height: size[1]), radius: radius, artIn: art,
                     lightText: light, fill: fill)
    }

    /// Art on the left / right of the outline: picture rows `top`...`bottom`, `reach` px in.
    private static func L(_ top: CGFloat, _ bottom: CGFloat, _ reach: CGFloat) -> PictureStyle.Art {
        PictureStyle.Art(right: false, top: top, bottom: bottom, reach: reach)
    }
    private static func R(_ top: CGFloat, _ bottom: CGFloat, _ reach: CGFloat) -> PictureStyle.Art {
        PictureStyle.Art(right: true, top: top, bottom: bottom, reach: reach)
    }

    /// The 35 styles, in picker order inside each group (README.md lists the groups).
    static let all: [PictureStyle] = [
        // Anime
        p("sakura", "Sakura", .anime, slice: [207, 125, 158, 208], bubble: [108, 711, 350, 0], ins: [0, 104, 0, 177], size: [721, 370], radius: 97, light: false, fill: 0xFED1DA,
          art: [R(285, 336, 99)]),
        p("blush", "Blush", .anime, slice: [235, 187, 151, 121], bubble: [123, 887, 385, 22], ins: [0, 175, 0, 60], size: [888, 410], radius: 97, light: false, fill: 0xD8ECFE,
          art: [L(319, 385, 60)]),
        p("manga", "Manga", .anime, slice: [240, 103, 133, 160], bubble: [127, 850, 396, 0], ins: [0, 55, 0, 149], size: [852, 397], radius: 100, light: false, fill: 0xFFFFFF,
          art: [R(295, 307, 35), R(337, 379, 94)]),
        p("bunny", "Bunny", .anime, slice: [218, 196, 176, 117], bubble: [101, 887, 437, 0], ins: [0, 160, 0, 70], size: [888, 448], radius: 115, light: false, fill: 0xFECDE2,
          art: [L(376, 409, 66), R(115, 167, 164)]),
        p("catgirl", "Cat Girl", .anime, slice: [241, 189, 172, 124], bubble: [113, 892, 436, 0], ins: [0, 173, 0, 82], size: [898, 437], radius: 122, light: false, fill: 0xE6D9FD,
          art: []),
        p("baddie", "Baddie", .anime, slice: [231, 106, 150, 188], bubble: [125, 859, 403, 0], ins: [0, 69, 0, 177], size: [860, 404], radius: 104, light: false, fill: 0xFEC8D6,
          art: [L(139, 145, 166), R(339, 377, 70)]),
        // Gen Z
        p("skull", "Skull", .genZ, slice: [163, 107, 104, 172], bubble: [86, 925, 434, 0], ins: [0, 80, 0, 162], size: [942, 461], radius: 75, light: true, fill: 0x211F27,
          art: [R(371, 418, 62)]),
        p("coolcamel", "Cool Camel", .genZ, slice: [234, 177, 207, 121], bubble: [113, 915, 430, 0], ins: [0, 67, 0, 72], size: [916, 466], radius: 119, light: true, fill: 0x251D30,
          art: [L(393, 399, 66)]),
        p("fire", "Fire", .genZ, slice: [175, 83, 96, 226], bubble: [89, 882, 398, 32], ins: [0, 72, 0, 184], size: [883, 399], radius: 75, light: true, fill: 0x1C1B20,
          art: [R(308, 379, 76)]),
        p("eyes", "Eyes", .genZ, slice: [199, 112, 158, 200], bubble: [87, 867, 396, 0], ins: [0, 61, 0, 61], size: [868, 397], radius: 110, light: true, fill: 0x0A0A0A,
          art: [L(103, 110, 253), R(355, 361, 69)]),
        p("hood", "Hood", .genZ, slice: [208, 147, 153, 108], bubble: [100, 801, 430, 0], ins: [0, 59, 0, 59], size: [802, 431], radius: 106, light: true, fill: 0x13161E,
          art: []),
        p("crown", "Crown", .genZ, slice: [135, 103, 106, 137], bubble: [58, 915, 378, 42], ins: [0, 85, 0, 78], size: [916, 379], radius: 75, light: true, fill: 0x181818,
          art: [L(72, 111, 79), R(285, 347, 90)]),
        // Cute
        p("camel", "Camel", .cute, slice: [256, 132, 187, 218], bubble: [124, 913, 455, 0], ins: [0, 115, 0, 193], size: [914, 456], radius: 130, light: false, fill: 0xFDE2B9,
          art: [L(138, 158, 210), R(330, 431, 128)]),
        p("kitten", "Kitten", .cute, slice: [210, 181, 155, 131], bubble: [100, 853, 387, 0], ins: [0, 170, 0, 121], size: [854, 388], radius: 108, light: false, fill: 0xFEF9ED,
          art: [L(305, 373, 123), R(114, 119, 170)]),
        p("bear", "Bear", .cute, slice: [190, 98, 107, 171], bubble: [113, 841, 363, 0], ins: [0, 67, 0, 161], size: [862, 383], radius: 75, light: false, fill: 0xFDD782,
          art: [L(127, 133, 160), R(282, 348, 72)]),
        p("strawberry", "Strawberry", .cute, slice: [152, 130, 168, 119], bubble: [46, 860, 367, 13], ins: [0, 86, 0, 77], size: [885, 387], radius: 104, light: false, fill: 0xFFC3CA,
          art: [L(63, 116, 82), R(290, 351, 92)]),
        p("glam", "Glam", .cute, slice: [189, 155, 159, 258], bubble: [41, 859, 361, 33], ins: [0, 72, 0, 206], size: [892, 372], radius: 121, light: false, fill: 0xFFFFFF,
          art: [L(55, 102, 214), L(243, 324, 74), R(243, 325, 75)]),
        // Careers
        p("doctor", "Doctor", .careers, slice: [188, 82, 77, 165], bubble: [111, 884, 444, 0], ins: [0, 40, 0, 155], size: [890, 445], radius: 75, light: false, fill: 0xD0F1EB,
          art: [R(365, 430, 75)]),
        p("nurse", "Nurse", .careers, slice: [205, 135, 170, 130], bubble: [97, 887, 426, 0], ins: [0, 123, 0, 59], size: [888, 444], radius: 106, light: false, fill: 0xD4EAFE,
          art: [R(398, 412, 126)]),
        p("lawyer", "Lawyer", .careers, slice: [192, 131, 115, 123], bubble: [110, 876, 436, 26], ins: [0, 120, 0, 87], size: [877, 437], radius: 80, light: false, fill: 0xF9EDD5,
          art: [L(331, 409, 90)]),
        p("engineer", "Engineer", .careers, slice: [247, 123, 115, 109], bubble: [110, 891, 435, 12], ins: [0, 52, 0, 65], size: [893, 454], radius: 95, light: false, fill: 0xE4E5E9,
          art: [L(316, 357, 18), L(417, 421, 151)]),
        p("teacher", "Teacher", .careers, slice: [173, 144, 77, 159], bubble: [96, 873, 426, 0], ins: [0, 132, 0, 40], size: [875, 427], radius: 75, light: true, fill: 0x354E41,
          art: [R(357, 410, 135)]),
        p("pilot", "Pilot", .careers, slice: [255, 152, 191, 182], bubble: [120, 923, 461, 0], ins: [0, 140, 0, 171], size: [924, 462], radius: 133, light: false, fill: 0xC1E9FE,
          art: [L(348, 437, 172)]),
        p("chef", "Chef", .careers, slice: [217, 130, 174, 128], bubble: [118, 847, 405, 0], ins: [0, 106, 0, 69], size: [861, 441], radius: 97, light: false, fill: 0xFEF7EC,
          art: [R(343, 391, 109)]),
        p("graduate", "Graduate", .careers, slice: [179, 179, 86, 88], bubble: [102, 833, 368, 0], ins: [0, 40, 0, 72], size: [843, 369], radius: 75, light: true, fill: 0x273973,
          art: [L(266, 273, 23), L(293, 352, 113)]),
        p("baller", "Baller", .careers, slice: [199, 116, 105, 209], bubble: [122, 911, 406, 0], ins: [0, 100, 0, 40], size: [912, 407], radius: 75, light: true, fill: 0x3B2062,
          art: [R(312, 384, 105)]),
        p("security", "Security", .careers, slice: [209, 165, 97, 89], bubble: [132, 913, 468, 0], ins: [0, 154, 0, 79], size: [914, 469], radius: 75, light: true, fill: 0x232834,
          art: [L(382, 445, 78)]),
        // Sport
        p("football", "Football", .sport, slice: [143, 107, 106, 182], bubble: [66, 853, 331, 0], ins: [0, 79, 0, 172], size: [871, 353], radius: 75, light: false, fill: 0xB2E387,
          art: [L(80, 112, 74), R(251, 317, 92)]),
        p("basketball", "Basketball", .sport, slice: [129, 117, 160, 110], bubble: [44, 821, 304, 0], ins: [0, 88, 0, 99], size: [839, 346], radius: 83, light: false, fill: 0xFEA34E,
          art: [L(274, 290, 102), R(58, 110, 93)]),
        p("trophy", "Trophy", .sport, slice: [146, 77, 108, 115], bubble: [69, 846, 308, 5], ins: [0, 44, 0, 85], size: [847, 309], radius: 75, light: false, fill: 0xFFDC8B,
          art: [L(84, 114, 89), R(233, 287, 80)]),
        p("racing", "Racing", .sport, slice: [239, 154, 162, 138], bubble: [77, 867, 424, 0], ins: [0, 142, 0, 75], size: [868, 425], radius: 132, light: false, fill: 0xDEDAE0,
          art: [R(337, 410, 129)]),
        // Everyday
        p("coffee", "Coffee", .everyday, slice: [151, 141, 165, 142], bubble: [34, 837, 346, 25], ins: [0, 102, 0, 64], size: [850, 347], radius: 115, light: false, fill: 0xECCEB2,
          art: [L(262, 320, 60), R(52, 84, 107)]),
        p("night", "Night", .everyday, slice: [131, 95, 102, 127], bubble: [27, 846, 358, 25], ins: [0, 74, 0, 91], size: [856, 359], radius: 84, light: true, fill: 0x2B395F,
          art: [L(71, 120, 91), R(267, 326, 74)]),
        p("leaf", "Leaf", .everyday, slice: [187, 122, 123, 167], bubble: [42, 864, 354, 24], ins: [0, 56, 0, 115], size: [884, 375], radius: 101, light: false, fill: 0xD9E6CF,
          art: [L(59, 86, 112), L(99, 129, 67), R(316, 323, 51)]),
        p("minimal", "Minimal", .everyday, slice: [140, 94, 107, 134], bubble: [23, 780, 281, 51], ins: [0, 44, 0, 44], size: [792, 306], radius: 81, light: false, fill: 0xFFFFFF,
          art: []),
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
