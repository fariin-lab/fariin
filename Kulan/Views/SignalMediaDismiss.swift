import SwiftUI
import UIKit

// Signal's interactive media dismiss, ported 1:1 from MediaInteractiveDismiss +
// MediaDismissAnimationController (studied from source; constants preserved exactly):
//   • ONE vertical DirectionalPanGestureRecognizer on the presented viewer's root view.
//   • On begin, the live SwiftUI content is hidden ONCE and a LIGHTWEIGHT COPY of the media moves —
//     an image copy when available (Signal's MediaTransitionImageView), else a live snapshot of the
//     media's screen region. The copy sits in a shadow container (black 20%, offset (0,32), radius 48).
//   • Finger lock: copy.center = fromFrame.center + RAW translation, 1:1 both axes. The 0.8 scale and
//     shadow are Signal's 0.2s "cock" scrubbed inside the 0.25s interactive timeline → they complete at
//     progress 0.8 and are NOT recomputed as functions of position.
//   • progress = clamp01(hypot(dx, dy) / 88)  (Signal's distanceToCompletion = 88pt).
//   • Backdrop alpha driven DIRECTLY from progress. Zero per-frame SwiftUI work.
//   • Release: FINISH on any progress (Signal: percentComplete > 0 — no velocity gate) with the 0.25s
//     critically-damped spring toward Signal's own no-destination fallback frame (fromFrame shifted
//     down by its height); gesture-cancel springs everything back.
// Shared by the image viewer AND the video player — one code path.
struct SignalDismissHost: UIViewRepresentable {
    var canBegin: () -> Bool                                  // e.g. current page at min zoom
    var media: () -> (frame: CGRect, image: UIImage?)?        // fitted media rect (screen coords) + image if loaded
    var onHideContent: (Bool) -> Void                         // hide/show the live SwiftUI viewer (once per gesture)
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
        private static let distanceToCompletion: CGFloat = 88   // Signal's exact threshold

        init(_ p: SignalDismissHost) { parent = p }

        func install(from marker: UIView) {
            guard root == nil, let vc = marker.owningViewController else { return }
            root = vc.view
            let g = DirectionalPanGestureRecognizer(direction: .vertical, target: self, action: #selector(handle(_:)))
            g.delegate = self
            vc.view.addGestureRecognizer(g)
        }

        // Coexist with the pager + zoom scroll views (Signal coordinates via delegation the same way);
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

                // The lightweight copy: the image itself when loaded (Signal's MediaTransitionImageView),
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
                // Shadow container (Signal: plain UIView so it can carry both corners and shadow).
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
                // 1:1 finger lock (Signal: center = fromFrame.offsetBy(offset).center) — both axes, raw.
                c.center = CGPoint(x: fromFrame.midX + o.x, y: fromFrame.midY + o.y)
                // The constant 0.8 scale + shadow: Signal's 0.2s cock inside the 0.25s timeline → both
                // complete at progress 0.8 (scrubbed, not recomputed from position).
                let t = min(1, progress / 0.8)
                c.transform = CGAffineTransform(scaleX: 1 - 0.2 * t, y: 1 - 0.2 * t)
                c.layer.shadowOpacity = Float(t)
                backdrop?.alpha = 1 - t   // background alpha driven directly from the drag progress

            case .ended:
                guard active else { return }
                let o = g.translation(in: root)
                // Signal: finish if percentComplete > 0 — any real progress dismisses, no velocity gate.
                if hypot(o.x, o.y) > 0.5 { finish() } else { cancel() }

            case .cancelled, .failed:
                guard active else { return }
                cancel()

            default: break
            }
        }

        // Signal's final spring (0.25s, damping 1) toward the no-destination fallback frame:
        // fromFrame shifted down by its own height; shadow off, backdrop out — then complete (dismiss).
        private func finish() {
            guard let c = container else { return }
            active = false
            UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
                           options: [.curveEaseInOut]) {
                c.transform = .identity
                c.frame = self.fromFrame.offsetBy(dx: 0, dy: self.fromFrame.height)
                c.layer.shadowOpacity = 0
                self.backdrop?.alpha = 0
            } completion: { _ in
                self.parent.onDismiss()
                // The presentation tears everything down with the cover.
            }
        }

        // Cancel: the same critically-damped spring back home, then restore the live content.
        private func cancel() {
            active = false
            guard let c = container else { parent.onHideContent(false); return }
            UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
                           options: [.curveEaseInOut]) {
                c.transform = .identity
                c.frame = self.fromFrame
                c.layer.shadowOpacity = 0
                self.backdrop?.alpha = 1
            } completion: { _ in
                self.parent.onHideContent(false)
                c.removeFromSuperview()
                self.backdrop?.removeFromSuperview()
                self.container = nil
                self.backdrop = nil
            }
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
