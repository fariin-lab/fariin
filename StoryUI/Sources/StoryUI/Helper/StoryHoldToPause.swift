//
//  StoryHoldToPause.swift
//  StoryUI
//
//  THE STORY PAUSES WHEN YOUR FINGER LANDS, NOT A QUARTER SECOND LATER.
//
//  His report: holding a story to look at it takes a moment to pause, and "telegram is so fast".
//  He told me to read their code rather than guess, so this is what it says.
//
//  `StoryContainerScreen.swift` defines `StoryLongPressRecognizer`, and the pause does NOT come from
//  the long press firing. It comes from `touchesBegan`:
//
//      override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
//          ...
//          if self.isValidated {
//              super.touchesBegan(touches, with: event)
//              if !self.isTracking {
//                  self.isTracking = true
//                  self.initialLocation = touches.first?.location(in: self.view)
//                  self.updateIsTracking?(initialLocation)     // <- this pauses
//              }
//          }
//      }
//
//  `updateIsTracking` sets `isHoldingTouch`, which is what stops the story. Their own gate on it is
//  called `allowsInstantPauseOnTouch(point:)`. The recogniser's `.began` — after the press duration
//  — is used for something else entirely (`itemSetPanState`, preparing the drag). So: instant on
//  touch, and the duration has nothing to do with it.
//
//  ⚠️ WHY WE COULD NOT SIMPLY DROP OUR OWN DURATION TO ZERO. Ours was a SwiftUI
//  `onLongPressGesture(minimumDuration: 0.25)`, and the 0.25 was itself a fix: a SwiftUI press whose
//  touch is stolen by a UIKit recogniser — the pager's page pan, the hero dismiss pan — does not
//  reliably report that it stopped pressing, so `isPaused` stranded at true and the story sat frozen
//  for no reason he could see. Pausing only after 0.25s meant a quick tap never armed it, which made
//  the strand rare rather than impossible.
//
//  Telegram's shape fixes the cause instead, and that is the point of copying it. UIKit calls
//  `reset()` on a recogniser whenever its touch sequence ends — released, cancelled, failed, or
//  claimed by somebody else — so a resume posted from there cannot be missed:
//
//      override func reset() {
//          super.reset()
//          self.isValidated = false
//          if self.isTracking { self.isTracking = false; self.updateIsTracking?(nil) }
//      }
//
//  ⚠️ AND WHY THIS ONE NEVER RECOGNISES. Ours stays in `.possible` for its whole life and never
//  moves to `.began`. A recogniser that does not recognise cannot cancel another one, cannot delay
//  touch delivery, and cannot claim the touch away from the pager's pans or from the tap zones — it
//  only watches. That matters here more than usual: [[kulan-scroll-gesture-rules]] is a standing
//  rule written because gestures added to this surface have twice claimed touches and locked
//  scrolling. This one is structurally incapable of it.
//

import SwiftUI
import UIKit

/// Watches a touch without ever competing for it. Reports true when a finger lands and false when
/// the touch sequence ends by ANY route.
final class StoryTouchHoldRecognizer: UIGestureRecognizer {
    var onHoldChanged: ((Bool) -> Void)?
    private var holding = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard !holding else { return }
        holding = true
        onHoldChanged?(true)
    }

    /// UIKit calls this at the end of every touch sequence this recogniser saw, whatever ended it.
    /// It is the guarantee the SwiftUI press did not give, and the whole reason the pause can now be
    /// instant without risking a story stranded paused.
    override func reset() {
        super.reset()
        guard holding else { return }
        holding = false
        onHoldChanged?(false)
    }

    // Deliberately empty overrides: this recogniser must never leave `.possible`. Moving to `.began`
    // or `.recognized` would let it cancel the pans it shares this view with.
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
    }
}

/// Installs the watcher on a transparent view laid over the story.
///
/// `isUserInteractionEnabled = false` on the view itself: the recogniser is attached to it, but the
/// view must not swallow anything — the taps that advance the story and the pans that page and
/// dismiss all belong to layers above and below it, and they must keep receiving touches exactly as
/// they did before this existed.
struct StoryHoldDetector: UIViewRepresentable {
    var onHoldChanged: (Bool) -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onHoldChanged: ((Bool) -> Void)?
        // Shares every touch with everybody. This watcher has no opinion about who wins.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }

    func makeCoordinator() -> Coordinator {
        let c = Coordinator()
        c.onHoldChanged = onHoldChanged
        return c
    }

    func makeUIView(context: Context) -> UIView {
        let g = StoryTouchHoldRecognizer(target: nil, action: nil)
        g.delegate = context.coordinator
        // None of these may be left at their defaults. `cancelsTouchesInView` would swallow the tap
        // that advances the story; `delaysTouchesBegan`/`Ended` would hold every touch back until
        // this had made up its mind, which is exactly the lateness being removed.
        g.cancelsTouchesInView = false
        g.delaysTouchesBegan = false
        g.delaysTouchesEnded = false
        g.onHoldChanged = { [weak c = context.coordinator] holding in c?.onHoldChanged?(holding) }
        return HostView(recognizer: g)
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onHoldChanged = onHoldChanged
    }

    /// ⚠️ THE RECOGNISER GOES ON THE SUPERVIEW, NOT ON THIS VIEW, and that is not a detail.
    ///
    /// UIKit offers a touch to the recognisers of the hit-test view and of its ANCESTORS. This
    /// representable is an overlay: it is a sibling of the story, not its parent, so a recogniser
    /// attached here would only ever see touches this view itself won — and it must win none, or it
    /// would be stealing the taps that advance the story. Attached one level up, it observes every
    /// touch that lands anywhere in the story without being in anybody's way.
    ///
    /// `hitTest` returns nil for the same reason: this view must be invisible to touch delivery. It
    /// is `didMoveToWindow` rather than `init` because a representable has no superview until
    /// SwiftUI has placed it, and re-checked on every move because SwiftUI is free to re-parent it.
    private final class HostView: UIView {
        private let recognizer: StoryTouchHoldRecognizer
        init(recognizer: StoryTouchHoldRecognizer) {
            self.recognizer = recognizer
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let host = superview else { return }
            guard recognizer.view !== host else { return }
            recognizer.view?.removeGestureRecognizer(recognizer)
            host.addGestureRecognizer(recognizer)
        }
    }
}
