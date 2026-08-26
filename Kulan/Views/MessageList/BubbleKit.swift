import SwiftUI   // Theme hands back SwiftUI Colors; this file is the one place that converts them
import UIKit

// ===== The message list's UIKit vocabulary =====
//
// Every number, colour and shape a row draws lives here, so a text bubble and a call row cannot
// drift apart. Phase 1 of the full UIKit migration: the list container was already UIKit, but each
// row was a SwiftUI view hosted in a cell, with its own layout/animation/render lifecycle running
// DURING scroll. That mixture is what made the list feel fragmented.
//
// ⚠️ ONE RULE GOVERNS THIS WHOLE DIRECTORY: measurement and rendering come from the SAME function.
// `MessageRowLayout.plan` returns every rect in the row; the height is that plan's height and the
// layout is that plan's rects. There is no second code path that could measure a row at one size
// and draw it at another — which is the bug family the SwiftUI sizer kept producing.

enum BubbleMetrics {
    /// ThreadView adds `.padding(.horizontal, 12)` to every row; the UIKit rows own that inset now.
    static let rowMargin: CGFloat = 12
    static let hPad: CGFloat = 15          // bubble text inset, horizontal
    static let vPad: CGFloat = 10          // bubble text inset, vertical
    static let clusterGapFirst: CGFloat = 14   // space above the first bubble of a sender's run
    static let clusterGap: CGFloat = 2         // space above a continuing bubble
    static let bigCorner: CGFloat = 18
    static let smallCorner: CGFloat = 6        // the interior corner of a fused cluster
    static let metaGap: CGFloat = 8            // gap between the last word and the timestamp
    static let maxWidthFraction: CGFloat = 0.72
    static let avatarSize: CGFloat = 28
    static let avatarGap: CGFloat = 6
    static let senderNameGap: CGFloat = 3      // VStack spacing above the bubble
    static let reactionOverhang: CGFloat = 13  // how far the badge hangs below the bubble
    static let hairline: CGFloat = 1 / UIScreen.main.scale

    static let bodyFont = UIFont.systemFont(ofSize: 17)
    static let metaFont = UIFont.systemFont(ofSize: 10)
    static let metaItalicFont = UIFont.italicSystemFont(ofSize: 10)
    static let senderNameFont = UIFont.systemFont(ofSize: 12, weight: .semibold)
    static let forwardedFont = UIFont.italicSystemFont(ofSize: 11)
    static let quoteNameFont = UIFont.systemFont(ofSize: 12, weight: .semibold)
    static let quoteTextFont = UIFont.systemFont(ofSize: 12)
    static let noticeFont = UIFont.systemFont(ofSize: 12, weight: .semibold)   // .caption.weight(.semibold)

    /// The width a row is laid out at. Never `UIScreen` inside a cell: on an iPad in Stage Manager
    /// the list is narrower than the screen, and the sizer and the cell must be handed one number.
    static func maxBubbleWidth(in rowWidth: CGFloat) -> CGFloat {
        max(1, rowWidth * maxWidthFraction)
    }
}

enum BubblePalette {
    static func hex(_ v: UInt32) -> UIColor {
        UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
    /// Theme.defaultBubble — the sent bubble when the chat has no custom colour.
    static let myFill = UIColor { $0.userInterfaceStyle == .dark ? hex(0x0A84FF) : hex(0x007AFF) }
    /// Theme.received — the flat incoming surface with no wallpaper behind it.
    static let receivedFill = UIColor { $0.userInterfaceStyle == .dark ? hex(0x26262B) : hex(0xF2F2F2) }
    /// Theme.bg — the page background, used by the Reduce Transparency surface.
    static let background = UIColor { $0.userInterfaceStyle == .dark ? hex(0x121214) : hex(0xFFFFFF) }
    static let myText = UIColor.white
    static let receivedText = UIColor { $0.userInterfaceStyle == .dark ? .white : .black }
    static let myMeta = UIColor.white.withAlphaComponent(0.7)
    static let receivedMeta = UIColor.secondaryLabel

    /// Stable per-sender colour for a group name label — the same arithmetic the SwiftUI bubble
    /// used (sum of unicode scalars into a fixed palette), so a name does not change colour when
    /// its row changes render path.
    static let senderPalette: [UIColor] = [.systemBlue, .systemPurple, .systemPink, .systemOrange,
                                           .systemGreen, .systemTeal, .systemIndigo, .systemRed]
    static func senderColor(_ uid: String) -> UIColor {
        let sum = uid.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return senderPalette[sum % senderPalette.count]
    }

    static func rim(_ dark: Bool) -> UIColor { UIColor(Theme.bubbleRim(dark)) }

    /// ⚠️ THE APP'S ACCENT IS `.primary`, WHICH IS WHITE AT NIGHT — and `UIColor.tintColor` is NOT
    /// the same thing. KulanApp sets `.tint(.primary)`, a SwiftUI value that never reaches a UIKit
    /// view's `tintColor`; a UIKit row asking for `.tintColor` would get the window's default blue
    /// and every reaction count, mention and divider in the chat would change colour on the day it
    /// moved to this path. `.primary` is `UIColor.label`, so that is what the SwiftUI rows were
    /// actually drawing and that is what these draw.
    static let accent = UIColor.label
}

/// What paints behind a bubble. Resolved by ThreadView (which owns the wallpaper and the chat
/// colour) and carried in the model, so a cell never reaches into app state to decide its own look.
enum BubbleFill: Equatable {
    case solid(UInt)                 // RGB hex — a chat colour or the default blue
    case gradient([UInt])            // 2+ stops, topLeading → bottomTrailing
    case received                    // the flat incoming grey
    /// The page background. `Theme.receivedSurface` returns THIS, not the incoming grey, when
    /// Reduce Transparency is on over a wallpaper — collapsing the two flats into one was a real
    /// difference for anyone with that setting turned on.
    case background
    case wallpaperSlice(WallpaperBlurState)   // incoming on a wallpaper: a slice of the blurred picture
    /// A borderless bubble. The reference app's own `isBubbleTransparent`: the bubble VIEW stays and
    /// only the fill is dropped, so the text insets and the footer position are unchanged. Used by
    /// jumbomoji, which is why an emoji message lines up with an ordinary one exactly.
    case clear

    /// A representative colour, for the places that need one number. Never used to paint a gradient.
    var representative: UIColor {
        switch self {
        case .solid(let v): return BubblePalette.hex(UInt32(truncatingIfNeeded: v))
        case .gradient(let v): return BubblePalette.hex(UInt32(truncatingIfNeeded: v.first ?? 0))
        case .received, .wallpaperSlice: return BubblePalette.receivedFill
        case .background: return BubblePalette.background
        case .clear: return .clear
        }
    }
}

// ===== Geometry =====

struct BubbleRadii: Equatable {
    var topLeading: CGFloat
    var topTrailing: CGFloat
    var bottomLeading: CGFloat
    var bottomTrailing: CGFloat

    static func uniform(_ r: CGFloat) -> BubbleRadii {
        BubbleRadii(topLeading: r, topTrailing: r, bottomLeading: r, bottomTrailing: r)
    }

    /// The fused-cluster shape: full 18pt outer corners, and the interior corner on the sending
    /// side shrinks to 6 so a same-sender run reads as one block.
    static func cluster(isMe: Bool, first: Bool, last: Bool) -> BubbleRadii {
        let big = BubbleMetrics.bigCorner, small = BubbleMetrics.smallCorner
        if isMe {
            return BubbleRadii(topLeading: big, topTrailing: first ? big : small,
                               bottomLeading: big, bottomTrailing: last ? big : small)
        }
        return BubbleRadii(topLeading: first ? big : small, topTrailing: big,
                           bottomLeading: last ? big : small, bottomTrailing: big)
    }
}

enum BubbleShape {
    /// A path with CONTINUOUS corners (the squircle SwiftUI draws for `style: .continuous`), per
    /// corner, so the cluster's squared-off side is honoured.
    ///
    /// ⚠️ Circular arcs are NOT the same shape and this matters here: nearly every row in the chat
    /// is drawn by this file now, so if it used `addArc` the whole list would shift to a rounder
    /// corner than the one that has been shipping. The 1.528 multiplier is the standard continuous
    /// approximation — the curve reaches 1.528·r along each edge and meets the corner with control
    /// points at 0.667·r, which lands within a fraction of a point of Apple's own curve at these
    /// radii.
    static func path(_ size: CGSize, _ r: BubbleRadii, continuous: Bool = true) -> UIBezierPath {
        let w = size.width, h = size.height
        // A radius can never exceed half the shorter side, or opposite corners overlap and the
        // path folds in on itself (a one-line bubble with an 18pt radius is 34 tall — close).
        let cap = min(w, h) / 2
        let tl = min(r.topLeading, cap), tr = min(r.topTrailing, cap)
        let bl = min(r.bottomLeading, cap), br = min(r.bottomTrailing, cap)
        let p = UIBezierPath()
        guard continuous else {
            p.move(to: CGPoint(x: tl, y: 0))
            p.addLine(to: CGPoint(x: w - tr, y: 0))
            p.addArc(withCenter: CGPoint(x: w - tr, y: tr), radius: tr, startAngle: -.pi / 2, endAngle: 0, clockwise: true)
            p.addLine(to: CGPoint(x: w, y: h - br))
            p.addArc(withCenter: CGPoint(x: w - br, y: h - br), radius: br, startAngle: 0, endAngle: .pi / 2, clockwise: true)
            p.addLine(to: CGPoint(x: bl, y: h))
            p.addArc(withCenter: CGPoint(x: bl, y: h - bl), radius: bl, startAngle: .pi / 2, endAngle: .pi, clockwise: true)
            p.addLine(to: CGPoint(x: 0, y: tl))
            p.addArc(withCenter: CGPoint(x: tl, y: tl), radius: tl, startAngle: .pi, endAngle: .pi * 1.5, clockwise: true)
            p.close()
            return p
        }
        // Continuous corners. `reach` is how far along each edge the curve starts; it is clamped so
        // two corners on one edge can never claim more than that edge has.
        func reach(_ radius: CGFloat, _ other: CGFloat, _ edge: CGFloat) -> CGFloat {
            let want = radius * 1.528
            let otherWant = other * 1.528
            guard want + otherWant > edge, want + otherWant > 0 else { return want }
            return edge * want / (want + otherWant)
        }
        let tlTop = reach(tl, tr, w), trTop = reach(tr, tl, w)
        let trRight = reach(tr, br, h), brRight = reach(br, tr, h)
        let brBottom = reach(br, bl, w), blBottom = reach(bl, br, w)
        let blLeft = reach(bl, tl, h), tlLeft = reach(tl, bl, h)
        // Control points sit at 0.667·r from the corner along each edge — the cubic that makes the
        // curvature continuous rather than jumping from straight to circular.
        func c(_ v: CGFloat) -> CGFloat { v * 0.667 / 1.528 }

        p.move(to: CGPoint(x: tlTop, y: 0))
        p.addLine(to: CGPoint(x: w - trTop, y: 0))
        p.addCurve(to: CGPoint(x: w, y: trRight),
                   controlPoint1: CGPoint(x: w - c(trTop), y: 0),
                   controlPoint2: CGPoint(x: w, y: c(trRight)))
        p.addLine(to: CGPoint(x: w, y: h - brRight))
        p.addCurve(to: CGPoint(x: w - brBottom, y: h),
                   controlPoint1: CGPoint(x: w, y: h - c(brRight)),
                   controlPoint2: CGPoint(x: w - c(brBottom), y: h))
        p.addLine(to: CGPoint(x: blBottom, y: h))
        p.addCurve(to: CGPoint(x: 0, y: h - blLeft),
                   controlPoint1: CGPoint(x: c(blBottom), y: h),
                   controlPoint2: CGPoint(x: 0, y: h - c(blLeft)))
        p.addLine(to: CGPoint(x: 0, y: tlLeft))
        p.addCurve(to: CGPoint(x: tlTop, y: 0),
                   controlPoint1: CGPoint(x: 0, y: c(tlLeft)),
                   controlPoint2: CGPoint(x: c(tlTop), y: 0))
        p.close()
        return p
    }

    static func capsulePath(_ size: CGSize) -> UIBezierPath {
        UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2)
    }
}

// ===== The tick glyphs =====

enum BubbleTicks {
    enum Kind: Equatable { case none, sending, failed, sent, read }

    /// The pair of overlapping checks the chat list draws. `checkmark.circle.fill` was a single
    /// glyph at the same size and colour, which is why an arriving read receipt looked identical to
    /// a plain delivered tick.
    private static var doubleCheckCache: [CGFloat: UIImage] = [:]

    static func image(_ kind: Kind) -> UIImage? {
        let cfg = UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        switch kind {
        case .none: return nil
        case .sending: return UIImage(systemName: "clock", withConfiguration: cfg)
        case .failed:
            return UIImage(systemName: "exclamationmark.circle.fill",
                           withConfiguration: UIImage.SymbolConfiguration(pointSize: 10))
        case .sent: return UIImage(systemName: "checkmark", withConfiguration: cfg)
        case .read: return doubleCheck(cfg)
        }
    }

    private static func doubleCheck(_ cfg: UIImage.SymbolConfiguration) -> UIImage? {
        if let hit = doubleCheckCache[9] { return hit }
        guard let one = UIImage(systemName: "checkmark", withConfiguration: cfg) else { return nil }
        let overlap: CGFloat = 2.5
        let size = CGSize(width: one.size.width * 2 - overlap, height: one.size.height)
        let img = UIGraphicsImageRenderer(size: size).image { _ in
            one.draw(in: CGRect(origin: .zero, size: one.size))
            one.draw(in: CGRect(origin: CGPoint(x: one.size.width - overlap, y: 0), size: one.size))
        }.withRenderingMode(.alwaysTemplate)
        doubleCheckCache[9] = img
        return img
    }
}

// ===== A fill that can be a gradient =====

/// The layer that paints a bubble. One class for all three fills because cells recycle: the very
/// next message this view draws may be the other kind.
///
/// ⚠️ A `CAGradientLayer` cannot be masked by a path the way a `CAShapeLayer` fills one, so the
/// gradient rides inside a shape-layer MASK rather than replacing it. Both live here so callers
/// hand over a `BubbleFill` and a path and never think about which mechanism is in play.
final class BubbleFillView: UIView {
    private let shape = CAShapeLayer()
    private let gradient = CAGradientLayer()
    private let gradientMask = CAShapeLayer()
    private var sliceView: WallpaperBlurSliceView?
    private var current: BubbleFill?

    private(set) var path = UIBezierPath()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.addSublayer(shape)
        gradient.startPoint = CGPoint(x: 0, y: 0)     // topLeading → bottomTrailing, as SwiftUI draws it
        gradient.endPoint = CGPoint(x: 1, y: 1)
        gradient.mask = gradientMask
        gradient.isHidden = true
        layer.addSublayer(gradient)
    }
    required init?(coder: NSCoder) { fatalError() }

    func apply(_ fill: BubbleFill, path p: UIBezierPath, bounds b: CGRect) {
        current = fill
        path = p
        frame = b
        // ⚠️ Every geometry write here is inside a disabled transaction. A CALayer's `path`,
        // `frame` and `colors` are IMPLICITLY animated, so a bubble whose height changed would
        // otherwise morph over a quarter second while its cell was already at the new size — the
        // "bubble catches up late" family of glitches.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        shape.frame = CGRect(origin: .zero, size: b.size)
        shape.path = p.cgPath
        gradient.frame = CGRect(origin: .zero, size: b.size)
        gradientMask.frame = CGRect(origin: .zero, size: b.size)
        gradientMask.path = p.cgPath

        switch fill {
        case .solid(let hex):
            shape.fillColor = BubblePalette.hex(UInt32(truncatingIfNeeded: hex)).cgColor
            gradient.isHidden = true
            sliceView?.isHidden = true
        case .gradient(let hexes):
            shape.fillColor = UIColor.clear.cgColor
            gradient.colors = hexes.map { BubblePalette.hex(UInt32(truncatingIfNeeded: $0)).cgColor }
            gradient.isHidden = false
            sliceView?.isHidden = true
        case .received:
            shape.fillColor = BubblePalette.receivedFill.cgColor
            gradient.isHidden = true
            sliceView?.isHidden = true
        case .background:
            shape.fillColor = BubblePalette.background.cgColor
            gradient.isHidden = true
            sliceView?.isHidden = true
        case .clear:
            shape.fillColor = UIColor.clear.cgColor
            gradient.isHidden = true
            sliceView?.isHidden = true
        case .wallpaperSlice(let state):
            // The fill goes to CLEAR, not left underneath: the slice is opaque and would cover it,
            // but a fill that is still there is a fill somebody will one day see at an edge.
            shape.fillColor = UIColor.clear.cgColor
            gradient.isHidden = true
            let v = sliceView ?? {
                let s = WallpaperBlurSliceView()
                insertSubview(s, at: 0)
                sliceView = s
                return s
            }()
            v.isHidden = false
            v.frame = CGRect(origin: .zero, size: b.size)
            v.state = state
            v.maskPath = p
            v.reposition()
        }
    }

    /// Re-resolve dynamic colours after a light↔dark flip. `apply` writes STATIC CGColors, so
    /// without this every visible bubble stayed in the old palette until its cell recycled.
    func refreshForTraitChange() {
        guard let current else { return }
        apply(current, path: path, bounds: frame)
    }
}
