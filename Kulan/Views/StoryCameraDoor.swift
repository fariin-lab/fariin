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
/// A note on why this is not literally a `UINavigationController` push, which is what he described:
/// a push goes right-to-left and there is no public flag to reverse it. The numbers below ARE the
/// push's — full travel for the arriving screen, ~30% for the one being left, one duration, one
/// curve — with the sign flipped, so it reads as the same motion coming the other way.
final class StoryCameraPushAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    /// True for opening, false for closing. One class for both so the two directions cannot drift.
    private let presenting: Bool
    init(presenting: Bool) { self.presenting = presenting }

    /// Apple's own push duration.
    func transitionDuration(using _: UIViewControllerContextTransitioning?) -> TimeInterval { 0.35 }

    /// ⚠️ THE SCREEN BEING LEFT MOVES A THIRD, NOT THE WHOLE WAY, and that single number is most of
    /// what makes a push look like a push rather than like two sheets of paper swapping places.
    private static let parallax: CGFloat = 0.30

    func animateTransition(using ctx: UIViewControllerContextTransitioning) {
        let container = ctx.containerView
        guard let from = ctx.viewController(forKey: .from)?.view,
              let to = ctx.viewController(forKey: .to)?.view else {
            ctx.completeTransition(false)
            return
        }
        let width = container.bounds.width
        let duration = transitionDuration(using: ctx)

        // The camera arrives from the LEFT, so the app it covers leaves to the RIGHT.
        let cameraOffscreen = CGAffineTransform(translationX: -width, y: 0)
        let appPushedAside = CGAffineTransform(translationX: width * Self.parallax, y: 0)

        if presenting {
            // `to` is the camera. It is the only view that has to be placed: the app is already in
            // the window and stays there (`.overFullScreen`), which is what lets it be moved.
            to.frame = container.bounds
            container.addSubview(to)
            to.transform = cameraOffscreen
            UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseInOut]) {
                to.transform = .identity
                from.transform = appPushedAside
            } completion: { _ in
                // ⚠️ THE APP IS PUT BACK STRAIGHT AWAY, AND IT IS COVERED WHEN THAT HAPPENS, so
                // nothing is visible. Leaving a transform standing on the app's own root for as long
                // as the camera is up would mean every coordinate under it is a lie — and the close
                // below re-applies it for exactly the length of its own animation anyway.
                from.transform = .identity
                ctx.completeTransition(!ctx.transitionWasCancelled)
            }
        } else {
            // `from` is the camera, `to` is the app — still in the window, never removed.
            to.transform = appPushedAside
            UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseInOut]) {
                from.transform = cameraOffscreen
                to.transform = .identity
            } completion: { _ in
                to.transform = .identity
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
        StoryCameraPushAnimator(presenting: true)
    }

    func animationController(forDismissed _: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        StoryCameraPushAnimator(presenting: false)
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
        // ⚠️ `.overFullScreen`, NOT `.fullScreen`, AND THE ANIMATION DEPENDS ON IT. A `.fullScreen`
        // presentation takes the presenting view out of the hierarchy, so there would be nothing left
        // to slide aside — the app would simply vanish and the camera would arrive over nothing.
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
