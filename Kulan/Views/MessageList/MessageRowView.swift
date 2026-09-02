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

// ── A reaction capsule ──

final class ReactionChipView: UIView {
    private let label = UILabel()
    private let ring = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.textAlignment = .center
        addSubview(label)
        ring.fillColor = UIColor.clear.cgColor
        ring.lineWidth = 1
        layer.addSublayer(ring)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ attr: NSAttributedString, mine: Bool) {
        label.attributedText = attr
        backgroundColor = mine ? BubblePalette.accent.withAlphaComponent(0.18) : BubblePalette.receivedFill
        ring.strokeColor = mine ? BubblePalette.accent.withAlphaComponent(0.9).cgColor : UIColor.clear.cgColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds
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

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(fill)
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.textAlignment = .center
        addSubview(label)
        addSubview(rim)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ plan: NoticePlan, dark: Bool) {
        label.attributedText = plan.attr
        label.textAlignment = plan.style == .pill ? .center : .left
        label.frame = plan.text

        let size = plan.capsule.size
        rim.frame = CGRect(origin: .zero, size: size)
        switch plan.style {
        case .pill:
            // The SAME surface an incoming bubble wears — the reference app's date header is not
            // styled to resemble a bubble, it IS one, minus the text colour. So this goes through
            // the identical `Theme.receivedSurface` decision every incoming bubble makes.
            let path = BubbleShape.capsulePath(size)
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
        let path = BubbleShape.path(size, .uniform(16))
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
    private let bodyLabel = UILabel()
    private let metaLabel = UILabel()

    private var mediaView: MediaBubbleView?
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
    private var forwardedLabel: UILabel?
    private var forwardedIcon: UIImageView?
    private var tombstoneIcon: UIImageView?
    private var failBadge: UIImageView?
    private var reactionViews: [ReactionChipView] = []
    private var headerPill: RowNoticePillView?
    private var dividerLeft: UIView?
    private var dividerRight: UIView?
    private var dividerLabel: UILabel?
    private var noticeView: RowNoticePillView?
    private var callView: CallBubbleView?
    private var checkbox: SelectionCheckboxView?
    /// The disappearing-message countdown, drawn over the footer. See `setExpiryTimer`.
    private var expiryRing: ExpiryRingView?

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
        model = m
        plan = p
        self.cid = cid
        let dark = traitCollection.userInterfaceStyle == .dark

        applyHeader(p, dark: dark)
        applyDivider(p)
        applyCheckbox(m, p)

        switch p.body {
        case .bubble(let b):
            bubbleBox.isHidden = false
            noticeView?.isHidden = true
            callView?.isHidden = true
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
        case .call(let c):
            bubbleBox.isHidden = true
            noticeView?.isHidden = true
            hideBubbleChrome()
            let v = callView ?? {
                let v = CallBubbleView(); addSubview(v); callView = v; return v
            }()
            v.isHidden = false
            v.frame = c.bubble
            v.configure(c, dark: dark)
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
            box.layer.add(a, forKey: "remove")
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
        let path = b.isCapsule ? BubbleShape.capsulePath(b.bubble.size)
                               : BubbleShape.path(b.bubble.size, b.radii)
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
        highlight.shape.fillColor = UIColor.label.withAlphaComponent(m.highlighted ? 0.18 : 0).cgColor
        CATransaction.commit()
        bubbleBox.bringSubviewToFront(rim)
        bubbleBox.bringSubviewToFront(highlight)

        bodyLabel.attributedText = b.bodyAttr
        bodyLabel.frame = b.text
        metaLabel.attributedText = BubbleText.meta(metaChrome(m), isMe: isMe(m), color: b.metaColor)
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
            let v = MediaBubbleView(); bubbleBox.insertSubview(v, aboveSubview: fill); mediaView = v; return v
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
            let rect = convert(thumb, to: nil)
            if rect.width > 1 { MediaOpenRects.capture(sr.anchorKey, rect, cornerRadius: 14) }
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
        v2.configure(v, plan: plan, tint: b.textColor, cid: cid)
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
        v.configure(card, plan: plan, tint: b.textColor, cid: cid)
    }

    private func applyStoryReply(_ b: BubblePlan, model m: MessageRowModel, cid: String) {
        guard let plan = b.storyReplyPlan,
              case .bubble(let row) = m.content, let sr = row.storyReply else {
            storyReplyView?.isHidden = true
            storyReplyView?.prepareForReuse()
            return
        }
        let v = storyReplyView ?? {
            let v = StoryReplyCardView(); addSubview(v); storyReplyView = v; return v
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
    func hitsLinkCard(_ point: CGPoint) -> Bool {
        guard let p = plan, case .bubble(let b) = p.body, let l = b.linkPlan else { return false }
        return l.card.offsetBy(dx: b.bubble.minX, dy: b.bubble.minY).contains(point)
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
        mask.path = (b.isCapsule ? BubbleShape.capsulePath(b.bubble.size)
                                 : BubbleShape.path(b.bubble.size, b.radii)).cgPath
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

    private func applySender(_ b: BubblePlan, model m: MessageRowModel) {
        if let rect = b.avatar, case .bubble(let row) = m.content, let s = row.sender {
            let v = avatarView ?? {
                let v = RowAvatarView(); addSubview(v); avatarView = v; return v
            }()
            v.isHidden = false
            v.frame = rect
            v.configure(name: s.name, photoUrl: s.avatarUrl)
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
                let cfg = UIImage.SymbolConfiguration(pointSize: 11)
                    .applying(UIImage.SymbolConfiguration(paletteColors: [.white, BubblePalette.hex(0x3DA1FD)]))
                let v = UIImageView(image: UIImage(systemName: "checkmark.seal.fill", withConfiguration: cfg))
                v.contentMode = .scaleAspectFit
                addSubview(v); verifiedView = v; return v
            }()
            v.isHidden = false
            v.frame = rect
        } else {
            verifiedView?.isHidden = true
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
        while reactionViews.count < b.reactions.count {
            let v = ReactionChipView()
            bubbleBox.addSubview(v)
            reactionViews.append(v)
        }
        for (i, v) in reactionViews.enumerated() {
            guard i < b.reactions.count else { v.isHidden = true; continue }
            v.isHidden = false
            // Row coordinates → the bubble box's coordinates, because the chips are its subviews so
            // that they ride the reply swipe with it.
            v.frame = b.reactions[i].offsetBy(dx: -b.bubble.minX, dy: -b.bubble.minY)
            v.configure(b.reactionAttrs[i], mine: b.reactionMine[i])
        }
    }

    private func applyFailBadge(_ b: BubblePlan) {
        guard let rect = b.failBadge else { failBadge?.isHidden = true; return }
        let icon = failBadge ?? {
            // Their `error-circle`: an outlined ring with an exclamation, drawn at the badge's full
            // 24pt box. `contentMode = .center` keeps the glyph at its own size, as theirs does.
            let v = UIImageView(image: UIImage(systemName: "exclamationmark.circle",
                                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 21, weight: .regular)))
            v.contentMode = .center
            v.tintColor = BubblePalette.failRed
            v.isUserInteractionEnabled = false   // the cell hit-tests the plan; see MessageRowCell
            addSubview(v); failBadge = v; return v
        }()
        icon.isHidden = false
        icon.frame = rect
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
    /// ⚠️ DRAWN OVER THE FOOTER, ADDING NO WIDTH AND NO HEIGHT. It sits in the lane the invisible
    /// reservation already leaves, exactly as the sending clock does, so the bubble does not resize
    /// while the timer runs. A footer that re-measured every second would re-bloom every expiring row
    /// on screen, once a second, which is the failure mode this file's own notes keep warning about.
    ///
    /// ⚠️ AND IT IS REDRAWN, NOT ANIMATED. A CADisplayLink or a per-second timer per row would mean
    /// dozens of live timers in a busy chat. The fraction is recomputed whenever the row is
    /// configured or repainted — which already happens on every land, tick and scroll — and the
    /// remaining time is coarse enough that a second's lag is invisible.
    private func setExpiryTimer(_ expiresAt: Date?, bornAt: Date?, over b: BubblePlan) {
        guard let expiresAt, b.meta != .zero else {
            expiryRing?.isHidden = true
            return
        }
        let v = expiryRing ?? {
            let x = ExpiryRingView(frame: .zero)
            bubbleBox.addSubview(x)
            expiryRing = x
            return x
        }()
        // The full span this message was given, so the ring can show a PROPORTION rather than an
        // absolute time — a five-minute timer half gone and a one-day timer half gone should look
        // the same, which is what makes the glyph readable at a glance.
        let total = bornAt.map { expiresAt.timeIntervalSince($0) } ?? 0
        let left = expiresAt.timeIntervalSinceNow
        v.isHidden = false
        v.tintColor = b.metaColor
        v.fraction = total > 0 ? max(0, min(1, left / total)) : 0
        // Leading of the footer, so it reads before the time rather than colliding with the tick's
        // reserved slot at the trailing edge.
        let side: CGFloat = 9
        v.frame = CGRect(x: b.meta.minX - side - 3, y: b.meta.midY - side / 2, width: side, height: side)
        bubbleBox.bringSubviewToFront(v)
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
        let side: CGFloat = 10
        v.frame = CGRect(x: b.meta.maxX - side, y: b.meta.midY - side / 2, width: side, height: side)
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

    /// Is this point on the picture? A tap there opens the viewer; a tap on the CAPTION does not,
    /// which is why this asks about the media rect and not about the whole bubble.
    func hitsMedia(_ point: CGPoint) -> Bool {
        guard let p = plan, case .bubble(let b) = p.body, let media = b.mediaPlan else { return false }
        return media.media.offsetBy(dx: b.bubble.minX, dy: b.bubble.minY).contains(point)
    }

    /// The map or its label — the whole card opens Maps.
    func hitsLocation(_ point: CGPoint) -> Bool {
        guard let p = plan, case .bubble(let b) = p.body, b.locationPlan != nil else { return false }
        return b.bubble.contains(point)
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
        guard let p = plan, case .bubble(let b) = p.body, let a = b.avatar else { return false }
        return a.contains(point)
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
        if case .bubble = plan?.body, m.highlighted != fromHighlighted {
            let a = CABasicAnimation(keyPath: "fillColor")
            a.fromValue = UIColor.label.withAlphaComponent(fromHighlighted ? 0.18 : 0).cgColor
            a.toValue = highlight.shape.fillColor
            a.duration = 0.4                  // the smooth found-result fade
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            highlight.shape.add(a, forKey: "flash")
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
        return meta(row.meta, isMe: row.isMe, color: b.metaColor)
    }
}
