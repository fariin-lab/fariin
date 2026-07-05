//
// Direction-locked pan recognizer, cloned from Signal-iOS (SignalUI/Views/DirectionalPanGestureRecognizer.swift,
// AGPL-3.0). It only begins if the first movement is in the allowed direction and cancels itself if the
// cross-axis dominates. We pair it with scrollView.panGestureRecognizer.require(toFail:) so the cube page
// swipe and the swipe-down dismiss are mutually exclusive.
//

import UIKit.UIGestureRecognizerSubclass

struct PanDirection: OptionSet {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    static let left = PanDirection(rawValue: 1 << 0)
    static let right = PanDirection(rawValue: 1 << 1)
    static let up = PanDirection(rawValue: 1 << 2)
    static let down = PanDirection(rawValue: 1 << 3)

    static let horizontal: PanDirection = [.left, .right]
    static let vertical: PanDirection = [.up, .down]
    static let any: PanDirection = [.left, .right, .up, .down]
}

final class DirectionalPanGestureRecognizer: UIPanGestureRecognizer {

    let direction: PanDirection
    private var startPoint: CGPoint?

    init(direction: PanDirection, target: AnyObject, action: Selector) {
        self.direction = direction
        super.init(target: target, action: action)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        startPoint = touches.first?.location(in: view)
    }

    override func reset() {
        super.reset()
        startPoint = nil
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        // Direction gate: judge the CUMULATIVE movement since touch-down, and only once the finger
        // has clearly moved (≥8pt on the dominant axis). Judging the single latest inter-sample
        // delta made the decision depend on micro-jitter: a slow drag sneaked in off a noisy
        // sample while one big clean first sample from a fast flick failed the pan instantly
        // ("fast swipe-down never closes"). Cumulative + threshold is stable at every speed.
        if state == .possible, let touch = touches.first {
            let loc = touch.location(in: view)
            let start = startPoint ?? loc
            let dx = loc.x - start.x   // + = finger moved right
            let dy = loc.y - start.y   // + = finger moved down
            let ax = abs(dx), ay = abs(dy)
            if max(ax, ay) >= 8 {
                // Only judge once one axis CLEARLY dominates (1.2×). Hard-failing on an ambiguous
                // diagonal first sample killed whole drags dead — a finger that rolls slightly
                // sideways at touch-down then pulls straight down never got the pan back ("scroll
                // down to close sometimes completely not working"). Ambiguous → keep sampling; the
                // .began velocity axis-check below still catches anything that slips through.
                if ay > ax * 1.2 {
                    // Clearly vertical: right direction begins, wrong direction fails (frees the tap
                    // zones / the app's swipe-up).
                    let ok = (direction.contains(.down) && dy > 0) || (direction.contains(.up) && dy < 0)
                    if !ok { state = .failed; return }
                } else if ax > ay * 1.2 {
                    // Clearly horizontal: fail NOW so the cube pager (require(toFail:) on us) can
                    // begin instantly — no sticky paging.
                    let ok = (direction.contains(.left) && dx < 0) || (direction.contains(.right) && dx > 0)
                    if !ok { state = .failed; return }
                }
            }
        }

        super.touchesMoved(touches, with: event)

        if state == .began {
            let vel = velocity(in: view)
            switch direction {
            case .left, .right:
                if abs(vel.y) > abs(vel.x) { state = .cancelled }
            case .up, .down:
                if abs(vel.x) > abs(vel.y) { state = .cancelled }
            default:
                break
            }
        }
    }
}
