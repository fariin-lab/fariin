import UIKit

// ===== UIKit bubble migration (reference-style unified scrolling surface) =====
// The conversation "felt fragmented" because every bubble was a SwiftUI view hosted in a cell, each with
// its own layout/animation/render lifecycle that ran DURING scroll. the reference app renders every bubble as static
// UIKit content laid out ONCE, so scrolling is a single rigid surface that just follows contentOffset.
//
// This is stage 1 of that migration: the most common bubble — a plain 1:1 delivered text message — renders
// as a native UIKit cell (no SwiftUI, no per-cell animation, no re-measure during scroll). Every other
// case (groups, media, replies, reactions, links, selection, highlight, sending/failed) still routes to
// the SwiftUI cell, so NO feature is lost. Subsequent stages migrate one type at a time.

// Resolved, SwiftUI-free description of a plain-text bubble. Built by ThreadView (which owns the context)
// and consumed by the UIKit cell — Equatable so identical reconfigures are free.
struct UIKitBubbleModel: Equatable {
    enum Tick: Equatable { case none, sending, failed, sent, read }
    struct Radii: Equatable { var topLeading: CGFloat; var topTrailing: CGFloat; var bottomLeading: CGFloat; var bottomTrailing: CGFloat }

    var isMe: Bool
    var text: String
    var edited: Bool
    var timeText: String
    var tick: Tick
    var radii: Radii
    var topSpacing: CGFloat   // cluster spacing above this bubble (14 first-in-cluster, else 2)
    /// Is this bubble sitting on a wallpaper? An incoming bubble is a flat fill without one and a
    /// blur material with one — see `Theme.receivedStyle`, which this path has to agree with or a
    /// chat draws two different incoming surfaces depending on which route a message took.
    /// Equatable, so applying a wallpaper reconfigures every visible bubble by itself.
    var onWallpaper: Bool = false
}

// ===== Shared palette (dynamic — adapts to light/dark like the SwiftUI Theme) =====
private enum BubblePalette {
    static func hex(_ v: UInt32) -> UIColor {
        UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
    static let myFill = UIColor { $0.userInterfaceStyle == .dark ? hex(0x0A84FF) : hex(0x007AFF) }   // Theme.defaultBubble
    static let receivedFill = UIColor { $0.userInterfaceStyle == .dark ? hex(0x26262B) : hex(0xF2F2F2) } // Theme.received (owner's F2F2F2)
    static let myText = UIColor.white
    static let receivedText = UIColor { $0.userInterfaceStyle == .dark ? .white : .black }
    static let myMeta = UIColor.white.withAlphaComponent(0.7)
    static let receivedMeta = UIColor.secondaryLabel

    static let hPad: CGFloat = 15
    static let vPad: CGFloat = 10
    static let rowMargin: CGFloat = 12   // ThreadView adds .padding(.horizontal, 12) to every row
    static let textFont = UIFont.systemFont(ofSize: 17)
    static let metaFont = UIFont.systemFont(ofSize: 10)
    static var maxBubbleWidth: CGFloat { UIScreen.main.bounds.width * 0.72 }
    static let metaGap: CGFloat = 6      // gap between the last word and the trailing time
}

// The bubble itself: a shape-layer background + the text label (with an invisible trailing spacer that
// reserves the timestamp's width on the LAST line) + the real meta label overlaid bottom-trailing. All
// static — nothing here animates or re-measures on its own.
final class UIKitBubbleView: UIView {
    private let bubbleLayer = CAShapeLayer()
    private let textLabel = UILabel()
    private let metaLabel = UILabel()
    private var model: UIKitBubbleModel?
    private(set) var lastCornerPath: UIBezierPath?   // exact bubble outline → context-menu lift preview

    // The blur behind an INCOMING bubble on a wallpaper. Built on first use and kept after that: a
    // recycled cell swings between the two surfaces as it is reused for a sent and a received
    // message, and building a visual-effect view mid-scroll is the expensive half.
    private var blurView: UIVisualEffectView?
    private let blurMask = CAShapeLayer()
    private var blurStyle: UIBlurEffect.Style?   // what the live blur was built for → rebuild only on a change

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(bubbleLayer)
        textLabel.numberOfLines = 0
        addSubview(textLabel)
        addSubview(metaLabel)
        // Audit M4: configure() resolves the dynamic colors to STATIC CGColors/attributed runs, so a
        // light↔dark switch left every visible uikit bubble in the old palette (mixed-palette chat next
        // to the adapting SwiftUI rows) until recycle. Re-resolve on trait change.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: UIKitBubbleView, _) in
            if let m = self.model { self.configure(m) }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ m: UIKitBubbleModel) {
        model = m
        textLabel.attributedText = Self.textAttr(m)   // body + invisible trailing meta spacer
        metaLabel.attributedText = Self.metaAttr(m)
        applySurface(m)
        setNeedsLayout()
    }

    /// Paint the bubble, or stop painting it and let the wallpaper through instead.
    ///
    /// MY bubbles are always a fill — a chat colour is a colour and a wallpaper does not change that.
    /// THEIRS is a fill only while the chat has no wallpaper; with one, the shape layer goes fully
    /// transparent and a masked blur takes the same outline. Both surfaces exist in one view because
    /// cells are recycled: the very next message this view draws may be the other kind.
    private func applySurface(_ m: UIKitBubbleModel) {
        let wantsBlur = !m.isMe && m.onWallpaper
        guard wantsBlur else {
            bubbleLayer.fillColor = (m.isMe ? BubblePalette.myFill : BubblePalette.receivedFill).cgColor
            blurView?.isHidden = true
            return
        }
        // Ultra-thin in dark, thin in light — the same split as Theme.receivedStyle, for the same
        // reason: dark mode is protecting the picture, light mode is protecting black text on it.
        let style: UIBlurEffect.Style = traitCollection.userInterfaceStyle == .dark
            ? .systemUltraThinMaterial : .systemThinMaterial
        // The fill has to go to CLEAR, not stay underneath. A blur over an opaque grey samples the
        // grey and nothing else, which is the flat bubble again with the cost of a blur on top.
        bubbleLayer.fillColor = UIColor.clear.cgColor
        if blurView == nil {
            let v = UIVisualEffectView(effect: UIBlurEffect(style: style))
            v.isUserInteractionEnabled = false
            v.layer.mask = blurMask
            // Below both labels. The shape layer is not view-backed and is transparent whenever this
            // blur is showing, so their relative order costs nothing.
            insertSubview(v, at: 0)
            blurView = v
            blurStyle = style
        } else if blurStyle != style {
            blurView?.effect = UIBlurEffect(style: style)   // light↔dark switch on a live bubble
            blurStyle = style
        }
        blurView?.isHidden = false
    }

    // ── Attributed strings ──

    // Body text + a clear NSTextAttachment sized to the meta width, so the last line reserves exactly the
    // timestamp's footprint (the SwiftUI "invisible metaPlaceholder run" trick, in UIKit).
    private static func textAttr(_ m: UIKitBubbleModel) -> NSAttributedString {
        let out = NSMutableAttributedString(string: m.text, attributes: [
            .font: BubblePalette.textFont,
            .foregroundColor: m.isMe ? BubblePalette.myText : BubblePalette.receivedText,
        ])
        let spacer = NSTextAttachment()
        // EXPLICIT empty image: an attachment with a nil image renders a "missing attachment"
        // artifact — a thin line exactly across the timestamp area (user screenshot). An empty
        // UIImage draws nothing; the bounds still reserve the meta's width on the last line.
        spacer.image = UIImage()
        spacer.bounds = CGRect(x: 0, y: 0, width: metaWidth(m) + BubblePalette.metaGap, height: 1)
        out.append(NSAttributedString(attachment: spacer))
        return out
    }

    private static func metaAttr(_ m: UIKitBubbleModel) -> NSAttributedString {
        let color = m.isMe ? BubblePalette.myMeta : BubblePalette.receivedMeta
        let s = NSMutableAttributedString()
        if m.edited {
            s.append(NSAttributedString(string: "edited ", attributes: [
                .font: UIFont.italicSystemFont(ofSize: 10), .foregroundColor: color]))
        }
        s.append(NSAttributedString(string: m.timeText, attributes: [
            .font: BubblePalette.metaFont, .foregroundColor: color]))
        if let img = tickImage(m) {
            let a = NSTextAttachment()
            a.image = img.withTintColor(m.tick == .failed ? .systemRed : color, renderingMode: .alwaysOriginal)
            a.bounds = CGRect(x: 0, y: -1, width: img.size.width, height: img.size.height)
            s.append(NSAttributedString(string: " "))
            s.append(NSAttributedString(attachment: a))
        }
        return s
    }

    private static func tickImage(_ m: UIKitBubbleModel) -> UIImage? {
        guard m.isMe else { return nil }
        let cfg = UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        switch m.tick {
        case .none: return nil
        case .sending: return UIImage(systemName: "clock", withConfiguration: cfg)
        case .failed: return UIImage(systemName: "exclamationmark.circle.fill",
                                     withConfiguration: UIImage.SymbolConfiguration(pointSize: 10))
        case .sent: return UIImage(systemName: "checkmark", withConfiguration: cfg)
        // TWO overlapping checks, matching the SwiftUI bubble and the chat list. `checkmark.circle.fill`
        // was a single glyph in the same colour and size, so a read receipt that WAS arriving looked
        // identical to a plain delivered tick — the whole reason read receipts appeared not to work.
        case .read: return doubleCheck(cfg)
        }
    }

    /// Two `checkmark` glyphs drawn with a -2.5pt overlap, as one template image.
    private static func doubleCheck(_ cfg: UIImage.SymbolConfiguration) -> UIImage? {
        guard let one = UIImage(systemName: "checkmark", withConfiguration: cfg) else { return nil }
        let overlap: CGFloat = 2.5
        let size = CGSize(width: one.size.width * 2 - overlap, height: one.size.height)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { _ in
            one.draw(in: CGRect(origin: .zero, size: one.size))
            one.draw(in: CGRect(origin: CGPoint(x: one.size.width - overlap, y: 0), size: one.size))
        }
        return img.withRenderingMode(.alwaysTemplate)   // tint follows the meta colour like the single tick
    }

    private static func metaWidth(_ m: UIKitBubbleModel) -> CGFloat {
        ceil(metaAttr(m).size().width)
    }

    // ── Sizing (the exact bubble + cell size the layout will use) ──

    // Returns (cellSize, bubbleSize): the cell spans the full width; the bubble is capped at 72% and
    // aligned inside. Height = text height (at the capped width) + padding + cluster spacing.
    static func sizes(_ m: UIKitBubbleModel, width: CGFloat) -> (cell: CGSize, bubble: CGSize) {
        let maxBubble = min(BubblePalette.maxBubbleWidth, width - BubblePalette.rowMargin * 2)
        let maxText = max(1, maxBubble - BubblePalette.hPad * 2)
        let attr = textAttr(m)
        let rect = attr.boundingRect(with: CGSize(width: maxText, height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let bubbleW = ceil(rect.width) + BubblePalette.hPad * 2
        let bubbleH = ceil(rect.height) + BubblePalette.vPad * 2
        let bubble = CGSize(width: min(maxBubble, bubbleW), height: bubbleH)
        return (CGSize(width: width, height: bubbleH + m.topSpacing), bubble)
    }

    // Lay the bubble out at its measured size, aligned leading/trailing within `bounds`.
    func layout(in bounds: CGRect, model m: UIKitBubbleModel) {
        let (_, bubble) = Self.sizes(m, width: bounds.width)
        let x = m.isMe ? (bounds.width - BubblePalette.rowMargin - bubble.width) : BubblePalette.rowMargin
        let y = m.topSpacing
        frame = CGRect(x: x, y: y, width: bubble.width, height: bubble.height)
        bubbleLayer.frame = self.bounds
        let path = Self.cornerPath(bubble, m.radii)
        bubbleLayer.path = path.cgPath
        lastCornerPath = path
        // The blur wears the bubble's own outline, not a corner radius. These bubbles have four
        // different radii (the cluster shape squares off the side that continues), so a rounded-rect
        // mask would round the two corners the shape deliberately keeps sharp.
        if let blur = blurView, !blur.isHidden {
            // No implicit animation: the mask is re-pathed on every layout pass, and a cell being
            // reused mid-scroll would otherwise animate its old outline into its new one.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            blur.frame = self.bounds
            blurMask.frame = self.bounds
            blurMask.path = path.cgPath
            CATransaction.commit()
        }
        textLabel.frame = CGRect(x: BubblePalette.hPad, y: BubblePalette.vPad,
                                 width: bubble.width - BubblePalette.hPad * 2,
                                 height: bubble.height - BubblePalette.vPad * 2)
        metaLabel.sizeToFit()
        metaLabel.frame = CGRect(x: bubble.width - BubblePalette.hPad - metaLabel.bounds.width,
                                 y: bubble.height - BubblePalette.vPad - metaLabel.bounds.height + 1,
                                 width: metaLabel.bounds.width, height: metaLabel.bounds.height)
    }

    private static func cornerPath(_ size: CGSize, _ r: UIKitBubbleModel.Radii) -> UIBezierPath {
        let p = UIBezierPath()
        let w = size.width, h = size.height
        p.move(to: CGPoint(x: r.topLeading, y: 0))
        p.addLine(to: CGPoint(x: w - r.topTrailing, y: 0))
        p.addArc(withCenter: CGPoint(x: w - r.topTrailing, y: r.topTrailing), radius: r.topTrailing,
                 startAngle: -.pi/2, endAngle: 0, clockwise: true)
        p.addLine(to: CGPoint(x: w, y: h - r.bottomTrailing))
        p.addArc(withCenter: CGPoint(x: w - r.bottomTrailing, y: h - r.bottomTrailing), radius: r.bottomTrailing,
                 startAngle: 0, endAngle: .pi/2, clockwise: true)
        p.addLine(to: CGPoint(x: r.bottomLeading, y: h))
        p.addArc(withCenter: CGPoint(x: r.bottomLeading, y: h - r.bottomLeading), radius: r.bottomLeading,
                 startAngle: .pi/2, endAngle: .pi, clockwise: true)
        p.addLine(to: CGPoint(x: 0, y: r.topLeading))
        p.addArc(withCenter: CGPoint(x: r.topLeading, y: r.topLeading), radius: r.topLeading,
                 startAngle: .pi, endAngle: .pi * 1.5, clockwise: true)
        p.close()
        return p
    }
}

// The cell: a plain UICollectionViewCell holding ONE UIKitBubbleView. No SwiftUI, no hosting controller.
final class UIKitBubbleCell: UICollectionViewCell {
    private let bubbleView = UIKitBubbleView()
    private var model: UIKitBubbleModel?
    var previewBubble: UIKitBubbleView { bubbleView }   // context-menu lift target

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(bubbleView)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ m: UIKitBubbleModel) {
        model = m
        bubbleView.configure(m)
        setNeedsLayout()
    }

    // DIRECT repaint channel (belt-and-braces from the build-325 field failure, where read ticks on
    // uikit rows did not refresh on device even though the diffable reconfigure chain looks correct):
    // the controller pushes the fresh model straight onto visible cells on every update. Gated to
    // GEOMETRY-NEUTRAL changes only (tick / time / radii — same text, same spacing): a height-changing
    // update must go through the measured reload path or the bubble would repaint at a stale frame.
    // The soft cross-dissolve mirrors the SwiftUI meta's 0.25s tick fade.
    func repaintIfMetaChanged(_ m: UIKitBubbleModel) {
        guard let old = model, m != old,
              m.text == old.text, m.edited == old.edited, m.topSpacing == old.topSpacing else { return }
        UIView.transition(with: contentView, duration: 0.25, options: [.transitionCrossDissolve]) {
            self.configure(m)
            self.layoutIfNeeded()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let m = model { bubbleView.layout(in: contentView.bounds, model: m) }
    }
}
