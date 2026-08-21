import SwiftUI
import UIKit

// THE CUSTOM LONG-PRESS MENU — the reference app's architecture, our code. EXPERIMENT BRANCH ONLY until the
// owner's device verdict (his deal 2026-07-30: ships alone, two TestFlights or we give up).
//
// Read 2026-07-30 from the reference implementation's CustomContextMenus/* (see kulan-context-menu-study memory).
// The whole idea in one line: Apple's menu is never involved. We SNAPSHOT the pressed bubble, hide
// the real one, blur the whole screen in our own overlay, and place bar · message · menu ourselves,
// shrinking the snapshot when a tall message would not fit. Every recognizer involved lives on THIS
// overlay — nothing here touches the chat list's tap system (the convicted a1b2c7e defect cannot
// exist in this shape).
//
// the reference app's numbers, kept: press 0.2s · squeeze 0.95 over 0.2s · present spring 0.4s damping 0.8
// v0 1.0 · blur-in 0.2s · menu scale-in from 0.2 anchored at the bubble corner · finger dead zone
// 40pt · gaps 12pt · content padding = safe area clamped to ≥8pt · menu width 250 · min preview
// scale (ours) 0.35 — the reference app allows 0.1 but a chat bubble smaller than a third reads as broken.

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
/// `bottomOverhang`: the reaction badge hangs 13pt BELOW the bubble's bottom edge, and the lift
/// crops the row snapshot to this rect — without the overhang the badge came up sliced (owner's
/// 417 screenshot, heart cut at the bubble edge). The extension is transparent row space except
/// the badge itself, and the menu card lays out below the EXTENDED rect, clearing the badge too.
struct CMBubbleRectReporter: ViewModifier {
    let id: String
    let radius: CGFloat
    var bottomOverhang: CGFloat = 0
    func body(content: Content) -> some View {
        content.background(
            GeometryReader { g in
                Color.clear
                    .onChange(of: g.frame(in: .global), initial: true) { _, f in publish(f) }
                    // A reaction ARRIVING does not move the bubble — only the overhang changes — so
                    // the frame observer above never fires and the rect stayed at the pre-reaction
                    // height, which is why the lift sliced a badge that had just appeared.
                    .onChange(of: bottomOverhang) { _, _ in publish(g.frame(in: .global)) }
            }
        )
    }

    private func publish(_ f: CGRect) {
        var r = f
        r.size.height += bottomOverhang
        CMBubbleRects.capture(id, r, radius: radius)
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

/// One presentation = one overlay instance, added directly to the window (the reference app adds their
/// controller's view the same way). Owns blur, dismiss catcher, preview snapshot, bar and card.
final class CMOverlay: UIView {

    /// WHOSE ANIMATION THIS MENU OPENS AND CLOSES WITH.
    ///
    /// The chat's long-press menu runs the .signal case's numbers and all, and he has judged it already — it does
    /// not change. The STORY ROW's runs the .telegram case's, on his 2026-08-08 order ("make it like the reference app…
    /// dont chnage my design just Long pres how to work long press and Close both"). The design is
    /// untouched either way; this is only what moves and how long it takes.
    ///
    /// **Read out of the reference app's own source, not guessed** — the reference implementation
    /// (the context-menu presentation node backing the .telegram motion):
    ///
    /// - **IN** `duration 0.42`, `CASpringAnimation(mass 5, stiffness 900, damping 104)`, from REST.
    ///   Critical damping there is `2·√(900·5) = 134.16`, so their ratio is `104/134.16 = 0.775` —
    ///   which is what `usingSpringWithDamping` takes. The extracted content only ever animates
    ///   `position.x` / `position.y`: **it does not scale on the way in.** The actions menu springs
    ///   `transform.scale` from `0.01` and takes its alpha over `0.05`, i.e. it is opaque almost at
    ///   once and its whole entrance is the growth.
    /// - **OUT** `duration 0.2`, plain `easeInEaseOut`, **no spring anywhere**. The content slides
    ///   home, the menu shrinks to `0.01` and fades on the same clock, and that is all of it.
    ///
    /// The close is where ours was furthest away: a 0.4s spring at damping 0.8 takes twice as long
    /// AND overshoots on the way back. That is the wobble he reported.
    enum Motion { case signal, telegram }

    private let motion: Motion

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
    // the reference app allows 0.1 and that is why their giant message fits with the whole menu below it —
    // 0.35 "for readability" was too timid, a monster message needs to become a small picture.
    private let minPreviewScale: CGFloat = 0.1
    private let deadZoneRadius: CGFloat = 40

    // The two openings are near twins — 0.42 against 0.4, ratio 0.775 against 0.8 — which is why the
    // way IN only needed the menu's own numbers moved. The way OUT is a different animation entirely.
    private var openDuration: TimeInterval { motion == .telegram ? 0.42 : springDuration }
    private var openDamping: CGFloat { motion == .telegram ? 0.775 : springDamping }
    /// The .telegram case's springs start from rest; the .signal case's are launched with velocity.
    private var openVelocity: CGFloat { motion == .telegram ? 0 : 1.0 }
    /// The .telegram case grows the menu out of nothing, the .signal case out of a fifth of itself.
    private var cardMinScale: CGFloat { motion == .telegram ? 0.01 : 0.2 }

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
         motion: Motion = .signal,
         onDismissed: @escaping () -> Void) {
        self.motion = motion
        self.previewView = previewView
        self.sourceFrame = sourceFrame
        self.alignRight = alignRight
        self.card = CMActionsCard(actions: actions)
        self.bar = react.map { CMReactionBar(config: $0) }
        self.onDismissed = onDismissed
        super.init(frame: .zero)

        addSubview(blurView)
        // Full-screen invisible catcher UNDER the preview: a plain tap anywhere that no accessory
        // claims dismisses the menu. Also the accessibility escape (the reference app does exactly this).
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
        // (shadow is driven by setPreviewShadow, which no-ops on iOS 26 the way the reference app's does)
        addSubview(card)
        if let bar { addSubview(bar) }

        card.onSelect = { [weak self] action in
            // Dismiss FIRST, run the action after — an action that mutates the list (Select, Delete)
            // must never destroy the row while the return spring still needs its frame.
            self?.dismiss(animated: true) { action.handler() }
        }
        bar?.onSelect = { [weak self] selection in
            guard let self, let react else { return }
            // the reference app's model (ContextMenuController.showEmojiSheet): the "…" full picker presents
            // OVER the still-open menu — blur and lifted message stay behind the sheet. Only a
            // direct emoji pick dismisses here; for .more the sheet's resolution (pick or cancel)
            // dismisses the overlay through `current`.
            if case .more = selection {
                react.onPick(selection)
            } else {
                self.dismiss(animated: true) { react.onPick(selection) }
            }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The one live overlay (weak — presentation adds it to the window, dismissal removes it).
    /// The full-picker sheet resolves AFTER a .more hand-off and needs a handle back to this.
    private(set) static weak var current: CMOverlay?

    // MARK: Present

    func present(in window: UIWindow, startAtSqueeze: Bool) {
        CMOverlay.current = self
        frame = window.bounds
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(self)

        blurView.frame = bounds
        dismissCatcher.frame = bounds

        let frames = computeFrames(in: bounds)
        // Everything starts where the real bubble is; the spring carries it to the computed place.
        previewView.frame = sourceFrame
        // THE .TELEGRAM CASE'S LIFT DOES NOT SCALE. Its extracted content animates `position` and nothing
        // else; the squeeze belongs to the press gesture, before the menu exists. Releasing a 0.95
        // squeeze here with no squeeze before it is a card that pops BIGGER under the finger, which
        // is not what its story row does.
        if startAtSqueeze, motion == .signal {
            previewView.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
        }

        card.sizeToFit()
        card.frame = frames.menu
        // The card grows out of the bubble's corner (the reference app sets the layer anchor to the aligned
        // corner and scales from 0.2). Setting anchorPoint moves the frame, so re-assert it after.
        let cardFrame = card.frame
        card.layer.anchorPoint = CGPoint(x: alignRight ? 1 : 0, y: 0)
        card.frame = cardFrame
        card.transform = CGAffineTransform(scaleX: cardMinScale, y: cardMinScale)
        card.alpha = 0
        // Ride the preview's travel: start displaced by the same delta the preview will move.
        let travel = frames.preview.minY - sourceFrame.minY
        card.frame.origin.y -= travel

        if let bar, let barFrame = frames.bar {
            bar.frame = barFrame
            bar.alpha = 0
        }

        // ⚠️ ONE RUNLOOP LATER, AND THAT IS THE WHOLE FIX. His 2026-08-08 report: the blur "is coming
        // one time feeling like pop", not gradually.
        //
        // The numbers here were never wrong — they are the reference app's, `animationDuration / 2.0`
        // = 0.2, plain ease-in-out, and their code animates `blurView.effect` in exactly this way.
        // What differs is WHEN. Theirs runs in `viewDidAppear`, so by the time it starts, their view
        // is in the window, laid out, and has already rendered a frame with `effect == nil`. Ours ran
        // in the same runloop turn as `addSubview`, when the blur view had never been drawn at all —
        // and a `UIVisualEffectView` can only interpolate an effect change if it has already
        // rendered the effect it is coming FROM. With no starting frame there is nothing to
        // interpolate, so UIKit applies the blur in one step. That is the pop.
        //
        // `layoutIfNeeded` puts the geometry in place now; the hop to the next turn is what lets a
        // frame be committed at effect-nil first. This is the same moment `viewDidAppear` would be,
        // reached the way a view added straight to the window has to reach it.
        layoutIfNeeded()
        DispatchQueue.main.async { [weak self] in
            // Dismissed inside that one turn (a press cancelled immediately): there is nothing left
            // to blur and turning it on now would light up an overlay on its way out.
            guard let self, !self.dismissing, self.superview != nil else { return }
            // ⛔ THEIR BACKDROP, READ FROM SOURCE (2026-08-21, five readers over Telegram-iOS master).
            // His report was "the brightness effect looks like a blur", and he was right about the
            // symptom for a reason nobody had guessed: OURS WAS LIGHTENING THE SCREEN.
            //
            // ⚠️ THE TINT WAS `white 0.2` IN DARK MODE — white, at 20%, laid over a `.regular` blur.
            // A milky veil. Theirs is `UIColor(rgb: 0x000000, alpha: 0.6)` — BLACK at sixty percent
            // (DefaultDarkPresentationTheme.swift:767, and the same literal in the tinted dark theme).
            // That is why theirs reads as a dim and ours reads as fog: opposite ends of the scale.
            //
            // ⚠️ AND THE BLUR STYLE IS `.light` IN BOTH THEMES, which looks wrong written down and is
            // right on screen — NavigationBackgroundView.swift:69, no branch on appearance anywhere.
            // The darkness is the tint's job; the blur only softens what is behind it. `.regular`
            // resolves dark-on-dark and fights the tint for the same job.
            //
            // Light theme is a very slightly blue black at only 20% (0x000a26, DefaultDay:1044) —
            // in light mode most of the separation comes from the blur desaturating the page, not
            // from the tint.
            //
            // 0.2s, and their own note is that the backdrop deliberately does NOT spring while the
            // menu does — ContextSourceContainer.swift:485 animates the whole thing as one alpha.
            UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseInOut]) {
                self.blurView.effect = UIBlurEffect(style: .light)
                self.blurView.backgroundColor = UIColor { tc in
                    tc.userInterfaceStyle == .dark ? UIColor(white: 0, alpha: 0.6)
                                                   : UIColor(red: 0, green: 0.039, blue: 0.149, alpha: 0.2)
                }
                self.setPreviewShadow(true)
            } completion: { _ in
                // ⚠️ AFTER THE EFFECT EXISTS, NEVER BEFORE. UIKit builds the effect view's children
                // when the effect is set, so there is nothing to strip until this point.
                //
                // Their `.light` blur only stops looking milky once UIKit's own tint plate is taken
                // off it and the backdrop's filter list is cut to the blur itself
                // (NavigationBackgroundView.swift:71-99). Without this the system lays its own light
                // wash under our black and the two cancel out — which is the same fog by another
                // road.
                for sub in self.blurView.subviews where String(describing: type(of: sub)).contains("VisualEffectSubview") {
                    sub.isHidden = true
                }
                if let backdrop = self.blurView.subviews.first?.layer,
                   let filters = backdrop.filters as? [NSObject] {
                    backdrop.filters = filters.filter {
                        let n = String(describing: $0)
                        return n.contains("gaussianBlur") || n.contains("colorSaturate")
                    }
                }
            }
        }

        // THE .TELEGRAM CASE TAKES THE MENU'S ALPHA OUT OF THE SPRING. It is opaque in 0.05 and its whole
        // entrance is the growth from 0.01; ours faded across the full spring, so the menu arrived by
        // materialising rather than by opening. The .signal case keeps its fade, inside the spring below.
        if motion == .telegram {
            UIView.animate(withDuration: 0.05) { self.card.alpha = 1 }
        }

        UIView.animate(withDuration: openDuration, delay: 0,
                       usingSpringWithDamping: openDamping, initialSpringVelocity: openVelocity,
                       options: [.curveEaseInOut, .beginFromCurrentState]) {
            self.previewView.transform = .identity
            self.previewView.frame = frames.preview
            self.card.transform = .identity
            if self.motion == .signal { self.card.alpha = 1 }
            self.card.frame = frames.menu
        }

        // The bar pops in slightly after the shift begins (the reference app delays 0.1s when the preview
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

    /// the reference app's `previewShadowVisible`: the lifted message drops a shadow on older systems, and none
    /// at all on iOS 26 where the glass already separates it from the blur. Their setter returns
    /// early under `if #available(iOS 26, *)`, so the shadow stays at the 0 it was built with.
    private func setPreviewShadow(_ visible: Bool) {
        if #available(iOS 26.0, *) { return }
        previewView.layer.shadowOpacity = visible ? 0.3 : 0
    }

    // MARK: Dismiss

    /// Fired the instant a dismissal STARTS, before the return spring — for a caller whose source
    /// cannot be un-hidden synchronously.
    ///
    /// The chat unhides its real bubble in `onDismissed`, and that is exactly right there: it is a
    /// `UIView.isHidden` write in the same runloop as `removeFromSuperview`, so the two land in one
    /// transaction and nothing can blink between them. A SwiftUI source cannot do that — its reveal
    /// is a published change that paints on the NEXT pass, which would leave one frame with the
    /// lift already gone and the card not yet back. Revealing as the return spring begins costs
    /// nothing, because the preview is on its way to that exact rectangle.
    var onWillDismiss: (() -> Void)?

    /// WHERE THE LIFT LANDS, asked at the moment it starts going home rather than remembered from
    /// the press. nil, or a nil answer, keeps the rectangle it came from.
    ///
    /// The chat does not need this: a bubble is exactly where it was. The story row does. Its card is
    /// DIPPED to 0.92 under the held finger, so the rectangle photographed at `.began` is 8% smaller
    /// than the card the finger has since let go of — and the copy would shrink past the real card's
    /// size to land on a rectangle that no longer exists, revealing a bigger card underneath at the
    /// last instant. Asking again costs one hit-test and lands on the card that is actually there.
    var liveSourceFrame: (() -> CGRect?)?

    func dismiss(animated: Bool, then: (() -> Void)? = nil) {
        guard !dismissing else { return }
        dismissing = true
        onWillDismiss?()
        guard animated else {
            removeFromSuperview()
            onDismissed(); then?()
            return
        }
        bar?.playDismissal(duration: 0.2)
        let home = liveSourceFrame?() ?? sourceFrame

        // THE .TELEGRAM CASE'S CLOSE, WHOLE. One animation, 0.2s, plain ease-in-out, nothing springing: the
        // card slides home, the menu shrinks to nothing and fades, the blur goes, and they all land
        // together. The reference implementation's close runs at `duration = 0.2` with `easeInEaseOut` and every layer
        // driven by `layer.animate(...)`, not `animateSpring`.
        //
        // ⚠️ THE ABSENCE OF THE SPRING IS THE POINT, not the shorter clock. A spring returning home
        // overshoots the slot and settles back into it, and on a card landing in a row of other
        // cards that reads as the thing bouncing — his report. Do not "improve" this by giving it a
        // gentle damping; there is no spring in the .telegram case's close at all.
        if motion == .telegram {
            UIView.animate(withDuration: 0.2, delay: 0,
                           options: [.curveEaseInOut, .beginFromCurrentState]) {
                self.blurView.effect = nil
                self.blurView.backgroundColor = nil
                self.setPreviewShadow(false)
                self.previewView.frame = home
                self.card.transform = CGAffineTransform(scaleX: 0.01, y: 0.01)
                self.card.alpha = 0
                self.bar?.alpha = 0
            } completion: { _ in
                self.removeFromSuperview()
                self.onDismissed()
                then?()
            }
            return
        }

        // the reference app runs the background off in its OWN plain animation, not on the spring that carries
        // the message home. A spring overshoots and settles, and driving a blur with it makes the
        // background wobble back in; a flat ease-out over the full 0.4 is what actually reads as
        // the reference app. The shadow rides here too, exactly as their `previewShadowVisible = false` does.
        UIView.animate(withDuration: springDuration) {
            self.blurView.effect = nil
            self.blurView.backgroundColor = nil
            self.setPreviewShadow(false)
        }

        // Same 0.4, so both land together and this one still owns the teardown.
        UIView.animate(withDuration: springDuration, delay: 0,
                       usingSpringWithDamping: springDamping, initialSpringVelocity: 1.0,
                       options: [.curveEaseInOut, .beginFromCurrentState]) {
            self.previewView.frame = home
            self.card.transform = CGAffineTransform(scaleX: 0.2, y: 0.2)
            self.card.alpha = 0
            self.bar?.alpha = 0
        } completion: { _ in
            self.removeFromSuperview()
            self.onDismissed()
            then?()
        }
    }

    @objc private func dismissTapped() { dismiss(animated: true) }

    // MARK: The layout math (the reference app's targetPreviewFrame, simplified to our vertical stack)

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

        // Still too tall → the preview gives up the difference (the reference app scales the snapshot).
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

    // MARK: Continuous finger (the reference app's star feature)

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

    /// After the initiating press ends, later drags are ours (the reference app swaps in a local pan too).
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
/// Taps are a minimumPressDuration=0 long-press (the reference app's trick) so a row highlights the moment a
/// finger lands and selects when it lifts — a UITapGesture would only fire at the end.
final class CMActionsCard: UIView {

    var onSelect: ((CMAction) -> Void)?

    private let actions: [CMAction]
    private let backdrop: UIVisualEffectView
    private let scroll = UIScrollView()
    private var rows: [CMActionRow] = []

    // THE REFERENCE APP'S OWN CARD NUMBERS, read from the reference implementation — no measurements,
    // no rounding of our own. Row = body line (~22) + their verticalPadding 23. maxWidth 250,
    // corner 33 / vMargin 10 under the iOS 26 glass, 12 / 0 on the frosted fallback.
    // The ONE deliberate divergence stays ours: NO hairline separators (owner rejected them).
    private let rowHeight: CGFloat = 45
    private let cardWidth: CGFloat = 250
    private let verticalInset: CGFloat = {
        if #available(iOS 26.0, *) { return 10 } else { return 0 }
    }()
    private let corner: CGFloat = {
        if #available(iOS 26.0, *) { return 33 } else { return 12 }
    }()

    init(actions: [CMAction]) {
        self.actions = actions
        // LIQUID GLASS on iOS 26+, exactly what makes the reference app's card read as native there (the owner's
        // zoomed side-by-side); the frosted material is only the fallback for older systems.
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect(style: .regular)
            // the reference app's flag: the INTERACTIVE glass is the brighter smoky-gray material in the
            // owner's reference photo — plain .regular passed the dark wallpaper straight through.
            glass.isInteractive = true
            backdrop = UIVisualEffectView(effect: glass)
        } else {
            backdrop = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        }
        super.init(frame: .zero)

        layer.cornerRadius = corner
        layer.cornerCurve = .continuous
        layer.shadowRadius = 64
        layer.shadowOffset = CGSize(width: 0, height: 32)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.2

        backdrop.layer.cornerRadius = corner
        backdrop.layer.cornerCurve = .continuous
        backdrop.layer.masksToBounds = true
        addSubview(backdrop)
        backdrop.contentView.addSubview(scroll)
        scroll.showsVerticalScrollIndicator = false

        for action in actions {
            let row = CMActionRow(action: action)
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
            row.frame = CGRect(x: 0, y: verticalInset + CGFloat(i) * rowHeight, width: bounds.width, height: rowHeight)
        }
        scroll.contentSize = CGSize(width: bounds.width, height: CGFloat(rows.count) * rowHeight + verticalInset * 2)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        // Taller than the allowance → the card caps its height and the rows scroll inside it.
        let natural = CGFloat(rows.count) * rowHeight + verticalInset * 2
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
    private let highlight = UIView()
    // NO separator lines — the owner rejected them against the reference app's clean glass ("u added lines
    // thats i don't"). The rows read as one sheet; the highlight fill is the only row chrome.

    var isHighlighted: Bool = false {
        didSet { highlight.isHidden = !isHighlighted }
    }

    init(action: CMAction) {
        self.action = action
        super.init(frame: .zero)

        // the reference app's own highlight fill (their `.the reference app.secondaryFill`); the system token is the same
        // idea and adapts to light/dark on its own.
        highlight.backgroundColor = .secondarySystemFill
        highlight.isHidden = true
        addSubview(highlight)

        let color: UIColor = action.destructive ? .systemRed : .label
        title.text = action.title
        title.font = .preferredFont(forTextStyle: .body)
        title.adjustsFontSizeToFitWidth = true
        title.minimumScaleFactor = 0.7
        title.textColor = color
        addSubview(title)

        // An SF Symbol name, or one of the app's own assets when we have drawn our own glyph.
        icon.image = UIImage(systemName: action.icon)
            ?? UIImage(named: action.icon)?.withRenderingMode(.alwaysTemplate)
        icon.tintColor = color
        icon.contentMode = .scaleAspectFit
        addSubview(icon)

        isAccessibilityElement = true
        accessibilityLabel = action.title
        accessibilityTraits = .button
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        // HIGHLIGHT GEOMETRY, verbatim from the reference app's row (`isHighlighted` didSet): on iOS 26 the
        // fill is `bounds.insetBy(dx: 10, dy: 1)` with capsule corners, so it reads as a pill inset
        // from the card's edges; older systems fill the whole row square. Ours was full-bounds and
        // square everywhere, which is the edge-to-edge block in the owner's side-by-side.
        if #available(iOS 26.0, *) {
            highlight.frame = bounds.insetBy(dx: 10, dy: 1)
            highlight.layer.cornerRadius = highlight.bounds.height / 2   // = their .capsule()
            highlight.layer.cornerCurve = .continuous
        } else {
            highlight.frame = bounds
            highlight.layer.cornerRadius = 0
        }
        // the reference app's row metrics verbatim (ContextMenuActionsAccessory.ContextMenuActionRow): icon
        // LEADING, and both margin and icon size step up on iOS 26 the way theirs do.
        let margin: CGFloat
        let iconSize: CGFloat
        if #available(iOS 26.0, *) { margin = 24; iconSize = 24 } else { margin = 16; iconSize = 20 }
        let iconSpacing: CGFloat = 12
        icon.frame = CGRect(x: margin, y: (bounds.height - iconSize) / 2,
                            width: iconSize, height: iconSize)
        title.frame = CGRect(x: icon.frame.maxX + iconSpacing, y: 0,
                             width: bounds.width - icon.frame.maxX - iconSpacing - margin,
                             height: bounds.height)
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
        // Liquid glass on iOS 26+, same as the card and same as the reference app's bar there.
        if #available(iOS 26.0, *) {
            backdrop = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        } else {
            backdrop = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        }
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
