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
            if max(abs(dx), abs(dy)) >= 8 {
                let isSatisfied: Bool = {
                    if abs(dy) > abs(dx) {
                        if direction.contains(.up), dy < 0 { return true }
                        if direction.contains(.down), dy > 0 { return true }
                    } else {
                        if direction.contains(.left), dx < 0 { return true }
                        if direction.contains(.right), dx > 0 { return true }
                    }
                    return false
                }()
                guard isSatisfied else {
                    // Off-axis movement: fail NOW instead of lingering in .possible, so a scroll view
                    // that did require(toFail:) us (the cube pager) can begin instantly (no sticky paging).
                    state = .failed
                    return
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
