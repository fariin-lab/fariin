import SwiftUI
import UIKit

// Instant hold-to-record gesture (fires the moment you touch the mic). A
// SwiftUI DragGesture goes through SwiftUI's gesture arbitration and can be delayed by ancestor views,
// which made recording feel laggy/unreliable. A UIKit UILongPressGestureRecognizer with
// minimumPressDuration = 0 recognises on touch-DOWN with no delay and no arbitration — so recording
// starts the instant the finger lands. It reports the translation from the touch-down point so the
// composer can drive slide-to-cancel (left) and slide-to-lock (up).
struct HoldToRecordView: UIViewRepresentable {
    var onBegan: () -> Void
    var onChanged: (CGSize) -> Void
    var onEnded: (_ translation: CGSize, _ cancelled: Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        let lp = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handle(_:)))
        lp.minimumPressDuration = 0          // fire on touch-down — the instant-record secret
        lp.allowableMovement = .greatestFiniteMagnitude   // never fail on movement (we WANT the drag)
        lp.cancelsTouchesInView = false
        lp.delegate = context.coordinator
        v.addGestureRecognizer(lp)
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.parent = self }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: HoldToRecordView
        private var start: CGPoint?
        init(_ parent: HoldToRecordView) { self.parent = parent }

        @objc func handle(_ g: UILongPressGestureRecognizer) {
            let loc = g.location(in: g.view)
            switch g.state {
            case .began:
                start = loc
                parent.onBegan()
            case .changed:
                let s = start ?? loc
                parent.onChanged(CGSize(width: loc.x - s.x, height: loc.y - s.y))
            case .ended:
                let s = start ?? loc
                parent.onEnded(CGSize(width: loc.x - s.x, height: loc.y - s.y), false)
                start = nil
            case .cancelled, .failed:
                let s = start ?? loc
                parent.onEnded(CGSize(width: loc.x - s.x, height: loc.y - s.y), true)
                start = nil
            default:
                break
            }
        }

        // Let it coexist with the surrounding scroll/tap gestures without stealing/being stolen.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
