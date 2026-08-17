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
        // ⚠️ NO SAFE-AREA INSETTING FROM THE CONTAINER. The panel is positioned by hand; letting the
        // hosted content inset itself against the SCREEN's safe area would put the tab row 34pt up
        // from the bottom of a panel that already ends at the screen's edge. SwiftUI still insets
        // for the keyboard, which is what carries the two pushed screens.
        hosting.safeAreaRegions = []
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

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if currentHeight <= 0 { currentHeight = restHeight }
        // Only the height is re-derived on a rotation; a panel mid-drag keeps where the finger has
        // put it, which is what stops a keyboard animation from snapping it home.
        layoutPanel(height: currentHeight, offset: panelOffset)
    }

    // MARK: Geometry

    /// How far DOWN from its seated position the panel currently is. The drag writes it; the springs
    /// take it back to zero or all the way out.
    private var panelOffset: CGFloat = 0

    private func layoutPanel(height: CGFloat, offset: CGFloat) {
        let h = max(120, height)
        panel.frame = CGRect(x: 0, y: view.bounds.height - h + offset,
                             width: view.bounds.width, height: h)
        hosting.view.frame = panel.bounds
        grabber.frame = CGRect(x: (panel.bounds.width - 36) / 2, y: 8, width: 36, height: 5)
    }

    // MARK: Appearing and leaving

    func animateIn() {
        currentHeight = restHeight
        layoutPanel(height: currentHeight, offset: currentHeight)
        // The sheet's own arrival, near enough: a firm spring with no bounce to speak of, and the
        // dim coming up with it rather than after it.
        UIView.animate(withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.9,
                       initialSpringVelocity: 0, options: [.allowUserInteraction]) {
            self.panelOffset = 0
            self.layoutPanel(height: self.currentHeight, offset: 0)
            self.dimView.backgroundColor = UIColor.black.withAlphaComponent(Self.dimAlpha)
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
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseIn]) {
            self.layoutPanel(height: self.currentHeight, offset: self.currentHeight)
            self.dimView.backgroundColor = UIColor.black.withAlphaComponent(0)
        } completion: { _ in
            let finish = self.onDismissed
            self.dismiss(animated: false)
            finish()
        }
    }

    @objc private func handleTapOutside() { animateOutAndFinish() }

    // MARK: The drag

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        let translation = g.translation(in: view).y
        switch g.state {
        case .changed:
            // Downwards only. Pulling UP on a tray that is already at its height is not a gesture
            // this tray has — the system sheet had a second detent to grow into and this one grows
            // for the keyboard instead.
            panelOffset = max(0, translation)
            layoutPanel(height: currentHeight, offset: panelOffset)
            // The dim lets go with the panel, so the editor behind is already coming back by the
            // time the tray is half gone.
            let p = 1 - min(1, panelOffset / max(1, currentHeight))
            dimView.backgroundColor = UIColor.black.withAlphaComponent(Self.dimAlpha * p)
        case .ended, .cancelled, .failed:
            let velocity = g.velocity(in: view).y
            // A quarter of the way down, or thrown. The same two-part rule every dismissable panel
            // in this app uses, so the tray answers a flick the way the story viewer does.
            if panelOffset > currentHeight * 0.25 || velocity > 900 {
                animateOutAndFinish(velocity: velocity)
            } else {
                UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.86,
                               initialSpringVelocity: 0, options: [.allowUserInteraction]) {
                    self.panelOffset = 0
                    self.layoutPanel(height: self.currentHeight, offset: 0)
                    self.dimView.backgroundColor = UIColor.black.withAlphaComponent(Self.dimAlpha)
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
    /// ⚠️ THE DRAG ONLY LIVES IN THE TOP STRIP, AND THAT IS WHAT KEEPS THE GRID SCROLLING.
    ///
    /// A pan across the whole panel would be in competition with the sticker grid's own scroll view
    /// for every vertical flick in it — and the tray is mostly grid. Beginning only in the top 64pt
    /// (the grabber and the search field's band, which is where a sheet is dragged from anyway)
    /// means the two gestures never meet, so neither has to yield to the other.
    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard let pan = g as? UIPanGestureRecognizer else { return true }
        let v = pan.velocity(in: panel)
        guard abs(v.y) > abs(v.x) else { return false }   // a sideways swipe is not ours
        return pan.location(in: panel).y <= 64
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
