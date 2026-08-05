//
// Route B: the single own-bucket host. My own story never pages between people (it is always one
// bucket), so it does not need UIPageViewController — and the viewers-sheet morph is the reason it
// must not have one. The morph used to transform the page controller's INTERNAL UIScrollView, a
// view whose `bounds.origin` is the content offset and whose gesture plumbing had to be disabled,
// masked around and generally argued with (see StoryCardMorph's history). Telegram's story viewer
// has no page controller and no scroll view anywhere in this interaction: their vertical pan
// scales a plain container they own (`StoryItemSetContainerComponent`, `contentContainerView`,
// CATransform3DMakeScale on the LIVE hierarchy). This host gives us the same thing: one plain
// `cardContainer` that every gesture transforms, with nothing of Apple's fighting underneath.
//
// Friends' stories keep StoryPager (multi-bucket cube paging + its dismiss pans, untouched).
//

import SwiftUI
import UIKit

struct StorySoloPager: UIViewControllerRepresentable {
    @ObservedObject var viewModel: StoryViewModel
    @Binding var isPresented: Bool
    let userClosure: UserCompletionHandler?
    let onProfile: ((StoryUIUser) -> Void)?
    let onItemSeen: ((String) -> Void)?
    let showMore: Bool
    let onDragChanged: (CGFloat) -> Void   // overlay fade only; the card itself moves in UIKit
    let onCommit: () -> Void               // pulled past threshold -> dismiss
    let onCancel: () -> Void               // released short -> overlays restore
    var onSwipeUpChanged: (CGFloat) -> Void = { _ in }   // LIVE upward drag amount (pts, +up)
    var onSwipeUpEnded: (CGFloat, CGFloat) -> Void = { _, _ in }  // (translation +up, velocity +up)
    var dismissEnabled: Bool = true        // true: library's own DOWN dismiss pan; false: Apple's
                                           // zoom-dismiss owns the close, we only watch it

    func makeUIViewController(context: Context) -> StorySoloHostVC {
        StoryPager.dismissActive = false   // fresh viewer never inherits a stale flag
        // No pager here, so no horizontal scroll can ever exist. getAngle treats a nil scroll as
        // "no live swipe" and keeps the cube flat, which for a single bucket is always correct.
        StoryPager.horizontalScroll = nil
        let vc = StorySoloHostVC()
        context.coordinator.host = vc
        context.coordinator.installPans(on: vc)
        return vc
    }

    func updateUIViewController(_ vc: StorySoloHostVC, context: Context) {
        context.coordinator.parent = self
        context.coordinator.installContentIfNeeded()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    static func dismantleUIViewController(_ vc: StorySoloHostVC, coordinator: Coordinator) {
        // ITS OWN container is passed, not a bare detach: SwiftUI dismantles this representable
        // AFTER building its replacement, and an unconditional detach here would clear the NEW
        // viewer's binding. Same rule as StoryPager — see StoryCardMorph.detach.
        StoryCardMorph.shared.detach(vc.cardContainer)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: StorySoloPager
        weak var host: StorySoloHostVC?
        private weak var dismissPan: DirectionalPanGestureRecognizer?
        // Baseline translation captured the instant the swipe-UP pan engages: the recognizer only
        // begins after ~8pt plus whatever moved while competing pans were failing, so the first
        // .changed already carries ~30-40pt. Reporting that raw value made the card JUMP the moment
        // the sheet engaged (the ~5% snap the owner measured with a red border). Zeroing at
        // engagement makes the card track from full size. Same fix as StoryPager's.
        private var swipeUpBaselineY: CGFloat?

        init(_ parent: StorySoloPager) { self.parent = parent }

        /// The bucket's StoryDetailView, hosted once the view model has it. `startStory` runs in
        /// the SwiftUI onAppear AFTER makeUIViewController, so the model is not there at make time
        /// — the same reason StoryPager fills its first page from syncIfNeeded.
        func installContentIfNeeded() {
            guard let host, host.isViewLoaded, host.content == nil,
                  let model = parent.viewModel.stories.first else { return }
            let root = StoryDetailView(
                viewModel: parent.viewModel,
                model: model,
                isPresented: parent.$isPresented,
                userClosure: parent.userClosure,
                onProfile: parent.onProfile,
                onItemSeen: parent.onItemSeen,
                showMore: parent.showMore
            )
            let hc = StoryPageHostVC(rootView: AnyView(root))   // clear bg + safeAreaRegions = []
            host.addChild(hc)
            hc.view.frame = host.cardContainer.bounds
            hc.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            host.cardContainer.addSubview(hc.view)
            hc.didMove(toParent: host)
            host.content = hc
        }

        func installPans(on vc: StorySoloHostVC) {
            vc.loadViewIfNeeded()
            // UP pan opens the views sheet, reported continuously so the host tracks the sheet 1:1
            // with the finger and decides open/close on release.
            let up = DirectionalPanGestureRecognizer(direction: .up, target: self, action: #selector(handleSwipeUp(_:)))
            up.delegate = self
            vc.view.addGestureRecognizer(up)

            if parent.dismissEnabled {
                // The library's own DOWN dismiss (reply-quote presentations: no zoom hero exists,
                // so this pan is the close). Identical behaviour to StoryPager.handleDismiss; the
                // view it moves is our plain container instead of a page controller's scroll view.
                let pan = DirectionalPanGestureRecognizer(direction: .down, target: self, action: #selector(handleDismiss(_:)))
                pan.delegate = self
                vc.view.addGestureRecognizer(pan)
                dismissPan = pan
                // Apple's zoom transition installs its own hidden interactive-dismiss pan up the
                // presentation chain and it wins fast flicks. Subordinate it exactly as StoryPager
                // does; the recognizer only exists once presentation settles, so try twice.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.subordinateSystemPans() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.subordinateSystemPans() }
            } else {
                // PASSIVE watcher over Apple's native zoom-dismiss (owner rule: never touch the
                // native close animation): moves NOTHING — it pauses the story the moment a
                // downward drag starts and COMMITS the close on a fast flick, which the system's
                // interactive dismissal tends to bounce back.
                let watch = DirectionalPanGestureRecognizer(direction: .down, target: self, action: #selector(handleDismissWatch(_:)))
                watch.delegate = self
                watch.cancelsTouchesInView = false
                vc.view.addGestureRecognizer(watch)
            }
        }

        @objc func handleSwipeUp(_ g: UIPanGestureRecognizer) {
            guard let host else { return }
            // WINDOW space, not host space: the sheet-open morph SCALES the card while this pan is
            // live, so host-space deltas get amplified by 1/scale — the compounding feedback loop
            // that made the sheet fly open on its own. Same lesson as StoryPager's up pan.
            let space: UIView = host.view.window ?? host.view
            let t = g.translation(in: space)
            let v = g.velocity(in: space)
            switch g.state {
            case .began:
                swipeUpBaselineY = t.y
            case .changed:
                if swipeUpBaselineY == nil { swipeUpBaselineY = t.y }
                let up = -(t.y - (swipeUpBaselineY ?? t.y))    // +up, zeroed at engagement
                parent.onSwipeUpChanged(max(0, up))
            case .ended, .cancelled:
                let up = -(t.y - (swipeUpBaselineY ?? t.y))
                parent.onSwipeUpEnded(up, -v.y)                // translation +up, velocity +up
                swipeUpBaselineY = nil
            default: break
            }
        }

        // Rides ALONGSIDE the system zoom-dismiss without influencing it. Pause on drag-start;
        // commit fast flicks via the SAME native dismissal (the zoom-back hero plays).
        @objc func handleDismissWatch(_ g: UIPanGestureRecognizer) {
            guard let host else { return }
            switch g.state {
            case .began:
                NotificationCenter.default.post(name: .pauseStory, object: nil)
            case .ended:
                let ty = g.translation(in: host.view).y
                let vy = g.velocity(in: host.view).y
                if ty > 20, vy > 800 {
                    NotificationCenter.default.post(name: .stopVideo, object: nil)
                    NotificationCenter.default.post(name: Notification.Name("storyForceClose"), object: nil)
                } else {
                    NotificationCenter.default.post(name: .resumeStory, object: nil)
                }
            case .cancelled, .failed:
                NotificationCenter.default.post(name: .resumeStory, object: nil)
            default: break
            }
        }

        @objc func handleDismiss(_ g: UIPanGestureRecognizer) {
            guard let host else { return }
            let card = host.cardContainer
            let t = g.translation(in: host.view)
            switch g.state {
            case .began:
                StoryPager.dismissActive = true
                // See-through dismissal: what pulls away is the story and nothing else. The card
                // paints its own black inside its own rounded rect (StoryDetailView), so both
                // containers can go clear for the whole drag.
                card.backgroundColor = .clear
                host.view.backgroundColor = .clear
                NotificationCenter.default.post(name: .pauseStory, object: nil)
            case .changed:
                let ty = max(0, t.y)
                let frac = min(1, ty / card.bounds.height)
                let scale = 1.0 - 0.7 * frac
                card.layer.cornerCurve = .continuous
                // Clip to the STORY, not the container — the strip above the 9:16 card is the
                // container's own background and must not shrink into view as a black header.
                StoryCardMorph.shared.maskToCard(cornerRadius: min(40, ty * 0.3), scale: scale)
                let tx = max(-60, min(60, t.x * 0.7))
                card.transform = CGAffineTransform(translationX: tx, y: ty * 0.85)
                    .scaledBy(x: scale, y: scale)
                parent.onDragChanged(ty)
            case .ended, .cancelled:
                let ty = t.y, vy = g.velocity(in: host.view).y
                if ty > 200 || (ty > 5 && vy > 200) {
                    NotificationCenter.default.post(name: .stopVideo, object: nil)
                    // The card SHRINKS AND MELTS AWAY in place (the owner's chosen close), it does
                    // not slide off the bottom.
                    let exitScale: CGFloat = 0.12
                    let exitTx = max(-60, min(60, t.x * 0.7))
                    UIView.animate(withDuration: 0.24, delay: 0, options: [.curveEaseIn]) {
                        card.transform = CGAffineTransform(translationX: exitTx, y: max(0, t.y) * 0.85 + 40)
                            .scaledBy(x: exitScale, y: exitScale)
                        card.alpha = 0
                    } completion: { _ in
                        self.parent.onCommit()
                        card.alpha = 1
                        StoryPager.dismissActive = false
                    }
                } else {
                    NotificationCenter.default.post(name: .resumeStory, object: nil)
                    UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85,
                                   initialSpringVelocity: 0.3, options: []) {
                        card.transform = .identity
                    } completion: { _ in
                        StoryCardMorph.shared.clearMask()
                        self.host?.view.backgroundColor = .black
                        StoryPager.dismissActive = false
                        self.parent.onCancel()
                    }
                }
            default: break
            }
        }

        // Any SYSTEM pan up the chain (Apple's private "_UI…" recognizers — name READ only) must
        // wait for our dismiss pan to fail, or it re-lays-out the cover mid-drag on fast flicks.
        private func subordinateSystemPans() {
            guard let pan = dismissPan, let v = host?.view else { return }
            var node: UIView? = v.superview
            while let cur = node {
                for g in cur.gestureRecognizers ?? [] where g !== pan {
                    guard g is UIPanGestureRecognizer else { continue }
                    if NSStringFromClass(type(of: g)).hasPrefix("_UI") {
                        g.require(toFail: pan)
                    }
                }
                node = cur.superview
            }
        }

        // Our pans coexist with the hosted SwiftUI gestures (tap zones, hold-to-pause) and with
        // the system zoom-dismiss pan the passive watcher rides alongside.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool { true }
    }
}

/// One plain container with the live story inside it. `cardContainer` is the ONLY view any gesture
/// transforms — its `bounds.origin` is always zero, it has no gesture plumbing of its own, and
/// nothing lays it out mid-drag. This is the "nothing of Apple's under the transform" property the
/// morph has needed since build 220.
final class StorySoloHostVC: UIViewController {
    let cardContainer = UIView()
    var content: StoryPageHostVC?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        cardContainer.backgroundColor = .clear
        cardContainer.frame = view.bounds
        cardContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(cardContainer)
        // The SAME view every gesture moves is the one the viewers sheet shrinks. No second card,
        // no picture of the story anywhere — see StoryCardMorph.
        StoryCardMorph.shared.attach(cardContainer)
    }

    /// Same rule as StoryPagerVC: the at-rest black lives inside the cover, so a zoom-dismiss
    /// would shrink the strip above the card into a black header on the story. The instant a real
    /// dismissal starts, the black steps aside and only the card (opaque by construction) pulls
    /// away; a cancelled drag restores it via viewWillAppear. A dismissal cannot start while the
    /// viewers sheet is up — its window pans subordinate Apple's — so this can never undercut the
    /// sheet's black canvas.
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isBeingDismissed { view.backgroundColor = .clear }
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        view.backgroundColor = .black
    }
}
