import SwiftUI
import UIKit

// THE CUSTOM LONG-PRESS MENU — Signal's architecture, our code. EXPERIMENT BRANCH ONLY until the
// owner's device verdict (his deal 2026-07-30: ships alone, two TestFlights or we give up).
//
// Read 2026-07-30 from Signal-iOS CustomContextMenus/* (see kulan-signal-custom-menu-study memory).
// The whole idea in one line: Apple's menu is never involved. We SNAPSHOT the pressed bubble, hide
// the real one, blur the whole screen in our own overlay, and place bar · message · menu ourselves,
// shrinking the snapshot when a tall message would not fit. Every recognizer involved lives on THIS
// overlay — nothing here touches the chat list's tap system (the convicted a1b2c7e defect cannot
// exist in this shape).
//
// Signal's numbers, kept: press 0.2s · squeeze 0.95 over 0.2s · present spring 0.4s damping 0.8
// v0 1.0 · blur-in 0.2s · menu scale-in from 0.2 anchored at the bubble corner · finger dead zone
// 40pt · gaps 12pt · content padding = safe area clamped to ≥8pt · menu width 250 · min preview
// scale (ours) 0.35 — Signal allows 0.1 but a chat bubble smaller than a third reads as broken.

// MARK: - Bubble rect registry

/// Window-space frames of the SwiftUI-hosted bubbles, so a long press can snapshot the BUBBLE and
/// not the full transparent row around it. Native text cells don't need this — they hand over their
/// `previewBubble` directly. Off-screen captures are ignored: every bubble also renders as the
/// list's invisible sizer copy, and letting that copy land would overwrite the real bubble's
/// position with a rect nowhere near the finger (the KeyboardSafeRects lesson, kept).
@MainActor enum CMBubbleRects {
    private static var rects: [String: (rect: CGRect, radius: CGFloat)] = [:]
    static func capture(_ id: String, _ rect: CGRect, radius: CGFloat) {
        guard !rect.isEmpty, rect.intersects(UIScreen.main.bounds) else { return }
        rects[id] = (rect, radius)
    }
    static func rect(_ id: String) -> CGRect? { rects[id]?.rect }
    static func radius(_ id: String) -> CGFloat { rects[id]?.radius ?? 18 }
}

/// Publishes a bubble's window rect + corner radius for as long as it is on screen.
struct CMBubbleRectReporter: ViewModifier {
    let id: String
    let radius: CGFloat
    func body(content: Content) -> some View {
        content.background(
            GeometryReader { g in
                Color.clear.onChange(of: g.frame(in: .global), initial: true) { _, f in
                    CMBubbleRects.capture(id, f, radius: radius)
                }
            }
        )
    }
}

// MARK: - Model

struct CMAction {
    let title: String
    let icon: String            // SF Symbol name
    var destructive: Bool = false
    let handler: () -> Void
}

/// What a lift over the bar chose. `.emoji(nil)` = remove my current reaction (tapping the one
/// already selected); `.more` = open the full picker. Two different things — never one nil.
enum CMReactionSelection {
    case emoji(String?)
    case more
}

struct CMReactConfig {
    let emojis: [String]        // the quick set, in order (≤6)
    let selected: String?       // my current reaction — drawn on a filled disc, tap removes
    let onPick: (CMReactionSelection) -> Void
}

// MARK: - Overlay

/// One presentation = one overlay instance, added directly to the window (Signal adds their
/// controller's view the same way). Owns blur, dismiss catcher, preview snapshot, bar and card.
final class CMOverlay: UIView {

    private let previewView: UIView
    private let sourceFrame: CGRect          // window space; animation start AND end
    private let alignRight: Bool
    private let card: CMActionsCard
    private let bar: CMReactionBar?
    private let onDismissed: () -> Void

    private let blurView = UIVisualEffectView(effect: nil)
    private let dismissCatcher = UIButton(type: .custom)

    private let gapY: CGFloat = 12
    private let springDuration: TimeInterval = 0.4
    private let springDamping: CGFloat = 0.8
    private let minPreviewScale: CGFloat = 0.35
    private let deadZoneRadius: CGFloat = 40

    private var fingerExitedDeadZone = false
    private var initialFingerPoint: CGPoint?
    private var dismissing = false
    private var localPan: UIPanGestureRecognizer?
    // ARMING: for a bottom message the menu RISES into the spot where the unmoved finger already is,
    // so a small wiggle + lift selected Reply or Pin the user never aimed at (his report). An
    // accessory the finger started inside stays dead until the finger has been seen OUTSIDE it once.
    private var cardArmed = false
    private var barArmed = false

    init(previewView: UIView,
         sourceFrame: CGRect,
         alignRight: Bool,
         actions: [CMAction],
         react: CMReactConfig?,
         onDismissed: @escaping () -> Void) {
        self.previewView = previewView
        self.sourceFrame = sourceFrame
        self.alignRight = alignRight
        self.card = CMActionsCard(actions: actions)
        self.bar = react.map { CMReactionBar(config: $0) }
        self.onDismissed = onDismissed
        super.init(frame: .zero)

        addSubview(blurView)
        // Full-screen invisible catcher UNDER the preview: a plain tap anywhere that no accessory
        // claims dismisses the menu. Also the accessibility escape (Signal does exactly this).
        dismissCatcher.accessibilityLabel = "Dismiss menu"
        dismissCatcher.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)
        addSubview(dismissCatcher)

        // Preview above the catcher, accessories above the preview.
        previewView.isUserInteractionEnabled = false
        previewView.layer.shadowRadius = 12
        previewView.layer.shadowOffset = CGSize(width: 0, height: 4)
        previewView.layer.shadowColor = UIColor.black.cgColor
        previewView.layer.shadowOpacity = 0
        addSubview(previewView)
        addSubview(card)
        if let bar { addSubview(bar) }

        card.onSelect = { [weak self] action in
            // Dismiss FIRST, run the action after — an action that mutates the list (Select, Delete)
            // must never destroy the row while the return spring still needs its frame.
            self?.dismiss(animated: true) { action.handler() }
        }
        bar?.onSelect = { [weak self] selection in
            guard let self, let react else { return }
            self.dismiss(animated: true) { react.onPick(selection) }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Present

    func present(in window: UIWindow, startAtSqueeze: Bool) {
        frame = window.bounds
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(self)

        blurView.frame = bounds
        dismissCatcher.frame = bounds

        let frames = computeFrames(in: bounds)
        // Everything starts where the real bubble is; the spring carries it to the computed place.
        previewView.frame = sourceFrame
        if startAtSqueeze { previewView.transform = CGAffineTransform(scaleX: 0.95, y: 0.95) }

        card.sizeToFit()
        card.frame = frames.menu
        // The card grows out of the bubble's corner (Signal sets the layer anchor to the aligned
        // corner and scales from 0.2). Setting anchorPoint moves the frame, so re-assert it after.
        let cardFrame = card.frame
        card.layer.anchorPoint = CGPoint(x: alignRight ? 1 : 0, y: 0)
        card.frame = cardFrame
        card.transform = CGAffineTransform(scaleX: 0.2, y: 0.2)
        card.alpha = 0
        // Ride the preview's travel: start displaced by the same delta the preview will move.
        let travel = frames.preview.minY - sourceFrame.minY
        card.frame.origin.y -= travel

        if let bar, let barFrame = frames.bar {
            bar.frame = barFrame
            bar.alpha = 0
        }

        UIView.animate(withDuration: 0.2) {
            self.blurView.effect = UIBlurEffect(style: .regular)
            self.blurView.backgroundColor = UIColor { tc in
                tc.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.2)
                                               : UIColor(white: 0, alpha: 0.2)
            }
            self.previewView.layer.shadowOpacity = 0.3
        }

        UIView.animate(withDuration: springDuration, delay: 0,
                       usingSpringWithDamping: springDamping, initialSpringVelocity: 1.0,
                       options: [.curveEaseInOut, .beginFromCurrentState]) {
            self.previewView.transform = .identity
            self.previewView.frame = frames.preview
            self.card.transform = .identity
            self.card.alpha = 1
            self.card.frame = frames.menu
        }

        // The bar pops in slightly after the shift begins (Signal delays 0.1s when the preview
        // shifts) with its own staggered emoji rise.
        let barDelay: TimeInterval = abs(travel) > 0.5 ? 0.1 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + barDelay) { [weak self] in
            guard let self, !self.dismissing, let bar = self.bar else { return }
            bar.alpha = 1
            bar.playPresentation()
        }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.8)
        UIAccessibility.post(notification: .screenChanged, argument: card)
    }

    // MARK: Dismiss

    func dismiss(animated: Bool, then: (() -> Void)? = nil) {
        guard !dismissing else { return }
        dismissing = true
        guard animated else {
            removeFromSuperview()
            onDismissed(); then?()
            return
        }
        bar?.playDismissal(duration: 0.2)
        UIView.animate(withDuration: springDuration, delay: 0,
                       usingSpringWithDamping: springDamping, initialSpringVelocity: 1.0,
                       options: [.curveEaseInOut, .beginFromCurrentState]) {
            self.previewView.frame = self.sourceFrame
            self.card.transform = CGAffineTransform(scaleX: 0.2, y: 0.2)
            self.card.alpha = 0
            self.blurView.effect = nil
            self.blurView.backgroundColor = nil
            self.previewView.layer.shadowOpacity = 0
            self.bar?.alpha = 0
        } completion: { _ in
            self.removeFromSuperview()
            self.onDismissed()
            then?()
        }
    }

    @objc private func dismissTapped() { dismiss(animated: true) }

    // MARK: The layout math (Signal's targetPreviewFrame, simplified to our vertical stack)

    /// bar (exterior top, gap 12) · preview · menu (exterior bottom, gap 12), all aligned to the
    /// bubble's own horizontal edge. Overflow bottom → shift up; overflow top → shift down; still
    /// too tall → scale the preview down (anchored to its aligned edge) and recompute.
    private func computeFrames(in bounds: CGRect) -> (preview: CGRect, bar: CGRect?, menu: CGRect) {
        let pad: CGFloat = 8
        let content = bounds.inset(by: UIEdgeInsets(
            top: max(safeAreaInsets.top, pad), left: max(safeAreaInsets.left, pad),
            bottom: max(safeAreaInsets.bottom, pad), right: max(safeAreaInsets.right, pad)))

        let menuSize = card.sizeThatFits(CGSize(width: 250, height: content.height))
        let barSize = bar?.naturalSize ?? .zero

        func stack(for preview: CGRect) -> (bar: CGRect?, menu: CGRect, top: CGFloat, bottom: CGFloat) {
            var barFrame: CGRect?
            var top = preview.minY
            if bar != nil {
                let x = alignRight ? preview.maxX - barSize.width : preview.minX
                barFrame = CGRect(x: x, y: preview.minY - gapY - barSize.height,
                                  width: barSize.width, height: barSize.height)
                top = barFrame!.minY
            }
            let mx = alignRight ? preview.maxX - menuSize.width : preview.minX
            let menuFrame = CGRect(x: mx, y: preview.maxY + gapY,
                                   width: menuSize.width, height: menuSize.height)
            return (barFrame, menuFrame, top, menuFrame.maxY)
        }

        var preview = sourceFrame
        var s = stack(for: preview)

        // Shift up if the group runs past the bottom, then down if past the top.
        if s.bottom > content.maxY {
            preview.origin.y -= (s.bottom - content.maxY)
            s = stack(for: preview)
        }
        if s.top < content.minY {
            preview.origin.y += (content.minY - s.top)
            s = stack(for: preview)
        }

        // Still too tall → the preview gives up the difference (Signal scales the snapshot).
        let groupHeight = s.bottom - s.top
        if groupHeight > content.height {
            let targetPreviewHeight = preview.height - (groupHeight - content.height)
            let scale = max(targetPreviewHeight / preview.height, minPreviewScale)
            let newWidth = preview.width * scale
            if alignRight { preview.origin.x += preview.width - newWidth }
            preview.size = CGSize(width: newWidth, height: preview.height * scale)
            // Re-run the shift pass at the new size.
            preview.origin.y = max(content.minY + (bar != nil ? barSize.height + gapY : 0), preview.origin.y)
            s = stack(for: preview)
            if s.bottom > content.maxY {
                preview.origin.y -= (s.bottom - content.maxY)
                s = stack(for: preview)
            }
        }

        // Horizontal clamp: accessories may be wider than a narrow bubble — keep them on screen.
        var barFrame = s.bar
        var menuFrame = s.menu
        if var b = barFrame {
            b.origin.x = min(max(b.origin.x, content.minX), content.maxX - b.width)
            barFrame = b
        }
        menuFrame.origin.x = min(max(menuFrame.origin.x, content.minX), content.maxX - menuFrame.width)

        return (preview, barFrame, menuFrame)
    }

    // MARK: Continuous finger (Signal's star feature)

    /// The initiating long-press keeps streaming through here while the finger is still down. After
    /// a 40pt dead zone the location drives highlight in the card and focus in the bar.
    func fingerMoved(to windowPoint: CGPoint) {
        let p = convert(windowPoint, from: nil)
        if !cardArmed { cardArmed = !card.frame.contains(p) }
        if let bar, !barArmed { barArmed = !bar.frame.contains(p) }
        if !fingerExitedDeadZone {
            guard let start = initialFingerPoint else { initialFingerPoint = p; return }
            fingerExitedDeadZone = hypot(p.x - start.x, p.y - start.y) >= deadZoneRadius
            if !fingerExitedDeadZone { return }
        }
        if cardArmed { card.updateHighlight(at: convert(p, to: card)) }
        if barArmed { bar?.updateFocus(at: convert(p, to: bar!)) }
    }

    /// Finger lifted. If it lifted over a row or an emoji, that selects; otherwise the overlay
    /// stays up and hands control to its own pan/tap recognizers for the next touch.
    func fingerEnded(at windowPoint: CGPoint) {
        let wasArmed = (card: cardArmed, bar: barArmed, deadZone: fingerExitedDeadZone)
        installLocalPanIfNeeded()
        guard wasArmed.deadZone else { return }
        let p = convert(windowPoint, from: nil)
        if wasArmed.card, card.selectHighlighted(at: convert(p, to: card)) { return }
        if wasArmed.bar, bar?.selectFocused(at: convert(p, to: bar!)) == true { return }
    }

    /// After the initiating press ends, later drags are ours (Signal swaps in a local pan too).
    private func installLocalPanIfNeeded() {
        guard localPan == nil else { return }
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panRecognized(_:)))
        addGestureRecognizer(pan)
        localPan = pan
        // The dead zone and the arming only guard the ORIGINAL press — any later touch is deliberate.
        fingerExitedDeadZone = true
        cardArmed = true
        barArmed = true
    }

    @objc private func panRecognized(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began, .changed:
            card.updateHighlight(at: convert(p, to: card))
            bar?.updateFocus(at: convert(p, to: bar!))
        case .ended:
            if card.selectHighlighted(at: convert(p, to: card)) { return }
            if bar?.selectFocused(at: convert(p, to: bar!)) == true { return }
            card.clearHighlight()
            bar?.clearFocus()
        default:
            card.clearHighlight()
            bar?.clearFocus()
        }
    }
}

// MARK: - Actions card

/// The menu list: material capsule card, icon+label rows, touch-down highlight, touch-up select.
/// Taps are a minimumPressDuration=0 long-press (Signal's trick) so a row highlights the moment a
/// finger lands and selects when it lifts — a UITapGesture would only fire at the end.
final class CMActionsCard: UIView {

    var onSelect: ((CMAction) -> Void)?

    private let actions: [CMAction]
    private let backdrop: UIVisualEffectView
    private let scroll = UIScrollView()
    private var rows: [CMActionRow] = []

    // Signal's card, from the owner's side-by-side screenshots (his circled reference): icons on the
    // LEADING edge, a slightly narrower card, big continuous corners, roomy rows.
    private let rowHeight: CGFloat = 52
    private let cardWidth: CGFloat = 260
    private let corner: CGFloat = 22

    init(actions: [CMAction]) {
        self.actions = actions
        backdrop = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        super.init(frame: .zero)

        layer.cornerRadius = corner
        layer.cornerCurve = .continuous
        layer.shadowRadius = 40
        layer.shadowOffset = CGSize(width: 0, height: 16)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.2

        backdrop.layer.cornerRadius = corner
        backdrop.layer.cornerCurve = .continuous
        backdrop.layer.masksToBounds = true
        addSubview(backdrop)
        backdrop.contentView.addSubview(scroll)
        scroll.showsVerticalScrollIndicator = false

        for (i, action) in actions.enumerated() {
            let row = CMActionRow(action: action, showsSeparator: i < actions.count - 1)
            rows.append(row)
            scroll.addSubview(row)
        }

        let press = UILongPressGestureRecognizer(target: self, action: #selector(pressRecognized(_:)))
        press.minimumPressDuration = 0
        press.cancelsTouchesInView = false
        addGestureRecognizer(press)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        backdrop.frame = bounds
        scroll.frame = bounds
        for (i, row) in rows.enumerated() {
            row.frame = CGRect(x: 0, y: CGFloat(i) * rowHeight, width: bounds.width, height: rowHeight)
        }
        scroll.contentSize = CGSize(width: bounds.width, height: CGFloat(rows.count) * rowHeight)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        // Taller than the allowance → the card caps its height and the rows scroll inside it.
        let natural = CGFloat(rows.count) * rowHeight
        let maxH = size.height > 0 ? size.height : natural
        return CGSize(width: cardWidth, height: min(natural, maxH))
    }

    // MARK: touch driving (both from the overlay's streamed finger and our own press)

    private func row(at point: CGPoint) -> CMActionRow? {
        guard bounds.contains(point) else { return nil }
        let inScroll = CGPoint(x: point.x, y: point.y + scroll.contentOffset.y)
        return rows.first { $0.frame.contains(inScroll) }
    }

    func updateHighlight(at point: CGPoint) {
        var changed = false
        let hit = row(at: point)
        for row in rows {
            let should = row === hit
            if row.isHighlighted != should { changed = true }
            row.isHighlighted = should
        }
        if changed && hit != nil { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    }

    func clearHighlight() { rows.forEach { $0.isHighlighted = false } }

    /// Returns true when the lift selected a row.
    @discardableResult
    func selectHighlighted(at point: CGPoint) -> Bool {
        defer { clearHighlight() }
        guard let hit = row(at: point) else { return false }
        onSelect?(hit.action)
        return true
    }

    @objc private func pressRecognized(_ g: UILongPressGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began, .changed: updateHighlight(at: p)
        case .ended: selectHighlighted(at: p)
        default: clearHighlight()
        }
    }
}

/// One menu row: label left, SF Symbol right (our app's existing menu look), destructive in red.
private final class CMActionRow: UIView {
    let action: CMAction
    private let title = UILabel()
    private let icon = UIImageView()
    private let separator = UIView()
    private let highlight = UIView()

    var isHighlighted: Bool = false {
        didSet { highlight.isHidden = !isHighlighted }
    }

    init(action: CMAction, showsSeparator: Bool) {
        self.action = action
        super.init(frame: .zero)

        highlight.backgroundColor = UIColor.label.withAlphaComponent(0.08)
        highlight.isHidden = true
        addSubview(highlight)

        let color: UIColor = action.destructive ? .systemRed : .label
        title.text = action.title
        title.font = .preferredFont(forTextStyle: .body)
        title.adjustsFontSizeToFitWidth = true
        title.minimumScaleFactor = 0.7
        title.textColor = color
        addSubview(title)

        icon.image = UIImage(systemName: action.icon)
        icon.tintColor = color
        icon.contentMode = .scaleAspectFit
        addSubview(icon)

        separator.backgroundColor = UIColor.separator.withAlphaComponent(0.35)
        separator.isHidden = !showsSeparator
        addSubview(separator)

        isAccessibilityElement = true
        accessibilityLabel = action.title
        accessibilityTraits = .button
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        highlight.frame = bounds
        // Signal's row: icon LEADING, label after it (the owner's circled reference).
        let margin: CGFloat = 20
        let iconSize: CGFloat = 22
        icon.frame = CGRect(x: margin, y: (bounds.height - iconSize) / 2,
                            width: iconSize, height: iconSize)
        title.frame = CGRect(x: icon.frame.maxX + 14, y: 0,
                             width: bounds.width - icon.frame.maxX - 14 - margin, height: bounds.height)
        let hairline = 1.0 / UIScreen.main.scale
        separator.frame = CGRect(x: 0, y: bounds.height - hairline, width: bounds.width, height: hairline)
    }
}

// MARK: - Reaction bar

/// The floating quick-reaction capsule. Rebuilt from the removed ReactionBar.swift with its two
/// hard-won lessons kept: the emoji holders are stretched (.fill — zero-height holders ate every
/// tap), and focus/selection also arrives via the overlay's streamed finger, not only its own taps.
final class CMReactionBar: UIView {

    var onSelect: ((CMReactionSelection) -> Void)?

    private let config: CMReactConfig
    private let backdrop: UIVisualEffectView
    private let stack = UIStackView()
    private var holders: [UIView] = []

    private var barHeight: CGFloat { UIScreen.main.bounds.width <= 375 ? 50 : 56 }
    private let padding: CGFloat = 6
    private var buttonSide: CGFloat { barHeight - padding * 2 }
    private var focusedIndex: Int? {
        didSet {
            guard focusedIndex != oldValue else { return }
            if focusedIndex != nil { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
            for (i, holder) in holders.enumerated() {
                UIView.animate(withDuration: 0.15) {
                    holder.transform = i == self.focusedIndex
                        ? CGAffineTransform(scaleX: 1.3, y: 1.3).translatedBy(x: 0, y: -6)
                        : .identity
                }
            }
        }
    }

    var naturalSize: CGSize {
        CGSize(width: CGFloat(config.emojis.count + 1) * buttonSide + padding * 2, height: barHeight)
    }

    init(config: CMReactConfig) {
        self.config = config
        backdrop = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        super.init(frame: .zero)

        backdrop.layer.masksToBounds = true
        addSubview(backdrop)

        stack.axis = .horizontal
        stack.alignment = .fill          // NEVER .center: zero-height holders swallowed every tap
        stack.distribution = .fillEqually
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: padding, left: padding, bottom: padding, right: padding)
        addSubview(stack)

        for emoji in config.emojis { holders.append(makeEmoji(emoji)) }
        holders.append(makeMore())
        holders.forEach { stack.addArrangedSubview($0) }

        let press = UILongPressGestureRecognizer(target: self, action: #selector(pressRecognized(_:)))
        press.minimumPressDuration = 0
        press.cancelsTouchesInView = false
        addGestureRecognizer(press)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        backdrop.frame = bounds
        backdrop.layer.cornerRadius = bounds.height / 2
        stack.frame = bounds
    }

    private func makeEmoji(_ emoji: String) -> UIView {
        let holder = UIView()
        if emoji == config.selected {
            let disc = UIView()
            disc.backgroundColor = UIColor.tintColor.withAlphaComponent(0.18)
            disc.layer.cornerRadius = (barHeight - 4) / 2
            disc.isUserInteractionEnabled = false
            holder.addSubview(disc)
            disc.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                disc.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
                disc.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
                disc.widthAnchor.constraint(equalToConstant: barHeight - 4),
                disc.heightAnchor.constraint(equalToConstant: barHeight - 4),
            ])
        }
        let label = UILabel()
        label.text = emoji
        label.font = .systemFont(ofSize: buttonSide * 0.72)
        label.textAlignment = .center
        label.isUserInteractionEnabled = false
        holder.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
        ])
        holder.accessibilityLabel = emoji
        holder.isAccessibilityElement = true
        return holder
    }

    private func makeMore() -> UIView {
        let holder = UIView()
        let disc = UIView()
        disc.backgroundColor = UIColor.label.withAlphaComponent(0.08)
        disc.layer.cornerRadius = buttonSide * 0.42
        disc.isUserInteractionEnabled = false
        let glyph = UIImageView(image: UIImage(systemName: "ellipsis"))
        glyph.tintColor = .label
        glyph.contentMode = .center
        disc.addSubview(glyph)
        holder.addSubview(disc)
        disc.translatesAutoresizingMaskIntoConstraints = false
        glyph.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            disc.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            disc.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            disc.widthAnchor.constraint(equalToConstant: buttonSide * 0.84),
            disc.heightAnchor.constraint(equalToConstant: buttonSide * 0.84),
            glyph.centerXAnchor.constraint(equalTo: disc.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: disc.centerYAnchor),
        ])
        holder.accessibilityLabel = "More reactions"
        holder.isAccessibilityElement = true
        return holder
    }

    // MARK: focus / select (from the overlay's streamed finger AND our own press)

    private func index(at point: CGPoint) -> Int? {
        // A little vertical grace: the finger sliding just above the bar still focuses (the bar
        // floats above the message, fingers overshoot upward).
        let grace = bounds.insetBy(dx: 0, dy: -18)
        guard grace.contains(point) else { return nil }
        let inStack = convert(point, to: stack)
        for (i, holder) in holders.enumerated() where holder.frame.insetBy(dx: 0, dy: -18).contains(inStack) {
            return i
        }
        return nil
    }

    func updateFocus(at point: CGPoint) { focusedIndex = index(at: point) }
    func clearFocus() { focusedIndex = nil }

    /// Returns true when the lift selected an emoji (or the more button).
    @discardableResult
    func selectFocused(at point: CGPoint) -> Bool {
        defer { clearFocus() }
        guard let i = index(at: point) else { return false }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if i == holders.count - 1 {
            onSelect?(.more)
        } else {
            let emoji = config.emojis[i]
            // Lifting on the already-selected emoji REMOVES the reaction — .emoji(nil).
            onSelect?(.emoji(emoji == config.selected ? nil : emoji))
        }
        return true
    }

    @objc private func pressRecognized(_ g: UILongPressGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began, .changed: updateFocus(at: p)
        case .ended: selectFocused(at: p)
        default: clearFocus()
        }
    }

    // MARK: presentation

    func playPresentation() {
        var delay: TimeInterval = 0
        for holder in holders {
            holder.alpha = 0
            holder.transform = CGAffineTransform(translationX: 0, y: 24)
            UIView.animate(withDuration: 0.2, delay: delay, options: .curveEaseIn) {
                holder.transform = .identity
                holder.alpha = 1
            }
            delay += 0.01
        }
    }

    func playDismissal(duration: TimeInterval) {
        UIView.animate(withDuration: duration) { self.alpha = 0 }
    }
}
