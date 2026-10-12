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

    /// ⛔ THE CARD ALONE, ON NOTHING — owner, 2026-10-12: "I see three layers of blur: the original
    /// has its own background, my story adds another, and there is an unwanted third between them",
    /// which appeared the moment he pinched the card smaller. This used to bake its own gradient
    /// surround into the whole 9:16 frame, so a shrunken card carried a second page inside the
    /// page. Now the surround is TRANSPARENT: the editor draws its canvas gradient from the same two
    /// colours (`edgeColours`, handed over as `StoryEditorView.repostCanvas`) and bakes it under the
    /// card at post time, so the card can be pinched to any size over one continuous ground.
    static func render(_ image: UIImage, name: String, avatar: UIImage?) -> UIImage {
        let size = image.size
        let card = cardRect(aspect: size.height > 0 ? size.width / size.height : 0)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: canvas, format: format).image { ctx in
            let cg = ctx.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
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

    /// The average colour of the picture's top and bottom halves, darkened by a third: the ground
    /// the card is shown and posted on (see `render`).
    static func edgeColours(_ image: UIImage) -> (top: UIColor, bottom: UIColor) {
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

/// What the editor's live card frame draws, in the card's own coordinate space. Plain values, so the
/// UIKit view can tell an unchanged frame from a new one without redrawing.
struct RepostCardFrameSpec: Equatable {
    let clip: CGRect
    let top: UIColor
    let bottom: UIColor
    let name: String
    let avatar: UIImage?

    static func == (l: RepostCardFrameSpec, r: RepostCardFrameSpec) -> Bool {
        l.clip == r.clip && l.top == r.top && l.bottom == r.bottom && l.name == r.name && l.avatar === r.avatar
    }
}

/// ⛔ THE VIDEO CARD'S FRAME AND CHIP, IN UIKIT — owner, 2026-10-12, third report: "before Next the
/// avatar and name are not appearing". Two SwiftUI drawings of this (`RepostCardFrame`, first as a
/// sibling of the canvas and then hosted inside it) never showed on his phone. This is layers and
/// labels on a plain `UIView` that sits in the canvas above the clip: nothing to host, nothing to
/// re-render, and its order in the view tree cannot lose. It does not move with the pinch; only
/// the picture and the clip are transformed.
final class RepostCardFrameView: UIView {
    private let surround = CAGradientLayer()
    private let hole = CAShapeLayer()
    private let face = UIImageView()
    private let letter = UILabel()
    private let name = UILabel()
    private var spec: RepostCardFrameSpec?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        // The page-coloured surround with the clip cut out of it (even-odd), so its corners round.
        hole.fillRule = .evenOdd
        hole.fillColor = UIColor.black.cgColor
        surround.mask = hole
        layer.addSublayer(surround)
        face.contentMode = .scaleAspectFill
        face.clipsToBounds = true
        face.layer.borderColor = UIColor.white.withAlphaComponent(0.9).cgColor
        face.backgroundColor = UIColor(white: 0.45, alpha: 1)
        addSubview(face)
        letter.textColor = .white
        letter.textAlignment = .center
        face.addSubview(letter)
        name.textColor = .white
        name.lineBreakMode = .byTruncatingTail
        name.layer.shadowColor = UIColor.black.withAlphaComponent(0.45).cgColor
        name.layer.shadowRadius = 3
        name.layer.shadowOpacity = 1
        name.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(name)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(_ s: RepostCardFrameSpec?) {
        guard s != spec else { return }
        spec = s
        isHidden = s == nil
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let s = spec, bounds.width > 1 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surround.frame = bounds
        surround.colors = [s.top.cgColor, s.bottom.cgColor]
        let path = UIBezierPath(rect: bounds)
        path.append(UIBezierPath(roundedRect: s.clip, cornerRadius: s.clip.width * RepostVideoCard.corner))
        hole.frame = bounds
        hole.path = path.cgPath
        CATransaction.commit()

        let w = bounds.width
        let d = w * RepostVideoCard.face
        let inset = w * RepostVideoCard.inset
        face.frame = CGRect(x: s.clip.minX + inset, y: s.clip.minY + inset, width: d, height: d)
        face.layer.cornerRadius = d / 2
        face.layer.borderWidth = max(1, d * 0.047)
        face.image = s.avatar
        letter.isHidden = s.avatar != nil
        letter.frame = face.bounds
        letter.font = .systemFont(ofSize: d * 0.47, weight: .semibold)
        letter.text = String(s.name.prefix(1)).uppercased()
        name.font = .systemFont(ofSize: w * RepostVideoCard.font, weight: .semibold)
        name.text = s.name.isEmpty ? "Story" : s.name
        let x = face.frame.maxX + d * 0.28
        let maxW = max(0, s.clip.maxX - inset - x)
        let fit = name.sizeThatFits(CGSize(width: maxW, height: d))
        name.frame = CGRect(x: x, y: face.frame.midY - fit.height / 2, width: min(maxW, fit.width), height: fit.height)
    }
}

/// The page-coloured surround with a rounded hole over the clip, plus the chip in its corner.
/// (SwiftUI; the export's chip still comes from `RepostChipView`. The editor draws
/// `RepostCardFrameView` instead — see its note.)
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
