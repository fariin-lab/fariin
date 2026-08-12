//
//  StoryCubePager.swift
//  StoryUI
//
//  THE PERSON-TO-PERSON CONTAINER, DRIVEN BY A RAW PAN — no UIPageViewController, no scroll view.
//
//  ⚠️ WHY THIS EXISTS AT ALL, since the cube already worked on a `UIPageViewController`.
//
//  It worked by borrowing somebody else's motion. The fold was computed every frame from where UIKit
//  had put its private `_UIQueuingScrollView`'s pages, which made two things true and both of them
//  were reported from a real phone on build 551:
//
//    * **The finger did not move the cube.** The fold ran only while that scroll view reported
//      itself as tracking, and the scroll view is switched OFF whenever the app has any reason to
//      keep it out of the way — a single bucket, the viewers sheet being up. One stale flag and the
//      person-to-person swipe was dead for the rest of the session, which is a bug this app has now
//      had three separate times, always with a different flag holding the switch.
//    * **The landing flashed.** The page positions are MODEL values and the scroll offset is a
//      PRESENTATION value, so for one frame at the end of every turn they described different
//      instants and the geometry read a full page-width wrong. The code carried a jump guard, a skip
//      streak and a seed-on-first-sight rule to paper over it, and he still photographed it.
//
//  Both are consequences of not owning the animation. The reference app owns it: no scroll view
//  exists in their story container, every peer sits at THE SAME FRAME, and the only thing that
//  separates them is the rotation. There is nothing to disagree with, because there is one number —
//  `panFraction` — and this file is the only thing that writes it.
//
//  A TAP IS A PAN. Their `navigate(direction:)` synthesises a zero-length pan and commits it with a
//  velocity of ±200, so a tap and a finger-lift are not two behaviours kept in agreement; they are
//  one path entered twice. That is why theirs feel identical, and it is why `navigate` below does
//  exactly the same thing rather than calling a separate animator.
//
//  THE NUMBERS ARE THEIRS: commit at |fraction| >= 0.3 or |velocity| >= 100pt/s; settle over 0.4s on
//  a spring of mass 3, stiffness 1000, damping 500; rubber-band only at the ends, coefficient 0.4
//  over a range of 600; at most three peers alive; hit testing restricted to the focused peer; the
//  face tint a black axial gradient 1.0 -> 0.8 -> 0.5 at |fraction| x 1.3.
//
//  WHAT IS OURS AND MUST STAY: `StoryPager.cubeTransform`. It already concatenates the face push into
//  a single matrix, which is why each peer here can be a plain `UIView` with its content inside it
//  and no `CATransformLayer` is needed. There is also no `undoSlide` any more — that term existed
//  only to cancel `UIPageViewController`'s flat slide, and there is no flat slide left to cancel.
//

import UIKit
// Setting `state` from inside a recogniser subclass needs this, not plain UIKit.
import UIKit.UIGestureRecognizerSubclass

protocol StoryCubePagerDataSource: AnyObject {
    func cubePager(_ pager: StoryCubePagerVC, pageBefore vc: UIViewController) -> UIViewController?
    func cubePager(_ pager: StoryCubePagerVC, pageAfter vc: UIViewController) -> UIViewController?
}

protocol StoryCubePagerDelegate: AnyObject {
    /// A turn is starting, by finger or by tap. Raised before anything moves.
    func cubePagerWillBeginTurn(_ pager: StoryCubePagerVC)
    /// The turn has landed. `committed` is false when the finger was released short and the focused
    /// peer sprang back to where it started — the person asked for nothing and nothing changed.
    func cubePager(_ pager: StoryCubePagerVC, didSettleOn vc: UIViewController, committed: Bool)
}

final class StoryCubePagerVC: UIViewController {

    enum Direction { case next, previous }

    weak var dataSource: StoryCubePagerDataSource?
    weak var delegate: StoryCubePagerDelegate?

    /// The peer square to the camera. Everything else is derived from it.
    private(set) var focused: UIViewController?
    /// The two it can turn to, built from the data source and kept only while they are wanted.
    private var before: UIViewController?
    private var after: UIViewController?

    /// -1 ... 1, and the ONLY state the fold is computed from. Negative = the focused peer is
    /// turning away to the left, which is a finger moving left, which is "the next person".
    private var panFraction: CGFloat = 0

    /// TRUE while a finger is down or a settle is running. Everything that must not interrupt a turn
    /// asks this — it replaces the old scroll view's `isTracking || isDragging || isDecelerating`,
    /// and unlike that one it cannot be left switched off by somebody else's flag.
    var isActive: Bool { pan.state == .began || pan.state == .changed || settleLink != nil }

    /// Whether a horizontal drag may start one. False for a single bucket (nothing to turn to) and
    /// while the viewers sheet is up.
    var swipeEnabled: Bool = true {
        didSet { pan.isEnabled = swipeEnabled }
    }

    /// Exposed so the down/up dismiss pans can be given priority over it: a downward close and a
    /// sideways turn must never contest the same touch. See `installDismissPan`.
    private(set) lazy var pan: UIPanGestureRecognizer = {
        let p = HorizontalPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        return p
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.layer.cornerCurve = .continuous
        view.addGestureRecognizer(pan)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        view.backgroundColor = .black
    }

    /// The picture pulls away on a dismissal and the black must not come with it — the chat list has
    /// to show through. Carried across verbatim from the controller this replaces.
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isBeingDismissed { view.backgroundColor = .clear }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // ⚠️ EVERY PEER AT THE SAME FRAME. There is no page width and no content size here: two peers
        // occupy the identical rectangle and only the rotation tells them apart. Laying them out any
        // other way reintroduces a translation the cube would then have to undo.
        for vc in livePeers { vc.view.frame = view.bounds }
        applyFold()
    }

    private var livePeers: [UIViewController] { [before, focused, after].compactMap { $0 } }

    // MARK: - Pages in and out

    /// Put a peer on screen with no animation. Used for the first page and for a jump that is not to
    /// a neighbour (there is no cube between two people who are not adjacent).
    func setFocused(_ vc: UIViewController) {
        guard vc !== focused else { return }
        for peer in livePeers where peer !== vc { detach(peer) }
        before = nil; after = nil
        focused = vc
        attach(vc)
        panFraction = 0
        applyFold()
        loadNeighbours()
    }

    /// A TAP, AND THE SETTLE IT SHARES WITH THE FINGER. Their `navigate(direction:)`: begin a pan of
    /// zero length, update it to zero, and commit it with a velocity of ±200. One path, entered
    /// twice, which is the whole reason a tap and a swipe feel the same.
    ///
    /// Refused while a turn is live. A tap landing during one used to compute its destination from
    /// the page being LEFT, which is how repeated taps walked forwards and then jumped back to a
    /// person already passed — his 2026-08-12 report.
    @discardableResult
    func navigate(_ direction: Direction) -> Bool {
        guard !isActive else { return false }
        guard peer(in: direction) != nil else { return false }
        beginTurn()
        panFraction = 0
        applyFold()
        commit(velocity: direction == .next ? -200 : 200)
        return true
    }

    /// Is there anybody that way? The tap asks before it moves, so the caller can fall through to
    /// its own end-of-list behaviour rather than being told a turn happened that did not.
    func canNavigate(_ direction: Direction) -> Bool { peer(in: direction) != nil }

    private func peer(in direction: Direction) -> UIViewController? {
        direction == .next ? after : before
    }

    /// Build the two neighbours if they are not already here, and let go of anything that is neither.
    /// At most three peers are alive at once, which is their ceiling too.
    private func loadNeighbours() {
        guard let focused else { return }
        if before == nil, let vc = dataSource?.cubePager(self, pageBefore: focused) {
            before = vc
            attach(vc)
        }
        if after == nil, let vc = dataSource?.cubePager(self, pageAfter: focused) {
            after = vc
            attach(vc)
        }
        applyFold()
    }

    private func attach(_ vc: UIViewController) {
        guard vc.parent !== self else { return }
        addChild(vc)
        vc.view.frame = view.bounds
        vc.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // ⚠️ NEVER ITS OWN ANIMATION. Every face is written every frame from `panFraction`, and an
        // implicit CALayer action on top of that lags the fold by a frame and fights the settle.
        vc.view.layer.actions = ["transform": NSNull(), "position": NSNull(), "bounds": NSNull()]
        vc.view.layer.isDoubleSided = false   // the back of a face is not a picture, it is a mirror
        view.addSubview(vc.view)
        vc.didMove(toParent: self)
    }

    private func detach(_ vc: UIViewController) {
        guard vc.parent === self else { return }
        vc.willMove(toParent: nil)
        vc.view.removeFromSuperview()
        vc.removeFromParent()
        vc.view.layer.transform = CATransform3DIdentity
        tints[ObjectIdentifier(vc.view)]?.removeFromSuperlayer()
        tints.removeValue(forKey: ObjectIdentifier(vc.view))
    }

    // MARK: - The finger

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        let w = view.bounds.width
        guard w > 1 else { return }
        switch g.state {
        case .began:
            // ⚠️ A NEW PAN KILLS THE SETTLE IN FLIGHT, exactly as theirs removes the `panState`
            // animation. Without this the finger and the spring both write `panFraction` and the
            // cube stutters between two answers.
            stopSettle()
            beginTurn()
        case .changed:
            panFraction = banded(g.translation(in: view).x / w)
            applyFold()
        case .ended, .cancelled, .failed:
            commit(velocity: g.velocity(in: view).x)
        default:
            break
        }
    }

    /// Rubber-band, but ONLY where there is nobody to turn to. In the middle of a bucket list the
    /// finger is followed one-to-one, which is the half of this he reported missing.
    private func banded(_ raw: CGFloat) -> CGFloat {
        let f = max(-1, min(1, raw))
        if f < 0, after == nil { return -rubber(-f * view.bounds.width) / view.bounds.width }
        if f > 0, before == nil { return rubber(f * view.bounds.width) / view.bounds.width }
        return f
    }

    /// Their banding: `bandingStart 0`, `range 600`, `coefficient 0.4`.
    private func rubber(_ offset: CGFloat) -> CGFloat {
        let range: CGFloat = 600, coefficient: CGFloat = 0.4
        let bandedFraction = min(1, offset / range)
        return (1 - (1 - bandedFraction) * (1 - bandedFraction)) * range * coefficient
    }

    // MARK: - Commit and settle

    /// Their thresholds: past 0.3 of a width, or moving at 100pt/s, and the turn is taken. A tap
    /// arrives here with ±200, so it is always past the second one.
    private func commit(velocity vx: CGFloat) {
        let far = abs(panFraction) >= 0.3
        let fast = abs(vx) >= 100
        // Past the distance, the direction is where the finger DRAGGED; short of it, a commit can
        // only have come from speed, so the direction is where the finger was THROWN. A tap arrives
        // with a fraction of zero and a velocity of ±200, so it always reads as the second.
        let goNext = far ? panFraction < 0 : vx < 0
        guard let target = goNext ? after : before, far || fast else {
            settle(to: 0) { [weak self] in
                guard let self, let focused = self.focused else { return }
                self.delegate?.cubePager(self, didSettleOn: focused, committed: false)
            }
            return
        }
        // ⚠️ THE ORDER HERE IS LOAD-BEARING AND IT IS THEIRS: move the focus first, shift the
        // fraction by a whole face so the picture does not change, and only then let the settle run
        // that shift back down to zero. Written the other way round — settle, then swap — the two
        // pictures cross over one frame apart, which is precisely the flash he photographed.
        let outgoing = focused
        focused = target
        if goNext {
            before = outgoing
            after = nil
            panFraction += 1
        } else {
            after = outgoing
            before = nil
            panFraction -= 1
        }
        applyFold()
        settle(to: 0) { [weak self] in
            guard let self, let focused = self.focused else { return }
            // The peer that is now two away is released here rather than at the start of the turn:
            // it is on screen for the whole of it.
            self.releaseDistantPeers()
            self.loadNeighbours()
            self.delegate?.cubePager(self, didSettleOn: focused, committed: true)
        }
    }

    private func releaseDistantPeers() {
        guard let focused else { return }
        for peer in children where peer !== focused && peer !== before && peer !== after {
            detach(peer)
        }
    }

    private var settleLink: CADisplayLink?
    private var settleFrom: CGFloat = 0
    private var settleTo: CGFloat = 0
    private var settleStart: CFTimeInterval = 0
    private var settleDone: (() -> Void)?

    /// ⚠️ 0.12s IS HIS, NOT THEIRS. Theirs is 0.4.
    ///
    /// He asked for about a tenth of a second on 2026-08-11 and again, having watched the real cube
    /// on 2026-08-12, for 0.12 exactly. It is his call and it is now genuinely one number: while the
    /// turn belonged to `UIPageViewController` the only lever was `layer.speed = 3.0` on a private
    /// scroll view, which also silently accelerated the dismiss spring and kept the page hierarchy
    /// alive for a second after every turn. Owning the settle is what made this a constant.
    ///
    /// The spring is unaffected — `springProgress` is normalised over its own duration, so the same
    /// sampled curve simply plays faster and still lands exactly on 1.
    private static let settleDuration: CFTimeInterval = 0.12

    private func settle(to target: CGFloat, then done: @escaping () -> Void) {
        stopSettle()
        guard abs(panFraction - target) > 0.0001 else {
            panFraction = target
            applyFold()
            done()
            return
        }
        settleFrom = panFraction
        settleTo = target
        settleStart = CACurrentMediaTime()
        settleDone = done
        let link = CADisplayLink(target: self, selector: #selector(stepSettle))
        // `.common` so a settle that overlaps anything else on the main runloop still runs.
        link.add(to: .main, forMode: .common)
        settleLink = link
    }

    @objc private func stepSettle() {
        let elapsed = CACurrentMediaTime() - settleStart
        let u = min(1, CGFloat(elapsed / Self.settleDuration))
        panFraction = settleFrom + (settleTo - settleFrom) * Self.springProgress(u)
        applyFold()
        guard u >= 1 else { return }
        let done = settleDone
        stopSettle()
        done?()
    }

    private func stopSettle() {
        settleLink?.invalidate()
        settleLink = nil
        settleDone = nil
    }

    /// THEIR SPRING, SAMPLED — `CASpringAnimation(mass: 3, stiffness: 1000, damping: 500)`.
    ///
    /// ⚠️ THE SPRING IS IN THE VALUES, NOT IN THE TIMING. They sample it into a keyframe track and
    /// replay that track LINEARLY; applying a spring timing function to sprung values double-applies
    /// it. This function is that sampling in closed form.
    ///
    /// The damping ratio is about 4.56, so it is heavily OVERDAMPED — there is no overshoot to
    /// reproduce and the solution is two decaying exponentials. Normalised so it starts at exactly 0
    /// with zero slope and ends at exactly 1, because a settle that ends at 0.63 of the way is not a
    /// settle.
    static func springProgress(_ u: CGFloat) -> CGFloat {
        let t = max(0, min(1, u)) * springDuration
        return (1 - (r2 * exp(r1 * t) - r1 * exp(r2 * t)) / (r2 - r1)) / springFinal
    }

    private static let springDuration: CGFloat = 0.5
    /// Roots of the characteristic equation for mass 3, stiffness 1000, damping 500.
    private static let r1: CGFloat = -2.024770
    private static let r2: CGFloat = -164.642500
    /// What the un-normalised curve has reached at `springDuration`.
    private static let springFinal: CGFloat =
        1 - (r2 * exp(r1 * springDuration) - r1 * exp(r2 * springDuration)) / (r2 - r1)

    // MARK: - The fold

    private func beginTurn() {
        delegate?.cubePagerWillBeginTurn(self)
    }

    /// Write every face from the one number. This is the whole renderer.
    ///
    /// `t` is the face's own rotation fraction: 0 square to the camera, ±1 edge-on. The focused peer
    /// is at `panFraction`; the one to its right is a whole face further round, the one to its left a
    /// whole face back. Same sign convention as the transform it feeds, which is the convention the
    /// shipped cube already used: a page's screen-x over the width.
    private func applyFold() {
        let w = view.bounds.width
        guard w > 1 else { return }
        var order: [(vc: UIViewController, t: CGFloat)] = []
        if let focused { order.append((focused, panFraction)) }
        if let after { order.append((after, panFraction + 1)) }
        if let before { order.append((before, panFraction - 1)) }

        for (vc, t) in order {
            let face: UIView = vc.view
            // Hit testing belongs to the peer square to the camera and to nothing else, or a tap
            // meant for the story lands on a face that is edge-on behind it.
            face.isUserInteractionEnabled = (vc === focused) && abs(panFraction) < 0.0001
            if abs(t) > 1.0 {
                // Further away than one face: flat and invisible rather than left wearing whatever
                // it last had. A stale rotation on a peer nobody can see is a black slab the moment
                // the geometry is briefly right.
                face.layer.transform = CATransform3DIdentity
                face.isHidden = true
                tint(for: face)?.opacity = 0
                continue
            }
            face.isHidden = false
            if let g = tint(for: face) {
                g.frame = face.bounds
                // The darkening runs the other way depending on which edge the face is turning on.
                if t < 0 {
                    g.startPoint = CGPoint(x: 0, y: 0); g.endPoint = CGPoint(x: 1, y: 0)
                } else if t > 0 {
                    g.startPoint = CGPoint(x: 1, y: 0); g.endPoint = CGPoint(x: 0, y: 0)
                }
                g.opacity = Float(min(1, abs(t) * 1.3))
            }
            face.layer.transform = abs(t) < 0.0001
                ? CATransform3DIdentity                       // a resting face is pixel-perfect
                : StoryPager.cubeTransform(t, width: w)
        }

        // ⚠️ PAINTER'S ORDER, BECAUSE THESE ARE SEPARATE LAYER TREES AND NOT ONE 3D SCENE. Each face
        // composes its own matrix, so nothing sorts them by depth for us: the face nearest square to
        // the camera is the nearest one in the world and has to be drawn last. Re-ordered only when
        // the order actually changes — `bringSubviewToFront` every frame is churn.
        let sorted = order.sorted { abs($0.t) > abs($1.t) }.map { ObjectIdentifier($0.vc) }
        if sorted != lastPaintOrder {
            lastPaintOrder = sorted
            for (vc, _) in order.sorted(by: { abs($0.t) > abs($1.t) }) {
                view.bringSubviewToFront(vc.view)
            }
        }
    }

    private var lastPaintOrder: [ObjectIdentifier] = []

    // MARK: - The tint

    private var tints: [ObjectIdentifier: CAGradientLayer] = [:]

    /// The black axial gradient over each face, `1.0 -> 0.8 -> 0.5`, theirs. A sublayer of the face
    /// rather than a sibling, so it inherits the fold for free and is culled by the same
    /// `isDoubleSided = false` when the face turns away — `isDoubleSided` is per layer and is not
    /// inherited, so this one needs its own.
    private func tint(for face: UIView) -> CAGradientLayer? {
        let key = ObjectIdentifier(face)
        if let existing = tints[key], existing.superlayer === face.layer {
            // It has to stay on top: a UIView's subviews ARE its layer's sublayers, so anything the
            // page adds afterwards lands above this and the darkening silently stops being visible.
            if face.layer.sublayers?.last !== existing { face.layer.addSublayer(existing) }
            return existing
        }
        let g = CAGradientLayer()
        g.type = .axial
        g.colors = [UIColor.black.withAlphaComponent(1.0).cgColor,
                    UIColor.black.withAlphaComponent(0.8).cgColor,
                    UIColor.black.withAlphaComponent(0.5).cgColor]
        g.opacity = 0
        g.isDoubleSided = false
        g.actions = ["opacity": NSNull(), "position": NSNull(), "bounds": NSNull(),
                     "startPoint": NSNull(), "endPoint": NSNull()]
        face.layer.addSublayer(g)
        tints[key] = g
        return g
    }

    deinit { settleLink?.invalidate() }
}

/// A pan that only ever claims a HORIZONTAL drag, either way.
///
/// The library's `DirectionalPanGestureRecognizer` takes one direction at a time; a pager needs both
/// and needs them to lose to a vertical drag, because the same touch is offered to the swipe-down
/// close and the swipe-up viewers sheet. The first real movement decides, once.
final class HorizontalPanGestureRecognizer: UIPanGestureRecognizer {
    private var decided = false

    override func reset() {
        super.reset()
        decided = false
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard !decided else { return }
        let v = velocity(in: view)
        // Nothing to judge yet. Deciding on a zero vector would refuse every touch that begins
        // perfectly still, which is most of them.
        guard abs(v.x) > 0.01 || abs(v.y) > 0.01 else { return }
        decided = true
        guard abs(v.y) > abs(v.x) else { return }
        // ⚠️ `.failed` IS ONLY LEGAL BEFORE IT HAS BEGUN. A recogniser that has already begun must be
        // CANCELLED instead; UIKit asserts on the other transition.
        state = (state == .possible) ? .failed : .cancelled
    }
}
