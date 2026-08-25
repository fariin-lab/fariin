import SwiftUI
import UIKit

/// THE STORY CAMERA OPENS THE WAY A CHAT DOES, ONLY MIRRORED.
///
/// Owner, 2026-08-24, after seeing the first attempt on his phone: "the current animation has too
/// many bugs in both the opening and closing transitions — replace it with Apple's native UIKit
/// transition. Use Apple's swipe, like when I click a chat and the chat page opens, but coming from
/// the left side. Animation only: + opens the camera, ✕ closes it, no finger swipe."
///
/// ⛔ WHAT WAS HERE BEFORE IS DELETED, AND HIS VERDICT ON IT WAS RIGHT. The first version drove a
/// SwiftUI `progress` by hand and moved four things off it — an offset, a scale, a half-speed inner
/// offset and a dim — plus an interactive drag. That is a lot of state to keep correct across a
/// screen rotation, a re-render and a mid-flight second tap, and his screenshot caught it wedged:
/// camera at 80%, parked somewhere in the middle, the app beside it. Every one of those bugs was in
/// machinery we owned.
///
/// ⚠️ THE TRANSITION IS UIKIT'S NOW, NOT OURS. `UIViewControllerAnimatedTransitioning` is the API
/// that already runs every push and every modal in the system: UIKit owns the container, the
/// completion, the interruption and the cleanup, and this file supplies two frames and a duration.
/// There is no progress variable and no gesture left to get out of step.
///
/// A note on why this is not literally a `UINavigationController` transition, which is what he
/// described: a push and a pop run right-to-left and there is no public flag to reverse either. The
/// numbers below ARE the system's — full travel for the screen on top, 30% for the one beneath, one
/// duration, one curve — with the sign flipped, so it reads as the same motion coming the other way.
final class StoryCameraSlideAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    /// True for opening, false for closing. One class for both so the two directions cannot drift.
    private let presenting: Bool
    init(presenting: Bool) { self.presenting = presenting }

    /// ⛔ 0.3 AND THEIR SPRING, READ FROM THEIR SOURCE — owner, 2026-08-25: "the camera speed is
    /// slow… read then get the speed number [the reference app] is using then use it, the speed you
    /// are using is wrong."
    ///
    /// Their `CameraScreen.animateIn` / `animateOut` drive every part of the entrance and the exit —
    /// preview position, bounds, scale, the chrome views — at `duration: 0.3` with
    /// `kCAMediaTimingFunctionSpring`, without exception. Ours was 0.35 on `.curveEaseInOut`: a
    /// twentieth of a second longer AND a curve that decelerates lazily where theirs arrives, which
    /// is why it read as slow rather than as slightly slow.
    func transitionDuration(using _: UIViewControllerContextTransitioning?) -> TimeInterval { 0.3 }

    /// Their timing function, handed to UIKit the way UIKit accepts it.
    ///
    /// ⚠️ `kCAMediaTimingFunctionSpring` is a Core Animation name with no `UIView.AnimationOptions`
    /// spelling, but the curve behind it is the system's curve 7 — the same one the keyboard reports
    /// and the same one `KeyboardWatcher.systemAnimation` already writes out for SwiftUI in this app.
    /// `7 << 16` is the documented shape of the options field (curve in the high bits), and it is how
    /// the reference app itself passes this curve to UIKit.
    private static let refSpringCurve = UIView.AnimationOptions(rawValue: 7 << 16)

    /// ⛔ THIS IS A POP, NOT A PUSH — owner, 2026-08-24, with ours beside theirs: "the camera page
    /// must be UNDER the page that is going up, and the page that is going must have rounded corners
    /// like image 2."
    ///
    /// ⚠️ THE FIRST VERSION HAD THE Z-ORDER THE WRONG WAY ROUND, and that one fact is both of his
    /// points. It was built as a push: the arriving camera on TOP, travelling the full width, with
    /// the app moving 30% beneath it. So the camera's hard edge cut across the chat list, and a
    /// screen that is underneath has no corners to round.
    ///
    /// A pop is the same animation with the roles swapped, and it is what he photographed: the
    /// LEAVING screen rides on top and travels the whole way out, revealing the arriving one
    /// underneath, which drifts in over the last 30% of the distance. Because the chat list is now
    /// the thing on top, it is the thing that carries a corner radius, exactly as in their shot.
    private static let parallax: CGFloat = 0.30

    /// ⛔ THE SYSTEM PICKS THE RADIUS, NOT US — owner, 2026-08-24: "do not hardcode 24 or another
    /// fixed radius; let iOS decide it per device so the transition matches the system on every
    /// iPhone."
    ///
    /// ⚠️ THE DEVICE'S DISPLAY RADIUS IS NOT PUBLIC. UIKit rounds a pushed screen to the physical
    /// corner of the display, but that number is reachable only through a private `UIScreen` key, and
    /// this app goes to App Store review. So it is not read — it is DELEGATED.
    ///
    /// `containerConcentric` is iOS 26's answer to exactly this question: the corner resolves against
    /// whatever container the view is in, which here is the screen, so iOS supplies the same radius it
    /// uses for its own transitions and keeps supplying the right one on hardware that does not exist
    /// yet. Nothing to maintain and no device table to go stale.
    ///
    /// ⚠️ The fallback is NOT a guess at the display radius, and deliberately so. On iOS 17–18 there
    /// is no way to ask, and a stated number would be right on one phone and wrong on the rest — so
    /// the older path takes a plain modest corner that reads as a card without pretending to match
    /// the hardware.
    private static let legacyCardRadius: CGFloat = 12

    /// ⚠️ THE PAGE THAT LEAVES IS A SNAPSHOT, AND IT HAS TO BE. The app's real view lives in the
    /// window, NOT in the transition's container, so it cannot be raised above the camera and cannot
    /// be given corners without mutating the live app's own layer. A snapshot can be put anywhere in
    /// the container, styled freely, and thrown away when the animation ends — the real view is never
    /// touched, which is also why nothing can be left behind if the transition is interrupted.
    /// ⛔ THE CORNERS ROUNDED ONLY SOMETIMES — owner, 2026-08-24, with a square-cornered chat list
    /// mid-slide. Two things made it a coin toss and both are gone:
    ///
    /// ⚠️ THE CORNER WAS BEING SET ON THE SNAPSHOT ITSELF. `snapshotView` does not return an ordinary
    /// view — it is a special replicant of another view's rendered content, and it is not a surface
    /// to hang a resolving corner configuration on. The snapshot is now CARGO: it rides inside a
    /// plain `UIView` that owns the corner and does the clipping, and a plain view resolves the way
    /// the API documents.
    ///
    /// ⚠️ AND THE CORNER WAS RESOLVED IN THE SAME BREATH AS THE FIRST ANIMATED FRAME. A concentric
    /// corner is worked out during layout; the card was created, added and animated in one runloop
    /// turn, so whether a layout pass happened first was down to timing — which is exactly what
    /// "sometimes it works" looks like from the outside. The caller forces that pass now, before any
    /// animation is set up.
    /// ⛔ FOURTH ATTEMPT, AND THE FIRST THREE ALL SHARE ONE MISTAKE — owner, 2026-08-25, still square
    /// on opening after three fixes shipped: "deep research that bug".
    ///
    /// ⚠️ EVERY PREVIOUS FIX TRIED TO MAKE `containerConcentric` RESOLVE **DURING** THE TRANSITION,
    /// and each one had a plausible story: set it on a plain view instead of the snapshot, force a
    /// layout pass, give the container a radius too, start the layout pass at the window. The stories
    /// were plausible and the bug did not move, three times. That is the signal to stop diagnosing
    /// the resolution and stop depending on it.
    ///
    /// The property is a QUESTION asked of a live view hierarchy: "what is my container's corner?"
    /// Inside a `.overFullScreen` presentation's transition container, on the way in, nothing in that
    /// chain has an answer, so it answers zero — and zero is square. On the way out UIKit's own
    /// dismissal container happens to carry a radius, so the same line of code returns a real number.
    /// One expression, two results, decided by scaffolding nobody in this file owns. It was never
    /// going to be made reliable by asking it more carefully.
    ///
    /// ⚠️ SO THE NUMBER IS RESOLVED ONCE, SOMEWHERE IT DOES WORK, AND REUSED. `displayCorner(in:)`
    /// puts a hidden probe view directly in the WINDOW — the one container iOS does resolve to the
    /// physical display corner, which is the documented purpose of the API — reads the number it
    /// resolves to, throws the probe away and caches it. Both directions then paint the SAME
    /// concrete radius, and neither depends on what the transition container happens to be.
    ///
    /// This still honours his original rule: the value is iOS's own answer for this device, not a
    /// number typed here, and it keeps being right on hardware that does not exist yet. What changed
    /// is only WHERE it is asked — in the window, where the question has an answer, instead of in a
    /// transition container, where it does not.
    private static func makeCard(of view: UIView, bounds: CGRect, radius: CGFloat) -> UIView? {
        guard let snapshot = view.snapshotView(afterScreenUpdates: false) else { return nil }
        let card = UIView(frame: bounds)
        card.layer.cornerRadius = radius
        card.layer.cornerCurve = .continuous
        card.layer.masksToBounds = true
        snapshot.frame = card.bounds
        snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        card.addSubview(snapshot)
        return card
    }

    /// iOS's own corner radius for this display, asked once in the one place that answers.
    ///
    /// ⚠️ THE PROBE IS HIDDEN AND LASTS ONE LAYOUT PASS. It is never drawn and never hit-tested; it
    /// exists only so `containerConcentric` has a window to resolve against, which is exactly the
    /// case the API documents. `layoutIfNeeded` on the window is what forces the resolution — the
    /// same missing pass that the third attempt correctly identified and then applied in the wrong
    /// place.
    ///
    /// ⚠️ CACHED FOR THE PROCESS. The display corner cannot change while the app runs, and a probe
    /// per transition would put a layout pass on the window in the frame before an animation starts.
    ///
    /// The fallback is only reached if the probe itself answers zero, and it is deliberately a modest
    /// card corner rather than a guess at the hardware: a wrong big number looks broken, a modest one
    /// looks like a card. Square is the one outcome this cannot produce any more.
    private static var cachedDisplayCorner: CGFloat?
    private static func displayCorner(in window: UIWindow?) -> CGFloat {
        if let cached = cachedDisplayCorner { return cached }
        guard #available(iOS 26.0, *), let window else { return legacyCardRadius }
        let probe = UIView(frame: window.bounds)
        probe.isHidden = true
        probe.isUserInteractionEnabled = false
        probe.cornerConfiguration = .corners(radius: .containerConcentric())
        window.addSubview(probe)
        window.layoutIfNeeded()
        let resolved = probe.layer.cornerRadius
        probe.removeFromSuperview()
        // Only a REAL answer is cached. A zero means the probe found nothing to resolve against this
        // time — a window mid-setup, say — and caching the fallback there would make one bad moment
        // permanent for the whole process. Falling back without caching costs a probe next time.
        guard resolved > 0 else { return legacyCardRadius }
        cachedDisplayCorner = resolved
        return resolved
    }

    func animateTransition(using ctx: UIViewControllerContextTransitioning) {
        let container = ctx.containerView
        guard let fromVC = ctx.viewController(forKey: .from),
              let toVC = ctx.viewController(forKey: .to) else {
            ctx.completeTransition(false)
            return
        }
        let width = container.bounds.width
        let duration = transitionDuration(using: ctx)

        // The radius is settled BEFORE anything is built, once per process, in the window. Nothing
        // about the transition container matters to it any more — see `makeCard` for why three
        // fixes that did care about the container all failed.
        let cardRadius = Self.displayCorner(in: container.window)

        // Underneath, the camera only ever covers the last 30% of the distance. On top, the page
        // being left travels the whole width.
        let beneathStart = CGAffineTransform(translationX: -width * Self.parallax, y: 0)
        let aboveOffscreen = CGAffineTransform(translationX: width, y: 0)

        if presenting {
            let camera = toVC.view!
            camera.frame = container.bounds
            container.addSubview(camera)
            camera.transform = beneathStart

            // Added AFTER the camera, so it sits above it.
            let card = Self.makeCard(of: fromVC.view, bounds: container.bounds, radius: cardRadius)
            if let card { container.addSubview(card) }

            UIView.animate(withDuration: duration, delay: 0, options: Self.refSpringCurve) {
                camera.transform = .identity
                card?.transform = aboveOffscreen
            } completion: { _ in
                card?.removeFromSuperview()
                ctx.completeTransition(!ctx.transitionWasCancelled)
            }
        } else {
            let camera = fromVC.view!
            // Coming back, the app arrives on top from the right and the camera slips away under it.
            let card = Self.makeCard(of: toVC.view, bounds: container.bounds, radius: cardRadius)
            if let card {
                container.addSubview(card)
                card.transform = aboveOffscreen
            }
            UIView.animate(withDuration: duration, delay: 0, options: Self.refSpringCurve) {
                camera.transform = beneathStart
                card?.transform = .identity
            } completion: { _ in
                card?.removeFromSuperview()
                camera.transform = .identity
                ctx.completeTransition(!ctx.transitionWasCancelled)
            }
        }
    }
}

/// Hands UIKit the animator for each direction. A singleton because a transitioning delegate is held
/// WEAKLY by the presented controller — a fresh instance would be released before it was ever asked,
/// and the presentation would silently fall back to the default slide-up.
final class StoryCameraTransitionDelegate: NSObject, UIViewControllerTransitioningDelegate {
    static let shared = StoryCameraTransitionDelegate()
    private override init() { super.init() }

    func animationController(forPresented _: UIViewController, presenting _: UIViewController,
                             source _: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        StoryCameraSlideAnimator(presenting: true)
    }

    func animationController(forDismissed _: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        StoryCameraSlideAnimator(presenting: false)
    }
}

/// Opening and closing the story camera, from anywhere.
@MainActor enum StoryCameraDoor {
    /// Weak: if UIKit takes it away for any reason, this reference goes with it rather than leaving
    /// `open()` convinced a camera is still up and refusing to present another.
    private static weak var presented: UIViewController?

    static func open() {
        guard presented == nil, let top = topViewController() else { return }
        let sheet = AddStorySheet(onPosted: { Task { await StoriesRepository.shared.load(force: true) } },
                                  onDismiss: { StoryCameraDoor.close() })
        let host = UIHostingController(rootView: sheet)
        // ⚠️ `.overFullScreen`, NOT `.fullScreen`, AND THE CLOSING ANIMATION DEPENDS ON IT. A
        // `.fullScreen` presentation takes the presenting view out of the hierarchy. On the way out
        // the camera slides 30% to the left, and what is revealed in that strip is the real app
        // sitting in the window — remove it and that strip is a black band for the whole animation.
        host.modalPresentationStyle = .overFullScreen
        host.transitioningDelegate = StoryCameraTransitionDelegate.shared
        // The camera paints its own black; without this the app shows through wherever it does not.
        host.view.backgroundColor = .black
        presented = host
        top.present(host, animated: true)
    }

    static func close() {
        presented?.dismiss(animated: true)
        presented = nil
    }

    /// Present on whatever is actually on top — presenting on a controller that is itself covered
    /// does nothing at all and reads as a dead tap. Same walk as `WebLink`'s.
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let root = scenes.first(where: { $0.activationState == .foregroundActive })?.keyWindow?.rootViewController
            ?? scenes.first?.keyWindow?.rootViewController
        var top = root
        while let next = top?.presentedViewController { top = next }
        return top
    }
}
