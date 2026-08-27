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

/// The root of the menu's own window. It exists because a `UIWindow` needs a root view controller to
/// lay out and to be handed a safe area, and for no other reason: it draws nothing, it presents
/// nothing, and the overlay covers it edge to edge.
///
/// ⚠️ IT DELIBERATELY DOES NOT OVERRIDE THE STATUS BAR OR THE HOME INDICATOR. UIKit takes both from
/// the KEY window's root controller, this window is never key, and answering those questions here
/// would be a way to accidentally change the chrome of a screen that is otherwise untouched.
final class CMOverlayHost: UIViewController {
    override func loadView() {
        let v = UIView()
        v.backgroundColor = .clear
        view = v
    }
}

/// One presentation = one overlay instance, added directly to a window (the reference app adds their
/// controller's view the same way). Owns blur, dismiss catcher, preview snapshot, bar and card.
final class CMOverlay: UIView {

    /// WHOSE ANIMATION THIS MENU OPENS AND CLOSES WITH.
    ///
    /// The chat's long-press menu runs the .launched case's numbers and all, and he has judged it already — it does
    /// not change. The STORY ROW's runs the .fromRest case's, on his 2026-08-08 order ("make it like the reference app…
    /// dont chnage my design just Long pres how to work long press and Close both"). The design is
    /// untouched either way; this is only what moves and how long it takes.
    ///
    /// **Read out of the reference app's own source, not guessed** — the reference implementation
    /// (the context-menu presentation node backing the .fromRest motion):
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
    enum Motion { case launched, fromRest }

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
    private var openDuration: TimeInterval { motion == .fromRest ? 0.42 : springDuration }
    private var openDamping: CGFloat { motion == .fromRest ? 0.775 : springDamping }
    /// The .fromRest case's springs start from rest; the .launched case's are launched with velocity.
    private var openVelocity: CGFloat { motion == .fromRest ? 0 : 1.0 }
    /// The .fromRest case grows the menu out of nothing, the .launched case out of a fifth of itself.
    private var cardMinScale: CGFloat { motion == .fromRest ? 0.01 : 0.2 }

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
         motion: Motion = .launched,
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
                // ⛔ GIVE THE LEVEL BACK BEFORE THE SHEET ARRIVES. The picker is presented by the
                // SwiftUI shell, which means it comes up inside the APP's window — so a menu sitting
                // in a window above the keyboard's would sit above the sheet too, and the picker
                // would open behind the blur it is supposed to open over. Stepping back into the app
                // window restores the exact stacking this hand-off has always had.
                self.returnToAppWindow()
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

    /// ⛔ ASK FOR A WINDOW OF OUR OWN, ABOVE THE KEYBOARD'S. Set by the chat before `present` when the
    /// keys are up. Off by default, so every caller that opens a menu with no keyboard — the story
    /// row — keeps the exact path it has today.
    ///
    /// THE PROBLEM IT SOLVES. The keyboard is not drawn by us and it is not in our view hierarchy: it
    /// is a window of its own, at a level far above the app's, and the system composites it over
    /// everything in ours. An overlay added as a subview of the app's window is therefore UNDERNEATH
    /// the keys no matter what we do to its z-position, its layer, or its order among siblings — his
    /// screenshot, with the menu card behind the keys.
    ///
    /// WHAT THE REFERENCE DOES, and it is the same answer in both apps he has pointed at: the menu is
    /// not a view in the conversation at all, it is its own presentation in its own window, and the
    /// window sits above the keyboard's. That is why their keyboard stays up, stays visible, and ends
    /// up UNDER the menu's blur rather than over the menu.
    ///
    /// ⚠️ AND IT IS NEVER MADE KEY. That is the whole reason this works without touching the
    /// keyboard: `makeKeyAndVisible` would move key status away from the app's window, the field
    /// there would lose the first responder, and the keys would go down — which is the very thing
    /// being fixed. A window only needs `isHidden = false` to be shown and to receive touches; key
    /// status governs where keyboard INPUT is routed, and we want that left exactly where it is.
    var presentsAboveKeyboard = false

    /// The window we made, if we made one. Held until teardown; see `removeFromSuperview`.
    private var hostWindow: UIWindow?
    /// The app's window, kept so the overlay can step back down into it — see `returnToAppWindow`.
    private weak var presentingWindow: UIWindow?

    /// ⚠️ DIAGNOSTIC ONLY — OUT BEFORE THIS SHIPS. "Long-press with the keyboard open and the menu
    /// comes up behind the keys."
    ///
    /// The level this window is published at is computed by scanning what is on screen, and build 707
    /// proved that scan finds nothing useful — the menu landed at about two thousand, under a keyboard
    /// somewhere near ten million. The obvious repair is to write ten million down as a floor, and
    /// that is a number out of my head rather than off this device. So before repairing it, print
    /// every window the app can actually see, with its class and its level, at the instant the menu
    /// is presented. Whatever the keyboard's window turns out to be — enumerable or not, and at what
    /// level — the fix follows from the print rather than from a constant I remember.
    private static func probeWindowLevels(_ tag: String) {
        for s in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for w in s.windows {
                print("[MPROBE \(tag)]",
                      "class=\(type(of: w))",
                      "level=\(w.windowLevel.rawValue)",
                      "hidden=\(w.isHidden)",
                      "key=\(w.isKeyWindow)",
                      "h=\(Int(w.bounds.height))")
            }
        }
    }

    func present(in window: UIWindow, startAtSqueeze: Bool) {
        CMOverlay.current = self
        presentingWindow = window
        CMOverlay.probeWindowLevels("present aboveKeyboard=\(presentsAboveKeyboard)")
        let host: UIView
        if presentsAboveKeyboard, let own = CMOverlay.makeWindowAboveKeyboard(over: window) {
            hostWindow = own
            host = own.rootViewController?.view ?? own
        } else {
            host = window
        }
        // The source rectangle was measured in the app window, and our window is laid over it edge
        // to edge, so the two coordinate spaces are the same one. Nothing needs converting.
        frame = host.bounds
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(self)

        blurView.frame = bounds
        dismissCatcher.frame = bounds

        let frames = computeFrames(in: bounds)
        // Everything starts where the real bubble is; the spring carries it to the computed place.
        previewView.frame = sourceFrame
        // THE .fromRest CASE'S LIFT DOES NOT SCALE. Its extracted content animates `position` and nothing
        // else; the squeeze belongs to the press gesture, before the menu exists. Releasing a 0.95
        // squeeze here with no squeeze before it is a card that pops BIGGER under the finger, which
        // is not what its story row does.
        if startAtSqueeze, motion == .launched {
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

        // ⛔ THE BLUR IS BUILT FULLY FORMED AND FADED IN BY ALPHA. IT IS NOT INTERPOLATED.
        //
        // Three attempts at one symptom, so the reasoning is written out rather than the answer.
        //
        // Round 1 animated `blurView.effect` from nil in the same runloop turn as `addSubview`, and
        // it popped: a `UIVisualEffectView` can only interpolate an effect change if it has already
        // rendered the effect it is coming FROM, and with no committed frame there is nothing to
        // interpolate. A runloop hop fixed the pop.
        //
        // Round 2 fixed a WHITE flash by stripping UIKit's tint plate inside the animation block
        // instead of its completion. It did not work, and he reported the flash again on 629. The
        // reason is the same fact as round 1 seen from the other side: setting `effect` inside a
        // `UIView.animate` block hands it to the animation machinery, so the effect view's children
        // are not built by the time the very next line runs. `layoutIfNeeded` had nothing to lay out
        // and the strip found nothing to strip — leaving the completion, 0.2s later, as the first
        // moment it took, which is the whole visible flash.
        //
        // Round 3 stops interpolating the effect at all, which is what the reference does anyway and
        // what the note at the bottom of this block always said: their backdrop "deliberately does
        // NOT spring while the menu does — ContextSourceContainer.swift:485 animates the whole thing
        // as one alpha". So the blur is applied NOW, at alpha 0, where nobody can see it; the tint
        // plate is stripped NOW, synchronously, with the children genuinely built because no
        // animation is holding them; and the only thing that animates is alpha, which cannot flash
        // because every frame it fades in is already the finished, stripped blur.
        //
        // This also retires the pop reasoning entirely. There is no from-effect to render first when
        // nothing is interpolating.
        //
        // ⛔ THEIR BACKDROP, READ FROM SOURCE (2026-08-21, five readers over the reference app's source).
        // His report was "the brightness effect looks like a blur", and he was right about the
        // symptom for a reason nobody had guessed: OURS WAS LIGHTENING THE SCREEN.
        //
        // ⚠️ THE TINT WAS `white 0.2` IN DARK MODE — white, at 20%, laid over a `.regular` blur.
        // A milky veil. Theirs is `UIColor(rgb: 0x000000, alpha: 0.6)` — BLACK at sixty percent
        // (DefaultDarkPresentationTheme.swift:767, and the same literal in the tinted dark theme).
        // That is why theirs reads as a dim and ours reads as fog: opposite ends of the scale.
        //
        // ⚠️ AND THE BLUR STYLE IS `.light` IN BOTH THEMES, which looks wrong written down and is
        // right on screen — NavigationBackgroundView.swift:69, no branch on appearance anywhere. The
        // darkness is the tint's job; the blur only softens what is behind it. `.regular` resolves
        // dark-on-dark and fights the tint for the same job.
        //
        // Light theme is a very slightly blue black at only 20% (0x000a26, DefaultDay:1044) — in
        // light mode most of the separation comes from the blur desaturating the page, not from the
        // tint.
        blurView.alpha = 0
        blurView.effect = UIBlurEffect(style: .light)
        blurView.backgroundColor = UIColor { tc in
            tc.userInterfaceStyle == .dark ? UIColor(white: 0, alpha: 0.6)
                                           : UIColor(red: 0, green: 0.039, blue: 0.149, alpha: 0.2)
        }
        layoutIfNeeded()
        stripSystemTint()

        // 0.2s, the reference's `animationDuration / 2.0`, plain ease-in-out.
        UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseInOut]) {
            self.blurView.alpha = 1
            self.setPreviewShadow(true)
        } completion: { _ in
            // Idempotent belt. If some future iOS defers the effect view's children past the
            // synchronous layout above, this is the fallback — and unlike round 2 it is no longer
            // load-bearing, because the blur it would be correcting has been at full alpha only
            // since this completion fired.
            self.stripSystemTint()
        }

        // THE .fromRest CASE TAKES THE MENU'S ALPHA OUT OF THE SPRING. It is opaque in 0.05 and its whole
        // entrance is the growth from 0.01; ours faded across the full spring, so the menu arrived by
        // materialising rather than by opening. The .launched case keeps its fade, inside the spring below.
        if motion == .fromRest {
            UIView.animate(withDuration: 0.05) { self.card.alpha = 1 }
        }

        UIView.animate(withDuration: openDuration, delay: 0,
                       usingSpringWithDamping: openDamping, initialSpringVelocity: openVelocity,
                       options: [.curveEaseInOut, .beginFromCurrentState]) {
            self.previewView.transform = .identity
            self.previewView.frame = frames.preview
            self.card.transform = .identity
            if self.motion == .launched { self.card.alpha = 1 }
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

    /// ⛔ TAKE UIKIT'S OWN LIGHT WASH OFF A `.light` BLUR.
    ///
    /// The darkness in this backdrop is OURS — the black `backgroundColor` set alongside the effect.
    /// The system blur is only there to soften what is behind it, and a `.light` blur ships with a
    /// tint plate and a stack of backdrop filters that between them lay a pale wash over everything.
    /// Left in place, that wash and our black cancel toward grey, which is the fog the whole backdrop
    /// rewrite was about (NavigationBackgroundView.swift:71-99 cuts exactly the same two things).
    ///
    /// Idempotent on purpose: it is called inside the entrance animation AND from its completion, so
    /// it must be safe to run on an already-stripped view. Both operations are simple assignments to
    /// the state they should already hold, so a second run is a no-op.
    ///
    /// ⚠️ EVERYTHING HERE IS MATCHED BY CLASS AND FILTER NAME, WHICH IS PRIVATE SHAPE. It degrades
    /// the right way: if a future iOS renames either, the loops simply match nothing and the backdrop
    /// falls back to looking as it did before this existed. Nothing throws and nothing is forced.
    private func stripSystemTint() {
        for sub in blurView.subviews
        where String(describing: type(of: sub)).contains("VisualEffectSubview") {
            sub.isHidden = true
        }
        if let backdrop = blurView.subviews.first?.layer,
           let filters = backdrop.filters as? [NSObject] {
            backdrop.filters = filters.filter {
                let n = String(describing: $0)
                return n.contains("gaussianBlur") || n.contains("colorSaturate")
            }
        }
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

        // THE .fromRest CASE'S CLOSE, WHOLE. One animation, 0.2s, plain ease-in-out, nothing springing: the
        // card slides home, the menu shrinks to nothing and fades, the blur goes, and they all land
        // together. The reference implementation's close runs at `duration = 0.2` with `easeInEaseOut` and every layer
        // driven by `layer.animate(...)`, not `animateSpring`.
        //
        // ⚠️ THE ABSENCE OF THE SPRING IS THE POINT, not the shorter clock. A spring returning home
        // overshoots the slot and settles back into it, and on a card landing in a row of other
        // cards that reads as the thing bouncing — his report. Do not "improve" this by giving it a
        // gentle damping; there is no spring in the .fromRest case's close at all.
        if motion == .fromRest {
            UIView.animate(withDuration: 0.2, delay: 0,
                           options: [.curveEaseInOut, .beginFromCurrentState]) {
                // ⚠️ ALPHA, MATCHING THE WAY IT CAME IN. Setting `effect = nil` inside an animation
                // is the same trap the entrance fell into three times: it hands the change to the
                // animation machinery, which rebuilds the effect view's children — and children
                // rebuilt here arrive WITH UIKit's tint plate restored, so the blur can flash pale
                // on its way out for exactly the reason it used to flash pale on its way in. Fading
                // the alpha of an already-stripped blur cannot do that.
                self.blurView.alpha = 0
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
            // Alpha, for the same reason as the .fromRest close above — see the note there.
            self.blurView.alpha = 0
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

    /// ⛔ THE WINDOW GOES WHEN THE VIEW GOES. Three separate animation completions call
    /// `removeFromSuperview`, so the teardown hangs off the one thing all three do rather than being
    /// copied into each of them and eventually missed by a fourth. A window left behind at this level
    /// would sit invisibly over the keyboard and swallow every touch meant for the keys.
    override func removeFromSuperview() {
        super.removeFromSuperview()
        guard let own = hostWindow else { return }
        hostWindow = nil          // break the cycle first: the root view held us, we held the window
        own.isHidden = true
        own.rootViewController = nil
        own.windowScene = nil
    }

    /// Move back into the app's window, unchanged and mid-presentation, and give up the window we
    /// took. The overlay keeps its frame because the two windows are laid over each other edge to
    /// edge, so nothing about the menu on screen moves.
    ///
    /// ⚠️ `hostWindow` IS CLEARED FIRST, and that ordering is load-bearing: re-parenting a view runs
    /// `removeFromSuperview`, whose override tears the window down, and it must find nothing left to
    /// do rather than pull the window out from under the move.
    private func returnToAppWindow() {
        guard let own = hostWindow, let app = presentingWindow else { return }
        hostWindow = nil
        frame = app.bounds
        app.addSubview(self)
        own.isHidden = true
        own.rootViewController = nil
        own.windowScene = nil
    }

    /// A window one level above the highest one currently on screen — which, while the keys are up,
    /// is the keyboard's.
    ///
    /// ⚠️ THE LEVEL IS MEASURED, NOT WRITTEN DOWN. The keyboard's own level is an implementation
    /// detail of UIKit that has moved between releases, and this app has already spent one whole
    /// build on an iOS 26/27 difference in keyboard plumbing. Reading what is actually on screen and
    /// going one above it needs no such constant and cannot go stale. The floor keeps us above the
    /// alert level even in the odd case where the scene reports nothing useful.
    private static func makeWindowAboveKeyboard(over host: UIWindow) -> UIWindow? {
        guard let scene = host.windowScene else { return nil }
        var top = max(host.windowLevel.rawValue, UIWindow.Level.alert.rawValue)
        for s in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for w in s.windows where !w.isHidden { top = max(top, w.windowLevel.rawValue) }
        }
        let own = UIWindow(windowScene: scene)
        own.frame = host.frame
        own.backgroundColor = .clear
        own.isOpaque = false
        own.rootViewController = CMOverlayHost()
        own.windowLevel = UIWindow.Level(rawValue: top + 1)
        own.isHidden = false   // ⛔ NOT `makeKeyAndVisible` — see `presentsAboveKeyboard`
        print("[MPROBE chose] scanTop=\(top) ourLevel=\(own.windowLevel.rawValue)")   // ⚠️ DIAGNOSTIC ONLY
        CMOverlay.probeWindowLevels("after")
        return own
    }

    // MARK: The layout math (the reference app's targetPreviewFrame, simplified to our vertical stack)

    /// bar (exterior top, gap 12) · preview · menu (exterior bottom, gap 12), all aligned to the
    /// bubble's own horizontal edge. Overflow bottom → shift up; overflow top → shift down; still
    /// too tall → scale the preview down (anchored to its aligned edge) and recompute.
    /// ⛔ THE MENU USES THE WHOLE SCREEN, KEYBOARD OR NO KEYBOARD. This used to take a
    /// `keyboardInset` and squeeze the whole stack into the strip above the keys, and the owner
    /// turned that down by name: the menu is an OVERLAY, the keys stay up and stay visible
    /// underneath it, and the blur goes over them. Squeezing produced a menu that opened in a
    /// different place depending on whether the keyboard happened to be up, which is exactly the
    /// behaviour difference he was pointing at. Where the menu actually gets the pixels to draw over
    /// the keys is `presentsAboveKeyboard` — a window problem, solved in a window, not here.
    private func computeFrames(in bounds: CGRect) -> (preview: CGRect, bar: CGRect?, menu: CGRect) {
        let pad: CGFloat = 8
        let content = bounds.inset(by: UIEdgeInsets(
            top: max(safeAreaInsets.top, pad), left: max(safeAreaInsets.left, pad),
            bottom: max(safeAreaInsets.bottom, pad),
            right: max(safeAreaInsets.right, pad)))

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
