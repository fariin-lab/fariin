import UIKit

// ===== The row, drawn =====
//
// Every subview here is laid out from the RowPlan by frame arithmetic — no Auto Layout, no
// intrinsic content sizes, nothing that could resolve to a different answer than the pass that
// measured this row. That is the whole point of the migration: a row is a static picture that
// scrolling only translates.
//
// Subviews are created LAZILY and hidden when unused. A plain text row must not pay for a quote
// box, an avatar and three reaction capsules it does not have — that allocation-per-cell cost is
// what made the hosted rows expensive to recycle.

/// A view whose backing layer IS a shape layer, so it takes part in subview ordering. A bare
/// `CAShapeLayer` added to a view's layer is appended once and then sits UNDER every subview added
/// afterwards — which is how the jump-to flash ended up painted behind the text it was meant to
/// cover. As a view it can be brought to the front like anything else.
final class BubbleShapeView: UIView {
    override class var layerClass: AnyClass { CAShapeLayer.self }
    var shape: CAShapeLayer { layer as! CAShapeLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        shape.fillColor = UIColor.clear.cgColor
        backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError() }
}

// ── The reply quote ──

final class BubbleQuoteView: UIView {
    private let accent = UIView()
    private let name = UILabel()
    private let snippet = UILabel()
    private var thumb: RowImageView?
    private let backing = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backing.layer.cornerRadius = 8
        backing.layer.cornerCurve = .continuous
        addSubview(backing)
        accent.layer.cornerRadius = 1.5
        addSubview(accent)
        snippet.lineBreakMode = .byTruncatingTail
        snippet.numberOfLines = 2   // the plan sizes the box for up to two lines — see `quoteSize`
        addSubview(name)
        addSubview(snippet)
        isUserInteractionEnabled = false   // the cell hit-tests the quote and routes the jump
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ q: QuoteChrome, plan: QuoteInnerPlan, textColor: UIColor, cid: String) {
        // Tinted with the (contrasting) text colour so it is visible on every bubble fill — a white
        // tint vanished on a white "mine" bubble in dark mode.
        backing.backgroundColor = textColor.withAlphaComponent(0.12)
        accent.backgroundColor = textColor.withAlphaComponent(0.7)
        name.attributedText = plan.nameAttr
        snippet.attributedText = plan.snippetAttr

        switch q.thumb {
        case .none:
            thumb?.reset()
            thumb?.isHidden = true
        case .story(let url):
            thumbView().configure(url: url, enc: nil, cid: cid, cornerRadius: 5)
            thumb?.isHidden = false
        case .media(let url, let enc, _):
            thumbView().configure(url: url, enc: enc, cid: cid, cornerRadius: 5)
            thumb?.isHidden = false
        case .gif(let url):
            thumbView().configure(url: url, enc: nil, cid: cid, cornerRadius: 5)
            thumb?.isHidden = false
        }
    }

    private func thumbView() -> RowImageView {
        if let thumb { return thumb }
        // `RowImageView(frame:)`, not `RowImageView()`: UIImageView adds its own designated
        // initialisers (`init(image:)`), so a subclass that overrides only `init(frame:)` does not
        // inherit the no-argument one.
        let v = RowImageView(frame: .zero)
        addSubview(v)
        thumb = v
        return v
    }

    func apply(_ plan: QuoteInnerPlan) {
        backing.frame = bounds
        accent.frame = plan.accent
        if let t = plan.thumb { thumb?.frame = t }
        // ⛔ THE TEXT COLUMN TAKES THE WIDTH THE BOX IS ACTUALLY DRAWN AT. The plan's rects were
        // measured against the quote's own natural width, and the caller then FILLS the box to the
        // bubble's content width — so a quote of a short message inside a long reply drew its name
        // and snippet at about 150pt inside a 280pt box, truncating with a hundred points of empty
        // grey to the right of the ellipsis. That is the "reply empty space" report.
        //
        // `bounds` is the filled width, so this is the stretch the plan's own comment always claimed
        // the caller was doing. Never narrower than planned, so a genuinely narrow box is unchanged.
        let filled = max(plan.name.width, bounds.width - plan.name.minX - plan.trailingInset)
        name.frame = CGRect(x: plan.name.minX, y: plan.name.minY, width: filled, height: plan.name.height)
        snippet.frame = CGRect(x: plan.snippet.minX, y: plan.snippet.minY,
                               width: filled, height: plan.snippet.height)
    }
}

// ── Where my reaction was picked ──

/// The hand-off between the place I pick a reaction (the menu's emoji bar, a double tap) and the row
/// that later draws its pill, which is rebuilt a moment afterwards by a different path. The picker
/// notes the screen point; the row takes it once, if it is fresh and for the same emoji, and flies
/// the emoji from there (owner 2026-10-29). A double tap does not know the emoji yet: nil = any.
@MainActor enum ReactionFlight {
    static let duration: CFTimeInterval = 0.36
    private static var pending: (emoji: String?, point: CGPoint, at: CFTimeInterval)?
    /// When I last sent a reaction from this device. ⛔ The landing animation plays only within a
    /// moment of one: a pill can also turn "mine" because my saved picks LOADED late (a channel's
    /// picks arrive by listener), and that must not ripple across every post on screen.
    private static var localAt: CFTimeInterval = -10

    static func markLocal() { localAt = CACurrentMediaTime() }
    static var recentLocal: Bool { CACurrentMediaTime() - localAt < 1.5 }

    static func note(_ emoji: String?, screenPoint: CGPoint) {
        pending = (emoji, screenPoint, CACurrentMediaTime())
    }

    static func take(_ emoji: String) -> CGPoint? {
        guard let p = pending else { return nil }
        pending = nil
        guard CACurrentMediaTime() - p.at < 1.5 else { return nil }
        if let want = p.emoji, plain(want) != plain(emoji) { return nil }
        return p.point
    }

    private static func plain(_ e: String) -> String { e.replacingOccurrences(of: "\u{FE0F}", with: "") }
}

// ── A reaction capsule ──

/// ⛔ A PILL HOLDS THE EMOJI AND WHO SENT IT — owner, 2026-09-16, with the reference app's bubble.
/// Up to three faces, overlapped; past three the layout hands over a count instead and `faces` is
/// empty. See `ReactionChip`.
final class ReactionChipView: UIView {
    private let label = UILabel()
    private let ring = CAShapeLayer()
    /// Built on the first chip that actually needs them, and kept for reuse. A view per chip that is
    /// never shown is a view per chip wasted.
    private var faceViews: [RowAvatarView] = []
    private var faceCount = 0
    private var isFreeform = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.textAlignment = .center
        addSubview(label)
        ring.fillColor = UIColor.clear.cgColor
        ring.lineWidth = 1
        layer.addSublayer(ring)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// ⛔ THE PILL TAKES THE COLOUR OF THE BUBBLE IT SITS ON — the reference app's own rule, read out
    /// of their source for his 2026-09-23 report. They pick the whole palette by side first
    /// (`case .incoming` / `case .outgoing`, each pulling `reactionInactiveBackground` and
    /// `reactionActiveBackground` from that side's bubble colours) and only then ask whether I
    /// reacted.
    ///
    /// ⚠️ OURS ASKED ONLY THE SECOND QUESTION, which is the whole bug. `onMyBubble` did not exist:
    /// an un-reacted pill was `receivedFill` wherever it sat. On a received bubble that is the
    /// bubble's own fill, so the pill was invisible; on one of MY bubbles, which is the chat colour
    /// he has set, a pale grey pill sat on top of it looking like it had been pasted there. His
    /// screenshot is the second case.
    ///
    /// ⚠️ WHITE AT ALPHA ON MY OWN BUBBLE, NOT A NAMED COLOUR, because the sent bubble is whatever
    /// chat colour he picked and a fixed grey cannot sit on all of them. The text on that bubble is
    /// already white for the same reason.
    ///
    /// ⚠️ AND THE RING IS GONE. The reference marks "I reacted" with a STRONGER FILL and draws no
    /// stroke at all; ours drew a `.label` outline, which on a wallpapered chat (forced dark, so
    /// `.label` is white) is the bright hoop around the pill in his screenshot. Selected is now the
    /// heavier of the two fills on each side, which is their rule and one less thing on screen.
    func configure(_ attr: NSAttributedString, mine: Bool, onMyBubble: Bool, faces: [ReactionFace],
                   freeform: Bool = false) {
        label.attributedText = attr
        isFreeform = freeform
        if freeform {
            // Under a picture, on the wallpaper: the time capsule's own dark glass, so it reads on
            // any background; heavier when it is mine, as on a bubble.
            backgroundColor = UIColor.black.withAlphaComponent(mine ? 0.5 : 0.35)
        } else if onMyBubble {
            backgroundColor = UIColor.white.withAlphaComponent(mine ? 0.45 : 0.22)
        } else {
            // Mine is the solid accent (owner 2026-10-29: "show a different badge colour so the
            // user feels they reacted"); 0.18 against 0.08 was too close to see.
            backgroundColor = mine ? BubblePalette.accent : BubblePalette.accent.withAlphaComponent(0.08)
        }
        ring.strokeColor = UIColor.clear.cgColor
        faceCount = faces.count
        while faceViews.count < faces.count {
            // Each new face goes UNDER the ones before it: the first reactor's face is on top, as in
            // the reference pill.
            let a = RowAvatarView()
            if let last = faceViews.last { insertSubview(a, belowSubview: last) } else { addSubview(a) }
            faceViews.append(a)
        }
        for (i, v) in faceViews.enumerated() {
            if i < faces.count {
                v.isHidden = false
                v.configure(name: faces[i].name, photoUrl: faces[i].photoUrl)
            } else {
                v.isHidden = true
            }
        }
        setNeedsLayout()
    }

    /// Where the emoji sits in the pill (its first character; the label is centred), for the flight
    /// of a reaction I just made (`MessageRowView.flyIn`).
    var emojiPoint: CGPoint {
        guard let t = label.attributedText, t.length > 0 else { return CGPoint(x: bounds.midX, y: bounds.midY) }
        let first = t.attributedSubstring(from: (t.string as NSString).rangeOfComposedCharacterSequence(at: 0))
        let full = t.size().width, w = first.size().width
        let x0 = label.frame.minX + max(0, (label.frame.width - full) / 2)
        return CGPoint(x: x0 + w / 2, y: label.frame.midY)
    }
    /// The emoji's point size in the pill, so the flight lands at the pill's own size.
    var emojiFontSize: CGFloat {
        guard let t = label.attributedText, t.length > 0,
              let f = t.attribute(.font, at: 0, effectiveRange: nil) as? UIFont else { return 15 }
        return f.pointSize
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The emoji keeps the left of the pill and the face sits at its trailing end, which is the
        // order in his screenshot. With no face the label owns the whole pill, as it always did.
        if faceCount > 0 {
            // The small pill on a picture's edge uses the small set (see `MessageRowLayout.decorations`).
            let d = isFreeform ? BubbleMetrics.reactionFaceSmall : BubbleMetrics.reactionFace
            let trail = isFreeform ? BubbleMetrics.reactionFaceTrailSmall : BubbleMetrics.reactionFaceTrail
            let gap = isFreeform ? BubbleMetrics.reactionFaceGapSmall : BubbleMetrics.reactionFaceGap
            let lead = isFreeform ? BubbleMetrics.reactionFaceLeadSmall : BubbleMetrics.reactionFaceLead
            let overlap = isFreeform ? BubbleMetrics.reactionFaceOverlapSmall : BubbleMetrics.reactionFaceOverlap
            let stackX = bounds.width - trail - BubbleMetrics.reactionFaceStack(faceCount, small: isFreeform)
            for i in 0..<faceCount {
                faceViews[i].frame = CGRect(x: stackX + CGFloat(i) * (d - overlap),
                                            y: (bounds.height - d) / 2, width: d, height: d)
            }
            label.frame = CGRect(x: lead, y: 0,
                                 width: max(0, stackX - gap - lead),
                                 height: bounds.height)
        } else {
            label.frame = bounds
        }
        layer.cornerRadius = bounds.height / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.path = UIBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                 cornerRadius: bounds.height / 2 - 0.5).cgPath
        ring.frame = bounds
        CATransaction.commit()
    }
}

// ── The disappearing-message countdown ──
//
// A ring that empties as the message's time runs out, drawn beside the timestamp. Theirs uses a
// shrinking hourglass for the same job; a ring is the shape this app already speaks in (the upload
// indicator is one) and it reads at 9pt, which an hourglass's waist does not.
//
// ⚠️ IT SHOWS A PROPORTION, NOT A DURATION. A five-minute timer half spent and a one-day timer half
// spent look the same, which is what makes it legible at a glance — the exact remaining time is a
// detail for the message's info, not for a 9pt glyph on every row.
//
// ⚠️ NO TIMER OF ITS OWN, deliberately. A per-row display link in a chat full of expiring messages
// is dozens of live timers; the fraction is recomputed on the repaints the row already gets, and a
// second's lag on a countdown nobody is watching to the second is invisible.
final class ExpiryRingView: UIView {
    private let track = CAShapeLayer()
    private let fill = CAShapeLayer()

    /// 1 = the whole life left, 0 = due now.
    var fraction: CGFloat = 1 { didSet { setNeedsLayout() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        for l in [track, fill] {
            l.fillColor = UIColor.clear.cgColor
            l.lineWidth = 1.5
            l.lineCap = .round
            layer.addSublayer(l)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // the ring must not animate its own relayout
        let r = min(bounds.width, bounds.height) / 2 - 0.75
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let full = UIBezierPath(arcCenter: c, radius: r, startAngle: -.pi / 2,
                                endAngle: 1.5 * .pi, clockwise: true).cgPath
        track.frame = bounds
        track.path = full
        track.strokeColor = tintColor.withAlphaComponent(0.3).cgColor
        fill.frame = bounds
        fill.path = full
        fill.strokeColor = tintColor.cgColor
        fill.strokeEnd = max(0, min(1, fraction))
        CATransaction.commit()
    }
}

// ── The selection circle ──
//
// A port of their `SelectionIndicatorView(style: .list)`, which is what the message list uses.
//
// Unselected is an EMPTY 2pt ring — no disc behind it, no shadow. Selected swaps the ring for a
// filled circle in the CHAT'S OWN COLOUR with a white tick on it. Ours used to draw a black disc at
// 30% under a white ring with a drop shadow, and fill it with one hard-coded blue on every chat.
//
// ⚠️ The two states are two views, hidden against each other, not one view repainted. That is
// theirs, and it is what makes `animated: false` genuinely instant: there is no colour to
// interpolate, only a swap.

final class SelectionCheckboxView: UIView {
    /// Their `SelectionIndicatorView.preferredSize` and `ringStrokeWidth`.
    static let preferredSize: CGFloat = 24
    private static let ringStrokeWidth: CGFloat = 2
    private static let innerRingInset: CGFloat = 1

    private let ring = CAShapeLayer()
    private let selectedDisc = UIView()
    private let tick = UIImageView(image: UIImage(systemName: "checkmark",
                                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)))

    private var isSelectedState = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        ring.fillColor = UIColor.clear.cgColor
        ring.lineWidth = Self.ringStrokeWidth
        layer.addSublayer(ring)
        selectedDisc.isUserInteractionEnabled = false
        addSubview(selectedDisc)
        tick.tintColor = .white
        // ⛔ NEVER SCALED. `.scaleAspectFit` in a frame the size of the disc STRETCHES the glyph up
        // to fill it, which is why the tick looked oversized inside its circle. Theirs is explicit
        // about this — "Checkmark is self-sized and only needs to be centered properly" — and its
        // asset is simply centred in the filled circle at its own size. `.center` is the mode that
        // means that: draw the image as it is, in the middle.
        tick.contentMode = .center
        selectedDisc.addSubview(tick)
        selectedDisc.isHidden = true
        applyAppearance()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Appearance

    /// The filled state's colour — the chat's own, handed down on the row model. Their
    /// `updateStyle(conversationStyle:)` does exactly this with `chatColorValue`.
    private var fillColor: UIColor = .systemBlue
    /// The empty ring's colour. Theirs is `tertiaryLabel`, dropping to a flat grey at 50% in LIGHT
    /// theme over a wallpaper, where a system tertiary is too faint to find.
    private var ringColor: UIColor = .tertiaryLabel

    func updateStyle(tint: UInt, onWallpaper: Bool) {
        // Same narrowing every other hex in this file uses — the models carry `UInt`, the palette
        // takes `UInt32`.
        fillColor = BubblePalette.hex(UInt32(truncatingIfNeeded: tint))
        let isLight = traitCollection.userInterfaceStyle != .dark
        ringColor = (isLight && onWallpaper) ? UIColor(white: 0x80 / 255, alpha: 0.5) : .tertiaryLabel
        applyAppearance()
    }

    /// Their `setIsSelected(_:animated:)`. The tap path passes `animated: false`, so the tick lands
    /// on the same frame as the finger — no spring, no delay, nothing to wait for.
    func setSelected(_ on: Bool, animated: Bool = false) {
        guard on != isSelectedState else { return }
        isSelectedState = on
        guard animated else { applyAppearance(); return }
        UIView.transition(with: self, duration: 0.15, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.applyAppearance()
        }
    }

    /// Re-assert the current state without animating — for a reconfigure that is not a state change.
    func refreshSelected(_ on: Bool) {
        isSelectedState = on
        applyAppearance()
    }

    private func applyAppearance() {
        selectedDisc.backgroundColor = fillColor
        selectedDisc.isHidden = !isSelectedState
        ring.strokeColor = ringColor.cgColor
        ring.isHidden = isSelectedState        // theirs: the ring is hidden by the fill, not drawn under it
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        // A CAShapeLayer's colour is a resolved CGColor and does not follow the trait environment on
        // its own, unlike a UIView's backgroundColor. Re-resolve it when the theme flips.
        if previous?.userInterfaceStyle != traitCollection.userInterfaceStyle { applyAppearance() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Their layout: the inner ring is inset 1pt from the view's bounds, and the filled circle has
        // the SAME diameter as that ring rather than filling the whole box.
        let diameter = bounds.height - Self.innerRingInset * 2
        selectedDisc.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        selectedDisc.center = CGPoint(x: bounds.midX, y: bounds.midY)
        selectedDisc.layer.cornerRadius = diameter / 2
        // Its own size, centred — not the disc's bounds. See the note on `contentMode` above.
        tick.bounds = CGRect(origin: .zero, size: tick.image?.size ?? .zero)
        tick.center = CGPoint(x: selectedDisc.bounds.midX, y: selectedDisc.bounds.midY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds
        ring.path = UIBezierPath(ovalIn: bounds.insetBy(dx: Self.innerRingInset + Self.ringStrokeWidth / 2,
                                                        dy: Self.innerRingInset + Self.ringStrokeWidth / 2)).cgPath
        CATransaction.commit()
    }
}

// ── A centred capsule notice ──

final class RowNoticePillView: UIView {
    private let fill = BubbleFillView()
    private let label = UILabel()
    private let rim = BubbleShapeView()
    /// `.storyCard` only (story mentions, owner 2026-10-16): the story picture as the app's story card;
    /// the ring layer is kept but unused (he asked for no ring).
    private let thumb = RowImageView(frame: .zero)
    private let ring = CAGradientLayer()
    private let ringMask = CAShapeLayer()
    private var flightKey = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(fill)
        thumb.clipsToBounds = true
        thumb.isHidden = true
        addSubview(thumb)
        ring.colors = [UIColor(red: 0x34/255, green: 0xC7/255, blue: 0x6F/255, alpha: 1).cgColor,
                       UIColor(red: 0x3D/255, green: 0xA1/255, blue: 0xFD/255, alpha: 1).cgColor]
        ring.startPoint = CGPoint(x: 0, y: 1)
        ring.endPoint = CGPoint(x: 1, y: 0)
        ringMask.fillColor = nil
        ringMask.strokeColor = UIColor.black.cgColor
        ringMask.lineWidth = 2.5
        ring.mask = ringMask
        ring.isHidden = true
        layer.addSublayer(ring)
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.textAlignment = .center
        addSubview(label)
        addSubview(rim)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ plan: NoticePlan, dark: Bool) {
        label.attributedText = plan.attr
        label.textAlignment = plan.style == .unsupported ? .left : .center
        label.frame = plan.text
        configureStory(plan)

        let size = plan.capsule.size
        rim.frame = CGRect(origin: .zero, size: size)
        switch plan.style {
        case .pill:
            // The SAME surface an incoming bubble wears — the reference app's date header is not
            // styled to resemble a bubble, it IS one, minus the text colour. So this goes through
            // the identical `Theme.receivedSurface` decision every incoming bubble makes.
            // A multi-line notice wears one background per line (owner 2026-10-17); the fill, the
            // wallpaper slice and the rim all take the path, so every surface variant follows it.
            let path = plan.lineRows.count > 1
                ? Self.stackedLinesPath(plan.lineRows, radius: plan.lineRadius)
                : BubbleShape.capsulePath(size)
            let bubbleFill: BubbleFill
            switch Theme.receivedSurface(dark, onWallpaper: plan.onWallpaper, blur: plan.wallpaperBlur) {
            case .flat:
                // `.flat` is two colours — see the note in MessageRowModelBuilder.receivedFill.
                bubbleFill = (plan.onWallpaper && UIAccessibility.isReduceTransparencyEnabled)
                    ? .background : .received
            case .slice(let state): bubbleFill = .wallpaperSlice(state)
            case .material: bubbleFill = .material
            }
            fill.apply(bubbleFill, path: path, bounds: CGRect(origin: .zero, size: size))
            fill.alpha = 1
            rim.shape.path = path.cgPath
            rim.shape.lineWidth = plan.onWallpaper ? BubbleMetrics.rimWidth : 0.5
            rim.shape.lineDashPattern = nil     // cleared: this view is reused for both styles
            rim.shape.strokeColor = plan.onWallpaper
                ? BubblePalette.rim(dark).cgColor
                : UIColor.white.withAlphaComponent(0.06).cgColor
        case .storyCard:
            // The pill's own surface (the incoming bubble's), as a rounded card.
            let path = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 26)
            let bubbleFill: BubbleFill
            switch Theme.receivedSurface(dark, onWallpaper: plan.onWallpaper, blur: plan.wallpaperBlur) {
            case .flat:
                bubbleFill = (plan.onWallpaper && UIAccessibility.isReduceTransparencyEnabled)
                    ? .background : .received
            case .slice(let state): bubbleFill = .wallpaperSlice(state)
            case .material: bubbleFill = .material
            }
            fill.apply(bubbleFill, path: path, bounds: CGRect(origin: .zero, size: size))
            fill.alpha = 1
            rim.shape.path = path.cgPath
            rim.shape.lineWidth = plan.onWallpaper ? BubbleMetrics.rimWidth : 0.5
            rim.shape.lineDashPattern = nil
            rim.shape.strokeColor = plan.onWallpaper
                ? BubblePalette.rim(dark).cgColor
                : UIColor.white.withAlphaComponent(0.06).cgColor
        case .unsupported:
            let path = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 14)
            fill.apply(.received, path: path, bounds: CGRect(origin: .zero, size: size))
            fill.alpha = 0.7
            rim.shape.path = path.cgPath
            rim.shape.lineWidth = 1
            rim.shape.strokeColor = UIColor.secondaryLabel.withAlphaComponent(0.25).cgColor
            rim.shape.lineDashPattern = [4, 3]
        }
    }
}

extension RowNoticePillView {
    /// The story mention card's picture, ring and flight source. Hidden on every other notice.
    fileprivate func configureStory(_ plan: NoticePlan) {
        guard plan.style == .storyCard, let img = plan.image else {
            thumb.isHidden = true; thumb.reset(); ring.isHidden = true
            setFlightKey("")
            return
        }
        // The Stories list card's shape: continuous corner 14 at 66 wide, scaled (owner 2026-10-16:
        // no circle, no ring). `ring` stays hidden.
        ring.isHidden = true
        thumb.isHidden = false
        thumb.frame = img
        thumb.configure(url: plan.storyThumbUrl, enc: nil, cid: "", cornerRadius: Self.cardCorner(img))
        thumb.layer.cornerCurve = .continuous
        setFlightKey(plan.flightKey)
    }

    /// The picture is where the story flies out of and back into (`ThreadView.openStory`), as the
    /// story reply card's thumbnail is. Circular: the radius is half the side.
    fileprivate func setFlightKey(_ key: String) {
        if key != flightKey, !flightKey.isEmpty { MediaOpenRects.releaseView(flightKey, ifItIs: thumb) }
        flightKey = key
        guard !key.isEmpty else { return }
        MediaOpenRects.captureView(key, thumb)
        if thumb.window != nil {
            MediaOpenRects.capture(key, thumb.convert(thumb.bounds, to: nil), cornerRadius: Self.cardCorner(thumb.bounds))
        }
    }

    /// `StoryListRow.corner` (14) at its 66pt width, kept in proportion.
    fileprivate static func cardCorner(_ r: CGRect) -> CGFloat { (14 * r.width / 66).rounded() }

    /// The outline of centred line rows stacked touching (owner 2026-10-17, the reference app's
    /// service message): the outer corners round outward, and where a wider line meets a narrower
    /// one the step rounds INTO the corner, so the two read as one poured shape. Walked clockwise
    /// as a polygon; `addArc(tangent1End:tangent2End:radius:)` rounds each vertex, and the turn
    /// direction alone makes a corner convex or concave.
    fileprivate static func stackedLinesPath(_ rows: [CGRect], radius r: CGFloat) -> UIBezierPath {
        guard let first = rows.first, let last = rows.last else { return UIBezierPath() }
        var pts: [(CGPoint, CGFloat)] = []
        // Down the right side.
        pts.append((CGPoint(x: first.maxX, y: first.minY), r))
        for i in 0..<(rows.count - 1) where rows[i].maxX != rows[i + 1].maxX {
            // A step can only round as far as half its own width, or the two arcs overlap.
            let s = min(r, abs(rows[i].maxX - rows[i + 1].maxX) / 2)
            pts.append((CGPoint(x: rows[i].maxX, y: rows[i].maxY), s))
            pts.append((CGPoint(x: rows[i + 1].maxX, y: rows[i].maxY), s))
        }
        pts.append((CGPoint(x: last.maxX, y: last.maxY), r))
        // Back up the left side.
        pts.append((CGPoint(x: last.minX, y: last.maxY), r))
        for i in stride(from: rows.count - 2, through: 0, by: -1) where rows[i].minX != rows[i + 1].minX {
            let s = min(r, abs(rows[i].minX - rows[i + 1].minX) / 2)
            pts.append((CGPoint(x: rows[i + 1].minX, y: rows[i].maxY), s))
            pts.append((CGPoint(x: rows[i].minX, y: rows[i].maxY), s))
        }
        pts.append((CGPoint(x: first.minX, y: first.minY), r))

        let path = CGMutablePath()
        path.move(to: CGPoint(x: first.midX, y: first.minY))
        for (i, p) in pts.enumerated() {
            let next = i + 1 < pts.count ? pts[i + 1].0 : CGPoint(x: first.midX, y: first.minY)
            path.addArc(tangent1End: p.0, tangent2End: next, radius: p.1)
        }
        path.closeSubpath()
        return UIBezierPath(cgPath: path)
    }
}

// ── The call-history bubble ──

final class CallBubbleView: UIView {
    private let fill = BubbleFillView()
    private let rim = BubbleShapeView()
    private let disc = UIView()
    private let icon = UIImageView()
    private let status = UILabel()
    private let detail = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(fill)
        rim.shape.lineWidth = BubbleMetrics.rimWidth
        addSubview(rim)
        disc.isUserInteractionEnabled = false
        addSubview(disc)
        icon.contentMode = .center
        addSubview(icon)
        status.lineBreakMode = .byTruncatingTail
        detail.lineBreakMode = .byTruncatingTail
        addSubview(status)
        addSubview(detail)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ plan: CallPlan, dark: Bool) {
        let size = plan.bubble.size
        // ⛔ APPLE'S CONTINUOUS CORNER — owner, 2026-09-16: "message bubble corners, call bubble
        // corners, voice message bubble corners ... use apple rounded corners looks smooth". See
        // `BubbleShape.path` for the extent cap that makes this mode safe to use at last.
        let path = BubbleShape.path(size, .uniform(16), continuous: true)
        fill.apply(plan.fill, path: path, bounds: CGRect(origin: .zero, size: size))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rim.frame = CGRect(origin: .zero, size: size)
        rim.shape.path = path.cgPath
        rim.shape.strokeColor = plan.rim ? BubblePalette.rim(dark).cgColor : UIColor.clear.cgColor
        CATransaction.commit()
        bringSubviewToFront(rim)

        disc.frame = plan.disc
        disc.layer.cornerRadius = plan.disc.height / 2
        disc.backgroundColor = plan.discColor
        icon.frame = plan.disc
        icon.image = UIImage(systemName: plan.symbol,
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        icon.tintColor = plan.iconColor
        status.attributedText = plan.statusAttr
        status.frame = plan.status
        detail.attributedText = plan.detailAttr
        detail.frame = plan.detail
    }
}

// ── The whole row ──

final class MessageRowView: UIView {
    /// The bubble's own box. The list controller lifts THIS for the long-press menu, hit-tests it
    /// for the double tap, and translates it for the reply swipe — so its frame has to be the
    /// bubble's real frame, not the row's.
    let bubbleBox = UIView()

    private let fill = BubbleFillView()
    private let rim = BubbleShapeView()
    private let highlight = BubbleShapeView()
    private var bubbleDark = false   // the bubble's last palette, for the jump flash's tint
    private let bodyLabel = UILabel()
    private let metaLabel = UILabel()

    private var mediaView: MediaBubbleView?

    /// While the picture is lifted into the viewer, the bubble shows nothing where it was: the
    /// fill and the rim get a hole the picture's size (owner 2026-10-29, "hide that empty
    /// background"). The caption under it keeps its bubble.
    private func setMediaLifted(_ lifted: Bool) {
        guard lifted, let mv = mediaView, !mv.isHidden else {
            fill.layer.mask = nil; rim.layer.mask = nil
            return
        }
        func holed(_ v: UIView) -> CALayer {
            let m = CAShapeLayer()
            let p = UIBezierPath(rect: v.bounds)
            p.append(UIBezierPath(rect: mv.convert(mv.bounds, to: v)))
            m.path = p.cgPath
            m.fillRule = .evenOdd
            return m
        }
        fill.layer.mask = holed(fill)
        rim.layer.mask = holed(rim)
    }
    /// The animated sticker this row shows, for the long-press lift (owner 2026-10-21).
    var stickerView: RowStickerView? { (mediaView?.isHidden ?? true) ? nil : mediaView?.stickerView }
    /// What this row draws over the bubble from outside it (sender name, mark, role chip, forwarded
    /// line), for the long-press lift: a snapshot of the bubble alone leaves a gap where the name
    /// was (owner 2026-10-23).
    var liftOverlays: [UIView] {
        [senderLabel, verifiedView, roleChipView, forwardedLabel, forwardedIcon]
            .compactMap { $0 }.filter { !$0.isHidden && $0.alpha > 0.01 }
    }
    /// Diagnostics only (ROWGEO#, owner 2026-10-23 overlap report): every drawn part that sits
    /// more than a point off the rect its plan gave it, as "part=dx,dy" in points, plus the view's
    /// height against the plan's and a role chip shown that the plan does not have. Nil when the
    /// row is drawn exactly as planned. Measured through `convert`, so a stranded transform counts.
    func planDrift() -> String? {
        guard let p = plan else { return nil }
        var parts: [String] = []
        func check(_ name: String, _ v: UIView?, _ want: CGRect?) {
            guard let v, !v.isHidden, let want else { return }
            let have = v.convert(v.bounds, to: self)
            let dx = have.minX - want.minX, dy = have.minY - want.minY
            if abs(dx) > 1 || abs(dy) > 1 { parts.append("\(name)=\(Int(dx)),\(Int(dy))") }
        }
        if abs(bounds.height - p.height) > 0.5 { parts.append("viewH=\(Int(bounds.height))/\(Int(p.height))") }
        check("div", dividerLabel, p.divider?.label)
        if case .bubble(let b) = p.body {
            check("box", bubbleBox, b.bubble)
            check("name", senderLabel, b.senderName)
            check("role", roleChipView, b.roleChip)
            if avatarLift < 0.5 { check("face", avatarView, b.avatar) }   // a pinned photo is lifted on purpose
            if let c = roleChipView, !c.isHidden, b.roleChip == nil { parts.append("role=unplanned") }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// What a reply swipe moves with the bubble: the overlays above plus the sender's photo
    /// (owner 2026-10-23: the bubble slid over a photo that stayed put). A story reply's caption,
    /// bar and card ride too (owner 2026-10-27: only the text bubble moved, the card stayed put).
    var swipeRiders: [UIView] {
        liftOverlays + [avatarView, storyReplyView].compactMap { $0 }.filter { !$0.isHidden }
    }
    private var albumView: AlbumBubbleView?
    private var fileView: FileBubbleView?
    private var locationView: LocationBubbleView?
    private var contactView: ContactBubbleView?
    private var pollView: PollBubbleView?
    private var linkView: LinkPreviewBubbleView?
    private var storyReplyView: StoryReplyCardView?
    private var voiceView: VoiceBubbleView?
    private var pillView: PillBubbleView?
    private var sendingSpinner: UIImageView?
    private var quoteView: BubbleQuoteView?
    private var avatarView: RowAvatarView?
    private var senderLabel: UILabel?
    private var verifiedView: UIImageView?
    private var roleChipView: UIView?          // owner 2026-10-18 Role chip after the sender's name
    private var forwardedLabel: UILabel?
    private var forwardedIcon: UIImageView?
    private var tombstoneIcon: UIImageView?
    private var failBadge: UIButton?
    /// A channel post's share button (`applyShareButton`) and where it is.
    private var shareButton: UIView?
    private var shareRect: CGRect?
    /// The failed badge's menu items, asked for when it is tapped. Set by the cell.
    var failMenuItems: (() -> [UIMenuElement])?
    private var reactionViews: [ReactionChipView] = []
    private var headerPill: RowNoticePillView?
    private var dividerLeft: UIView?
    private var dividerRight: UIView?
    private var dividerLabel: UILabel?
    private var noticeView: RowNoticePillView?
    private var noticeButtonViews: [RowNoticePillView] = []
    private var callView: CallBubbleView?
    private var checkbox: SelectionCheckboxView?
    /// The disappearing-message icon, drawn over the footer. See `setExpiryTimer`.
    private var expiryRing: UIImageView?

    private(set) var plan: RowPlan?
    private(set) var model: MessageRowModel?
    private var cid: String = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        // ⚠️ The bubble box does NOT clip. Reaction capsules are its subviews so they ride the reply
        // swipe with it, and they deliberately hang off its bottom corner.
        bubbleBox.clipsToBounds = false
        bubbleBox.addSubview(fill)
        bodyLabel.numberOfLines = 0
        // ⚠️ A UILabel defaults to `.byTruncatingTail`, and that is not just a truncation setting —
        // it changes how the text WRAPS. Measuring with `boundingRect` (word wrapping) and drawing
        // with the default would put the two passes back into disagreement, which is exactly what
        // this whole directory exists to prevent.
        bodyLabel.lineBreakMode = .byWordWrapping
        // ⛔ NO LINE-BREAK STRATEGY — found 2026-09-26 checking the timestamp fix. A UILabel's
        // default `.standard` includes `.pushOut`: it moves a word down so a paragraph never ends
        // on one lone word. `boundingRect` and the layout manager that measure this text do not,
        // so the drawn last line could be WIDER than the measured one and the time, placed in the
        // room the measurement promised, landed on the words. Same wrapping in both passes.
        bodyLabel.lineBreakStrategy = []
        bubbleBox.addSubview(bodyLabel)
        // ⛔ NEVER TRUNCATE THE FOOTER — owner, 2026-08-26: his bubbles read "2:44 PM…" with the
        // ticks replaced by an ellipsis. A UILabel defaults to `.byTruncatingTail`, and the meta's
        // frame is its own measured width, so a fraction of a point of disagreement between
        // `boundingRect` and the label's own typesetting is enough to eat the tick. The footer is
        // one short line that is always given exactly the room it asked for; clipping is the honest
        // failure mode here, and in practice it never has to.
        metaLabel.lineBreakMode = .byClipping
        bubbleBox.addSubview(metaLabel)
        // The rim and the jump-to flash are `.overlay`s in the design: above the content, added
        // last so subview order puts them there.
        rim.shape.lineWidth = BubbleMetrics.rimWidth
        bubbleBox.addSubview(rim)
        bubbleBox.addSubview(highlight)
        addSubview(bubbleBox)

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: MessageRowView, _) in
            // `apply` resolves dynamic colours to static CGColors and attributed runs, so without
            // this every visible row stayed in the old palette after a light↔dark flip until it
            // recycled — a chat drawn in two palettes at once.
            if let m = self.model, let p = self.plan { self.apply(m, plan: p, cid: self.cid) }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Apply

    func apply(_ m: MessageRowModel, plan p: RowPlan, cid: String) {
        fill.layer.mask = nil; rim.layer.mask = nil   // a reused row is never left holed
        shareButton?.isHidden = true; shareRect = nil  // the bubble path puts it back (`applyShareButton`)
        // A reaction arriving on, or leaving, the message this view is ALREADY showing. Never on a
        // recycled cell (a different id): that would be motion out of nowhere mid-scroll.
        let oldKeys = Self.reactionKeys(model), newKeys = Self.reactionKeys(m)
        var before: ReactionBefore?
        // Owner audit 2026-10-06 chat #38: a growth belongs to the pass that made it. When the list
        // skipped its read (a moving list, or the main apply path), the old number waited here and
        // a later, unrelated height change on this cell handed it out, sliding the whole screen.
        pendingGrowth = 0
        // owner 2026-10-25: any change to the pills, not only a new or gone emoji. A count or a face
        // arriving can resize a pill and the bubble with it, and that used to snap to the new size.
        if model?.id == m.id, let oldKeys, let newKeys, Self.reactionChips(model) != Self.reactionChips(m),
           !UIAccessibility.isReduceMotionEnabled, case .bubble(let ob)? = plan?.body {
            before = captureBefore(ob, oldKeys: oldKeys, newKeys: newKeys)
        }
        // ⛔ THE CORNER EASES WHEN THE RUN CHANGES (owner 2026-10-26: "the corner comes like a pop").
        // A new message below mine turns this bubble's big bottom corner into the run's small one;
        // the same message at the same size with only its corners changed morphs over a quarter
        // second instead of snapping. A reaction growth has its own animation and wins.
        var cornerFrom: (fill: UIBezierPath, rim: CGPath?)?
        if before == nil, model?.id == m.id, !UIAccessibility.isReduceMotionEnabled,
           case .bubble(let ob)? = plan?.body, case .bubble(let nb) = p.body,
           !ob.isCapsule, !nb.isCapsule, ob.bubble.size == nb.bubble.size, ob.radii != nb.radii {
            cornerFrom = (fill.shownPath, rim.shape.path)
        }
        model = m
        plan = p
        self.cid = cid
        let dark = traitCollection.userInterfaceStyle == .dark
        defer {
            if let before, case .bubble(let nb) = p.body { animateReactionChange(from: before, to: nb) }
            if let cornerFrom, case .bubble(let nb) = p.body { animateCorners(from: cornerFrom, size: nb.bubble.size) }
            // Owner audit 2026-10-06 chat #39: the direction is for this pass only. Left set, it was
            // read by a later pass the list had not decided it for. Back to the fixed-top default.
            growsFromBottom = false
        }

        applyHeader(p, dark: dark)
        applyDivider(p)
        applyCheckbox(m, p)

        switch p.body {
        case .bubble(let b):
            bubbleBox.isHidden = false
            noticeView?.isHidden = true
            callView?.isHidden = true
            applyNoticeButtons(nil, dark: dark)
            applyBubble(b, model: m, dark: dark, cid: cid)
        case .notice(let n):
            bubbleBox.isHidden = true
            callView?.isHidden = true
            hideBubbleChrome()
            let v = noticeView ?? {
                let v = RowNoticePillView(); addSubview(v); noticeView = v; return v
            }()
            v.isHidden = false
            v.configure(n, dark: dark)
            v.frame = n.capsule
            applyNoticeButtons(n, dark: dark)
        case .call(let c):
            bubbleBox.isHidden = true
            noticeView?.isHidden = true
            applyNoticeButtons(nil, dark: dark)
            hideBubbleChrome()
            let v = callView ?? {
                let v = CallBubbleView(); addSubview(v); callView = v; return v
            }()
            v.isHidden = false
            v.frame = c.bubble
            v.configure(c, dark: dark)
            // The caller's face in a group (2026-10-20), after hideBubbleChrome hid it.
            if let rect = c.avatar, case .call(let row) = m.content, let name = row.callerName {
                let a = avatarView ?? {
                    let a = RowAvatarView(); addSubview(a); avatarView = a; return a
                }()
                a.isHidden = false
                a.frame = rect
                a.configure(name: name, photoUrl: row.callerPhoto)
            }
        }
    }

    /// ⛔ HIDE THE CHROME THAT LIVES ON THE ROW, NOT IN THE BUBBLE.
    ///
    /// Hiding `bubbleBox` takes everything INSIDE it with it — the picture, the quote, the poll —
    /// but the sender name, the avatar, the Forwarded tag, the retry line, the verified mark and
    /// the story-reply card are the bubble's siblings, because they sit outside its box by design.
    /// A notice or a call row never touches them, so a cell recycled from a group bubble onto a
    /// system notice kept somebody's name and face floating over it.
    private func hideBubbleChrome() {
        avatarView?.isHidden = true
        senderLabel?.isHidden = true
        verifiedView?.isHidden = true
        roleChipView?.isHidden = true
        forwardedLabel?.isHidden = true
        forwardedIcon?.isHidden = true
        failBadge?.isHidden = true
        storyReplyView?.isHidden = true
    }

    private func applyHeader(_ p: RowPlan, dark: Bool) {
        guard let h = p.dateHeader else { headerPill?.isHidden = true; return }
        let v = headerPill ?? {
            let v = RowNoticePillView(); addSubview(v); headerPill = v; return v
        }()
        v.isHidden = false
        v.configure(h, dark: dark)
        v.frame = h.capsule
    }

    private func applyDivider(_ p: RowPlan) {
        guard let d = p.divider else {
            dividerLeft?.isHidden = true; dividerRight?.isHidden = true; dividerLabel?.isHidden = true
            return
        }
        if dividerLeft == nil {
            let l = UIView(), r = UIView(), lab = UILabel()
            lab.textAlignment = .center
            addSubview(l); addSubview(r); addSubview(lab)
            dividerLeft = l; dividerRight = r; dividerLabel = lab
        }
        let line = BubblePalette.accent.withAlphaComponent(0.3)
        dividerLeft?.isHidden = false; dividerRight?.isHidden = false; dividerLabel?.isHidden = false
        dividerLeft?.backgroundColor = line
        dividerRight?.backgroundColor = line
        dividerLeft?.frame = d.leftLine
        dividerRight?.frame = d.rightLine
        dividerLabel?.attributedText = d.attr
        dividerLabel?.frame = d.label
    }

    private func applyCheckbox(_ m: MessageRowModel, _ p: RowPlan) {
        guard let rect = p.checkbox else {
            // ⛔ THE CIRCLE IS TAKEN OUT OF THE CELL, NOT FADED. This is the fix for the stranded
            // checkbox, and it is theirs: their message component only puts the selection view into
            // the stack while `isShowingSelectionUI || wasShowingSelectionUI`, so the pass after the
            // slide-out simply builds a cell that has no such view in it.
            //
            // What this replaced set `alpha = 0`, left the view in the hierarchy, and said in a
            // comment that `prepareForReuse` was what actually put it away. That made the whole exit
            // depend on one reconfigure reaching one cell at one moment — and any cell that missed
            // it (a land held back by the gate, a row the signature diff skipped, an exit that
            // arrived in the same turn as a delete) kept a fully drawn circle until it was recycled.
            // There is nothing left to strand now.
            checkbox?.layer.removeAllAnimations()
            checkbox?.removeFromSuperview()
            checkbox = nil
            return
        }
        let isNew = checkbox == nil
        let v = checkbox ?? {
            let v = SelectionCheckboxView(); addSubview(v); checkbox = v; return v
        }()
        v.isHidden = false
        // Bounds and center, for the same reason the bubble box uses them: a translation may be
        // riding on this view from the slide, and a view's `frame` is undefined under a transform.
        let seat = {
            v.bounds = CGRect(origin: .zero, size: rect.size)
            v.center = CGPoint(x: rect.midX, y: rect.midY)
        }
        // ⚠️ A CIRCLE BEING BORN INSIDE THE ENTRY ANIMATION MUST NOT INTERPOLATE ITS WAY THERE. This
        // method is called from inside the cell's `UIView.animate` block, and a view created in that
        // block starts life at the origin — so writing its centre there would fly it in diagonally
        // from the row's top-left corner. It is seated at its final place with no animation, and the
        // slide is added afterwards as a layer animation, which is theirs.
        if isNew { UIView.performWithoutAnimation(seat) } else { seat() }
        v.updateStyle(tint: m.selectionTint, onWallpaper: m.onWallpaper)
        v.refreshSelected(m.selected)
        v.alpha = 1
    }

    /// The slide, as a layer animation on top of a layout that is already final — their model
    /// exactly (`CABasicAnimation` on `transform.translation.x`, 0.2s, ease-in-ease-out).
    ///
    /// ⚠️ The circle travels FURTHER than the content: it starts fully outside the leading margin
    /// (`checkboxTravel`), while the content only moves by its own lane (`selectionShift`). Their
    /// two constants, `selectionOffset` and `hInnerStackOffset`, say the same thing.
    ///
    /// Leaving is `fillMode: .forwards` with `isRemovedOnCompletion = false`, so the circle STAYS
    /// parked off the edge when the animation ends instead of snapping back for one frame. The pass
    /// that follows removes the view outright, so nothing is left holding a stale animation.
    func animateSelectionSlide(entering: Bool) {
        guard let box = checkbox else { return }
        let travel = -MessageRowLayout.checkboxTravel
        let a = CABasicAnimation(keyPath: "transform.translation.x")
        a.duration = MessageRowLayout.selectionAnimationDuration
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        if entering {
            a.fromValue = travel
            a.toValue = 0
            box.layer.add(a, forKey: "insert")
        } else {
            a.fromValue = 0
            a.toValue = travel
            a.fillMode = .forwards
            a.isRemovedOnCompletion = false
            // ⛔ THE CIRCLE TAKES ITSELF AWAY WHEN IT HAS SLID OUT — owner, 2026-09-27, a screenshot of
            // six empty circles left after X. The forwards fill was the only thing hiding it until the
            // second pass rebuilt the row, and Core Animation drops such a fill whenever the layer
            // leaves its window (a pre-rendered cell, the app going to the background): the circle
            // then came back at its real place on any cell the second pass had not reached. Now the
            // slide's own completion removes it, unless the row has gone back into selection.
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self, weak box] in
                guard let self, let box, self.checkbox === box, self.model?.selecting != true else { return }
                box.layer.removeAllAnimations()
                box.removeFromSuperview()
                self.checkbox = nil
            }
            box.layer.add(a, forKey: "remove")
            CATransaction.commit()
        }
    }

    private func animateCorners(from old: (fill: UIBezierPath, rim: CGPath?), size: CGSize) {
        let dur: CFTimeInterval = 0.25
        let curve = CAMediaTimingFunction(name: .easeInEaseOut)
        fill.animateGeometry(fromPath: old.fill, fromSize: size, duration: dur, timing: curve)
        guard let rp = old.rim else { return }
        for l in [rim.shape, highlight.shape] {
            let a = CABasicAnimation(keyPath: "path")
            a.fromValue = rp
            a.duration = dur
            a.timingFunction = curve
            l.add(a, forKey: "corners.path")
        }
    }

    private func applyBubble(_ b: BubblePlan, model m: MessageRowModel, dark: Bool, cid: String) {
        // ⚠️ BOUNDS AND CENTER, NOT FRAME. The reply swipe puts a translation transform on this
        // view, and a view's `frame` is undefined while a transform is applied — writing it there
        // distorts the box. A repaint (a read tick arriving) can land mid-swipe, so this write has
        // to be safe against one; bounds and center stay meaningful and the translation keeps
        // riding on top of them.
        bubbleBox.bounds = CGRect(origin: .zero, size: b.bubble.size)
        bubbleBox.center = CGPoint(x: b.bubble.midX, y: b.bubble.midY)
        let local = CGRect(origin: .zero, size: b.bubble.size)
        // Continuous corners on every bubble — his 2026-09-16 ask. A capsule has no corners to
        // curve, so it is untouched.
        let path = b.isCapsule ? BubbleShape.capsulePath(b.bubble.size)
                               : BubbleShape.path(b.bubble.size, b.radii, continuous: true)
        fill.apply(b.fill, path: path, bounds: local)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rim.frame = local
        rim.shape.path = path.cgPath
        // The hairline rim is incoming-on-a-wallpaper only; an outgoing bubble never wears one.
        rim.shape.strokeColor = b.rim ? BubblePalette.rim(dark).cgColor : UIColor.clear.cgColor
        // The jump-to flash uses the bubble's OWN shape and cluster corners, so it covers exactly
        // the bubble with no generic-rounded-rect overhang.
        highlight.frame = local
        highlight.shape.path = path.cgPath
        // The jump flash is a one-shot animation on this view now (`performJumpHighlight`), not a
        // model state, so the resting fill is always clear (owner, 2026-10-08).
        highlight.shape.fillColor = UIColor.clear.cgColor
        bubbleDark = dark
        CATransaction.commit()
        bubbleBox.bringSubviewToFront(rim)
        bubbleBox.bringSubviewToFront(highlight)

        bodyLabel.attributedText = b.bodyAttr
        bodyLabel.frame = b.text
        metaLabel.attributedText = BubbleText.meta(metaChrome(m), isMe: isMe(m), color: b.metaColor,
                                                   solidTicks: b.mediaPlan?.metaCapsule != nil
                                                       || b.albumPlan?.metaCapsule != nil)
        // Theirs SPINS while a message is in flight (`isAnimated: true` on the sending indicator,
        // a full turn a second, repeating). A still clock reads as a stuck message.
        setSendingSpin(metaChrome(m).tick == .sending, over: b)
        setExpiryTimer(metaChrome(m).expiresAt, bornAt: metaChrome(m).bornAt, over: b)
        metaLabel.frame = b.meta
        metaLabel.isHidden = b.meta == .zero

        applyMedia(b, model: m, cid: cid)
        applyAlbum(b, model: m, cid: cid)
        applyFile(b, model: m, cid: cid)
        applyLocation(b, model: m, dark: dark)
        applyContact(b, model: m)
        applyPoll(b, model: m, cid: cid)
        applyLinkPreview(b, model: m, cid: cid)
        applyStoryReply(b, model: m, cid: cid)
        applyVoice(b, model: m, cid: cid)
        applyPill(b)
        applyTombstone(b)
        applyQuote(b, model: m, cid: cid)
        applySender(b, model: m)
        applyForwarded(b)
        applyReactions(b)
        applyFailBadge(b)
        applyShareButton(b, model: m)
    }

    /// ⛔ A SHARE BUTTON BESIDE EVERY CHANNEL POST (owner 2026-10-29, with the reference app's feed):
    /// a small round button off the bubble's bottom-right corner, in the gap a channel post leaves on
    /// its right (`MessageRowLayout`, `wide`). A tap opens Forward (`rowCellDidTapShare`). The cell's
    /// own tap routing hits it (`hitsShare`), so the view takes no touches itself.
    private func applyShareButton(_ b: BubblePlan, model m: MessageRowModel) {
        // Not on a post still sending (Forward would open on something not out yet), and not while
        // selecting, where the button sat under the selection tap (owner 2026-10-29 review fix).
        // `canSwipeToReply` is the builder's "sent" flag (sendState nil, not deleted).
        guard case .bubble(let row) = m.content, row.wide, !row.showsFailedBadge, row.canSwipeToReply,
              !m.selecting, !m.wasSelecting, b.bubble.width > 0 else {
            shareButton?.isHidden = true; shareRect = nil; return
        }
        let v = shareButton ?? {
            let v = UIView()
            v.isUserInteractionEnabled = false
            v.layer.cornerRadius = 16
            v.layer.cornerCurve = .circular
            v.backgroundColor = UIColor { $0.userInterfaceStyle == .dark
                ? UIColor(white: 1, alpha: 0.12) : UIColor(white: 0, alpha: 0.08) }
            let icon = UIImageView(image: UIImage(systemName: "arrowshape.turn.up.right.fill",
                                                  withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)))
            icon.tintColor = .label
            icon.contentMode = .center
            icon.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
            v.addSubview(icon)
            addSubview(v); shareButton = v; return v
        }()
        let r = CGRect(x: b.bubble.maxX + 8, y: b.bubble.maxY - 32, width: 32, height: 32)
        // ⛔ IN PLACE WHEN IT FIRST SHOWS (owner 2026-10-29: on a post just sent the button sat
        // inside the bubble, by the time). It appears when the send lands, inside the row's own
        // layout animation, so a new or hidden button flew in from its old frame (0,0 for a new
        // one). Only a button already showing moves with the bubble.
        if v.isHidden || v.frame == .zero {
            UIView.performWithoutAnimation { v.frame = r; v.alpha = 0 }
            v.isHidden = false
            UIView.animate(withDuration: 0.18) { v.alpha = 1 }
        } else {
            v.frame = r
        }
        shareRect = r
    }

    /// The share button's frame (row coordinates), nil when the row has none.
    func hitsShare(_ point: CGPoint) -> Bool {
        guard let r = shareRect, shareButton?.isHidden == false else { return false }
        return r.insetBy(dx: -6, dy: -6).contains(point)
    }

    private func applyMedia(_ b: BubblePlan, model m: MessageRowModel, cid: String) {
        guard let plan = b.mediaPlan,
              case .bubble(let row) = m.content,
              case .media(let media) = row.body else {
            mediaView?.isHidden = true
            mediaView?.prepareForReuse()
            return
        }
        let v = mediaView ?? {
            // BELOW the fill's siblings but above the fill itself: the picture is the bubble's
            // surface here, and the rim and the flash still have to sit over it.
            let v = MediaBubbleView(); bubbleBox.insertSubview(v, aboveSubview: fill); mediaView = v
            v.onLifted = { [weak self] lifted in self?.setMediaLifted(lifted) }
            return v
        }()
        v.isHidden = false
        v.frame = CGRect(origin: .zero, size: b.bubble.size)
        // ⛔ THE PICTURE IS CLIPPED BY THE BUBBLE'S OWN PATH, not by a corner radius. These bubbles
        // have four different radii (a cluster squares off the side that continues), so a rounded
        // rect mask would round the two corners the shape deliberately keeps sharp.
        v.layer.mask = bubbleMask(b)
        v.configure(media, plan: plan, cid: cid)

        registerFlightRects(b, model: m)
    }

    /// ⛔ PUBLISH EVERY FLIGHT RECT THIS ROW OWNS, IN WINDOW COORDINATES.
    ///
    /// Opening a photo flies the MEDIA out of its bubble and lands it back on the same rectangle.
    /// With nothing registered `MediaOpen` falls through to a plain presentation — the photo comes
    /// up from the BOTTOM of the screen instead of out of the message, which is exactly what he
    /// reported.
    ///
    /// ⚠️ THE KEY COMES FROM THE MODEL, NOT FROM THE ROW'S id. The row's id is `clientId ?? id`,
    /// which differs from the message id for every message this device sent — so deriving the key
    /// here registered the rect under one name while the tap looked it up under another. His own
    /// photos were the ones that opened wrong.
    ///
    /// ⚠️ AND IT IS CALLED AGAIN AT TAP TIME. A rect published when the cell was configured is
    /// stale the moment the list scrolls, and the registry's own note calls flying from a stale
    /// rect "the wrong area class of bug this registry exists to prevent".
    func registerFlightRects(_ b: BubblePlan, model m: MessageRowModel) {
        guard case .bubble(let row) = m.content else { return }
        switch row.body {
        case .media(let media):
            guard let v = mediaView, let plan = b.mediaPlan else { return }
            let rect = v.convert(plan.media, to: nil)
            guard rect.width > 1, rect.height > 1 else { return }
            // The radius handed over is the one this bubble ACTUALLY draws. The open used to leave
            // it at a 14pt default while the close read the real value, so media whose bubble had a
            // different radius started the flight at one shape and finished at another.
            MediaOpenRects.capture(media.flightKey, rect, cornerRadius: b.radii.topLeading)
        case .album(let album):
            guard let v = albumView, let plan = b.albumPlan else { return }
            for (i, tile) in plan.tiles.enumerated() where i < album.tiles.count {
                let inGrid = tile.rect.offsetBy(dx: plan.grid.minX, dy: plan.grid.minY)
                let rect = v.convert(inGrid, to: nil)
                guard rect.width > 1, rect.height > 1 else { continue }
                // A tile's corner is the GRID's, not the bubble's: only the outer tiles touch the
                // bubble's rounded edge and the inner ones are square.
                MediaOpenRects.capture(album.tiles[i].flightKey, rect, cornerRadius: 0)
            }
        default:
            break
        }
        if let sr = row.storyReply, sr.opens,
           let plan = b.storyReplyPlan, let thumb = plan.thumb {
            // In the scope `StoryDoor` reads — see `StoryReplyCardView.flightKey`. The card also
            // registers its live view; this keeps the rectangle current on a tap after a scroll.
            let rect = convert(thumb, to: nil)
            if rect.width > 1 {
                MediaOpenRects.capture(MediaOpenRects.key(.storyRow, sr.anchorKey), rect, cornerRadius: 14)
            }
        }
    }

    private func applyAlbum(_ b: BubblePlan, model m: MessageRowModel, cid: String) {
        guard let plan = b.albumPlan,
              case .bubble(let row) = m.content, case .album(let a) = row.body else {
            albumView?.isHidden = true
            albumView?.prepareForReuse()
            return
        }
        let v = albumView ?? {
            let v = AlbumBubbleView(); bubbleBox.insertSubview(v, aboveSubview: fill); albumView = v; return v
        }()
        v.isHidden = false
        v.frame = CGRect(origin: .zero, size: b.bubble.size)
        v.layer.mask = bubbleMask(b)
        v.configure(a, plan: plan, cid: cid)
    }

    private func applyFile(_ b: BubblePlan, model m: MessageRowModel, cid: String) {
        guard let plan = b.filePlan,
              case .bubble(let row) = m.content, case .file(let f) = row.body else {
            fileView?.isHidden = true
            fileView?.prepareForReuse()
            return
        }
        let v = fileView ?? {
            let v = FileBubbleView(); bubbleBox.insertSubview(v, aboveSubview: fill); fileView = v; return v
        }()
        v.isHidden = false
        v.frame = CGRect(origin: .zero, size: b.bubble.size)
        v.configure(f, plan: plan, tint: b.textColor, cid: cid)
    }

    private func applyLocation(_ b: BubblePlan, model m: MessageRowModel, dark: Bool) {
        guard let plan = b.locationPlan,
              case .bubble(let row) = m.content, case .location(let l) = row.body else {
            locationView?.isHidden = true
            locationView?.prepareForReuse()
            return
        }
        let v = locationView ?? {
            let v = LocationBubbleView(); bubbleBox.insertSubview(v, aboveSubview: fill); locationView = v; return v
        }()
        v.isHidden = false
        v.frame = CGRect(origin: .zero, size: b.bubble.size)
        v.layer.mask = bubbleMask(b)      // the map is flush to the corners, so it wears them
        v.configure(l, plan: plan, tint: b.textColor, dark: dark)
    }

    private func applyContact(_ b: BubblePlan, model m: MessageRowModel) {
        guard let plan = b.contactPlan,
              case .bubble(let row) = m.content, case .contact(let c) = row.body else {
            contactView?.isHidden = true
            return
        }
        let v = contactView ?? {
            let v = ContactBubbleView(); bubbleBox.insertSubview(v, aboveSubview: fill); contactView = v; return v
        }()
        v.isHidden = false
        v.frame = CGRect(origin: .zero, size: b.bubble.size)
        v.configure(c, plan: plan, tint: b.textColor)
    }

    private func applyPoll(_ b: BubblePlan, model m: MessageRowModel, cid: String) {
        guard let plan = b.pollPlan,
              case .bubble(let row) = m.content, case .poll(let p) = row.body else {
            pollView?.isHidden = true
            pollView?.prepareForReuse()
            return
        }
        let v = pollView ?? {
            let v = PollBubbleView(); bubbleBox.insertSubview(v, aboveSubview: fill); pollView = v; return v
        }()
        v.isHidden = false
        v.frame = CGRect(origin: .zero, size: b.bubble.size)
        v.configure(p, plan: plan, tint: b.textColor, cid: cid)
    }

    /// Which poll option is under this point, for the tap that casts a vote.
    func pollOptionIndex(at point: CGPoint) -> Int? {
        guard let p = plan, case .bubble(let b) = p.body, b.pollPlan != nil else { return nil }
        let local = CGPoint(x: point.x - b.bubble.minX, y: point.y - b.bubble.minY)
        return pollView?.optionIndex(at: local)
    }

    func castPollVote(option i: Int) { pollView?.castVote(option: i) }

    /// The poll's footer, which opens the results page (2026-10-19).
    func hitsPollResults(_ point: CGPoint) -> Bool {
        guard let p = plan, case .bubble(let b) = p.body, b.pollPlan != nil, let v = pollView else { return false }
        return v.hitsResults(CGPoint(x: point.x - b.bubble.minX, y: point.y - b.bubble.minY))
    }

    /// Set by the cell, so the disc's tap can reach ThreadView — `VoiceNotePlayer.toggle` needs a
    /// whole `Message` and only ThreadView has one.
    var onVoicePlayToggle: (() -> Void)? {
        didSet { voiceView?.onPlayToggle = { [weak self] in self?.onVoicePlayToggle?() } }
    }

    private func applyPill(_ b: BubblePlan) {
        guard let plan = b.pillPlan else {
            pillView?.isHidden = true
            pillView?.prepareForReuse()
            return
        }
        let v = pillView ?? {
            let x = PillBubbleView(); bubbleBox.insertSubview(x, aboveSubview: fill); pillView = x; return x
        }()
        v.isHidden = false
        v.frame = CGRect(origin: .zero, size: b.bubble.size)
        v.configure(plan, tint: b.textColor)
    }

    /// The pill — a view-once photo or voice note opens on tap.
    func hitsPill(_ point: CGPoint) -> Bool {
        guard let p = plan, case .bubble(let b) = p.body, b.pillPlan != nil else { return false }
        return b.bubble.contains(point)
    }

    private func applyVoice(_ b: BubblePlan, model m: MessageRowModel, cid: String) {
        guard let plan = b.voicePlan,
              case .bubble(let row) = m.content, case .voice(let v) = row.body else {
            voiceView?.isHidden = true
            voiceView?.prepareForReuse()
            return
        }
        let v2 = voiceView ?? {
            let x = VoiceBubbleView(); bubbleBox.insertSubview(x, aboveSubview: fill); voiceView = x; return x
        }()
        v2.isHidden = false
        v2.frame = CGRect(origin: .zero, size: b.bubble.size)
        v2.onPlayToggle = { [weak self] in self?.onVoicePlayToggle?() }
        // The row already resolved what paints behind this bubble; the disc only needs to know
        // whether that is a blurred wallpaper surface — EITHER recipe — so it can be a blur too.
        // ⚠️ `isWallpaperBlur`, never `== .material`: that exact comparison is what made the disc
        // fall back to a flat colour the day the slice was restored. See the note on the helper.
        v2.configure(v, plan: plan, tint: b.textColor,
                     onMaterial: row.fill.isWallpaperBlur, cid: cid)
    }

    private func applyLinkPreview(_ b: BubblePlan, model m: MessageRowModel, cid: String) {
        guard let plan = b.linkPlan,
              case .bubble(let row) = m.content, case .text(let t) = row.body,
              let card = t.linkPreview else {
            linkView?.isHidden = true
            linkView?.prepareForReuse()
            return
        }
        let v = linkView ?? {
            let v = LinkPreviewBubbleView(); bubbleBox.insertSubview(v, aboveSubview: fill); linkView = v; return v
        }()
        v.isHidden = false
        v.frame = CGRect(origin: .zero, size: b.bubble.size)
        v.configure(card, plan: plan, tint: b.textColor, cid: cid, rowId: m.id)
    }

    private func applyStoryReply(_ b: BubblePlan, model m: MessageRowModel, cid: String) {
        guard let plan = b.storyReplyPlan,
              case .bubble(let row) = m.content, let sr = row.storyReply else {
            storyReplyView?.isHidden = true
            storyReplyView?.prepareForReuse()
            return
        }
        let v = storyReplyView ?? {
            // UNDER the bubble, not over it (owner 2026-10-13: the react-bar emoji went under the
            // story picture). The card and the bubble only overlap for a story reaction, whose
            // emoji sits on the card's corner and has to be drawn on top of it.
            let v = StoryReplyCardView(); insertSubview(v, belowSubview: bubbleBox); storyReplyView = v; return v
        }()
        v.isHidden = false
        v.frame = bounds
        v.configure(sr, plan: plan, cid: cid)

    }

    /// Re-publish this row's flight rects from their CURRENT positions. Called on the tap that is
    /// about to open something, because a rect published at configure time is stale after a scroll.
    func refreshFlightRects() {
        guard let m = model, let p = plan, case .bubble(let b) = p.body else { return }
        registerFlightRects(b, model: m)
    }

    /// The story-reply card — tapping it opens the story.
    func hitsStoryReply(_ point: CGPoint) -> Bool {
        guard let p = plan, case .bubble(let b) = p.body, let sr = b.storyReplyPlan else { return false }
        guard let thumb = sr.thumb else { return false }
        return thumb.contains(point)
    }

    /// The OG card — tapping it opens the link (or the person, on a profile card's button).
    /// The link card's press tint (`LinkPreviewBubbleView.setPressed`), for the cell's touches.
    func setLinkCardPressed(_ on: Bool) { linkView?.setPressed(on) }

    func hitsLinkCard(_ point: CGPoint) -> Bool {
        guard let p = plan, case .bubble(let b) = p.body, let l = b.linkPlan else { return false }
        return l.card.offsetBy(dx: b.bubble.minX, dy: b.bubble.minY).contains(point)
    }

    /// A call card's "Join Call" button. Its rect is already in bubble coordinates.
    func hitsCallJoin(_ point: CGPoint) -> Bool {
        guard let p = plan, case .bubble(let b) = p.body,
              let l = b.linkPlan, let join = l.join else { return false }
        return join.offsetBy(dx: b.bubble.minX, dy: b.bubble.minY).contains(point)
    }

    func hitsLinkButton(_ point: CGPoint) -> Bool {
        guard let p = plan, case .bubble(let b) = p.body,
              let l = b.linkPlan, let button = l.button else { return false }
        return button.offsetBy(dx: b.bubble.minX + l.card.minX, dy: b.bubble.minY + l.card.minY)
            .contains(point)
    }

    /// The bubble's own outline as a mask. These bubbles carry four different radii (a cluster
    /// squares off the side that continues), so a corner RADIUS would round the two corners the
    /// shape deliberately keeps sharp.
    private func bubbleMask(_ b: BubblePlan) -> CAShapeLayer {
        let mask = CAShapeLayer()
        // ⚠️ THE SAME SHAPE AS THE FILL ABOVE, and it has to stay that way: this masks the rim, so
        // a mismatch draws a stroke that does not follow the bubble it belongs to.
        mask.path = (b.isCapsule ? BubbleShape.capsulePath(b.bubble.size)
                                 : BubbleShape.path(b.bubble.size, b.radii, continuous: true)).cgPath
        return mask
    }

    private func applyTombstone(_ b: BubblePlan) {
        guard let rect = b.tombstoneIcon else { tombstoneIcon?.isHidden = true; return }
        let v = tombstoneIcon ?? {
            let v = UIImageView(image: UIImage(systemName: "nosign",
                                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 12)))
            v.contentMode = .center
            bubbleBox.addSubview(v); tombstoneIcon = v; return v
        }()
        v.isHidden = false
        v.frame = rect
        v.tintColor = b.textColor.withAlphaComponent(0.65)
    }

    private func applyQuote(_ b: BubblePlan, model m: MessageRowModel, cid: String) {
        guard let rect = b.quote, let inner = b.quoteInner,
              case .bubble(let row) = m.content, let q = row.quote else {
            quoteView?.isHidden = true
            return
        }
        let v = quoteView ?? {
            let v = BubbleQuoteView(); bubbleBox.insertSubview(v, aboveSubview: fill); quoteView = v; return v
        }()
        v.isHidden = false
        v.frame = rect
        v.configure(q, plan: inner, textColor: b.textColor, cid: cid)
        v.apply(inner)
    }

    /// How far the sender's photo is away from its planned place (see
    /// `MessageListController.pinRunAvatars`); 0 = where the plan put it.
    private(set) var avatarLift: CGFloat = 0
    /// The group sender of this bubble, for the run's photo; nil = not someone else's group bubble.
    private var runSender: SenderChrome?
    private var runPhotoKey: String?

    /// This row's part of a run of one person's messages: who, whether it opens / closes the run,
    /// and the span the run's photo may use here (bubble top to the planned photo's bottom).
    var runSlot: (uid: String, first: Bool, last: Bool, top: CGFloat, bottom: CGFloat)? {
        guard let s = runSender, let p = plan, case .bubble(let b) = p.body else { return nil }
        return (s.uid, s.startsRun, s.showsAvatar, b.bubble.minY, b.avatar?.maxY ?? b.bubble.maxY)
    }

    /// The run's photo with its top at `minY` (this view's coordinates), or nil = this row does
    /// not carry it. Placed by bounds and center, so a reply-swipe transform on it is left alone.
    func placeRunAvatar(minY: CGFloat?) {
        guard let s = runSender, let p = plan, case .bubble(let b) = p.body else { return }
        guard let y = minY else { avatarView?.isHidden = true; avatarLift = 0; return }
        let size = BubbleMetrics.avatarSize
        let x = b.avatar?.minX ?? (b.bubble.minX - BubbleMetrics.avatarGap - size)
        let v = avatarView ?? {
            let v = RowAvatarView(); addSubview(v); avatarView = v; return v
        }()
        let key = s.uid + "|" + (s.avatarUrl ?? "")
        if runPhotoKey != key { runPhotoKey = key; v.configure(name: s.name, photoUrl: s.avatarUrl) }
        v.isHidden = false
        v.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        let mid = CGPoint(x: x + size / 2, y: y + size / 2)
        if abs(v.center.y - mid.y) > 0.25 || abs(v.center.x - mid.x) > 0.25 { v.center = mid }
        avatarLift = b.avatar.map { $0.minY - y } ?? 1
    }

    private func applySender(_ b: BubblePlan, model m: MessageRowModel) {
        if case .bubble(let row) = m.content { runSender = row.sender } else { runSender = nil }
        runPhotoKey = nil
        if let rect = b.avatar, case .bubble(let row) = m.content, let s = row.sender {
            let v = avatarView ?? {
                let v = RowAvatarView(); addSubview(v); avatarView = v; return v
            }()
            v.isHidden = false
            v.frame = rect
            avatarLift = 0   // back at the planned place; the list re-pins it (pinRunAvatars)
            v.configure(name: s.name, photoUrl: s.avatarUrl)
            runPhotoKey = s.uid + "|" + (s.avatarUrl ?? "")
        } else {
            avatarView?.isHidden = true
        }

        if let rect = b.senderName, let attr = b.senderNameAttr {
            let v = senderLabel ?? {
                let v = UILabel(); addSubview(v); senderLabel = v; return v
            }()
            v.isHidden = false
            v.attributedText = attr
            v.frame = rect
        } else {
            senderLabel?.isHidden = true
        }

        if let rect = b.verifiedMark {
            let v = verifiedView ?? {
                // PALETTE, not a tint: the mark is a WHITE check on a blue seal. A monochrome
                // `checkmark.seal.fill` in the same blue is a different glyph — the check goes
                // blue-on-blue and disappears.
                let v = UIImageView()
                v.contentMode = .scaleAspectFit
                addSubview(v); verifiedView = v; return v
            }()
            // The shared weight (`VerifiedMark`, owner 2026-10-13), 11pt beside a name, and the
            // sender's own colour: gold for a company's verification, blue for everyone else.
            var uid = ""
            if case .bubble(let row) = m.content, let s = row.sender { uid = s.uid }
            let cfg = UIImage.SymbolConfiguration(pointSize: BubbleMetrics.verifiedSide, weight: VerifiedMark.weight)
                .applying(UIImage.SymbolConfiguration(paletteColors: [.white, VerifiedMark.color(for: uid)]))
            v.image = UIImage(systemName: "checkmark.seal.fill", withConfiguration: cfg)
            v.isHidden = false
            v.frame = rect
        } else {
            verifiedView?.isHidden = true
        }

        // owner 2026-10-18 ROLE: the chip after the name. The capsule is this view's own layer
        // (the label inset inside it), so it truncates with a tail like the name does.
        if let rect = b.roleChip, let attr = b.roleAttr {
            let chip = roleChipView ?? {
                let c = UIView()
                c.isUserInteractionEnabled = false
                let l = UILabel()
                l.tag = 1
                c.addSubview(l)
                addSubview(c); roleChipView = c; return c
            }()
            chip.isHidden = false
            chip.frame = rect
            chip.backgroundColor = b.roleTint
            chip.layer.cornerRadius = rect.height / 2
            chip.layer.cornerCurve = .circular
            if let l = chip.viewWithTag(1) as? UILabel {
                l.attributedText = attr
                l.lineBreakMode = .byTruncatingTail
                l.frame = rect.size.width > BubbleMetrics.roleHPad * 2
                    ? CGRect(x: BubbleMetrics.roleHPad, y: 0,
                             width: rect.width - BubbleMetrics.roleHPad * 2, height: rect.height)
                    : .zero
            }
        } else {
            roleChipView?.isHidden = true
        }
    }

    private func applyForwarded(_ b: BubblePlan) {
        guard let rect = b.forwarded, let iconRect = b.forwardedIcon else {
            forwardedLabel?.isHidden = true; forwardedIcon?.isHidden = true; return
        }
        let label = forwardedLabel ?? {
            let v = UILabel(); addSubview(v); forwardedLabel = v; return v
        }()
        let icon = forwardedIcon ?? {
            let v = UIImageView(image: UIImage(systemName: "arrowshape.turn.up.right.fill",
                                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 9)))
            v.contentMode = .center
            addSubview(v); forwardedIcon = v; return v
        }()
        label.isHidden = false; icon.isHidden = false
        label.attributedText = NSAttributedString(string: "Forwarded", attributes: [
            .font: BubbleMetrics.forwardedFont, .foregroundColor: UIColor.secondaryLabel])
        label.frame = rect
        icon.tintColor = .secondaryLabel
        icon.frame = iconRect
    }

    private func applyReactions(_ b: BubblePlan) {
        // Each chip view keeps the emoji it showed, so a reaction added before an existing one does
        // not hand that existing chip's view to the newcomer (which would animate the wrong pill).
        if let keys = Self.reactionKeys(model), keys.count == b.reactions.count {
            var byKey: [String: ReactionChipView] = [:]
            for (k, v) in zip(chipKeys, reactionViews) where !k.isEmpty { byKey[k] = v }
            var spare = zip(chipKeys, reactionViews).filter { !keys.contains($0.0) }.map { $0.1 }
            var ordered: [ReactionChipView] = []
            for k in keys {
                if let v = byKey[k] { ordered.append(v); continue }
                if let v = spare.popLast() { ordered.append(v); continue }
                let v = ReactionChipView(); bubbleBox.addSubview(v); ordered.append(v)
            }
            reactionViews = ordered + spare
            chipKeys = keys + Array(repeating: "", count: spare.count)
        }
        while reactionViews.count < b.reactions.count {
            let v = ReactionChipView()
            bubbleBox.addSubview(v)
            reactionViews.append(v)
            chipKeys.append("")
        }
        if Self.reactionKeys(model)?.count != b.reactions.count {
            chipKeys = Array(repeating: "", count: reactionViews.count)   // identity unknown this time
        }
        for (i, v) in reactionViews.enumerated() {
            guard i < b.reactions.count else { v.isHidden = true; continue }
            v.isHidden = false
            // Row coordinates → the bubble box's coordinates, because the chips are its subviews so
            // that they ride the reply swipe with it.
            v.frame = b.reactions[i].offsetBy(dx: -b.bubble.minX, dy: -b.bubble.minY)
            v.configure(b.reactionAttrs[i], mine: b.reactionMine[i],
                        onMyBubble: b.reactionsOnMyBubble,
                        faces: i < b.reactionFaces.count ? b.reactionFaces[i] : [],
                        freeform: b.reactionsFreeform)
            // Half of a picture's pill lies ON the picture, and the picture view can be created after
            // the pill in a recycled cell, which would draw it over the pill's top half.
            bubbleBox.bringSubviewToFront(v)
        }
    }

    // MARK: - A reaction arriving or leaving
    //
    // ⛔ THE REFERENCE APP'S MOTION AND NUMBERS — owner, 2026-09-27: "copy the animation when I
    // react: the badge effect and the bubble animation, its maths and logic". Read from its source
    // (behaviour and numbers only; nothing of its code is here):
    //   · every change runs 0.4s on its list curve, a cubic bezier (0.38, 0.70, 0.125, 1.00): quick
    //     start, long soft landing, no overshoot;
    //   · a NEW pill scales 0.01 → 1 on that curve while fading 0 → 1 in 0.2s ease-in-out;
    //   · pills already there slide to their new places on the same 0.4s;
    //   · a REMOVED pill scales to 0.01 and fades out in 0.2s ease-in-out, then goes;
    //   · the bubble grows or shrinks on the 0.4s curve. Their list is upside down, so a message at
    //     the bottom keeps its bottom edge and grows UP, pushing the conversation above it up.
    // The list lands its final layout in one pass as always (see `refreshVisible`); everything here
    // is a layer animation FROM where things were, so no frame the list relies on is ever mid-flight.

    static let reactionDuration: CFTimeInterval = 0.4
    static let reactionCurve = CAMediaTimingFunction(controlPoints: 0.38, 0.7, 0.125, 1.0)
    /// Handed in by the list through the cell before each configure: true when a row that grows
    /// keeps its bottom edge still (a reader at the newest message), false when it grows down from a
    /// fixed top. Per row, not static: two chat screens alive during a push or pop each own theirs.
    /// Used by ONE apply and then put back to false (chat #39), so it must be handed in every time.
    var growsFromBottom = false

    /// The emoji shown by each entry of `reactionViews`, "" when unknown.
    private var chipKeys: [String] = []
    /// How much this row's bubble grew in its last reaction animation; the list reads it once to
    /// move the rest of the conversation with it (see `takeReactionGrowth`).
    private var pendingGrowth: CGFloat = 0
    func takeReactionGrowth() -> CGFloat { defer { pendingGrowth = 0 }; return pendingGrowth }
    /// Snapshots of leaving pills still fading out, so a recycle can take them away (chat #78).
    private var leavingSnaps: [UIView] = []

    /// Every reaction animation on this row's layers, at any depth: the bubble's own ("reaction.*"),
    /// the fill's shape and masks ("reactionGrow.*"), the chips, the body, and the date pill, divider
    /// and sender name above the box. Only those keys, so nothing else running here is touched.
    private static func dropReactionAnimations(_ l: CALayer) {
        for k in l.animationKeys() ?? [] where k.hasPrefix("reaction") { l.removeAnimation(forKey: k) }
        l.sublayers?.forEach(dropReactionAnimations)
    }

    private struct ReactionBefore {
        var bubble: CGRect
        var rowHeight: CGFloat
        var fillPath: UIBezierPath
        var rimPath: CGPath?
        var frames: [ObjectIdentifier: CGRect]      // bubble-box children, by view
        var chipFrames: [String: CGRect]            // surviving pills, by emoji
        var leaving: [(UIView, CGRect)]             // snapshots of pills about to go
        var arriving: Set<String>
        var mineBefore: Set<String>                 // the pills that were already mine
    }

    private static func reactionKeys(_ m: MessageRowModel?) -> [String]? {
        guard let m, case .bubble(let row) = m.content else { return nil }
        return row.reactions.map(\.emoji)
    }

    private static func reactionChips(_ m: MessageRowModel?) -> [ReactionChip]? {
        guard let m, case .bubble(let row) = m.content else { return nil }
        return row.reactions
    }

    /// ⛔ WHERE A VIEW IS DRAWN, NOT WHERE IT WILL END. Owner, 2026-10-25: a group reaction grew,
    /// shrank and grew again. A second pass can land while the first growth is still running (the
    /// listener's echo, a face resolving, a second tap), and capturing the MODEL frame there meant
    /// the new animation started from the previous animation's end: everything jumped there, then
    /// eased back. The reference app starts every transition from the current presented value.
    /// Bounds and position, never `frame`, so a pill's arrival scale or a swipe's translation is
    /// not read as a size.
    private static func drawnFrame(_ v: UIView) -> CGRect {
        guard let keys = v.layer.animationKeys(), keys.contains(where: { $0.hasPrefix("reaction") }),
              let p = v.layer.presentation() else { return v.frame }
        let s = p.bounds.size, c = p.position
        return CGRect(x: c.x - s.width * v.layer.anchorPoint.x, y: c.y - s.height * v.layer.anchorPoint.y,
                      width: s.width, height: s.height)
    }

    private func captureBefore(_ ob: BubblePlan, oldKeys: [String], newKeys: [String]) -> ReactionBefore {
        var frames: [ObjectIdentifier: CGRect] = [:]
        let chipSet = Set(reactionViews.map(ObjectIdentifier.init))
        for v in bubbleBox.subviews where !v.isHidden && !chipSet.contains(ObjectIdentifier(v)) {
            frames[ObjectIdentifier(v)] = Self.drawnFrame(v)
        }
        var chipFrames: [String: CGRect] = [:]
        var leaving: [(UIView, CGRect)] = []
        for (k, v) in zip(chipKeys, reactionViews) where !k.isEmpty && !v.isHidden {
            if newKeys.contains(k) {
                chipFrames[k] = Self.drawnFrame(v)
            } else if let snap = v.snapshotView(afterScreenUpdates: false) {
                leaving.append((snap, v.frame))
            }
        }
        // The bubble and its outline as drawn: mid-growth, the in-flight shape (see `drawnFrame`).
        let midFlight = bubbleBox.layer.animation(forKey: "reaction.bounds.size") != nil
        let shownBubble = midFlight ? Self.drawnFrame(bubbleBox) : ob.bubble
        let rimPath: CGPath? = rim.shape.animation(forKey: "reaction.path") != nil
            ? (rim.shape.presentation()?.path ?? rim.shape.path) : rim.shape.path
        return ReactionBefore(bubble: shownBubble, rowHeight: plan?.height ?? 0,
                              fillPath: fill.shownPath, rimPath: rimPath,
                              frames: frames, chipFrames: chipFrames, leaving: leaving,
                              arriving: Set(newKeys).subtracting(oldKeys),
                              mineBefore: Set((Self.reactionChips(model) ?? []).filter(\.mine).map(\.emoji)))
    }

    private func animateReactionChange(from old: ReactionBefore, to nb: BubblePlan) {
        let dur = Self.reactionDuration, curve = Self.reactionCurve
        func add(_ layer: CALayer, _ key: String, _ from: Any, duration: CFTimeInterval = dur,
                 timing: CAMediaTimingFunction = curve) {
            let a = CABasicAnimation(keyPath: key)
            a.fromValue = from
            a.duration = duration
            a.timingFunction = timing
            layer.add(a, forKey: "reaction.\(key)")
        }
        func move(_ v: UIView, from f: CGRect) {
            guard f != v.frame else { return }
            add(v.layer, "bounds.size", NSValue(cgSize: f.size))
            add(v.layer, "position", NSValue(cgPoint: CGPoint(x: f.midX, y: f.midY)))
        }
        // ⛔ THE ROW'S GROWTH, NOT THE BUBBLE'S — owner, 2026-09-27, a photo reacted to: "the other
        // messages flash for a second". The list moves its neighbours by how much the whole ROW changed.
        // On a text message that equals the bubble's change; on a photo or GIF the pill hangs below
        // the picture, the row grows by the overhang and the bubble box by nothing at all, so this
        // used to report zero and the neighbours the list had already moved got no animation back —
        // they snapped. The row's height is the number the list actually moved everything by.
        let grow = (plan?.height ?? old.rowHeight) - old.rowHeight
        // Where the old bubble sat in THIS pass's coordinates. The list moved the row by the row's
        // growth when it kept the bottom still, so everything in it is that much lower here.
        let oldRect = growsFromBottom ? old.bubble.offsetBy(dx: 0, dy: grow) : old.bubble
        if oldRect != nb.bubble {
            add(bubbleBox.layer, "bounds.size", NSValue(cgSize: oldRect.size))
            add(bubbleBox.layer, "position", NSValue(cgPoint: CGPoint(x: oldRect.midX, y: oldRect.midY)))
            let oldLocal = CGRect(origin: .zero, size: old.bubble.size)
            move(fill, from: oldLocal)
            fill.animateGeometry(fromPath: old.fillPath, fromSize: old.bubble.size, duration: dur, timing: curve)
            if let rp = old.rimPath {
                move(rim, from: oldLocal); add(rim.shape, "path", rp)
                move(highlight, from: oldLocal); add(highlight.shape, "path", rp)
            }
        }
        // ⛔ AND THE ROW'S OWN CHROME ABOVE THE BUBBLE — owner, 2026-09-27, a frame of his recording:
        // the date pill over this row sat ON the bubble mid-animation. When the bubble grows from its
        // bottom, the list has moved this whole row by `grow`, so the date pill, divider and sender
        // name above the box jumped at once while the box was still easing from its old top. They
        // ride the same curve from where they were.
        //
        // ⛔ AND THE NAME INSIDE THE BUBBLE'S TOP. Owner, 2026-10-25, a frozen frame of a group
        // reaction: the sender's name already above and outside the bubble, an empty gap where it had
        // been. The name, mark, role tag and forwarded line live on the ROW, not in `bubbleBox`
        // (`liftOverlays`), and they sit inside the bubble's top, so the old "above the box" test
        // never picked them: they took their final place at once while the box eased. They move with
        // the bubble's TOP edge, the sender's photo with its BOTTOM edge, all on the box's own curve,
        // the way the reference app moves its name node inside the bubble's one transition.
        let topDY = oldRect.minY - nb.bubble.minY, bottomDY = oldRect.maxY - nb.bubble.maxY
        let riders = liftOverlays
        for v in subviews where v !== bubbleBox && !v.isHidden {
            let dy: CGFloat
            if riders.contains(where: { $0 === v }) || v.frame.maxY <= nb.bubble.minY + 1 {
                dy = topDY
            } else if v === avatarView {
                dy = bottomDY
            } else {
                continue
            }
            if abs(dy) > 0.5 { add(v.layer, "transform.translation.y", dy) }
        }
        // Everything else in the bubble (text, time, ticks, media) glides from where it was.
        for v in bubbleBox.subviews where !v.isHidden {
            if let f = old.frames[ObjectIdentifier(v)], v !== fill, v !== rim, v !== highlight { move(v, from: f) }
        }
        // How far the bubble box starts from where it ends (its top-left, in row coordinates). A new
        // pill is a subview of the box, so it would ride that slide and start `grow` too low: owner,
        // 2026-09-27, a new heart drawn over the message below. It is held at its final place instead.
        let boxDX = oldRect.minX - nb.bubble.minX, boxDY = oldRect.minY - nb.bubble.minY
        for (k, v) in zip(chipKeys, reactionViews) where !v.isHidden && !k.isEmpty {
            if old.arriving.contains(k) {
                add(v.layer, "transform.scale", 0.01)
                add(v.layer, "opacity", 0, duration: 0.2, timing: CAMediaTimingFunction(name: .easeInEaseOut))
                if abs(boxDY) > 0.5 { add(v.layer, "transform.translation.y", -boxDY) }
                if abs(boxDX) > 0.5 { add(v.layer, "transform.translation.x", -boxDX) }
            } else if let f = old.chipFrames[k] {
                move(v, from: f)
            }
        }
        for (snap, f) in old.leaving {
            snap.frame = f
            bubbleBox.addSubview(snap)
            leavingSnaps.append(snap)
            UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseInOut]) {
                snap.transform = CGAffineTransform(scaleX: 0.01, y: 0.01)
                snap.alpha = 0
            } completion: { [weak self] _ in
                snap.removeFromSuperview()
                self?.leavingSnaps.removeAll { $0 === snap }
            }
        }
        playMyReactionFlair(old)
        pendingGrowth = grow
    }

    // MARK: - My own reaction landing (owner 2026-10-29: "our own animation, not copied")
    //
    // Ours, on top of the pill motion above, and ONLY for a pick I just made (a pill that was not
    // mine and now is): other people's reactions arriving stay quiet. "Drop and ripple":
    //   - the emoji flies from where I picked it (the bar's emoji, or my double-tap point) along a
    //     short arc into its pill (`ReactionFlight`); with no recorded origin there is no flight;
    //   - the pill lands with a small overshoot (1, 1.22, 0.94, 1), after the flight if any;
    //   - one thin ring spreads from the pill and fades, and three dots in the emoji's own colour
    //     drift up and out. Drawn here with Core Animation; no artwork, nothing borrowed.
    // Reduce Motion skips all of it (no `before` is captured then).

    /// Ripple, dots and flying emoji still on screen, so a recycle can take them away.
    private var fxLayers: [CALayer] = []
    private var fxViews: [UIView] = []

    private func playMyReactionFlair(_ old: ReactionBefore) {
        guard window != nil, ReactionFlight.recentLocal, let chips = Self.reactionChips(model) else { return }
        for chip in chips where chip.mine && !chip.isAdd && !old.mineBefore.contains(chip.emoji) {
            guard let j = chipKeys.firstIndex(of: chip.emoji), j < reactionViews.count else { continue }
            let v = reactionViews[j]
            guard !v.isHidden else { continue }
            var delay: CFTimeInterval = 0
            if let from = ReactionFlight.take(chip.emoji), flyIn(chip.emoji, from: from, to: v) {
                delay = ReactionFlight.duration
            }
            popPill(v, arriving: old.arriving.contains(chip.emoji), delay: delay)
            ripple(around: v, emoji: chip.emoji, delay: delay)
            break   // one pick per person per message
        }
    }

    private func popPill(_ v: UIView, arriving: Bool, delay: CFTimeInterval) {
        let begin = CACurrentMediaTime() + delay
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [arriving ? 0.01 : 1.0, 1.22, 0.94, 1.0]
        pop.keyTimes = [0, 0.45, 0.75, 1]
        pop.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut),
                               CAMediaTimingFunction(name: .easeInEaseOut)]
        pop.duration = 0.45
        pop.beginTime = begin
        pop.fillMode = .backwards
        // Same key as the arrival scale above, so it REPLACES it rather than fighting it.
        v.layer.add(pop, forKey: "reaction.transform.scale")
        if arriving && delay > 0 {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.12
            fade.beginTime = begin
            fade.fillMode = .backwards
            v.layer.add(fade, forKey: "reaction.opacity")
        }
    }

    private func ripple(around v: UIView, emoji: String, delay: CFTimeInterval) {
        let center = v.convert(CGPoint(x: v.bounds.midX, y: v.bounds.midY), to: self)
        let begin = CACurrentMediaTime() + delay + 0.08
        let tint = Self.flairColor(emoji)

        let ring = CAShapeLayer()
        ring.bounds = v.bounds
        ring.position = center
        ring.path = UIBezierPath(roundedRect: v.bounds, cornerRadius: v.bounds.height / 2).cgPath
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = BubblePalette.accent.cgColor
        ring.lineWidth = 1.5
        ring.opacity = 0
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = 1.55
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.7
        fade.toValue = 0
        let thin = CABasicAnimation(keyPath: "lineWidth")
        thin.fromValue = 2
        thin.toValue = 0.5
        let ringGroup = CAAnimationGroup()
        ringGroup.animations = [grow, fade, thin]
        ringGroup.duration = 0.5
        ringGroup.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ringGroup.beginTime = begin
        addFX(ring, ringGroup, life: delay + 0.65)

        // Three dots, up and out, spread over the top half so they never fall into the message below.
        let angles: [CGFloat] = [-150, -95, -35].map { ($0 + CGFloat.random(in: -12...12)) * .pi / 180 }
        for a in angles {
            let d: CGFloat = 4
            let dot = CALayer()
            dot.bounds = CGRect(x: 0, y: 0, width: d, height: d)
            dot.cornerRadius = d / 2
            dot.backgroundColor = tint.cgColor
            dot.opacity = 0
            let start = CGPoint(x: center.x + cos(a) * v.bounds.width * 0.35,
                                y: center.y + sin(a) * v.bounds.height * 0.4)
            let end = CGPoint(x: center.x + cos(a) * (v.bounds.width / 2 + CGFloat.random(in: 10...18)),
                              y: center.y + sin(a) * (v.bounds.height / 2 + 14))
            dot.position = start
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = NSValue(cgPoint: start)
            move.toValue = NSValue(cgPoint: end)
            let shrink = CABasicAnimation(keyPath: "transform.scale")
            shrink.fromValue = 1.2
            shrink.toValue = 0.3
            let show = CAKeyframeAnimation(keyPath: "opacity")
            show.values = [0, 1, 1, 0]
            show.keyTimes = [0, 0.15, 0.6, 1]
            let g = CAAnimationGroup()
            g.animations = [move, shrink, show]
            g.duration = 0.55
            g.timingFunction = CAMediaTimingFunction(name: .easeOut)
            g.beginTime = begin
            addFX(dot, g, life: delay + 0.7)
        }
    }

    /// A short-lived effect layer on the row (not the bubble box: the ring spreads past the bubble's
    /// edge), taken away when its time is up.
    private func addFX(_ l: CALayer, _ a: CAAnimation, life: CFTimeInterval) {
        layer.addSublayer(l)
        fxLayers.append(l)
        l.add(a, forKey: "reactionFX")
        DispatchQueue.main.asyncAfter(deadline: .now() + life) { [weak self, weak l] in
            guard let l else { return }
            l.removeFromSuperlayer()
            self?.fxLayers.removeAll { $0 === l }
        }
    }

    /// The emoji travelling from where it was picked to its pill, in the window. False when there is
    /// nowhere sensible to fly from (no window, or a start point off this screen).
    private func flyIn(_ emoji: String, from screenPoint: CGPoint, to v: UIView) -> Bool {
        guard let win = window, let chip = v as? ReactionChipView else { return false }
        let start = win.convert(screenPoint, from: win.screen.coordinateSpace)
        guard win.bounds.insetBy(dx: -20, dy: -20).contains(start) else { return false }
        let end = chip.convert(chip.emojiPoint, to: win)
        let label = UILabel()
        label.text = emoji
        label.font = .systemFont(ofSize: 30)
        label.sizeToFit()
        label.center = end
        label.isUserInteractionEnabled = false
        let endScale = max(0.3, min(1, chip.emojiFontSize / 30))
        label.transform = CGAffineTransform(scaleX: endScale, y: endScale)
        label.alpha = 0   // shown only by the flight; it never sits on the pill by itself
        win.addSubview(label)
        fxViews.append(label)

        let dur = ReactionFlight.duration
        let path = UIBezierPath()
        path.move(to: start)
        let lift = min(70, max(30, abs(end.y - start.y) * 0.35))
        path.addQuadCurve(to: end, controlPoint: CGPoint(x: (start.x + end.x) / 2, y: min(start.y, end.y) - lift))
        let travel = CAKeyframeAnimation(keyPath: "position")
        travel.path = path.cgPath
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.15
        scale.toValue = endScale
        let show = CABasicAnimation(keyPath: "opacity")
        show.fromValue = 1
        show.toValue = 1
        let g = CAAnimationGroup()
        g.animations = [travel, scale, show]
        g.duration = dur
        g.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
        label.layer.add(g, forKey: "reactionFX")
        DispatchQueue.main.asyncAfter(deadline: .now() + dur) { [weak self, weak label] in
            guard let label else { return }
            label.removeFromSuperview()
            self?.fxViews.removeAll { $0 === label }
        }
        return true
    }

    /// The dots' colour: the emoji's own main colour for the common ones, the accent otherwise.
    private static func flairColor(_ emoji: String) -> UIColor {
        switch emoji.replacingOccurrences(of: "\u{FE0F}", with: "") {
        case "\u{2764}", "😍", "🥰", "😘", "💔", "🌹", "💯": return UIColor(red: 1, green: 0.23, blue: 0.3, alpha: 1)
        case "🔥", "🍾", "🏆": return UIColor(red: 1, green: 0.55, blue: 0.1, alpha: 1)
        case "😢", "😭": return UIColor(red: 0.3, green: 0.6, blue: 1, alpha: 1)
        case "😡", "🤬": return UIColor(red: 0.95, green: 0.3, blue: 0.2, alpha: 1)
        case "👍", "👎", "😂", "🤣", "😁", "😮", "😱", "🙏", "👏", "🤩", "😅", "\u{26A1}", "🥳", "🎉", "😇":
            return UIColor(red: 1, green: 0.78, blue: 0.15, alpha: 1)
        default: return BubblePalette.accent
        }
    }

    private func applyFailBadge(_ b: BubblePlan) {
        guard let rect = b.failBadge else { failBadge?.isHidden = true; return }
        let icon = failBadge ?? {
            // Their `error-circle`: an outlined ring with an exclamation, drawn at the badge's full
            // 24pt box. `contentMode = .center` keeps the glyph at its own size, as theirs does.
            // ⛔ A SYSTEM MENU BUTTON — owner, 2026-10-06: the "Message not sent" box just popped in,
            // with none of iOS 26's opening motion. An arrowless popover has no source to grow from;
            // a button's own menu grows out of the button, which is the system animation he means.
            // The items are asked for at tap time (`failMenuItems`), so a reused cell never shows a
            // stale row's actions.
            let v = UIButton(type: .system)
            v.setImage(UIImage(systemName: "exclamationmark.circle",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 21, weight: .regular)),
                       for: .normal)
            v.tintColor = BubblePalette.failRed
            v.showsMenuAsPrimaryAction = true
            v.menu = UIMenu(title: "Message not sent", children: [
                UIDeferredMenuElement.uncached { [weak self] done in done(self?.failMenuItems?() ?? []) }
            ])
            addSubview(v); failBadge = v; return v
        }()
        icon.isHidden = false
        // The 40pt finger target `hitsFailBadge` has always promised; the glyph stays centred at 24.
        icon.frame = rect.insetBy(dx: -8, dy: -8)
    }

    // MARK: - Helpers

    private func isMe(_ m: MessageRowModel) -> Bool {
        if case .bubble(let b) = m.content { return b.isMe }
        return false
    }

    private func metaChrome(_ m: MessageRowModel) -> MetaChrome {
        if case .bubble(let b) = m.content { return b.meta }
        return MetaChrome(timeText: "", edited: false, tick: .none, bornAt: nil)
    }

    /// The spinning sending indicator, drawn over the footer's tick slot.
    ///
    /// ⚠️ A SEPARATE VIEW, not the label's attachment: an attachment cannot rotate, and rotating
    /// the whole footer would spin the timestamp with it.
    /// ⛔ THE DISAPPEARING-MESSAGE TIMER, beside the timestamp — owner's decision, 2026-08-28.
    ///
    /// Disappearing messages have been live server-side and the row said nothing at all about it: a
    /// message with two minutes left looked exactly like one that stays forever. Theirs puts a
    /// shrinking hourglass in the footer for this, and it is not a decoration — the whole feature is
    /// the fact that this message is going away.
    ///
    /// ⚠️ DRAWN OVER THE FOOTER, ADDING NO WIDTH AND NO HEIGHT. It sits in the room
    /// `BubbleText.footerWidth` counts for it, exactly as the sending clock does, so the bubble does not resize
    /// while the timer runs. A footer that re-measured every second would re-bloom every expiring row
    /// on screen, once a second, which is the failure mode this file's own notes keep warning about.
    ///
    /// ⚠️ AND IT IS REDRAWN, NOT ANIMATED. A CADisplayLink or a per-second timer per row would mean
    /// dozens of live timers in a busy chat. The fraction is recomputed whenever the row is
    /// configured or repainted — which already happens on every land, tick and scroll — and the
    /// remaining time is coarse enough that a second's lag is invisible.
    private func setExpiryTimer(_ expiresAt: Date?, bornAt: Date?, over b: BubblePlan) {
        // ⛔ RETIRED 2026-09-29: the icon is drawn inside the footer text now, between the time and
        // the tick (`BubbleText.meta`). This view stays hidden so a reused cell never shows both.
        expiryRing?.isHidden = true
    }

    private func setSendingSpin(_ on: Bool, over b: BubblePlan) {
        guard on else {
            sendingSpinner?.layer.removeAllAnimations()
            sendingSpinner?.isHidden = true
            return
        }
        let v = sendingSpinner ?? {
            let x = UIImageView(image: UIImage(systemName: "clock",
                                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold)))
            x.contentMode = .center
            bubbleBox.addSubview(x)
            sendingSpinner = x
            return x
        }()
        v.isHidden = false
        v.tintColor = b.metaColor
        // Over the tick, at the footer's trailing edge.
        // ⛔ CENTRED ON THE DIGITS, NOT ON THE LINE BOX — owner, 2026-09-29: "the pending clock sits
        // higher than the time". `meta.midY` is the middle of the whole line box, whose height is
        // not the digits' (the line carries more room above the cap height than below the
        // baseline), so the clock rode high. The tick attachment it stands in for is centred on the
        // cap height (`BubbleText.meta`); this uses the same point: baseline − capHeight / 2, with
        // the baseline found from the line's bottom and the font's descender.
        let side: CGFloat = 10
        let f = BubbleMetrics.metaFont
        let baseline = b.meta.maxY + f.descender          // descender is negative
        let centreY = baseline - f.capHeight / 2
        v.frame = CGRect(x: b.meta.maxX - side, y: centreY - side / 2, width: side, height: side)
        bubbleBox.bringSubviewToFront(v)
        guard v.layer.animation(forKey: "spin") == nil else { return }
        // Their numbers, verbatim: one full turn, one second, cumulative, forever.
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.toValue = CGFloat.pi * 2
        a.duration = 1
        a.isCumulative = true
        a.repeatCount = .greatestFiniteMagnitude
        v.layer.add(a, forKey: "spin")
    }

    /// Hit-test a tapped link inside the body, in this view's coordinates.
    func link(at point: CGPoint) -> URL? {
        guard let p = plan, case .bubble(let b) = p.body, !b.links.isEmpty else { return nil }
        let inBubble = CGPoint(x: point.x - b.bubble.minX, y: point.y - b.bubble.minY)
        guard b.text.contains(inBubble) else { return nil }
        let local = CGPoint(x: inBubble.x - b.text.minX, y: inBubble.y - b.text.minY)

        let storage = NSTextStorage(attributedString: b.bodyAttr)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: b.text.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byWordWrapping
        container.maximumNumberOfLines = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)

        let index = manager.characterIndex(for: local, in: container,
                                           fractionOfDistanceBetweenInsertionPoints: nil)
        // `characterIndex` clamps to the nearest glyph, so a tap past the end of a line would
        // "hit" the last link on it. Reject anything outside the glyph's own rect. It also returns
        // `length` for a tap past the very end, where a 1-character range would be out of bounds.
        guard index < storage.length else { return nil }
        let glyphRange = manager.glyphRange(forCharacterRange: NSRange(location: index, length: 1),
                                            actualCharacterRange: nil)
        let box = manager.boundingRect(forGlyphRange: glyphRange, in: container)
        guard box.contains(local) else { return nil }
        return b.links.first { NSLocationInRange(index, $0.range) }?.url
    }

    /// Is this point on the reply quote? A tap there jumps to the original rather than opening.
    func hitsQuote(_ point: CGPoint) -> Bool {
        guard let p = plan, case .bubble(let b) = p.body, let q = b.quote else { return false }
        return q.offsetBy(dx: b.bubble.minX, dy: b.bubble.minY).contains(point)
    }

    /// A tap on media that is not on the phone yet belongs to its download (start / cancel / retry),
    /// not to the viewer. False when the file is here and the tap should open it as before.
    func handleMediaDownloadTap() -> Bool { mediaView?.handleDownloadTap() ?? false }

    /// 2026-10-17 chat stickers: see `MessageRowCell.setOnScreen`.
    func setMediaOnScreen(_ on: Bool) { mediaView?.setOnScreen(on) }
    var stickerBytes: Data? { mediaView?.isHidden == false ? mediaView?.stickerBytes : nil }
    /// The same for one album tile.
    func handleAlbumDownloadTap(tile i: Int) -> Bool { albumView?.handleDownloadTap(tile: i) ?? false }

    /// Is this point on the picture? A tap there opens the viewer; a tap on the CAPTION does not,
    /// which is why this asks about the media rect and not about the whole bubble.
    func hitsMedia(_ point: CGPoint) -> Bool {
        guard let p = plan, case .bubble(let b) = p.body, let media = b.mediaPlan else { return false }
        return media.media.offsetBy(dx: b.bubble.minX, dy: b.bubble.minY).contains(point)
    }

    /// The caption block of a photo, video or album bubble (never the picture). A double tap there
    /// reacts like on any text message; on the picture it stays off so a single tap opens at once
    /// (owner, 2026-09-29: "image with caption, double tap on the caption does not react").
    func hitsMediaCaption(_ point: CGPoint) -> Bool {
        guard let p = plan, case .bubble(let b) = p.body else { return false }
        let caption = b.mediaPlan?.caption ?? b.albumPlan?.caption
        guard let c = caption else { return false }
        return c.offsetBy(dx: b.bubble.minX, dy: b.bubble.minY).contains(point)
    }

    /// The map or its label — the whole card opens Maps.
    func hitsLocation(_ point: CGPoint) -> Bool {
        guard let p = plan, case .bubble(let b) = p.body, b.locationPlan != nil else { return false }
        return b.bubble.contains(point)
    }

    /// The answer buttons under a notice (Reject / Accept on a Restricted chat request). Each is
    /// drawn by the same pill view as the notice itself, so it wears the notice's surface on every
    /// wallpaper. Recycled cells hide the ones they no longer need.
    private func applyNoticeButtons(_ n: NoticePlan?, dark: Bool) {
        let buttons = n?.buttons ?? []
        while noticeButtonViews.count < buttons.count {
            let v = RowNoticePillView(); addSubview(v); noticeButtonViews.append(v)
        }
        for (i, v) in noticeButtonViews.enumerated() {
            guard i < buttons.count, let n else { v.isHidden = true; continue }
            let b = buttons[i]
            v.isHidden = false
            v.configure(NoticePlan(capsule: CGRect(origin: .zero, size: b.rect.size), text: b.text,
                                   attr: b.attr, style: .pill,
                                   onWallpaper: n.onWallpaper, wallpaperBlur: n.wallpaperBlur),
                        dark: dark)
            v.frame = b.rect
        }
    }

    /// Which notice button a point is on, by its action id, or nil.
    func noticeAction(at point: CGPoint) -> String? {
        guard let p = plan, case .notice(let n) = p.body else { return nil }
        // A little slop around each pill: they are short targets.
        if let hit = n.buttons.first(where: { $0.rect.insetBy(dx: -2, dy: -6).contains(point) })?.id { return hit }
        // A story mention card opens its story from anywhere on the card, as its button does.
        if n.style == .storyCard, n.capsule.contains(point) { return n.buttons.first?.id }
        return nil
    }

    /// The contact card's "message" button, specifically. Tapping the card ELSEWHERE opens the
    /// person's profile, so the two targets have to be told apart.
    func hitsContactButton(_ point: CGPoint) -> Bool {
        guard let p = plan, case .bubble(let b) = p.body,
              let c = b.contactPlan, let button = c.button else { return false }
        return button.offsetBy(dx: b.bubble.minX, dy: b.bubble.minY).contains(point)
    }

    func hitsContactCard(_ point: CGPoint) -> Bool {
        guard let p = plan, case .bubble(let b) = p.body, b.contactPlan != nil else { return false }
        return b.bubble.contains(point)
    }

    /// Is this point on a single photo's/video's upload indicator? The X in its centre cancels the
    /// send, so this is asked BEFORE `hitsMedia` — the indicator is drawn on top of the picture.
    func hitsUploadRing(_ point: CGPoint) -> Bool {
        guard let p = plan, case .bubble(let b) = p.body,
              let ring = b.mediaPlan?.uploadRing else { return false }
        return ring.offsetBy(dx: b.bubble.minX, dy: b.bubble.minY).contains(point)
    }

    /// Which album tile's upload indicator is under this point. Per TILE, because each X cancels
    /// only its own item and the album ships without it.
    func uploadRingTileIndex(at point: CGPoint) -> Int? {
        guard let p = plan, case .bubble(let b) = p.body, let a = b.albumPlan else { return nil }
        let local = CGPoint(x: point.x - b.bubble.minX, y: point.y - b.bubble.minY)
        return a.tiles.firstIndex {
            $0.ring?.offsetBy(dx: a.grid.minX, dy: a.grid.minY).contains(local) == true
        }
    }

    /// Which album tile is under this point, if any.
    func albumTileIndex(at point: CGPoint) -> Int? {
        guard let p = plan, case .bubble(let b) = p.body, let a = b.albumPlan else { return nil }
        let local = CGPoint(x: point.x - b.bubble.minX, y: point.y - b.bubble.minY)
        return albumView?.tileIndex(at: local, plan: a)
    }

    /// The file row — tapping it opens the document.
    func hitsFile(_ point: CGPoint) -> Bool {
        guard let p = plan, case .bubble(let b) = p.body, b.filePlan != nil else { return false }
        return b.bubble.contains(point)
    }

    /// The call bubble itself — NOT the row. His report, 2026-08-27: tapping the empty wallpaper
    /// beside a call bubble offered to call again; the cell's `.call` case fired for a tap
    /// anywhere in the row because nothing asked WHERE. The wallpaper is nobody's button.
    func hitsCallBubble(_ point: CGPoint) -> Bool {
        guard let p = plan, case .call(let c) = p.body else { return false }
        return c.bubble.contains(point)
    }

    /// The emoji of the pill under the finger (owner 2026-10-29: a channel pill reacts on tap). nil
    /// for the "+N" overflow pill, which has no emoji of its own.
    func reactionEmoji(at point: CGPoint) -> String? {
        guard let p = plan, case .bubble(let b) = p.body,
              let i = b.reactions.firstIndex(where: { $0.contains(point) }),
              let keys = Self.reactionKeys(model), i < keys.count else { return nil }
        return keys[i]
    }

    func hitsReactions(_ point: CGPoint) -> Bool {
        guard let p = plan, case .bubble(let b) = p.body else { return false }
        return b.reactions.contains { $0.contains(point) }
    }

    func hitsFailBadge(_ point: CGPoint) -> Bool {
        guard let p = plan, case .bubble(let b) = p.body, let r = b.failBadge else { return false }
        // The badge is 24pt; the target is 40, which is the smallest a finger should be asked for.
        return r.insetBy(dx: -8, dy: -8).contains(point)
    }

    func hitsCheckbox(_ point: CGPoint) -> Bool {
        guard let rect = plan?.checkbox else { return false }
        return rect.insetBy(dx: -12, dy: -12).contains(point)
    }

    func hitsAvatar(_ point: CGPoint) -> Bool {
        guard let p = plan, case .bubble = p.body, let v = avatarView, !v.isHidden else { return false }
        // Where the photo is drawn now: the run's photo can sit beside any bubble of the run.
        return v.frame.contains(point)
    }

    func hitsSenderName(_ point: CGPoint) -> Bool {
        guard let p = plan, case .bubble(let b) = p.body, let n = b.senderName else { return false }
        return n.contains(point)
    }

    /// Animate the two decorations that changed, FROM the state the row was in before `apply` ran.
    ///
    /// ⚠️ The from-values have to be passed in. `apply` has already written the new state by the
    /// time this is called, so an animation that read the current value would run from the
    /// destination to the destination — visually nothing, which is how a "tick that pops" and a
    /// "flash that never fades" both look like the animation was never written.
    func animateDecorations(fromSelected: Bool, fromHighlighted: Bool) {
        guard let m = model else { return }
        // ⚠️ THE TICK DOES NOT ANIMATE. Theirs writes `setIsSelected(_, animated: false)` straight
        // onto the view from the tap handler: the fill appears on the same frame as the finger.
        // Ours used a 0.35s spring with a scale-up on the glyph, which is a third of a second of
        // catch-up on every tap of a twenty-message selection.
        if let box = checkbox, m.selected != fromSelected {
            box.refreshSelected(m.selected)
        }
        // The jump flash no longer rides `highlighted`: see `performJumpHighlight`.
        _ = fromHighlighted
    }

    /// ⛔ THE JUMP FLASH IS THE REFERENCE MESSENGER'S, EXACTLY — owner, 2026-10-08: "when I tap a
    /// pinned message the highlight works wrong, make it exactly how it works there". Read from its
    /// source (`performMessageBubbleHighlightAnimation` + `CVDimmableView.performDimmingAnimation`):
    /// a dimmer layer the shape of the bubble, white 25% on dark and black 25% on light, fades in
    /// over 0.4s, starts fading out 0.8s after the start, over 0.4s, then removes itself. It is
    /// fired by the LIST the moment its scroll animation ends (or at once when the row was already
    /// fully on screen), never by a timer and never by re-rendering the row.
    func performJumpHighlight() {
        guard case .bubble = plan?.body, let path = highlight.shape.path else { return }
        let dimmer = CAShapeLayer()
        dimmer.path = path
        dimmer.frame = highlight.bounds
        dimmer.fillColor = (bubbleDark ? UIColor.white : UIColor.black).withAlphaComponent(0.25).cgColor
        dimmer.opacity = 0
        highlight.layer.addSublayer(dimmer)

        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        fadeIn.duration = 0.4
        fadeIn.fillMode = .forwards
        fadeIn.isRemovedOnCompletion = false
        dimmer.add(fadeIn, forKey: "fadeIn")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak dimmer] in
            guard let dimmer else { return }
            CATransaction.begin()
            CATransaction.setCompletionBlock { dimmer.removeFromSuperlayer() }
            let fadeOut = CABasicAnimation(keyPath: "opacity")
            fadeOut.fromValue = 1
            fadeOut.toValue = 0
            fadeOut.duration = 0.4
            fadeOut.fillMode = .forwards
            fadeOut.isRemovedOnCompletion = false
            dimmer.add(fadeOut, forKey: "fadeOut")
            CATransaction.commit()
        }
    }

    /// Write the tick straight onto the live view, ahead of the model round trip.
    ///
    /// Theirs does exactly this in `handleTap`: `selectionView.isSelected = true` on the view first,
    /// then the selection state is updated. The list is never reloaded for a tick. Ours put the id
    /// into a SwiftUI `Set`, which rebuilt every row model, re-hashed every row signature and
    /// reconfigured every visible cell before the circle you tapped could fill in.
    func setSelectedImmediately(_ on: Bool) {
        checkbox?.setSelected(on, animated: false)
    }

    /// The box a long press lifts and a swipe translates. A notice and a call row are not bubbles,
    /// and lifting a hidden `bubbleBox` still holding the frame of whatever row this cell drew last
    /// is how a menu ends up anchored to nothing.
    var liftTarget: UIView {
        switch plan?.body {
        case .notice: return noticeView ?? bubbleBox
        case .call: return callView ?? bubbleBox
        default: return bubbleBox
        }
    }

    func prepareForReuse() {
        // Anything the cell can be recycled MID-ANIMATION out of has to be put back by hand. A
        // stranded transform slides the wrong row left; a stranded flash animation keeps pulsing on
        // a message nobody jumped to; a checkbox left mid-fade arrives at the next row half there.
        bubbleBox.transform = .identity
        bubbleBox.layer.removeAllAnimations()
        highlight.shape.removeAllAnimations()
        highlight.layer.sublayers?.forEach { $0.removeFromSuperlayer() }   // a jump flash still on it
        // Owner audit 2026-10-06 chat #79: a notice or call row is the box a swipe translates
        // (`liftTarget`), so its transform is put back here as well, not only the bubble box's.
        noticeView?.transform = .identity
        callView?.transform = .identity
        // 2026-10-23: the name, mark, role tag and forwarded line now ride a reply swipe with the
        // bubble, so they are put back too (a recycled row must not start shifted).
        [senderLabel, verifiedView, roleChipView, forwardedLabel, forwardedIcon, avatarView].forEach { $0?.transform = .identity }
        // Owner audit 2026-10-06 chat #78: the reset above covers the box, not its children. A
        // reaction's animations on the fill, chips, body and the chrome above the box kept running
        // for up to 0.4s on the next row drawn here, morphing it from the old row's geometry.
        Self.dropReactionAnimations(layer)
        // Emptied before the removals: a removal can run the fade's completion, which edits the list.
        let snaps = leavingSnaps
        leavingSnaps.removeAll()
        snaps.forEach { $0.removeFromSuperview() }
        // My-reaction ripple, dots and flying emoji belong to the row that made them.
        let fx = fxLayers, fv = fxViews
        fxLayers.removeAll()
        fxViews.removeAll()
        fx.forEach { $0.removeFromSuperlayer() }
        fv.forEach { $0.removeFromSuperview() }
        pendingGrowth = 0   // chat #38: never handed to the next row this cell draws
        // The countdown belongs to one message's timer; a recycled cell must not inherit it.
        expiryRing?.isHidden = true
        // The circle is a view that only exists while the selection lane does, so recycling takes it
        // out rather than parking it. A cell coming back for a row that is not in selection mode
        // cannot then be handed a hidden-but-present box to get confused about.
        if let box = checkbox {
            box.layer.removeAllAnimations()
            box.removeFromSuperview()
            checkbox = nil
        }
        quoteView?.isHidden = true
        hideBubbleChrome()
        mediaView?.prepareForReuse()
        albumView?.prepareForReuse()
        fileView?.prepareForReuse()
        locationView?.prepareForReuse()
        pollView?.prepareForReuse()
        linkView?.prepareForReuse()
        storyReplyView?.prepareForReuse()
        voiceView?.prepareForReuse()
        pillView?.prepareForReuse()
        sendingSpinner?.layer.removeAllAnimations()
        sendingSpinner?.isHidden = true
        model = nil
        plan = nil
    }
}

private extension BubbleText {
    /// The meta string for a bubble that is already planned — keeps the two call sites in
    /// `MessageRowView` from restating the colour and the isMe test.
    static func meta(b: BubblePlan, m: MessageRowModel) -> NSAttributedString {
        guard case .bubble(let row) = m.content else { return NSAttributedString() }
        return meta(row.meta, isMe: row.isMe, color: b.metaColor,
                    solidTicks: b.mediaPlan?.metaCapsule != nil || b.albumPlan?.metaCapsule != nil)
    }
}
