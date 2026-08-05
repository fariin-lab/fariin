//
// Route A: UIKit UIPageViewController pager (replaces the SwiftUI TabView). The dismiss pan is added to
// the pager's OWN scroll view (a real direct subview) with require(toFail:), so cube (sideways) and
// dismiss (down) are mutually exclusive (the same page-controller mechanism). Each page hosts
// the existing SwiftUI StoryDetailView, so all the story logic (progress, reply, tap-advance) is reused.
// The cube fold itself is the existing rotation3DEffect inside StoryDetailView (reads its own position).
//

import SwiftUI
import UIKit

struct StoryPager: UIViewControllerRepresentable {
    @ObservedObject var viewModel: StoryViewModel
    @Binding var isPresented: Bool
    let userClosure: UserCompletionHandler?
    let onProfile: ((StoryUIUser) -> Void)?
    let onItemSeen: ((String) -> Void)?
    let showMore: Bool                    // show the header "…" dropdown menu
    let onDragChanged: (CGFloat) -> Void   // overlay fade only; the card itself moves in UIKit (smooth)
    let onCommit: () -> Void               // pulled past threshold -> dismiss
    let onCancel: () -> Void               // released short -> overlays restore
    let onSwipeUp: () -> Void              // up-swipe -> host opens the views sheet
    var onSwipeUpChanged: (CGFloat) -> Void = { _ in }   // LIVE upward drag amount (pts, +up) → real-time open
    var onSwipeUpEnded: (CGFloat, CGFloat) -> Void = { _, _ in }  // (translation +up, velocity +up) on release
    var dismissEnabled: Bool = true        // install the library's native DOWN dismiss pan (smooth UIKit)
    var swipeUpEnabled: Bool = true        // install the library's UP pan (false -> host owns swipe-up)

    // TRUE while a swipe-down dismiss drag/exit is running. The cube fold (getAngle) derives
    // its 3D angle from each page's GLOBAL minX — and the dismiss transform MOVES the card,
    // so a fast flick slammed the pages into a sudden violent fold (content flips away =
    // "wrong story/layout", edge-on = "black frame"). The cube must be inert during dismissal.
    static var dismissActive = false
    // The pager's horizontal scroll view: the cube may fold ONLY while THIS is live (a real
    // finger page-swipe: tracking/dragging/decelerating). Any other page movement — Apple's
    // zoom-transition interactive dismiss, layout shifts — must never fold the pages.
    static weak var horizontalScroll: UIScrollView?

    func makeUIViewController(context: Context) -> UIPageViewController {
        StoryPager.dismissActive = false   // fresh viewer never inherits a stale flag
        let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
        pager.dataSource = context.coordinator
        pager.delegate = context.coordinator
        pager.view.backgroundColor = .black   // solid card; slides as one unit during dismiss
        // The MEDIA is rounded inside StoryDetailView; the page itself stays square at rest (reply bar on
        // black, not in a card). cornerCurve is set so the dismiss-grow uses the Apple squircle.
        pager.view.layer.cornerCurve = .continuous
        context.coordinator.pager = pager
        if let first = context.coordinator.makePage(for: viewModel.currentStoryUser) {
            pager.setViewControllers([first], direction: .forward, animated: false)
        }
        DispatchQueue.main.async { context.coordinator.installDismissPan() }
        return pager
    }

    func updateUIViewController(_ pager: UIPageViewController, context: Context) {
        context.coordinator.syncIfNeeded()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // CADisplayLink retains its target (the coordinator), and the run loop retains the link, so deinit
    // never runs on its own -> leak + a per-frame wakeup that lives forever. Tear it down explicitly when
    // SwiftUI dismantles the representable (story closed).
    static func dismantleUIViewController(_ uiViewController: UIPageViewController, coordinator: Coordinator) {
        coordinator.cubeLink?.invalidate()
        coordinator.cubeLink = nil
        // The card is going away. Leaving a stale transform on a recycled view would open the next
        // story already shrunken, and the reference is weak but the MASK is not: detach clears both.
        StoryCardMorph.shared.detach()
    }

    // The cube transform (sideAngle = 0): perspective m34 = -1/500, Y-rotation up to 90°, plus the
    // cube-distance depth so the two faces meet at the shared edge, and a face push (+w/2 z) so the centred
    // page sits flat at full size (cancels the -w/2). t in [-1, 1]: 0 = flat centre, ±1 = edge-on.
    static func cubeTransform(_ t: CGFloat, width w: CGFloat) -> CATransform3D {
        let tc = max(-1, min(1, t))
        let absT = abs(tc)
        let angle = tc * (.pi / 2)
        let cubeDistance = 0.5 * w * (1.4142135623731 * sin((.pi / 2) * absT + .pi / 4) - 1.0)
        var perspective = CATransform3DIdentity
        perspective.m34 = -1.0 / 500.0
        var t3d = CATransform3DTranslate(perspective, 0, 0, -w * 0.5)
        t3d = CATransform3DTranslate(t3d, 0, 0, -cubeDistance)
        t3d = CATransform3DConcat(CATransform3DMakeRotation(angle, 0, 1, 0), t3d)
        let face = CATransform3DMakeTranslation(0, 0, w * 0.5)
        return CATransform3DConcat(face, t3d)
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
        let parent: StoryPager
        weak var pager: UIPageViewController?
        weak var internalScroll: UIScrollView?
        // Stationary blurred backdrop revealed BEHIND the card during swipe-down (instead of black). It does
        // not move with the drag — only the card (internalScroll) translates — so the gap shows the blur.
        private let dismissBackdrop = UIImageView()
        private let dismissBlur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterialDark))
        private var didInstallPan = false
        private weak var dismissPan: DirectionalPanGestureRecognizer?   // ours — system pans defer to it
        fileprivate var cubeLink: CADisplayLink?   // fileprivate so dismantleUIViewController can invalidate it
        // Baseline translation captured the instant the swipe-UP pan engages. The recognizer only
        // begins after the finger has already travelled ~its 8pt threshold plus whatever it moved
        // while the competing pans were failing — so translation(in:) is already ~30-40pt at the
        // first .changed. Reporting that raw value made the card JUMP ~5% the moment the sheet
        // engaged (user's red-border test: a 12px snap at t=0.94). Subtracting this baseline makes
        // the drag start from ZERO at engagement, so the card tracks smoothly from full size.
        private var swipeUpBaselineY: CGFloat?

        init(_ parent: StoryPager) { self.parent = parent }
        deinit { cubeLink?.invalidate() }

        private func index(of id: String) -> Int? {
            parent.viewModel.stories.firstIndex { $0.id == id }
        }

        func makePage(for id: String) -> StoryPageHostVC? {
            guard let idx = index(of: id) else { return nil }
            let model = parent.viewModel.stories[idx]
            let root = StoryDetailView(
                viewModel: parent.viewModel,
                model: model,
                isPresented: parent.$isPresented,
                userClosure: parent.userClosure,
                onProfile: parent.onProfile,
                onItemSeen: parent.onItemSeen,
                showMore: parent.showMore
            )
            let vc = StoryPageHostVC(rootView: AnyView(root))
            vc.bucketID = id
            return vc
        }

        // Keep the visible page synced if currentStoryUser changes from outside the pager (e.g. tap-advance
        // off the end of a bucket sets the next user).
        // Own story (host owns the swipe): fully neutralize the pager's internal scroll so its
        // horizontal pan/bounce can't fight the host's vertical dismiss drag (the shaky double-image).
        func neutralizePagerScrollIfHostOwnsSwipe() {
            // Own story = a SINGLE bucket: nothing to navigate to horizontally, so kill the internal
            // scroll (its bounce would fight the vertical dismiss pan). Friends have multiple buckets
            // and keep it for user-to-user swipe.
            guard parent.viewModel.stories.count <= 1, let scroll = internalScroll else { return }
            scroll.isScrollEnabled = false
            scroll.panGestureRecognizer.isEnabled = false
            scroll.bounces = false
            scroll.alwaysBounceHorizontal = false
        }

        func syncIfNeeded() {
            neutralizePagerScrollIfHostOwnsSwipe()   // re-assert on every update; UIPageViewController may reset it
            guard let pager else { return }
            let shown = (pager.viewControllers?.first as? StoryPageHostVC)?.bucketID
            // Initial population: stories/currentStoryUser weren't ready at makeUIViewController time
            // (startStory runs in .onAppear, after), so the pager came up empty -> black. Fill it now.
            if shown == nil {
                if let first = makePage(for: parent.viewModel.currentStoryUser) {
                    pager.setViewControllers([first], direction: .forward, animated: false)
                }
                return
            }
            guard shown != parent.viewModel.currentStoryUser,
                  let from = index(of: shown!), let to = index(of: parent.viewModel.currentStoryUser),
                  let target = makePage(for: parent.viewModel.currentStoryUser)
            else { return }
            pager.setViewControllers([target], direction: to > from ? .forward : .reverse, animated: true)
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
            guard let cur = (vc as? StoryPageHostVC)?.bucketID, let i = index(of: cur), i > 0 else { return nil }
            return makePage(for: parent.viewModel.stories[i - 1].id)
        }
        func pageViewController(_ pvc: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
            guard let cur = (vc as? StoryPageHostVC)?.bucketID, let i = index(of: cur),
                  i < parent.viewModel.stories.count - 1 else { return nil }
            return makePage(for: parent.viewModel.stories[i + 1].id)
        }

        func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let cur = (pvc.viewControllers?.first as? StoryPageHostVC)?.bucketID else { return }
            parent.viewModel.currentStoryUser = cur   // StoryView's onChange fires onUserChanged
        }

        // MARK: dismiss pan (down only) + require-to-fail on the pager's own scroll
        /// How many times the scroll-view lookup below has come up empty. Capped so a pager that
        /// genuinely never builds one cannot spin forever.
        private var bindAttempts = 0

        func installDismissPan() {
            guard !didInstallPan, let pager else { return }
            // THE ONE-SHOT FLAG USED TO BE SET HERE, BEFORE WE KNEW WE HAD ANYTHING, and that is why
            // the viewers sheet came up over a full-size story that never shrank.
            //
            // This runs one runloop tick after `makeUIViewController`, and a UIPageViewController has
            // not always built its internal scroll view by then. When it had not, `scroll` was nil,
            // `internalScroll` and `StoryCardMorph.shared.card` were both set to nil, and
            // `didInstallPan = true` meant it never looked again. The morph then silently did nothing
            // for the whole session: `apply` guards on `card` and returns, so the story stayed exactly
            // where it was while the sheet slid up over it. That is his screenshot.
            //
            // It failed silently in the worst way — the swipe-down dismiss still worked, because that
            // pan goes on `pager.view` rather than on the scroll view, so nothing looked broken until
            // somebody pulled the sheet.
            guard let scroll = pager.view.subviews.compactMap({ $0 as? UIScrollView }).first else {
                guard bindAttempts < 20 else { return }
                bindAttempts += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.installDismissPan()
                }
                return
            }
            didInstallPan = true
            internalScroll = scroll
            StoryPager.horizontalScroll = scroll   // getAngle gates the cube on ITS live activity
            // The SAME view the dismiss pan transforms is the one the viewers sheet shrinks. There is
            // no second card and no picture of the story anywhere: see StoryCardMorph.
            StoryCardMorph.shared.attach(scroll)
            // When the host owns the swipe (own story: app-level SwiftUI dismiss), the pager's internal
            // scroll pan has nothing to navigate to (single bucket) and only CONTENDS with the host drag
            // for the same touch — that horizontal scroll/bounce fighting the vertical drag is the
            // "shaky"/double-image swipe-down. Fully neutralize it (scroll off + pan recognizer off +
            // no bounce). Friends keep it for user-to-user swipe. Re-applied in syncIfNeeded so a
            // UIPageViewController internal reset can't turn it back on.
            neutralizePagerScrollIfHostOwnsSwipe()
            // Stationary blurred backdrop behind the pages: hidden at rest, shown only during a dismiss drag
            // so the area the card uncovers (above it) is a blurred copy of the story, not black.
            dismissBackdrop.contentMode = .scaleAspectFill
            dismissBackdrop.clipsToBounds = true
            dismissBackdrop.frame = pager.view.bounds
            dismissBackdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            dismissBackdrop.isHidden = true
            dismissBlur.frame = pager.view.bounds
            dismissBlur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            dismissBlur.isHidden = true
            pager.view.insertSubview(dismissBackdrop, at: 0)
            pager.view.insertSubview(dismissBlur, aboveSubview: dismissBackdrop)
            // DOWN dismiss pan (native UIKit — smooth). Installed for BOTH own and friends now, so the
            // own-story swipe-down uses the exact same buttery pan friends use (no app-level SwiftUI
            // offset). The card moves in pure UIKit; require(toFail:) keeps the horizontal slide separate.
            if !parent.dismissEnabled {
                // PASSIVE watcher over Apple's native zoom-dismiss (user rule: never touch the
                // native close animation): it moves NOTHING — it only (a) pauses the story the
                // moment a downward drag starts and (b) COMMITS the close on a fast flick, which
                // the system's interactive dismissal tends to bounce back ("fast doesn't work").
                let watch = DirectionalPanGestureRecognizer(direction: .down, target: self, action: #selector(handleDismissWatch(_:)))
                watch.delegate = self
                watch.cancelsTouchesInView = false
                pager.view.addGestureRecognizer(watch)
            }
            if parent.dismissEnabled {
                let pan = DirectionalPanGestureRecognizer(direction: .down, target: self, action: #selector(handleDismiss(_:)))
                pan.delegate = self
                pager.view.addGestureRecognizer(pan)
                scroll.panGestureRecognizer.require(toFail: pan)
                dismissPan = pan
                // The zoom navigationTransition installs its OWN hidden interactive-dismiss pan on the
                // presentation chain, and it wins the race on fast flicks (re-lays-out the cover mid-
                // drag: wrong story flash, black frame, stuck dismissal — and it IGNORES
                // .interactiveDismissDisabled, device-proven on build 220). Subordinate it: any SYSTEM
                // pan up the chain must WAIT for our pan to fail — ours begins on every real downward
                // drag, so the system gesture never engages during drags, while X/auto closes (no pan)
                // keep the zoom-back hero. The recognizer only exists once presentation settles, so
                // try shortly after mount and again after the transition completes.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.subordinateSystemPans() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.subordinateSystemPans() }
            }
            // UP pan opens the views sheet. NOT installed for own stories — the host owns swipe-up there
            // (real-time viewers-sheet tracking), so the library up pan would double-fire.
            if parent.swipeUpEnabled {
                let upPan = DirectionalPanGestureRecognizer(direction: .up, target: self, action: #selector(handleSwipeUp(_:)))
                upPan.delegate = self
                pager.view.addGestureRecognizer(upPan)
                scroll.panGestureRecognizer.require(toFail: upPan)
            }
            // NO UIKit cube display-link: the cube is now the StoryUI library's SwiftUI rotation3DEffect
            // (getAngle in StoryDetailView). The old CADisplayLink applyCube fought it and caused the
            // shake/black, so it's disabled — the pager just provides the horizontal slide.
        }

        // The cube: rotate each page around the shared vertical edge with perspective depth, driven
        // by its position relative to screen centre. Centre page = flat; ±1 page = 90° (edge-on, hidden).
        @objc func applyCube() {
            guard let scroll = internalScroll else { return }
            // Only do per-frame transform work while a horizontal swipe is actually in motion. At rest the
            // pages are already settled (centred page = identity from the last frame), so skip the churn.
            guard scroll.isDragging || scroll.isDecelerating || scroll.isTracking else { return }
            let w = scroll.bounds.width
            guard w > 1 else { return }
            for sub in scroll.subviews {
                guard abs(sub.bounds.width - w) < 1.0 else { continue }   // page-sized views only
                // Read the UNTRANSFORMED position (layer.position is the layout anchor, unaffected by our
                // transform), NOT sub.frame.minX — once a 3D transform is set, `frame` becomes the transformed
                // bounding box, so reading it back fed our own rotation into the next frame's math. That
                // feedback loop was the SHAKE, and its drift pushed pages off-screen → the BLACK flash.
                let pageMinX = sub.layer.position.x - sub.bounds.width / 2
                let relX = pageMinX - scroll.contentOffset.x              // page's screen-x (0 = centred, ±w = neighbour)
                let t = relX / w
                sub.layer.isDoubleSided = false                            // hide the back face
                if abs(t) < 0.001 {
                    sub.layer.transform = CATransform3DIdentity            // resting page is pixel-perfect
                } else if abs(t) <= 1.0 {
                    // Undo the scroll's flat slide FIRST, then rotate — so the cube anchors to the screen
                    // edge instead of stacking rotation on top of the slide. The transform drives the cube from
                    // the pan alone with no scroll translation underneath (confirmed from StoryContainerScreen);
                    // this makes our UIPageViewController scroll behave the same way visually.
                    let undoSlide = CATransform3DMakeTranslation(-relX, 0, 0)
                    sub.layer.transform = CATransform3DConcat(StoryPager.cubeTransform(t, width: w), undoSlide)
                }
            }
        }

        // Rides ALONGSIDE the system zoom-dismiss without influencing it (cancelsTouchesInView
        // false, simultaneous recognition). Pause on drag-start; commit fast flicks via the
        // SAME native dismissal (isPresented=false → the zoom-back hero plays — no custom anim).
        @objc func handleDismissWatch(_ g: UIPanGestureRecognizer) {
            guard let pager else { return }
            switch g.state {
            case .began:
                NotificationCenter.default.post(name: .pauseStory, object: nil)
            case .ended:
                let ty = g.translation(in: pager.view).y
                let vy = g.velocity(in: pager.view).y
                if ty > 20, vy > 800 {
                    NotificationCenter.default.post(name: .stopVideo, object: nil)
                    NotificationCenter.default.post(name: Notification.Name("storyForceClose"), object: nil)
                } else {
                    // Released gently: the system gesture decides commit/cancel on its own;
                    // resume so a cancelled drag never leaves the story frozen.
                    NotificationCenter.default.post(name: .resumeStory, object: nil)
                }
            case .cancelled, .failed:
                NotificationCenter.default.post(name: .resumeStory, object: nil)
            default: break
            }
        }

        @objc func handleDismiss(_ g: UIPanGestureRecognizer) {
            guard let pager, let card = internalScroll else { return }
            let t = g.translation(in: pager.view)
            switch g.state {
            case .began:
                StoryPager.dismissActive = true   // freeze the cube: no 3D fold while the card moves
                // SEE-THROUGH dismissal (user reference): the shrinking card must reveal the CHAT
                // LIST behind the cover, not a blurred copy of itself. The stationary container
                // goes clear (the cover's presentation background is already clear at rest); the
                // MOVING card keeps its own solid backing so the story never turns transparent.
                card.backgroundColor = .black
                pager.view.backgroundColor = .clear
                dismissBackdrop.isHidden = true
                dismissBlur.isHidden = true
                NotificationCenter.default.post(name: .pauseStory, object: nil)   // freeze for the whole drag
            case .changed:
                let ty = max(0, t.y)
                let frac = min(1, ty / card.bounds.height)
                // Reference video (user's chosen close): the card shrinks HARD as you pull —
                // down to ~30% at a full drag — floating over the live chat list, with a light
                // horizontal follow. It shrinks in place; it does not ride off with the finger.
                let scale = 1.0 - 0.7 * frac
                card.layer.cornerCurve = .continuous    // Apple squircle
                // CLIPPED TO THE STORY, NOT TO THE PAGE, which is the black header he circled. The
                // page is taller than the 9:16 card and the strip above it is the page's own black
                // background; rounding the PAGE shrank that strip into view as a black band inside
                // the card. Masking to the story means what pulls away is the story. See
                // StoryCardMorph.maskToCard.
                StoryCardMorph.shared.maskToCard(cornerRadius: min(40, ty * 0.3), scale: scale)
                // Horizontal follow clamped: a flick's large t.x must not yank the card sideways.
                let tx = max(-60, min(60, t.x * 0.7))
                card.transform = CGAffineTransform(translationX: tx, y: ty * 0.85)
                    .scaledBy(x: scale, y: scale)
                parent.onDragChanged(ty)                // fade the host overlays
            case .ended, .cancelled:
                let ty = t.y, vy = g.velocity(in: pager.view).y
                // commit threshold: translation.y > 200 OR (translation.y > 5 AND velocity.y > 200)
                if ty > 200 || (ty > 5 && vy > 200) {
                    // Dismiss → STOP playback/timer for good (don't resume). The story was already paused on
                    // .began; killing the video here means no audio/frame keeps running behind the dismissal.
                    NotificationCenter.default.post(name: .stopVideo, object: nil)
                    // Reference video (user's chosen close): the card SHRINKS AND MELTS AWAY in
                    // place over the visible chat list. It must NOT slide off the bottom — the
                    // slide-off exit was the rejected look. Same exit at every drag depth/speed.
                    let exitScale: CGFloat = 0.12
                    let exitTx = max(-60, min(60, t.x * 0.7))   // clamped like the drag
                    UIView.animate(withDuration: 0.24, delay: 0, options: [.curveEaseIn]) {
                        card.transform = CGAffineTransform(translationX: exitTx, y: max(0, t.y) * 0.85 + 40)
                            .scaledBy(x: exitScale, y: exitScale)
                        card.alpha = 0
                    } completion: { _ in
                        self.parent.onCommit()
                        card.alpha = 1   // reset in case the pager is ever reused
                        StoryPager.dismissActive = false
                    }
                } else {
                    NotificationCenter.default.post(name: .resumeStory, object: nil)   // sprang back -> resume
                    UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85,
                                   initialSpringVelocity: 0.3, options: []) {
                        card.transform = .identity
                        card.layer.cornerRadius = 0   // back to square (the media keeps its own rounding)
                    } completion: { _ in
                        // The dismiss clip comes off only once the card is home, or the story would
                        // pop back to full-page bounds mid-spring.
                        StoryCardMorph.shared.clearMask()
                        self.pager?.view.backgroundColor = .black   // restore the solid backing at rest
                        StoryPager.dismissActive = false            // cube live again at rest
                        self.parent.onCancel()
                    }
                }
            default: break
            }
        }

        // One-time snapshot of the live card, used as the stationary backdrop during the dismiss drag.
        private func snapshot(_ view: UIView) -> UIImage? {
            guard view.bounds.width > 1, view.bounds.height > 1 else { return nil }
            let r = UIGraphicsImageRenderer(bounds: view.bounds)
            return r.image { _ in view.drawHierarchy(in: view.bounds, afterScreenUpdates: false) }
        }
        @objc func handleSwipeUp(_ g: UIPanGestureRecognizer) {
            guard let pager else { return }
            // WINDOW space, not pager space: the sheet-open morph SCALES the pager while this
            // pan is live, so pager-space deltas get amplified by 1/scale — a compounding
            // feedback loop that made the sheet leave the finger at ~50% and fly open on its
            // own (user report; same disease as the sheet drag's old .local-space bug).
            let space: UIView = pager.view.window ?? pager.view
            let t = g.translation(in: space)
            let v = g.velocity(in: space)
            // Report the drag CONTINUOUSLY so the host tracks the viewers sheet 1:1 with the finger
            // (native feel), then decides open/close on release. Direction-locked to .up, so it never
            // fights the down dismiss pan. The drag is measured from the ENGAGEMENT point (baseline),
            // not from touch-down, so the first frame reports ~0 instead of the accumulated wake-up
            // distance (that was the ~5% engagement snap the user measured).
            switch g.state {
            case .began:
                swipeUpBaselineY = t.y
            case .changed:
                if swipeUpBaselineY == nil { swipeUpBaselineY = t.y }
                let up = -(t.y - (swipeUpBaselineY ?? t.y))    // +up, zeroed at engagement
                parent.onSwipeUpChanged(max(0, up))
            case .ended, .cancelled:
                let up = -(t.y - (swipeUpBaselineY ?? t.y))
                parent.onSwipeUpEnded(up, -v.y)                // translation +up (from engagement), velocity +up
                swipeUpBaselineY = nil
            default: break
            }
        }

        // Walk the presentation chain (pager → window) and make every SYSTEM pan recognizer —
        // identified by Apple's private "_UI…" class-name prefix (name READ only, no private API
        // called) — wait for our dismiss pan to fail. SwiftUI's own gesture host recognizers
        // ("SwiftUI.…") and the scroll pans are untouched. Idempotent; if nothing matches
        // (future iOS moves it), behavior simply stays as before — graceful no-op.
        private func subordinateSystemPans() {
            guard let pan = dismissPan, let v = pager?.view else { return }
            var node: UIView? = v.superview
            while let cur = node {
                for g in cur.gestureRecognizers ?? [] where g !== pan {
                    guard g is UIPanGestureRecognizer else { continue }
                    if NSStringFromClass(type(of: g)).hasPrefix("_UI") {
                        g.require(toFail: pan)
                    }
                }
                node = cur.superview   // ends at (and includes) the UIWindow
            }
        }

        // Let our pans coexist with EVERYTHING: the hosted SwiftUI gestures (tap zones,
        // hold-to-pause), the page scroll, and — critically — the system zoom-dismiss pan,
        // which the passive watcher must ride alongside without ever blocking it. (The old
        // "_UI…" exclusion protected the CUSTOM card pan from double-driving; that pan is
        // inert now, and excluding the system pan would kill the native close outright.)
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool { true }
    }
}

// Hosts one bucket's StoryDetailView; remembers which bucket it is for the dataSource lookups.
final class StoryPageHostVC: UIHostingController<AnyView> {
    var bucketID: String = ""
    override init(rootView: AnyView) {
        super.init(rootView: rootView)
        view.backgroundColor = .clear
        // The story photo must fill edge-to-edge UNDER the status bar. A UIHostingController insets
        // its SwiftUI content by the safe area by default — THAT was the black strip at the top. Turn it off;
        // the progress bars + reply bar re-add their own safe-area padding inside StoryDetailView.
        if #available(iOS 16.4, *) { safeAreaRegions = [] }
    }
    @MainActor required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
