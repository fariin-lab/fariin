import Observation
import SwiftUI
import UIKit

// ⛔ THE ATTACH SHEET IS OUR OWN CONTAINER, NOT `.sheet` — owner, 2026-09-28, build 789: "+ sometimes
// does not open, sometimes does not close, it lags after many times; copy the reference app exactly".
//
// What `.sheet` + `.navigationTransition(.zoom)` did, and why it could not be patched:
// - The "+" was hidden BEFORE the sheet was asked to present. SwiftUI drops a presentation asked for
//   while the last dismissal is still running, and then nothing ever showed the "+" again: a dead,
//   invisible button until the next successful close.
// - The zoom's own interactive dismissal fought the 62%/full detent snap (the reason it was pulled
//   twice before, July and 2026-08-24).
// - Every tap wrote four to eight `@State`s on ThreadView, each a full re-render of the chat.
// - The "+" was hidden through `alpha`, which the composer also animates for its own states.
//
// This is the shape the reference app uses (`AttachmentController` + `AttachmentContainer`): one
// container that owns its geometry, its drag and its springs, with a phase machine so a tap during
// an animation reverses it instead of queueing a second presentation. Every number below is theirs,
// read off their source, not tuned by eye:
//
//   open   position  customSpring(damping 110, initialVelocity 1.1), 0.40s
//          size+scale customSpring(damping 110, initialVelocity 0),   0.45s
//          corners   easeInOut 0.20s, circle → 38
//          content   alpha 0 → 1, 0.20s;  "+" glyph fades out 0.15s;  dim 0.30s linear
//   close  position  customSpring(damping 110, v), 0.40s
//          size+scale customSpring(damping 124, v), 0.30s;  corners customSpring(124, v), 0.20s
//          content   alpha 1 → 0, 0.12s;  glyph back 0.22s;  glass fades 0.15s after 0.20s
//   drag   dismiss when pulled > 60pt below rest or flicked > 300pt/s down;
//          between rest and full: flick ±300pt/s decides, else the nearer half;
//          snap customSpring(damping 124, v = |velocity / distance|), 0.45s; "stay" easeInOut 0.30s
//
// Their `customSpring` is a CASpringAnimation (mass 5, stiffness 900, damping d) whose whole settling
// time is squeezed into the stated duration by `speed`. `RefSpring` rebuilds that exact curve for
// `UIViewPropertyAnimator` (see there), which is what makes every animation here interruptible.

/// The reference app's `customSpring` as a property animator. Their CASpringAnimation runs for its
/// `settlingDuration` at `speed = settling / duration`, i.e. the spring's clock runs K times fast.
/// x(t) = X(K·t) solves m·x'' + (c·K)·x' + (k·K²)·x = 0 with x'(0) = K·X'(0), so the same curve
/// in wall-clock time is damping c·K, stiffness k·K², initial velocity v·K.
@MainActor enum RefSpring {
    static func animator(damping: CGFloat, velocity: CGFloat, duration: TimeInterval) -> UIViewPropertyAnimator {
        let probe = CASpringAnimation()
        probe.mass = 5
        probe.stiffness = 900
        probe.damping = damping
        probe.initialVelocity = velocity
        let k = max(probe.settlingDuration / duration, 0.01)
        let p = UISpringTimingParameters(mass: 5, stiffness: 900 * k * k, damping: damping * k,
                                         initialVelocity: CGVector(dx: velocity * k, dy: velocity * k))
        return UIViewPropertyAnimator(duration: duration, timingParameters: p)
    }
}

/// The bottom inset the hosted panel pads itself by. The host is told to ignore the container safe
/// area (it moves below the screen while dragged, and a changing inset would make the bottom bar
/// jump), so the home-indicator band is handed in as a number instead; 0 while the keyboard is up,
/// which brings its own inset.
@Observable final class AttachSheetMetrics {
    var bottom: CGFloat = 0
}

private struct AttachSheetRoot: View {
    let metrics: AttachSheetMetrics
    let content: AnyView
    var body: some View {
        content.safeAreaPadding(.bottom, metrics.bottom)
    }
}

@MainActor
final class AttachSheetController: UIViewController, UIGestureRecognizerDelegate {
    enum Phase { case closed, opening, open, closing }
    private(set) var phase: Phase = .closed

    /// Called when the sheet closes ITSELF (drag, tap outside), so the owner's flag follows.
    var onUserClose: (() -> Void)?
    /// A tap on the "+" while the sheet is shrinking back into it: the owner re-opens.
    var onReopenTap: (() -> Void)?
    /// Once, when the sheet is fully gone and dismissed.
    var onClosed: (() -> Void)?

    private let metrics = AttachSheetMetrics()
    private let host: UIHostingController<AttachSheetRoot>
    private let dim = UIView()
    private let shell = UIView()
    private let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let glyph = UIImageView(image: UIImage(named: "ic_composer_plus")?.withRenderingMode(.alwaysTemplate))
    private let content = UIView()
    private let grabber = UIView()

    private var animators: [UIViewPropertyAnimator] = []
    private var laterGen = 0
    private var sheetTop: CGFloat = 0
    private var isExpanded = false
    private var keyboardUp = false

    // Drag state
    private var scroll: UIScrollView?
    private var lastTranslation: CGFloat = 0
    private var sheetMoved = false

    init(root: AnyView) {
        host = UIHostingController(rootView: AttachSheetRoot(metrics: metrics, content: root))
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        host.safeAreaRegions = .keyboard
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setRoot(_ root: AnyView) {
        host.rootView = AttachSheetRoot(metrics: metrics, content: root)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        // The reference's attach dim: black at 25%.
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.25)
        dim.alpha = 0
        view.addSubview(dim)

        shell.clipsToBounds = true
        shell.layer.cornerCurve = .continuous
        shell.isHidden = true
        view.addSubview(shell)

        glass.isUserInteractionEnabled = false
        shell.addSubview(glass)
        glyph.tintColor = .label
        glyph.sizeToFit()
        glass.contentView.addSubview(glyph)

        content.backgroundColor = .clear
        shell.addSubview(content)
        addChild(host)
        host.view.backgroundColor = .systemBackground
        content.addSubview(host.view)
        host.didMove(toParent: self)

        // The system sheet's drag indicator, which the panel has relied on since August.
        grabber.backgroundColor = .tertiaryLabel
        grabber.layer.cornerRadius = 2.5
        grabber.isUserInteractionEnabled = false
        content.addSubview(grabber)

        let tap = UITapGestureRecognizer(target: self, action: #selector(backgroundTap(_:)))
        tap.delegate = self
        view.addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        pan.delegate = self
        shell.addGestureRecognizer(pan)

        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow),
                                               name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        dim.frame = view.bounds
        if !keyboardUp { setBottom(view.safeAreaInsets.bottom) }
        // A size change (rotation) while resting re-seats the sheet; never under a running animation.
        if phase == .open, animators.allSatisfy({ $0.state != .active }), scroll == nil {
            setTop(isExpanded ? expandedTop : compactTop)
        }
    }

    // MARK: - Geometry

    /// 62% of the screen, as the detent was (user spec: the camera row plus ~3 photo rows).
    private var compactTop: CGFloat { view.bounds.height - (view.bounds.height * 0.62).rounded() }
    /// Where the system's large detent sat: just under the status bar.
    private var expandedTop: CGFloat { view.safeAreaInsets.top > 0 ? view.safeAreaInsets.top + 10 : 0 }

    /// The sheet's frame for a top edge. Above rest it grows (its bottom stays on the screen's);
    /// below rest it only moves, so the panel's own layout is not touched while it is pulled away.
    private func frame(forTop y: CGFloat) -> CGRect {
        let b = view.bounds
        if y >= compactTop { return CGRect(x: 0, y: y, width: b.width, height: b.height - compactTop) }
        return CGRect(x: 0, y: y, width: b.width, height: b.height - y)
    }

    private func layoutContent(size: CGSize) {
        content.frame = CGRect(origin: .zero, size: size)
        host.view.frame = content.bounds
        grabber.frame = CGRect(x: (size.width - 36) / 2, y: 5, width: 36, height: 5)
    }

    /// Resting geometry (identity transform): frame, content, corners.
    private func setTop(_ y: CGFloat) {
        sheetTop = y
        let f = frame(forTop: y)
        shell.transform = .identity
        shell.bounds = CGRect(origin: .zero, size: f.size)
        shell.center = CGPoint(x: f.midX, y: f.midY)
        glass.frame = shell.bounds
        layoutContent(size: f.size)
        host.view.layoutIfNeeded()
    }

    private func sourceRect() -> CGRect {
        let r = ChatComposerView.AttachSource.windowRect
        guard r != .zero, let w = view.window else { return .zero }
        return view.convert(r, from: w)
    }

    // MARK: - Animation bookkeeping

    private func run(_ a: UIViewPropertyAnimator, after delay: TimeInterval = 0) {
        animators.append(a)
        a.addCompletion { [weak self, weak a] _ in
            guard let self, let a else { return }
            self.animators.removeAll { $0 === a }
        }
        if delay > 0 { a.startAnimation(afterDelay: delay) } else { a.startAnimation() }
    }

    /// A delayed step that `stopAll` cancels (by generation), so a reversed animation never gets a
    /// stale "show the +" from the one it replaced.
    private func later(_ delay: TimeInterval, _ body: @escaping () -> Void) {
        let gen = laterGen
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.laterGen == gen else { return }
                body()
            }
        }
    }

    /// Freezes every running animation where it is on screen (no completions run) — the one door
    /// for reversing or grabbing mid-flight, so two animations never own the same property.
    private func stopAll() {
        for a in animators where a.state == .active { a.stopAnimation(true) }
        animators.removeAll()
        laterGen &+= 1
    }

    private func linear(_ d: TimeInterval, _ body: @escaping () -> Void) -> UIViewPropertyAnimator {
        UIViewPropertyAnimator(duration: d, curve: .linear, animations: body)
    }
    private func easeInOut(_ d: TimeInterval, _ body: @escaping () -> Void) -> UIViewPropertyAnimator {
        UIViewPropertyAnimator(duration: d, curve: .easeInOut, animations: body)
    }

    // MARK: - Open

    /// Grows the sheet out of the "+". From `.closing` it reverses from wherever it is.
    func open() {
        guard isViewLoaded, phase == .closed || phase == .closing else { return }
        let reversing = phase == .closing
        stopAll()
        phase = .opening
        isExpanded = false
        shell.isHidden = false
        shell.isUserInteractionEnabled = true
        content.isUserInteractionEnabled = true

        let target = frame(forTop: compactTop)
        sheetTop = compactTop
        let src = sourceRect()

        guard src != .zero else {
            // No "+" on screen (text-only request, recording): the reference's plain slide-up.
            if !reversing {
                glass.isHidden = true
                content.alpha = 1
                shell.layer.cornerRadius = 38
                setTop(compactTop)
                shell.center.y += view.bounds.height
            }
            let a = UIViewPropertyAnimator(duration: 0.4, timingParameters: UICubicTimingParameters(
                controlPoint1: CGPoint(x: 0.23, y: 1), controlPoint2: CGPoint(x: 0.32, y: 1)))
            a.addAnimations { [self] in setTop(compactTop); shell.layer.cornerRadius = 38; content.alpha = 1 }
            a.addCompletion { [weak self] p in if p == .end { self?.didOpen() } }
            run(a)
            run(linear(0.3) { [self] in dim.alpha = 1 })
            return
        }

        let scale = src.width / target.width
        ChatComposerView.AttachSource.setLifted(true)

        if !reversing {
            // The start: a circle the width of the sheet, centred on its middle band, scaled down
            // to the button and sitting on it, dressed as the button (glass + glyph).
            layoutContent(size: target.size)
            host.view.layoutIfNeeded()
            let square = CGRect(x: 0, y: (target.height - target.width) / 2, width: target.width, height: target.width)
            shell.transform = .identity
            shell.bounds = square
            glass.frame = square
            glass.isHidden = false
            glass.alpha = 1
            shell.center = CGPoint(x: src.midX, y: src.midY)
            shell.transform = CGAffineTransform(scaleX: scale, y: scale)
            shell.layer.cornerRadius = target.width / 2
            glyph.center = CGPoint(x: square.midX, y: square.midY)
            glyph.transform = CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)
            glyph.alpha = 1
            content.alpha = 0
        }
        view.layoutIfNeeded()

        let full = CGRect(origin: .zero, size: target.size)
        let position = RefSpring.animator(damping: 110, velocity: 1.1, duration: 0.4)
        position.addAnimations { [self] in shell.center = CGPoint(x: target.midX, y: target.midY) }
        position.addCompletion { [weak self] p in if p == .end { self?.didOpen() } }

        let size = RefSpring.animator(damping: 110, velocity: 0, duration: 0.45)
        size.addAnimations { [self] in
            shell.bounds = full
            shell.transform = .identity
            glass.frame = full
            glyph.center = CGPoint(x: full.midX, y: full.midY)
        }

        run(position)
        run(size)
        run(easeInOut(0.2) { [self] in shell.layer.cornerRadius = 38 })
        run(easeInOut(0.2) { [self] in content.alpha = 1 })
        run(easeInOut(0.15) { [self] in glyph.alpha = 0 })
        run(linear(0.3) { [self] in dim.alpha = 1 })
    }

    private func didOpen() {
        phase = .open
        glass.isHidden = true
        // The real "+" is back under the dim, as in the reference (`sourceGlassView.isHidden = false`).
        ChatComposerView.AttachSource.setLifted(false)
        setTop(isExpanded ? expandedTop : compactTop)
    }

    /// The panel asked for the full height (caption field focused). Their 0.5s keyboard curve.
    func expand() {
        guard phase == .open, !isExpanded, scroll == nil else { return }
        stopAll()
        isExpanded = true
        let a = UIViewPropertyAnimator(duration: 0.5, timingParameters: UICubicTimingParameters(
            controlPoint1: CGPoint(x: 0.23, y: 1), controlPoint2: CGPoint(x: 0.32, y: 1)))
        a.addAnimations { [self] in setTop(expandedTop) }
        run(a)
    }

    // MARK: - Close

    /// Shrinks the sheet back into the "+". `velocity` is the release speed of a drag (pt/s, down
    /// positive), normalised the reference's way: by the screen height.
    func close(velocity: CGFloat = 0) {
        guard isViewLoaded, phase == .opening || phase == .open else { return }

        // Something is open ON the sheet (an editor after Send): take the whole stack down in one
        // move, the way `.sheet` did, so the sheet never flashes back between the two.
        if presentedViewController != nil {
            stopAll()
            phase = .closing
            presentingViewController?.dismiss(animated: true) { [weak self] in self?.finish(dismissed: true) }
            return
        }

        stopAll()
        phase = .closing
        // The whole shell stops taking touches, not just the panel: it is flying onto the "+", and
        // a tap there has to reach `backgroundTap` to re-open.
        shell.isUserInteractionEnabled = false
        let v = velocity / max(view.bounds.height, 1)
        let src = sourceRect()

        run(easeInOut(0.25) { [self] in dim.alpha = 0 })

        guard src != .zero else {
            let a = easeInOut(0.25) { [self] in shell.center.y = view.bounds.height + shell.bounds.height / 2 }
            a.addCompletion { [weak self] p in if p == .end { self?.finish(dismissed: false) } }
            run(a)
            return
        }

        // The current size, unscaled (an interrupted open is still scaled; its bounds are true).
        let cur = shell.bounds
        let w = cur.width
        let scale = src.width / w
        let square = CGRect(x: 0, y: (cur.height - w) / 2, width: w, height: w)

        glass.isHidden = false
        glass.frame = cur
        glass.alpha = 1
        glyph.center = CGPoint(x: cur.midX, y: cur.midY)
        glyph.transform = CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)
        ChatComposerView.AttachSource.setLifted(true)

        let position = RefSpring.animator(damping: 110, velocity: v, duration: 0.4)
        position.addAnimations { [self] in shell.center = CGPoint(x: src.midX, y: src.midY) }
        position.addCompletion { [weak self] p in if p == .end { self?.finish(dismissed: false) } }

        let size = RefSpring.animator(damping: 124, velocity: v, duration: 0.3)
        size.addAnimations { [self] in
            shell.bounds = square
            shell.transform = CGAffineTransform(scaleX: scale, y: scale)
            glass.frame = square
            glyph.center = CGPoint(x: square.midX, y: square.midY)
        }
        let corners = RefSpring.animator(damping: 124, velocity: v, duration: 0.2)
        corners.addAnimations { [self] in shell.layer.cornerRadius = w / 2 }

        run(position)
        run(size)
        run(corners)
        run(easeInOut(0.12) { [self] in content.alpha = 0 })
        run(easeInOut(0.22) { [self] in glyph.alpha = 1 })
        // The real "+" takes over as the copy's glass fades: 0.15s from 0.2s in, theirs.
        later(0.2) { ChatComposerView.AttachSource.setLifted(false) }
        run(linear(0.15) { [self] in glass.alpha = 0 }, after: 0.2)
    }

    private func finish(dismissed: Bool) {
        stopAll()
        phase = .closed
        shell.isHidden = true
        ChatComposerView.AttachSource.setLifted(false)
        NotificationCenter.default.removeObserver(self)
        let done = { [weak self] in self?.onClosed?() }
        if dismissed || presentingViewController == nil { done() }
        else { presentingViewController?.dismiss(animated: false, completion: done) }
    }

    /// The chat went away under an open sheet: no animation, just leave nothing behind.
    func tearDown() {
        stopAll()
        ChatComposerView.AttachSource.setLifted(false)
        guard phase != .closed else { return }
        phase = .closed
        NotificationCenter.default.removeObserver(self)
        presentingViewController?.dismiss(animated: false)
    }

    private func userClose(velocity: CGFloat) {
        guard phase == .opening || phase == .open else { return }
        close(velocity: velocity)
        onUserClose?()
    }

    // MARK: - Gestures

    @objc private func backgroundTap(_ g: UITapGestureRecognizer) {
        switch phase {
        case .opening, .open:
            userClose(velocity: 0)
        case .closing:
            // A tap on the "+" while the sheet shrinks into it opens it again from where it is.
            let src = sourceRect().insetBy(dx: -12, dy: -12)
            if src.contains(g.location(in: view)) { onReopenTap?() }
        case .closed:
            break
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if g is UITapGestureRecognizer { return touch.view === view || touch.view === dim }
        return true
    }

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard let pan = g as? UIPanGestureRecognizer else { return true }
        guard phase == .open else { return false }
        let v = pan.velocity(in: view)
        return abs(v.y) > abs(v.x)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g is UIPanGestureRecognizer && other.view is UIScrollView
    }

    /// The vertical scroll view under the finger, if any (the reference's `findScrollView`).
    private func scrollView(at p: CGPoint) -> UIScrollView? {
        var v = view.hitTest(p, with: nil)
        while let cur = v, cur !== shell {
            if let s = cur as? UIScrollView, s.contentSize.width <= s.bounds.width + 1 { return s }
            v = cur.superview
        }
        return nil
    }

    private func atScrollTop(_ s: UIScrollView?) -> Bool {
        guard let s else { return true }
        return s.contentOffset.y <= -s.adjustedContentInset.top + 1
    }

    private func pinScrollTop(_ s: UIScrollView?) {
        guard let s else { return }
        let top = -s.adjustedContentInset.top
        if s.contentOffset.y != top { s.contentOffset.y = top }
    }

    @objc private func pan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            // Grabbed mid-snap: freeze it where it is and carry on from there.
            if !animators.isEmpty {
                stopAll()
                sheetTop = shell.frame.minY
            }
            scroll = scrollView(at: g.location(in: view))
            lastTranslation = 0
            sheetMoved = false

        case .changed:
            let t = g.translation(in: view).y
            let dy = t - lastTranslation
            lastTranslation = t
            // The sheet moves while it is below full height, or when pulled down with its list at
            // the top; otherwise the list scrolls. Whichever moves, the other holds still.
            if sheetTop > expandedTop + 0.5 || (dy > 0 && atScrollTop(scroll)) {
                sheetMoved = true
                setTop(max(expandedTop, sheetTop + dy))
                pinScrollTop(scroll)
            }

        case .ended, .cancelled, .failed:
            let s = scroll
            scroll = nil
            guard sheetMoved else { return }
            let vy = g.state == .ended ? g.velocity(in: view).y : 0
            let y = sheetTop

            if y > compactTop {
                if y - compactTop > 60 || vy > 300 { userClose(velocity: vy); return }
                snap(expanded: false, velocity: vy, stay: !isExpanded)
                return
            }
            let mid = (compactTop + expandedTop) / 2
            let toFull: Bool = vy < -300 ? true : (vy > 300 ? false : y < mid)
            pinScrollTop(s)
            snap(expanded: toFull, velocity: vy, stay: toFull == isExpanded)

        default:
            break
        }
    }

    /// To rest or full. A change of state rides their 0.45s spring with the finger's speed; going
    /// back to the state it came from is their plain 0.3s ease.
    private func snap(expanded: Bool, velocity: CGFloat, stay: Bool) {
        stopAll()
        isExpanded = expanded
        let target = expanded ? expandedTop : compactTop
        let distance = abs(target - sheetTop)
        let a: UIViewPropertyAnimator
        if stay || distance < 0.5 {
            a = easeInOut(0.3) { [self] in setTop(target) }
        } else {
            a = RefSpring.animator(damping: 124, velocity: abs(velocity) / distance, duration: 0.45)
            a.addAnimations { [self] in setTop(target) }
        }
        run(a)
    }

    // MARK: - Keyboard

    @objc private func keyboardWillShow() {
        keyboardUp = true
        setBottom(0)
    }
    @objc private func keyboardWillHide() {
        keyboardUp = false
        setBottom(view.safeAreaInsets.bottom)
    }
    /// Only on a real change: an `@Observable` write re-renders the panel even when equal.
    private func setBottom(_ v: CGFloat) {
        if metrics.bottom != v { metrics.bottom = v }
    }
}

// MARK: - SwiftUI door

extension View {
    /// The attach sheet. Same contract as `.sheet(isPresented:onDismiss:)`: the flag opens and
    /// closes it, and flips back to false when the user closes it; `onDismiss` runs once it is gone.
    /// `expandTick` changing asks for the full height.
    func attachSheet<Content: View>(isPresented: Binding<Bool>, expandTick: Int,
                                    onDismiss: @escaping () -> Void,
                                    @ViewBuilder content: @escaping () -> Content) -> some View {
        background(AttachSheetAnchor(isPresented: isPresented, expandTick: expandTick,
                                     onDismiss: onDismiss, content: { AnyView(content()) })
            .frame(width: 0, height: 0)
            .allowsHitTesting(false))
    }
}

private struct AttachSheetAnchor: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let expandTick: Int
    let onDismiss: () -> Void
    let content: () -> AnyView

    func makeUIViewController(context: Context) -> Anchor { Anchor() }

    func updateUIViewController(_ a: Anchor, context: Context) {
        let binding = $isPresented
        a.setPresented = { binding.wrappedValue = $0 }
        a.onDismiss = onDismiss
        a.sync(isPresented: isPresented, expandTick: expandTick, content: content)
    }

    static func dismantleUIViewController(_ a: Anchor, coordinator: ()) { a.sheet?.tearDown() }

    @MainActor final class Anchor: UIViewController {
        private(set) weak var sheet: AttachSheetController?
        var setPresented: ((Bool) -> Void)?
        var onDismiss: (() -> Void)?
        private var lastTick = 0
        private var presenting = false
        /// The owner's flag as last seen. Every async step re-reads it, so a tap that lands between
        /// two steps is never lost and never leaves a sheet up that nobody asked for.
        private var wantsOpen = false
        private var latestContent: (() -> AnyView)?

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        func sync(isPresented: Bool, expandTick: Int, content: @escaping () -> AnyView) {
            wantsOpen = isPresented
            latestContent = content
            if let s = sheet {
                if s.phase != .closed { s.setRoot(content()) }
                if isPresented {
                    if s.phase == .closing { s.open() }
                    if expandTick != lastTick { s.expand() }
                } else if s.phase == .opening || s.phase == .open {
                    s.close()
                }
                // `.closed` but not yet gone: `onClosed` checks `wantsOpen` and opens a fresh one.
            } else if isPresented && !presenting {
                present(attempt: 0)
            }
            lastTick = expandTick
        }

        private func present(attempt: Int) {
            guard wantsOpen, let content = latestContent else { presenting = false; return }
            presenting = true
            var top: UIViewController = self
            while let p = top.presentedViewController, !p.isBeingDismissed { top = p }
            // Something is still leaving (a picker, an alert): wait for it rather than have UIKit
            // drop this presentation, which is how the old "+" went dead. Up to a second.
            if top.presentedViewController != nil || top.isBeingDismissed || view.window == nil {
                guard attempt < 20 else { presenting = false; setPresented?(false); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    MainActor.assumeIsolated { self?.present(attempt: attempt + 1) }
                }
                return
            }
            let s = AttachSheetController(root: content())
            s.onUserClose = { [weak self] in self?.setPresented?(false) }
            s.onReopenTap = { [weak self] in self?.setPresented?(true) }
            s.onClosed = { [weak self, weak s] in
                guard let self, self.sheet === s else { return }
                self.sheet = nil
                self.onDismiss?()
                if self.wantsOpen { self.present(attempt: 0) }
            }
            sheet = s
            top.present(s, animated: false) { [weak self, weak s] in
                guard let self, let s else { return }
                self.presenting = false
                s.open()
                if !self.wantsOpen { s.close() }
            }
        }
    }
}
