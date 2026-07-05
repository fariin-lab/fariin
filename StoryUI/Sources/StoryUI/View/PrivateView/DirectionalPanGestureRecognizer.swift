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

    init(direction: PanDirection, target: AnyObject, action: Selector) {
        self.direction = direction
        super.init(target: target, action: action)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        // Only start the gesture if the initial movement is in the specified direction.
        if state == .possible {
            guard let touch = touches.first else { return }
            let previousLocation = touch.previousLocation(in: view)
            let location = touch.location(in: view)
            let deltaY = previousLocation.y - location.y
            let deltaX = previousLocation.x - location.x

            let isSatisfied: Bool = {
                if abs(deltaY) > abs(deltaX) {
                    if direction.contains(.up), deltaY < 0 { return true }
                    if direction.contains(.down), deltaY > 0 { return true }
                } else {
                    if direction.contains(.left), deltaX < 0 { return true }
                    if direction.contains(.right), deltaX > 0 { return true }
                }
                return false
            }()

            guard isSatisfied else {
                // Clearly off-axis movement: fail NOW instead of lingering in .possible, so a scroll view
                // that did require(toFail:) us (the cube pager) can begin instantly (no sticky paging).
                if abs(deltaX) > 0.5 || abs(deltaY) > 0.5 { state = .failed }
                return
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
