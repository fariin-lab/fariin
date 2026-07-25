import SwiftUI
import UIKit

// Interactive media dismiss — an interactive-dismiss + dismiss-animation controller pair:
//   • ONE vertical DirectionalPanGestureRecognizer on the presented viewer's root view.
//   • On begin, the live SwiftUI content is hidden ONCE and a LIGHTWEIGHT COPY of the media moves —
//     an image copy when available (a media transition image view), else a live snapshot of the
//     media's screen region. The copy sits in a shadow container (black 20%, offset (0,32), radius 48).
//   • Finger lock: copy.center = fromFrame.center + RAW translation, 1:1 both axes. The 0.8 scale and
//     shadow are a 0.2s "cock" scrubbed inside the 0.25s interactive timeline → they complete at
//     progress 0.8 and are NOT recomputed as functions of position.
//   • progress = clamp01(hypot(dx, dy) / 88)  (distanceToCompletion = 88pt).
//   • Backdrop alpha driven DIRECTLY from progress. Zero per-frame SwiftUI work.
//   • Release: FINISH on any progress (percentComplete > 0 — no velocity gate) with the 0.25s
//     critically-damped spring toward a no-destination fallback frame (fromFrame shifted
//     down by its height); gesture-cancel springs everything back.
// Shared by the image viewer AND the video player — one code path.
struct SignalDismissHost: UIViewRepresentable {
    var canBegin: () -> Bool                                  // e.g. current page at min zoom
    var media: () -> (frame: CGRect, image: UIImage?)?        // fitted media rect (screen coords) + image if loaded
    var onHideContent: (Bool) -> Void                         // hide/show the live SwiftUI viewer (once per gesture)
    /// Where the media came from (the thumbnail's global rect), if known. Given one, the release
    /// FLIES THE COPY HOME into that rect instead of fading out mid-air — so a drag-down close lands
    /// exactly on the tile it opened from, which is what the system zoom transition failed to do
    /// (it shrank the whole black viewer, so the photo only lined up at the very end).
    var targetRect: () -> CGRect? = { nil }
    var onDismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let v = Marker()
        v.isUserInteractionEnabled = false
        v.isHidden = true
        v.coordinator = context.coordinator
        return v
    }
    func updateUIView(_ v: UIView, context: Context) { context.coordinator.parent = self }

    final class Marker: UIView {
        weak var coordinator: Coordinator?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { coordinator?.install(from: self) }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: SignalDismissHost
        private weak var root: UIView?
        private var backdrop: UIView?
        private var container: UIView?
        private var fromFrame: CGRect = .zero
        private var active = false
        private static let distanceToCompletion: CGFloat = 88    // visual scrub (scale/alpha) reference
        // Commit thresholds. Were 160pt / 800 — that much travel made closing feel like work (user:
        // "too hard"). Telegram and WhatsApp commit around a short drag or any real flick, so a normal
        // downward swipe should already mean "close". Changing your mind still works: the decision uses
        // the NET downward offset, so dragging back up above the threshold cancels.
        private static let completionDistance: CGFloat = 90      // drag past this ↓ → dismiss (else recover)
        private static let completionVelocity: CGFloat = 500     // ...or a downward flick faster than this

        init(_ p: SignalDismissHost) { parent = p }

        func install(from marker: UIView) {
            guard root == nil, let vc = marker.owningViewController else { return }
            root = vc.view
            let g = DirectionalPanGestureRecognizer(direction: .vertical, target: self, action: #selector(handle(_:)))
            g.delegate = self
            vc.view.addGestureRecognizer(g)
            // The viewer may be presented with a native .zoom transition (hero open from the bubble).
            // That transition installs its OWN interactive-dismiss pan/pinch on the presentation chain,
            // and that drag moves the WHOLE card — chrome, thumbnails, everything — over a moving
            // presenter (the user rejected exactly this). Disable those so THIS pan is the only dismiss
            // drag: only the media copy moves, the page behind never does. The zoom OPEN animation and
            // the programmatic shrink-into-bubble close are untouched — they're the animator, not the
            // gesture. Run again after the presentation settles: the system can attach its gestures late.
            neutralizeSystemDismissGestures()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.neutralizeSystemDismissGestures()
            }
        }

        // Walk from the presented root up through the presentation container views and disable every
        // pan/pinch that isn't ours. Scroll views (zoom, pager, thumb strip) keep their pans — those
        // live on the scroll views themselves, deeper in the hierarchy, never on this chain.
        private func neutralizeSystemDismissGestures() {
            var v: UIView? = root
            while let cur = v {
                for g in cur.gestureRecognizers ?? [] where !(g is DirectionalPanGestureRecognizer) {
                    if g is UIPanGestureRecognizer || g is UIPinchGestureRecognizer { g.isEnabled = false }
                }
                v = cur.superview
            }
        }

        // Coexist with the pager + zoom scroll views (coordinated via delegation the same way);
        // the directional recognizer self-cancels on horizontal intent, and we gate on canBegin.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        @objc private func handle(_ g: UIPanGestureRecognizer) {
            guard let root else { return }
            switch g.state {
            case .began:
                guard !active, parent.canBegin(), let m = parent.media() else { return }
                active = true
                fromFrame = m.frame

                // Backdrop the interaction owns (alpha driven directly from progress).
                let bd = UIView(frame: root.bounds)
                bd.backgroundColor = .black
                bd.autoresizingMask = [.flexibleWidth, .flexibleHeight]

                // The lightweight copy: the image itself when loaded (a media transition image view),
                // else a live snapshot of the media's region (videos).
                let content: UIView
                if let img = m.image {
                    let iv = UIImageView(image: img)
                    iv.contentMode = .scaleAspectFill
                    iv.clipsToBounds = true
                    content = iv
                } else {
                    content = root.resizableSnapshotView(from: m.frame, afterScreenUpdates: false,
                                                         withCapInsets: .zero) ?? UIView()
                }
                // Shadow container (plain UIView so it can carry both corners and shadow).
                let c = UIView(frame: m.frame)
                c.layer.shadowColor = UIColor.black.withAlphaComponent(0.2).cgColor   // ows_blackAlpha20
                c.layer.shadowOffset = CGSize(width: 0, height: 32)
                c.layer.shadowRadius = 48
                c.layer.shadowOpacity = 0
                content.frame = c.bounds
                content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                c.addSubview(content)

                root.addSubview(bd)
                root.addSubview(c)
                backdrop = bd
                container = c
                parent.onHideContent(true)   // exactly ONE SwiftUI update for the whole gesture

            case .changed:
                guard active, let c = container else { return }
                let o = g.translation(in: root)
                let progress = min(1, max(0, hypot(o.x, o.y) / Self.distanceToCompletion))
                // 1:1 finger lock (center = fromFrame.offsetBy(offset).center) — both axes, raw.
                c.center = CGPoint(x: fromFrame.midX + o.x, y: fromFrame.midY + o.y)
                // The constant 0.8 scale + shadow: a 0.2s cock inside the 0.25s timeline → both
                // complete at progress 0.8 (scrubbed, not recomputed from position).
                let t = min(1, progress / 0.8)
                c.transform = CGAffineTransform(scaleX: 1 - 0.2 * t, y: 1 - 0.2 * t)
                c.layer.shadowOpacity = Float(t)
                backdrop?.alpha = 1 - t   // background alpha driven directly from the drag progress

            case .ended:
                guard active else { return }
                let o = g.translation(in: root)
                let v = g.velocity(in: root)
                // The completion decision (shouldCompleteTransition): finish ONLY if the media was
                // dragged past the dismiss threshold OR flung downward fast; otherwise CANCEL and spring
                // it back to exactly where it came from. This is what lets you drag down, change your
                // mind, drag back up, and fully recover — the net downward offset is what counts, so
                // dragging back above the threshold cancels. The release velocity is handed to the
                // spring either way, so the motion CONTINUES the finger instead of restarting from zero.
                if o.y > Self.completionDistance || v.y > Self.completionVelocity {
                    finish(offset: o, velocity: v)
                } else {
                    cancel(velocity: v)
                }

            case .cancelled, .failed:
                guard active else { return }
                cancel()

            default: break
            }
        }

        // Normalized spring velocity (UISpringTimingParameters expects velocity as a FRACTION of the
        // remaining travel per second) so the animation takes over at exactly the finger's speed.
        private static func springVelocity(_ v: CGPoint, from: CGPoint, to: CGPoint) -> CGVector {
            let dx = to.x - from.x, dy = to.y - from.y
            return CGVector(dx: abs(dx) > 1 ? v.x / dx : 0, dy: abs(dy) > 1 ? v.y / dy : 0)
        }

        // Dismiss (damping 1): the backdrop is already clear past the threshold (the chat shows behind),
        // so the copy fades out from RIGHT WHERE IT WAS RELEASED with a small continued drift + shrink —
        // seeded with the release velocity so it carries the finger's motion. Then dismiss.
        private func finish(offset o: CGPoint, velocity: CGPoint = .zero) {
            guard let c = container else { return }
            active = false

            // FLY HOME when we know where the media came from: the copy scales and travels into the
            // thumbnail's exact rect and only fades at the very end, so it visibly "lands" on the tile.
            if let home = parent.targetRect(), home.width > 1, home.height > 1 {
                let center = CGPoint(x: home.midX, y: home.midY)
                let scale = max(0.05, min(home.width / max(1, fromFrame.width),
                                          home.height / max(1, fromFrame.height)))
                let spring = UISpringTimingParameters(
                    dampingRatio: 0.9,
                    initialVelocity: Self.springVelocity(velocity, from: c.center, to: center))
                // 0.22s, not 0.34: the return should feel immediate, like Telegram/WhatsApp.
                let animator = UIViewPropertyAnimator(duration: 0.22, timingParameters: spring)
                animator.addAnimations {
                    c.center = center
                    c.transform = CGAffineTransform(scaleX: scale, y: scale)
                    c.layer.cornerRadius = 14        // meet the tile's rounding as it arrives
                    c.layer.shadowOpacity = 0
                    self.backdrop?.alpha = 0
                }
                // Hold opacity nearly to the end so it reads as landing, not vanishing.
                animator.addAnimations({ c.alpha = 0 }, delayFactor: 0.8)
                animator.addCompletion { _ in self.parent.onDismiss() }
                animator.startAnimation()
                return
            }

            // No known source (e.g. opened from somewhere that doesn't report a rect): the original
            // Signal behaviour — drift on and fade out from where the finger let go.
            let target = CGPoint(x: fromFrame.midX + o.x, y: fromFrame.midY + o.y + 40)
            let spring = UISpringTimingParameters(dampingRatio: 1,
                                                  initialVelocity: Self.springVelocity(velocity, from: c.center, to: target))
            let animator = UIViewPropertyAnimator(duration: 0.18, timingParameters: spring)
            animator.addAnimations {
                c.center = target
                c.transform = CGAffineTransform(scaleX: 0.72, y: 0.72)
                c.alpha = 0
                c.layer.shadowOpacity = 0
                self.backdrop?.alpha = 0
            }
            animator.addCompletion { _ in
                self.parent.onDismiss()
                // The presentation tears everything down with the cover.
            }
            animator.startAnimation()
        }

        // Cancel: a critically-damped spring back home that CONTINUES the release velocity (Signal's
        // interactive-dismiss recovery), then restore the live content. Signal animates center +
        // transform only — the old path also animated the FRAME while the transform was mid-flight,
        // and frame math under a non-identity transform is what made the snap-back visibly choppy.
        private func cancel(velocity: CGPoint = .zero) {
            active = false
            guard let c = container else { parent.onHideContent(false); return }
            let home = CGPoint(x: fromFrame.midX, y: fromFrame.midY)
            let spring = UISpringTimingParameters(dampingRatio: 1,
                                                  initialVelocity: Self.springVelocity(velocity, from: c.center, to: home))
            let animator = UIViewPropertyAnimator(duration: 0.26, timingParameters: spring)
            animator.addAnimations {
                c.center = home
                c.transform = .identity
                c.layer.shadowOpacity = 0
                self.backdrop?.alpha = 1
            }
            animator.addCompletion { _ in
                self.parent.onHideContent(false)
                c.removeFromSuperview()
                self.backdrop?.removeFromSuperview()
                self.container = nil
                self.backdrop = nil
            }
            animator.startAnimation()
        }
    }
}

// Aspect-fit rect of media with size `media` centered in `bounds` (the copy's start frame).
func mediaFitRect(_ media: CGSize, in bounds: CGRect) -> CGRect {
    guard media.width > 0, media.height > 0 else { return bounds }
    let s = min(bounds.width / media.width, bounds.height / media.height)
    let size = CGSize(width: media.width * s, height: media.height * s)
    return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                  width: size.width, height: size.height)
}
