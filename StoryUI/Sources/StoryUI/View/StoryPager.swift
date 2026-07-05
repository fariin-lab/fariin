//
// Route A: UIKit UIPageViewController pager (replaces the SwiftUI TabView). The dismiss pan is added to
// the pager's OWN scroll view (a real direct subview) with require(toFail:), so cube (sideways) and
// dismiss (down) are mutually exclusive (Signal's StoryPageViewController mechanism). Each page hosts
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
    let onSwipeUp: () -> Void              // up-swipe -> host opens the views sheet (Telegram)
    var onSwipeUpChanged: (CGFloat) -> Void = { _ in }   // LIVE upward drag amount (pts, +up) → real-time open
    var onSwipeUpEnded: (CGFloat, CGFloat) -> Void = { _, _ in }  // (translation +up, velocity +up) on release
    var dismissEnabled: Bool = true        // install the library's native DOWN dismiss pan (smooth UIKit)
    var swipeUpEnabled: Bool = true        // install the library's UP pan (false -> host owns swipe-up)

    func makeUIViewController(context: Context) -> UIPageViewController {
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
    }

    // Telegram's cube transform (sideAngle = 0): perspective m34 = -1/500, Y-rotation up to 90°, plus the
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
        fileprivate var cubeLink: CADisplayLink?   // fileprivate so dismantleUIViewController can invalidate it

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
        func installDismissPan() {
            guard !didInstallPan, let pager else { return }
            didInstallPan = true
            let scroll = pager.view.subviews.compactMap { $0 as? UIScrollView }.first
            internalScroll = scroll
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
            if parent.dismissEnabled {
                let pan = DirectionalPanGestureRecognizer(direction: .down, target: self, action: #selector(handleDismiss(_:)))
                pan.delegate = self
                pager.view.addGestureRecognizer(pan)
                scroll?.panGestureRecognizer.require(toFail: pan)
            }
            // UP pan opens the views sheet. NOT installed for own stories — the host owns swipe-up there
            // (real-time viewers-sheet tracking), so the library up pan would double-fire.
            if parent.swipeUpEnabled {
                let upPan = DirectionalPanGestureRecognizer(direction: .up, target: self, action: #selector(handleSwipeUp(_:)))
                upPan.delegate = self
                pager.view.addGestureRecognizer(upPan)
                scroll?.panGestureRecognizer.require(toFail: upPan)
            }
            // NO UIKit cube display-link: the cube is now the StoryUI library's SwiftUI rotation3DEffect
            // (getAngle in StoryDetailView). The old CADisplayLink applyCube fought it and caused the
            // shake/black, so it's disabled — the pager just provides the horizontal slide.
        }

        // Telegram's cube: rotate each page around the shared vertical edge with perspective depth, driven
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
                    // edge instead of stacking rotation on top of the slide. Telegram drives the cube from
                    // the pan alone with no scroll translation underneath (confirmed from StoryContainerScreen);
                    // this makes our UIPageViewController scroll behave the same way visually.
                    let undoSlide = CATransform3DMakeTranslation(-relX, 0, 0)
                    sub.layer.transform = CATransform3DConcat(StoryPager.cubeTransform(t, width: w), undoSlide)
                }
            }
        }

        @objc func handleDismiss(_ g: UIPanGestureRecognizer) {
            guard let pager, let card = internalScroll else { return }
            let t = g.translation(in: pager.view)
            switch g.state {
            case .began:
                // Snapshot the current card, show it (blurred) as the stationary backdrop the drag uncovers.
                dismissBackdrop.image = snapshot(card)
                dismissBackdrop.isHidden = false
                dismissBlur.isHidden = false
                NotificationCenter.default.post(name: .pauseStory, object: nil)   // freeze for the whole drag
            case .changed:
                let ty = max(0, t.y)
                let frac = min(1, ty / card.bounds.height)
                let scale = 1.0 - 0.4 * frac            // Telegram: card scales 1.0 -> 0.6 as you pull
                card.layer.cornerCurve = .continuous    // Apple squircle
                card.layer.cornerRadius = min(40, ty * 0.3) // grows from 0 as you pull down
                card.layer.masksToBounds = true
                // Move ONLY the card; the backdrop stays put, so the area above it shows the blur, not black.
                card.transform = CGAffineTransform(translationX: 0, y: ty).scaledBy(x: scale, y: scale)
                parent.onDragChanged(ty)                // fade the host overlays
            case .ended, .cancelled:
                let ty = t.y, vy = g.velocity(in: pager.view).y
                // Telegram commit: translation.y > 200 OR (translation.y > 5 AND velocity.y > 200)
                if ty > 200 || (ty > 5 && vy > 200) {
                    // Dismiss → STOP playback/timer for good (don't resume). The story was already paused on
                    // .began; killing the video here means no audio/frame keeps running behind the dismissal.
                    NotificationCenter.default.post(name: .stopVideo, object: nil)
                    // Exit at the size the drag already reached (1 - 0.4*frac), not a forced 0.6.
                    // A velocity commit (fast flick) releases near full size; forcing 0.6 there read
                    // as a sudden zoom. A slow full drag has already reached ~0.6 — unchanged look.
                    let exitFrac = min(1, max(0, ty) / card.bounds.height)
                    let exitScale = 1.0 - 0.4 * exitFrac
                    // ONE shared exit for distance AND velocity commits: continue the linear slide from
                    // the release point at (roughly) the finger's release speed. The old fixed 0.25s
                    // ease-IN visibly decelerated right after a fast flick (finger leaves fast, card
                    // almost stops, then re-accelerates) — read as an abrupt/system-y jump. Linear +
                    // velocity-matched duration makes the flick exit flow seamlessly out of the gesture;
                    // a slow-drag release only has a short remainder, so it looks the same as before.
                    let remaining = max(1, card.bounds.height - max(0, ty))
                    let speed = max(vy, 1100)                     // pts/s floor: slow commits still finish briskly
                    let duration = min(0.3, max(0.12, remaining / speed))
                    UIView.animate(withDuration: duration, delay: 0, options: [.curveLinear]) {
                        card.transform = CGAffineTransform(translationX: 0, y: card.bounds.height).scaledBy(x: exitScale, y: exitScale)
                    } completion: { _ in self.parent.onCommit() }
                } else {
                    NotificationCenter.default.post(name: .resumeStory, object: nil)   // sprang back -> resume
                    UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85,
                                   initialSpringVelocity: 0.3, options: []) {
                        card.transform = .identity
                        card.layer.cornerRadius = 0   // back to square (the media keeps its own rounding)
                    } completion: { _ in
                        self.dismissBackdrop.isHidden = true
                        self.dismissBlur.isHidden = true
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
            let t = g.translation(in: pager.view)
            let v = g.velocity(in: pager.view)
            // Report the drag CONTINUOUSLY so the host tracks the viewers sheet 1:1 with the finger
            // (native feel), then decides open/close on release. Direction-locked to .up, so it never
            // fights the down dismiss pan.
            switch g.state {
            case .changed:
                parent.onSwipeUpChanged(max(0, -t.y))          // +up
            case .ended, .cancelled:
                parent.onSwipeUpEnded(-t.y, -v.y)              // translation +up, velocity +up
            default: break
            }
        }

        // Let the dismiss/swipe-up pans coexist with the hosted SwiftUI gestures (tap zones, hold-to-pause)
        // and the page scroll. Returning false here blocked the pans whenever the content was tracking a
        // touch, so swipe-down-to-close and swipe-up never fired. The horizontal-scroll relationship is
        // still ordered by require(toFail:), so this doesn't double-handle paging.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool { true }
    }
}

// Hosts one bucket's StoryDetailView; remembers which bucket it is for the dataSource lookups.
final class StoryPageHostVC: UIHostingController<AnyView> {
    var bucketID: String = ""
    override init(rootView: AnyView) {
        super.init(rootView: rootView)
        view.backgroundColor = .clear
        // The story photo must fill edge-to-edge UNDER the status bar (WhatsApp). A UIHostingController insets
        // its SwiftUI content by the safe area by default — THAT was the black strip at the top. Turn it off;
        // the progress bars + reply bar re-add their own safe-area padding inside StoryDetailView.
        if #available(iOS 16.4, *) { safeAreaRegions = [] }
    }
    @MainActor required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
