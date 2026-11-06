import UIKit

/// ⛔ BUBBLE STYLE DECORATIONS (owner 2026-11-06, stage two of Bubble Styles). Small pieces of art at
/// a styled bubble's corners: hearts, a strawberry, a bow, stars, sparkles, a blossom, a leaf, a
/// cloud. Drawn here in code (SF Symbols and our own paths), so there is no artwork to license.
///
/// Rules that keep them cute and not loud: only the LAST bubble of a run carries them (never every
/// bubble), at most two or three per bubble, mostly on the bottom corners so they hang into the gap
/// below the run rather than onto the bubble above; a top corner only on the run's first bubble.
/// The sender chooses them (`bsd` on the message), so the other person sees the same.
struct BubbleDecor: Equatable {
    enum Corner: Equatable { case topLeading, topTrailing, bottomLeading, bottomTrailing }
    enum Glyph: Equatable { case symbol(String), bow, strawberry }
    let corner: Corner
    let glyph: Glyph
    let size: CGFloat
    let light: UInt
    let dark: UInt
    /// Offset of the art's centre from the corner point, pointing OUT of the bubble when positive.
    var out: CGFloat = 4
    var rotation: CGFloat = 0
}

/// A decoration resolved for one bubble: which actual corner (mirrored for theirs) and which colour.
struct PlacedDecor: Equatable {
    let corner: BubbleDecor.Corner
    let glyph: BubbleDecor.Glyph
    let size: CGFloat
    let color: UInt
    let out: CGFloat
    let rotation: CGFloat
}

enum BubbleDecorSets {
    static func decor(for styleId: String) -> [BubbleDecor] {
        switch styleId {
        case "strawberry":
            return [BubbleDecor(corner: .bottomTrailing, glyph: .strawberry, size: 22, light: 0xE8364F, dark: 0xFF5A72, rotation: 0.25),
                    BubbleDecor(corner: .topLeading, glyph: .symbol("heart.fill"), size: 13, light: 0xFF6F91, dark: 0xFF8FAB, rotation: -0.3)]
        case "lavender":
            return [BubbleDecor(corner: .bottomTrailing, glyph: .symbol("sparkles"), size: 17, light: 0x8E6CF0, dark: 0xD6C6FF),
                    BubbleDecor(corner: .topLeading, glyph: .symbol("sparkle"), size: 11, light: 0xA98BFF, dark: 0xE6DBFF)]
        case "peach":
            return [BubbleDecor(corner: .bottomTrailing, glyph: .symbol("camera.macro"), size: 19, light: 0xFF8A65, dark: 0xFFB59A, rotation: 0.2),
                    BubbleDecor(corner: .bottomLeading, glyph: .symbol("leaf.fill"), size: 13, light: 0x7CB86F, dark: 0x9AD68C, rotation: -0.5)]
        case "mint":
            return [BubbleDecor(corner: .bottomTrailing, glyph: .symbol("leaf.fill"), size: 17, light: 0x2FA77A, dark: 0x7FE0B8, rotation: 0.4),
                    BubbleDecor(corner: .topLeading, glyph: .symbol("sparkle"), size: 11, light: 0x45C493, dark: 0xB6F5DA)]
        case "cotton":
            return [BubbleDecor(corner: .bottomTrailing, glyph: .symbol("cloud.fill"), size: 20, light: 0xA9D4FF, dark: 0xC9E4FF),
                    BubbleDecor(corner: .topLeading, glyph: .symbol("star.fill"), size: 12, light: 0xFF9ECF, dark: 0xFFC2E2, rotation: 0.3)]
        case "heart":
            return [BubbleDecor(corner: .bottomTrailing, glyph: .symbol("heart.fill"), size: 18, light: 0xFF3B6E, dark: 0xFF6F91, rotation: 0.3),
                    BubbleDecor(corner: .topLeading, glyph: .symbol("heart.fill"), size: 11, light: 0xFF6F91, dark: 0xFF9DB6, rotation: -0.35)]
        case "kawaii":
            return [BubbleDecor(corner: .topTrailing, glyph: .bow, size: 24, light: 0xFF6FA3, dark: 0xFF8FB8, out: 3, rotation: 0.15),
                    BubbleDecor(corner: .bottomLeading, glyph: .symbol("star.fill"), size: 13, light: 0xFFC83D, dark: 0xFFD866, rotation: -0.3),
                    BubbleDecor(corner: .bottomTrailing, glyph: .symbol("sparkles"), size: 14, light: 0xFFB020, dark: 0xFFD866)]
        case "glass":
            return [BubbleDecor(corner: .bottomTrailing, glyph: .symbol("sparkle"), size: 13, light: 0x8E8E93, dark: 0xD1D1D6)]
        default:
            return []
        }
    }

    /// Placed for one bubble. Theirs is a mirror of mine (the art stays on the outer side). A top
    /// corner only on the run's first bubble, so it never lands on the bubble above.
    /// `besideAvatar`: their bubble in a group, whose bottom-leading corner is next to the sender's
    /// face; nothing is drawn there (5-angle check: it covered the avatar).
    static func placed(styleId: String, isMe: Bool, dark: Bool, first: Bool,
                       besideAvatar: Bool = false) -> [PlacedDecor] {
        decor(for: styleId).compactMap { d in
            var c = d.corner
            if !isMe {
                switch c {
                case .topLeading: c = .topTrailing
                case .topTrailing: c = .topLeading
                case .bottomLeading: c = .bottomTrailing
                case .bottomTrailing: c = .bottomLeading
                }
            }
            if !first, c == .topLeading || c == .topTrailing { return nil }
            if besideAvatar, c == .bottomLeading { return nil }
            return PlacedDecor(corner: c, glyph: d.glyph, size: d.size, color: dark ? d.dark : d.light,
                               out: d.out, rotation: isMe ? d.rotation : -d.rotation)
        }
    }
}

/// The art itself, drawn once per glyph, size and colour.
enum BubbleDecorArt {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(_ g: BubbleDecor.Glyph, size: CGFloat, color: UInt) -> UIImage? {
        let key = "\(g)|\(Int(size))|\(color)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let ui = UIColor(red: CGFloat((color >> 16) & 0xFF) / 255, green: CGFloat((color >> 8) & 0xFF) / 255,
                         blue: CGFloat(color & 0xFF) / 255, alpha: 1)
        let img: UIImage?
        switch g {
        case .symbol(let name):
            let cfg = UIImage.SymbolConfiguration(pointSize: size, weight: .bold)
            img = UIImage(systemName: name, withConfiguration: cfg)?.withTintColor(ui, renderingMode: .alwaysOriginal)
        case .bow: img = bow(size: size, color: ui)
        case .strawberry: img = strawberry(size: size, color: ui)
        }
        if let img { cache.setObject(img, forKey: key) }
        return img
    }

    /// Two rounded loops, a knot and two short tails.
    private static func bow(size s: CGFloat, color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: s, height: s * 0.75)).image { _ in
            let w = s, h = s * 0.75
            color.setFill()
            let left = UIBezierPath()
            left.move(to: CGPoint(x: w * 0.5, y: h * 0.42))
            left.addCurve(to: CGPoint(x: w * 0.04, y: h * 0.14), controlPoint1: CGPoint(x: w * 0.30, y: h * 0.02),
                          controlPoint2: CGPoint(x: w * 0.06, y: h * 0.0))
            left.addCurve(to: CGPoint(x: w * 0.5, y: h * 0.52), controlPoint1: CGPoint(x: w * 0.0, y: h * 0.62),
                          controlPoint2: CGPoint(x: w * 0.30, y: h * 0.70))
            left.close(); left.fill()
            let right = UIBezierPath()
            right.move(to: CGPoint(x: w * 0.5, y: h * 0.42))
            right.addCurve(to: CGPoint(x: w * 0.96, y: h * 0.14), controlPoint1: CGPoint(x: w * 0.70, y: h * 0.02),
                           controlPoint2: CGPoint(x: w * 0.94, y: h * 0.0))
            right.addCurve(to: CGPoint(x: w * 0.5, y: h * 0.52), controlPoint1: CGPoint(x: w * 1.0, y: h * 0.62),
                           controlPoint2: CGPoint(x: w * 0.70, y: h * 0.70))
            right.close(); right.fill()
            let tails = UIBezierPath()
            tails.move(to: CGPoint(x: w * 0.46, y: h * 0.50)); tails.addLine(to: CGPoint(x: w * 0.30, y: h * 0.98))
            tails.addLine(to: CGPoint(x: w * 0.42, y: h * 0.90)); tails.close()
            tails.move(to: CGPoint(x: w * 0.54, y: h * 0.50)); tails.addLine(to: CGPoint(x: w * 0.70, y: h * 0.98))
            tails.addLine(to: CGPoint(x: w * 0.58, y: h * 0.90)); tails.close()
            tails.fill()
            color.withAlphaComponent(1).setFill()
            UIColor.white.withAlphaComponent(0.35).setFill()
            UIBezierPath(ovalIn: CGRect(x: w * 0.42, y: h * 0.34, width: w * 0.16, height: h * 0.22)).fill()
            color.setFill()
            UIBezierPath(ovalIn: CGRect(x: w * 0.44, y: h * 0.36, width: w * 0.12, height: h * 0.18)).fill()
        }
    }

    /// A rounded berry with a green cap and pale seeds.
    private static func strawberry(size s: CGFloat, color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: s, height: s)).image { _ in
            let body = UIBezierPath()
            body.move(to: CGPoint(x: s * 0.5, y: s * 0.98))
            body.addCurve(to: CGPoint(x: s * 0.08, y: s * 0.38), controlPoint1: CGPoint(x: s * 0.22, y: s * 0.86),
                          controlPoint2: CGPoint(x: s * 0.02, y: s * 0.62))
            body.addCurve(to: CGPoint(x: s * 0.92, y: s * 0.38), controlPoint1: CGPoint(x: s * 0.20, y: s * 0.18),
                          controlPoint2: CGPoint(x: s * 0.80, y: s * 0.18))
            body.addCurve(to: CGPoint(x: s * 0.5, y: s * 0.98), controlPoint1: CGPoint(x: s * 0.98, y: s * 0.62),
                          controlPoint2: CGPoint(x: s * 0.78, y: s * 0.86))
            body.close()
            color.setFill(); body.fill()
            UIColor(red: 1, green: 0.95, blue: 0.75, alpha: 0.95).setFill()
            for (x, y) in [(0.32, 0.50), (0.50, 0.46), (0.68, 0.50), (0.40, 0.66), (0.60, 0.66), (0.50, 0.80)] {
                UIBezierPath(ovalIn: CGRect(x: s * x - s * 0.03, y: s * y - s * 0.04, width: s * 0.06, height: s * 0.08)).fill()
            }
            UIColor(red: 0.30, green: 0.68, blue: 0.32, alpha: 1).setFill()
            for (x, r) in [(0.30, -0.5), (0.50, 0.0), (0.70, 0.5)] {
                let leaf = UIBezierPath(ovalIn: CGRect(x: -s * 0.08, y: -s * 0.16, width: s * 0.16, height: s * 0.30))
                leaf.apply(CGAffineTransform(rotationAngle: CGFloat(r)))
                leaf.apply(CGAffineTransform(translationX: s * CGFloat(x), y: s * 0.24))
                leaf.fill()
            }
        }
    }
}
