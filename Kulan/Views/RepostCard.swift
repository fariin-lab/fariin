import UIKit

/// ⛔ THE REPOST AS A CARD — owner, 2026-10-11, with the reference screenshots: a repost shows the
/// original story as a rounded card in the middle, its author's face and name in the card's top-left
/// corner, over a soft gradient taken from the picture's own colours. "Make it strong and simple".
///
/// ⚠️ BAKED INTO THE PICTURE, NOT DRAWN BY THE VIEWER. The composer is handed this image as its
/// source, so what the reposter edits is exactly what is posted, every viewer on every build sees the
/// same card, and a repost stays whole when the original expires or its author leaves — the same
/// reason the repost already copies the media rather than pointing at it (`beginRepost`).
///
/// The tap on the card (the bubble with the author's face and name, which opens their profile) is
/// NOT baked: it is laid over the card by the viewer from `Story.repostOf`. See `RepostCard.tapRect`.
enum RepostCard {
    /// The story canvas, 9:16 — the shape every photo story is posted at.
    static let canvas = CGSize(width: 1080, height: 1920)
    /// The card's widest and tallest, as fractions of the canvas.
    static let maxWidth: CGFloat = 0.80
    static let maxHeight: CGFloat = 0.74

    /// The card's rectangle on the canvas for a picture of this shape (width / height).
    static func cardRect(aspect: CGFloat) -> CGRect {
        let a = aspect > 0 ? aspect : 9.0 / 16.0
        var w = canvas.width * maxWidth
        var h = w / a
        if h > canvas.height * maxHeight { h = canvas.height * maxHeight; w = h * a }
        return CGRect(x: (canvas.width - w) / 2, y: (canvas.height - h) / 2, width: w, height: h)
    }

    /// Where the viewer answers a tap with the author bubble, as fractions of the canvas.
    /// ⛔ THE CENTRE COLUMN ONLY — owner, 2026-10-11, two red lines on his screenshot at about 30%
    /// and 70% across, top to bottom of the card: "if you make it everywhere, left and right taps to
    /// the next story are blocked". Outside it, the left and right taps move between stories as
    /// they always did.
    static let tapRect = CGRect(x: 0.30, y: 0.12, width: 0.40, height: 0.76)

    static func render(_ image: UIImage, name: String, avatar: UIImage?) -> UIImage {
        let size = image.size
        let card = cardRect(aspect: size.height > 0 ? size.width / size.height : 0)
        let (top, bottom) = edgeColours(image)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: canvas, format: format).image { ctx in
            let cg = ctx.cgContext
            // The backdrop: the picture's own top and bottom colours, darkened so the card and the
            // white name always stand off it.
            let space = CGColorSpaceCreateDeviceRGB()
            if let g = CGGradient(colorsSpace: space,
                                  colors: [top.cgColor, bottom.cgColor] as CFArray,
                                  locations: [0, 1]) {
                cg.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: canvas.height), options: [])
            }
            // The card, with a soft shadow under it.
            let radius = card.width * 0.04
            let path = UIBezierPath(roundedRect: card, cornerRadius: radius)
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: 12), blur: 40,
                         color: UIColor.black.withAlphaComponent(0.35).cgColor)
            UIColor.black.setFill()
            path.fill()
            cg.restoreGState()
            cg.saveGState()
            path.addClip()
            image.draw(in: card)
            // A light scrim along the top so the name reads on a bright picture.
            if let scrim = CGGradient(colorsSpace: space,
                                      colors: [UIColor.black.withAlphaComponent(0.35).cgColor,
                                               UIColor.black.withAlphaComponent(0).cgColor] as CFArray,
                                      locations: [0, 1]) {
                cg.drawLinearGradient(scrim, start: CGPoint(x: 0, y: card.minY),
                                      end: CGPoint(x: 0, y: card.minY + 180), options: [])
            }
            cg.restoreGState()
            drawChip(in: card, name: name, avatar: avatar, cg: cg)
        }
    }

    /// The author's face and name in the card's top-left corner.
    private static func drawChip(in card: CGRect, name: String, avatar: UIImage?, cg: CGContext) {
        let d: CGFloat = 64
        let inset: CGFloat = 26
        let face = CGRect(x: card.minX + inset, y: card.minY + inset, width: d, height: d)
        cg.saveGState()
        UIBezierPath(ovalIn: face).addClip()
        if let avatar {
            // Aspect-fill into the circle.
            let s = max(d / max(avatar.size.width, 1), d / max(avatar.size.height, 1))
            let w = avatar.size.width * s, h = avatar.size.height * s
            avatar.draw(in: CGRect(x: face.midX - w / 2, y: face.midY - h / 2, width: w, height: h))
        } else {
            UIColor(white: 0.45, alpha: 1).setFill()
            UIRectFill(face)
            let letter = String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 30, weight: .semibold),
                .foregroundColor: UIColor.white]
            let t = (letter as NSString).size(withAttributes: attrs)
            (letter as NSString).draw(at: CGPoint(x: face.midX - t.width / 2, y: face.midY - t.height / 2),
                                      withAttributes: attrs)
        }
        cg.restoreGState()
        UIColor.white.withAlphaComponent(0.9).setStroke()
        let ring = UIBezierPath(ovalIn: face.insetBy(dx: 1.5, dy: 1.5))
        ring.lineWidth = 3
        ring.stroke()

        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = CGSize(width: 0, height: 1)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 36, weight: .semibold),
            .foregroundColor: UIColor.white,
            .shadow: shadow]
        let maxW = card.maxX - face.maxX - inset - 18
        let text = name.isEmpty ? "Story" : name
        let box = (text as NSString).boundingRect(with: CGSize(width: maxW, height: 50),
                                                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                                  attributes: attrs, context: nil)
        (text as NSString).draw(with: CGRect(x: face.maxX + 18, y: face.midY - box.height / 2,
                                             width: maxW, height: box.height),
                                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                attributes: attrs, context: nil)
    }

    /// The average colour of the picture's top and bottom halves, darkened by a third.
    private static func edgeColours(_ image: UIImage) -> (UIColor, UIColor) {
        let fallback = (UIColor(white: 0.18, alpha: 1), UIColor(white: 0.06, alpha: 1))
        guard let cgImage = image.cgImage else { return fallback }
        var px = [UInt8](repeating: 0, count: 8)
        guard let ctx = CGContext(data: &px, width: 1, height: 2, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return fallback }
        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 2))
        // Row 0 of the buffer is the TOP of the picture (CoreGraphics draws bottom-up into memory).
        func colour(_ i: Int) -> UIColor {
            let k: CGFloat = 0.62
            return UIColor(red: CGFloat(px[i]) / 255 * k, green: CGFloat(px[i + 1]) / 255 * k,
                           blue: CGFloat(px[i + 2]) / 255 * k, alpha: 1)
        }
        return (colour(0), colour(4))
    }
}

import SwiftUI

/// ⛔ THE VIDEO CARD, LIVE — owner, 2026-10-11: "users can repost photo and video, card and full
/// screen". A photo card is baked once (`RepostCard.render`); a clip cannot be, so the editor shows
/// the clip shrunk to the card's width (its existing pinch-out, which the export already burns in
/// with the canvas gradient around it) and draws THIS over it: the gradient with a rounded hole
/// where the clip is, so its corners are rounded, plus the author chip. The export draws the same
/// chip into its overlay and cuts the same rounded hole (`StoryBurnIn.holeCorner`), so the posted
/// clip is what was framed here.
enum RepostVideoCard {
    /// The clip's width on the card, as a fraction of its fitted width — the photo card's width.
    static let scale: CGFloat = RepostCard.maxWidth
    /// Corner radius as a fraction of the clip's drawn width — the photo card's ratio.
    static let corner: CGFloat = 0.04
    /// The chip, in fractions of the CANVAS width, matching the photo card's 64 / 36 / 26 px on 1080.
    static let face: CGFloat = 64.0 / 1080
    static let font: CGFloat = 36.0 / 1080
    static let inset: CGFloat = 26.0 / 1080
}

/// The author chip, laid out for a canvas `width` points wide.
struct RepostChipView: View {
    let name: String
    let avatar: UIImage?
    let width: CGFloat

    var body: some View {
        let d = width * RepostVideoCard.face
        HStack(spacing: d * 0.28) {
            Group {
                if let avatar { Image(uiImage: avatar).resizable().scaledToFill() }
                else {
                    ZStack {
                        Color(white: 0.45)
                        Text(String(name.prefix(1)).uppercased())
                            .font(.system(size: d * 0.47, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .frame(width: d, height: d)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: max(1, d * 0.047)))
            Text(name.isEmpty ? "Story" : name)
                .font(.system(size: width * RepostVideoCard.font, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
                .lineLimit(1)
        }
        .fixedSize()
    }
}

/// The page-coloured surround with a rounded hole over the clip, plus the chip in its corner.
struct RepostCardFrame: View {
    let canvas: CGSize
    let clip: CGRect
    let top: UIColor
    let bottom: UIColor
    let name: String
    let avatar: UIImage?

    var body: some View {
        ZStack(alignment: .topLeading) {
            SurroundShape(hole: clip, radius: clip.width * RepostVideoCard.corner)
                .fill(LinearGradient(colors: [Color(uiColor: top), Color(uiColor: bottom)],
                                     startPoint: .top, endPoint: .bottom),
                      style: FillStyle(eoFill: true))
            RepostChipView(name: name, avatar: avatar, width: canvas.width)
                .offset(x: clip.minX + canvas.width * RepostVideoCard.inset,
                        y: clip.minY + canvas.width * RepostVideoCard.inset)
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private struct SurroundShape: Shape {
        let hole: CGRect
        let radius: CGFloat
        func path(in rect: CGRect) -> Path {
            var p = Path(rect)
            p.addRoundedRect(in: hole, cornerSize: CGSize(width: radius, height: radius), style: .continuous)
            return p
        }
    }
}
