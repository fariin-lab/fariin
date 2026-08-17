//
//  StoryTraySheet.swift
//  A bottom tray of OUR OWN, edge to edge, for the story editor.
//
//  WHY THIS EXISTS. Owner, 2026-08-17, three times: "no space left and right". The sticker tray was
//  a system `.sheet` at a partial detent, and on iOS 26 that is presented as a FLOATING PANEL inset
//  from the screen on both sides — the gap he keeps circling. It is drawn by the presentation
//  controller, so nothing about the sheet's own background, corner radius or content can reach it;
//  `.presentationSizing(.page)` was the documented way to ask for the full-width presentation
//  instead, it shipped, and the gap survived. His answer was the one already written down as the
//  fallback: "you can Make custom sheet but same ui like now".
//
//  ⚠️ THE CONTENT IS NOT TOUCHED, AND THAT IS THE POINT. `StoryStickerSheet` is handed to this
//  container exactly as it was handed to `.sheet` — same search field, same pills, same grid, same
//  glass tab row, same black ground, same 80% height. This file replaces the PRESENTATION and
//  nothing else: the panel is pinned to both screen edges and the bottom, so there is no inset for
//  anybody to draw.
//
//  WHAT IT REPLACES, PIECE FOR PIECE, so the tray behaves as it did:
//    · `.presentationDetents([.fraction(0.8)])`  → `restHeight`, and the keyboard grows it to full
//      the way the `.large` detent used to (the Link and Location screens type).
//    · `.presentationDragIndicator(.visible)`    → `grabber`, drawn OVER the content at the top like
//      the system's, so it insets nothing and the search field keeps its own 16pt.
//    · `.presentationBackground(Color.black)`    → the panel's own black.
//    · the system's dim + tap-outside-to-close   → `dimView` and `handleTapOutside`.
//    · the system's drag-to-dismiss              → `handlePan`, which only begins in the top strip
//      so the sticker grid's own scrolling is never in competition with it.
//
//  The presentation itself is `.overFullScreen` with `animated: false`, which is this app's house
//  pattern for a screen we animate ourselves — see `StoryZoomPresenter`, written after build 481
//  died animating a system transition. Nothing private is touched here either.
//

import SwiftUI
import UIKit

@MainActor
enum StoryTrayPresenter {
    private static var container: StoryTrayContainerVC?

    static var isActive: Bool { container != nil }

    /// Put `content` up as a bottom tray. `onDismissed` fires for EVERY way out — the drag, the tap
    /// outside, and the programmatic close — so the caller's `isPresented` can be put back down
    /// without it having to know which one happened.
    static func present<Content: View>(_ content: Content,
                                       heightFraction: CGFloat,
                                       onDismissed: @escaping () -> Void) {
        guard container == nil, let top = topController() else { return }
        let vc = StoryTrayContainerVC(rootView: AnyView(content),
                                      heightFraction: heightFraction,
                                      onDismissed: {
                                          container = nil
                                          onDismissed()
                                      })
        container = vc
        top.present(vc, animated: false) { vc.animateIn() }
    }

    /// Close from the outside — the tray's own buttons hand a finished sticker back and then ask for
    /// this. Plays the same slide-down a drag does, so a Time sticker and a flicked-away tray leave
    /// the screen the same way.
    static func dismiss() {
        container?.animateOutAndFinish()
    }

    private static func topController() -> UIViewController? {
        var top = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

final class StoryTrayContainerVC: UIViewController {

    private let dimView = UIView()
    private let panel = UIView()
    private let grabber = UIView()
    private let hosting: UIHostingController<AnyView>
    private let heightFraction: CGFloat
    private let onDismissed: () -> Void

    /// Where the panel sits when nothing is dragging it and no keyboard is up.
    private var restHeight: CGFloat {
        (view.bounds.height * heightFraction).rounded()
    }
    /// Raised while the keyboard is up: the two pushed screens (Link, Location) type, and 80% of a
    /// phone with a keyboard over it is not a screen you can type on. This is what the old
    /// `.large` detent in the detent list was for.
    private var keyboardUp = false
    private var currentHeight: CGFloat = 0
    private var leaving = false

    /// The tray's ground, and the dim over the editor behind it. 0.35 is the system's own sheet dim
    /// closely enough that the change of presentation does not read as a change of design.
    private static let dimAlpha: CGFloat = 0.35
    /// The top corners. The system sheet drew a device-matched radius; 32 continuous is that shape
    /// at this size, and it is the only number here that is judged rather than carried across.
    private static let corner: CGFloat = 32

    init(rootView: AnyView, heightFraction: CGFloat, onDismissed: @escaping () -> Void) {
        self.hosting = UIHostingController(rootView: rootView)
        self.heightFraction = heightFraction
        self.onDismissed = onDismissed
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Every story surface is dark whatever the phone is set to — the app's standing rule. The
        // hosted tray sets it for itself too (`storyAlwaysDark`); this is for the container, so a
        // system control that resolves from the trait cannot come out light around it.
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .clear

        dimView.backgroundColor = UIColor.black.withAlphaComponent(0)
        dimView.frame = view.bounds
        dimView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(dimView)
        dimView.addGestureRecognizer(UITapGestureRecognizer(target: self,
                                                            action: #selector(handleTapOutside)))

        panel.backgroundColor = .black
        panel.layer.cornerRadius = Self.corner
        panel.layer.cornerCurve = .continuous
        // TOP TWO ONLY. The panel runs off the bottom of the screen, and rounding a corner that is
        // not on screen cuts a notch out of the black at the home indicator.
        panel.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        panel.clipsToBounds = true
        view.addSubview(panel)

        addChild(hosting)
        hosting.view.backgroundColor = .clear
        // ⚠️ NO CONTAINER INSETTING, BUT THE KEYBOARD ONE STAYS. The panel is positioned by hand;
        // letting the hosted content inset itself against the SCREEN's safe area would put the tab
        // row 34pt up from the bottom of a panel that already ends at the screen's edge.
        //
        // ⚠️ IT WAS `[]`, AND `[]` IS BOTH REGIONS, NOT ONE. `SafeAreaRegions` is an option set of
        // `.container` and `.keyboard`, so the empty set turned the keyboard avoidance off as well —
        // and the note here claimed the opposite. The Link and Location screens each have a text
        // field near the bottom of what is left of the panel, so with avoidance off they type
        // underneath the keys. `.keyboard` is the half that was meant.
        hosting.safeAreaRegions = .keyboard
        panel.addSubview(hosting.view)
        hosting.didMove(toParent: self)

        // The system's drag indicator, drawn OVER the content rather than above it, so the tray's
        // own top padding is unchanged and the layout is the one he approved.
        grabber.backgroundColor = UIColor(white: 1, alpha: 0.3)
        grabber.layer.cornerRadius = 2.5
        grabber.isUserInteractionEnabled = false
        panel.addSubview(grabber)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.delegate = self
        panel.addGestureRecognizer(pan)

        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow),
                                               name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    /// ⚠️ RAISED FOR AS LONG AS AN ANIMATION OWNS THE PANEL, AND ITS ABSENCE WAS A REAL BUG.
    ///
    /// `viewDidLayoutSubviews` runs for every reason UIKit has to lay out — the hosted SwiftUI content
    /// settling, a keyboard, a rotation, a trait change — and it re-seated the panel from
    /// `panelOffset` every time. During a flight that number is NOT where the panel is: `animateIn`
    /// laid the panel out at `offset: currentHeight` without ever writing it to `panelOffset`, and
    /// `animateOutAndFinish` animated to `currentHeight` without writing it either. So any layout pass
    /// landing inside either flight snapped the panel straight to `panelOffset` — fully open — with no
    /// animation. That is one frame of the tray open before it slides up, and it is a tray that
    /// appears to shut and come back when a layout lands mid-dismissal.
    ///
    /// Two halves to the repair: the offset is written EVERY time the panel is placed (below), and a
    /// layout pass stands down while a flight is in progress rather than overwriting it.
    private var isAnimatingPanel = false

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if currentHeight <= 0 { currentHeight = restHeight }
        guard !isAnimatingPanel else { return }
        // Only the height is re-derived on a rotation; a panel mid-drag keeps where the finger has
        // put it, which is what stops a keyboard animation from snapping it home.
        layoutPanel(height: currentHeight, offset: panelOffset)
    }

    // MARK: Geometry

    /// How far DOWN from its seated position the panel currently is. The drag writes it; the springs
    /// take it back to zero or all the way out.
    private var panelOffset: CGFloat = 0

    /// ⚠️ THE OFFSET IS RECORDED HERE AND NOWHERE ELSE. Every caller used to pass a number and leave
    /// `panelOffset` saying something different, which is what let a stray layout pass put the panel
    /// somewhere the animation never asked for. One writer, so the field and the frame cannot disagree.
    private func layoutPanel(height: CGFloat, offset: CGFloat) {
        let h = max(120, height)
        panelOffset = offset
        panel.frame = CGRect(x: 0, y: view.bounds.height - h + offset,
                             width: view.bounds.width, height: h)
        hosting.view.frame = panel.bounds
        grabber.frame = CGRect(x: (panel.bounds.width - 36) / 2, y: 8, width: 36, height: 5)
    }

    // MARK: Appearing and leaving

    func animateIn() {
        currentHeight = restHeight
        // Seated fully out of frame, and `panelOffset` now says so — see `layoutPanel`.
        layoutPanel(height: currentHeight, offset: currentHeight)
        view.layoutIfNeeded()
        isAnimatingPanel = true
        // The sheet's own arrival, near enough: a firm spring with no bounce to speak of, and the
        // dim coming up with it rather than after it.
        UIView.animate(withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.9,
                       initialSpringVelocity: 0, options: [.allowUserInteraction]) {
            self.layoutPanel(height: self.currentHeight, offset: 0)
            self.dimView.backgroundColor = UIColor.black.withAlphaComponent(Self.dimAlpha)
        } completion: { _ in
            self.isAnimatingPanel = false
        }
    }

    /// The one way out. `leaving` makes it idempotent: a drag that has already committed must not be
    /// restarted by the button underneath it firing a programmatic close in the same breath.
    func animateOutAndFinish(velocity: CGFloat = 0) {
        guard !leaving else { return }
        leaving = true
        view.endEditing(true)
        let remaining = max(1, currentHeight - panelOffset)
        // A flicked tray leaves at the speed it was flicked at, capped so a hard flick is quick
        // rather than instant.
        let duration = min(0.35, max(0.18, Double(remaining / max(600, velocity))))
        isAnimatingPanel = true
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseIn]) {
            self.layoutPanel(height: self.currentHeight, offset: self.currentHeight)
            self.dimView.backgroundColor = UIColor.black.withAlphaComponent(0)
        } completion: { _ in
            self.isAnimatingPanel = false
            let finish = self.onDismissed
            self.dismiss(animated: false)
            finish()
        }
    }

    @objc private func handleTapOutside() { animateOutAndFinish() }

    // MARK: The drag

    /// THE SCROLL VIEW THE DRAG IS CURRENTLY ARGUING WITH, learned from the simultaneous-recognition
    /// callback rather than by hunting the view tree. Nil when the finger is on the search field, the
    /// pills or the tab row, none of which scroll — and nil is treated as "at the top", so a drag
    /// there moves the panel at once, exactly as it did when the drag lived only in the top strip.
    private weak var trackedScroll: UIScrollView?
    /// Raised the moment the panel takes the drag over from the scroll view. Until then a downward
    /// finger belongs to the grid.
    private var dragOwnsPanel = false
    /// Where the finger was when the panel took over, so the panel starts moving from ZERO rather
    /// than jumping by however far the grid had already been scrolled up to its top.
    private var dragHandoverTranslation: CGFloat = 0

    private var scrollIsAtTop: Bool {
        guard let sv = trackedScroll else { return true }
        return sv.contentOffset.y <= -sv.adjustedContentInset.top + 0.5
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        let translation = g.translation(in: view).y
        switch g.state {
        case .began:
            dragOwnsPanel = false
            dragHandoverTranslation = 0

        case .changed:
            // ⚠️ THE HAND-OVER, AND IT IS WHY THE DRAG NO LONGER LIVES IN A 64pt STRIP.
            //
            // The tray is mostly grid, so restricting the drag to the top 64pt meant that swiping
            // down anywhere a thumb naturally lands did nothing at all — his "it does not follow my
            // finger and does not dismiss". The rule every real bottom sheet uses instead is the one
            // below: the grid keeps every drag while it still has somewhere to scroll, and the panel
            // takes over the moment the grid is at its top and the finger is still going down.
            if !dragOwnsPanel {
                guard scrollIsAtTop, translation > 0 else { return }
                dragOwnsPanel = true
                dragHandoverTranslation = translation
            }
            // 1:1 with the finger from the hand-over point. Downwards only — pulling UP on a tray
            // already at its height is not a gesture this tray has; it grows for the keyboard instead.
            let offset = max(0, translation - dragHandoverTranslation)
            layoutPanel(height: currentHeight, offset: offset)
            // The grid must not scroll under a panel that is following the finger, or the two move at
            // once and the sheet feels loose.
            if let sv = trackedScroll, offset > 0 {
                sv.contentOffset.y = -sv.adjustedContentInset.top
            }
            // The dim lets go with the panel, so the editor behind is already coming back by the
            // time the tray is half gone.
            let p = 1 - min(1, offset / max(1, currentHeight))
            dimView.backgroundColor = UIColor.black.withAlphaComponent(Self.dimAlpha * p)

        case .ended, .cancelled, .failed:
            defer { dragOwnsPanel = false }
            guard dragOwnsPanel else { return }
            let velocity = g.velocity(in: view).y
            // A quarter of the way down, or thrown. The same two-part rule every dismissable panel
            // in this app uses, so the tray answers a flick the way the story viewer does.
            if panelOffset > currentHeight * 0.25 || velocity > 900 {
                animateOutAndFinish(velocity: velocity)
            } else {
                isAnimatingPanel = true
                UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.86,
                               initialSpringVelocity: 0, options: [.allowUserInteraction]) {
                    self.layoutPanel(height: self.currentHeight, offset: 0)
                    self.dimView.backgroundColor = UIColor.black.withAlphaComponent(Self.dimAlpha)
                } completion: { _ in
                    self.isAnimatingPanel = false
                }
            }
        default: break
        }
    }

    // MARK: The keyboard

    @objc private func keyboardWillShow(_ note: Notification) {
        guard !keyboardUp, !leaving else { return }
        keyboardUp = true
        setHeight(view.bounds.height - view.safeAreaInsets.top, note: note)
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        guard keyboardUp, !leaving else { return }
        keyboardUp = false
        setHeight(restHeight, note: note)
    }

    /// Grow or shrink ON THE KEYBOARD'S OWN CLOCK. The duration and curve are read out of the
    /// notification rather than guessed, so the panel and the keyboard move as one thing — the same
    /// rule the story's reply dim follows.
    private func setHeight(_ h: CGFloat, note: Notification) {
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let raw = (note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int) ?? 7
        currentHeight = h
        UIView.animate(withDuration: duration, delay: 0,
                       options: [UIView.AnimationOptions(rawValue: UInt(raw) << 16), .allowUserInteraction]) {
            self.layoutPanel(height: h, offset: self.panelOffset)
        }
    }
}

extension StoryTrayContainerVC: UIGestureRecognizerDelegate {
    /// ⚠️ THE DRAG LIVES ON THE WHOLE PANEL NOW, AND THE 64pt STRIP IT USED TO LIVE IN WAS THE BUG.
    ///
    /// The old rule was that a pan across the whole panel would compete with the sticker grid, so it
    /// was allowed to begin only in the top 64pt — the grabber and the search field's band. The tray
    /// is mostly grid, so in practice that meant swiping down anywhere a thumb naturally falls did
    /// nothing whatsoever: his "it does not follow my finger and does not dismiss".
    ///
    /// Competing was never the problem to avoid. Both recognisers run, and `handlePan` decides which
    /// one the movement belongs to: the grid keeps it while it still has somewhere to scroll, and the
    /// panel takes over the instant the grid is at its top and the finger is still going down. That is
    /// the same hand-over the system sheet performs and it is why a system sheet can be dragged shut
    /// from anywhere inside it.
    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard let pan = g as? UIPanGestureRecognizer else { return true }
        let v = pan.velocity(in: panel)
        return abs(v.y) > abs(v.x)   // a sideways swipe is not ours
    }

    /// Running alongside the grid is what makes the hand-over possible at all — and the callback is
    /// also where the grid introduces itself, so nothing has to go hunting for a scroll view.
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        if let scroll = other.view as? UIScrollView { trackedScroll = scroll }
        return true
    }
}

// MARK: - The SwiftUI face

extension View {
    /// Present `content` as the story editor's own bottom tray. A drop-in for the `.sheet` this
    /// replaces: same binding, same content, and every way out puts the binding back down.
    func storyTray<TrayContent: View>(isPresented: Binding<Bool>,
                                      heightFraction: CGFloat = 0.8,
                                      @ViewBuilder content: @escaping () -> TrayContent) -> some View {
        onChange(of: isPresented.wrappedValue) { _, show in
            if show {
                StoryTrayPresenter.present(content(), heightFraction: heightFraction) {
                    // Guarded: the binding is what brought us here, and writing it back when it has
                    // already been put down (the tray closed itself on a chosen sticker) would be a
                    // second, pointless render of the editor.
                    if isPresented.wrappedValue { isPresented.wrappedValue = false }
                }
            } else if StoryTrayPresenter.isActive {
                StoryTrayPresenter.dismiss()
            }
        }
    }
}
