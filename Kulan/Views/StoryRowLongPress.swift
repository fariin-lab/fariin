import SwiftUI
import UIKit

//
// THE STORIES ROW'S LONG PRESS, ON THE APP'S OWN MENU.
//
// He asked for this and it was never started (build-state, "OPEN, HIS CALL (b)"): the row's long
// press in UIKit, with a real lifted preview per card instead of SwiftUI's `.contextMenu`.
//
// WHAT WAS WRONG WITH THE SwiftUI ONE. `.contextMenu(menuItems:preview:)` does not lift the card —
// it BUILDS A SECOND ONE from the `preview:` closure. So the thing that rose off the row was a
// freshly constructed copy: its `StoryImage` started loading again (a beat of empty card on a cold
// cache), its avatar sat in a different place than the real card's, and it wore a caption the card
// itself does not have. Two views that have to look identical, maintained by hand, which is the
// mistake this codebase keeps writing down.
//
// WHAT THIS DOES INSTEAD. One `UILongPressGestureRecognizer` on the row's own scroll view, and the
// lift is a photograph of the card that is actually on screen — the same window-crop the story
// flight wears (`StoryCardShot`), at the card's own 24pt continuous radius. The menu is `CMOverlay`,
// the app's own long-press menu, so the row and the conversation now press the same way: one
// system, one set of numbers, one place to fix anything either of them gets wrong.
//
// ONE RECOGNISER, ON AN ANCESTOR, and both halves of that matter. A recogniser attached to a view
// laid OVER the card would have to be hit-testable, and then the card's own Button would never see
// a plain tap. On the scroll view it sees every press in the row without taking anything away: a
// tap never reaches the 0.2s threshold, so `cancelsTouchesInView` never fires and the tap opens the
// story as before; a real press recognises, UIKit cancels the touch the Button was tracking, and
// the story does NOT open behind the menu when the finger lifts.
//
// See [[kulan-story-row-isolation-rule]]: this area ships alone.
//

/// What a press on the row found: which card, where it is, and what its menu should say.
struct StoryMenuTarget {
    /// `MediaOpenRects` key, so the real card can be hidden while its picture is lifted.
    let key: String
    let rect: CGRect            // window space
    let actions: [CMAction]
}

/// A picture of what is really on screen inside `rect`.
///
/// THE WINDOW IS PHOTOGRAPHED AND CROPPED, NOT THE CARD'S OWN VIEW, and that is not a shortcut. The
/// row registers an ANCHOR with `MediaOpenRects` — a `.background {}` view whose frame is the card's
/// and which draws nothing — and `drawHierarchy` renders the receiver's own hierarchy, so
/// photographing the anchor returns a transparent image. The story flight's cover was blank for its
/// whole life for exactly that reason. Cropping the window takes the pixels the eye is looking at.
enum StoryCardShot {
    static func crop(_ rect: CGRect, in window: UIWindow) -> UIImage? {
        guard rect.width > 1, rect.height > 1, rect.maxX > 0, rect.maxY > 0 else { return nil }
        return UIGraphicsImageRenderer(size: rect.size).image { _ in
            // Shifted so the card lands at the origin. `afterScreenUpdates: false`: the last
            // rendered frame is exactly what is on screen, and a flush would cost the press a frame.
            window.drawHierarchy(in: CGRect(x: -rect.minX, y: -rect.minY,
                                            width: window.bounds.width,
                                            height: window.bounds.height),
                                 afterScreenUpdates: false)
        }
    }

    /// The same picture, taken of a registered view wherever it is now.
    static func crop(_ view: UIView) -> UIImage? {
        guard let window = view.window else { return nil }
        return crop(view.convert(view.bounds, to: window), in: window)
    }
}

/// Installs the row's press recogniser. Draws nothing and never takes a touch of its own.
struct StoryRowLongPress: UIViewRepresentable {
    /// Which card is under this window point, and what its menu is. Asked at press time, so it
    /// always answers about the row as it stands right now rather than as it stood at layout.
    let target: (CGPoint) -> StoryMenuTarget?

    func makeUIView(context: Context) -> UIView {
        let v = Anchor()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        v.coordinator = context.coordinator
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.target = target
        (uiView as? Anchor)?.coordinator = context.coordinator
    }

    func makeCoordinator() -> Coordinator { Coordinator(target: target) }

    /// Install and remove on the window change rather than in `dismantleUIView`: this view is the
    /// only thing that knows when the row is really on screen, and a UIView's own callback is
    /// unambiguously on the main actor, which the static teardown hook is not.
    final class Anchor: UIView {
        weak var coordinator: Coordinator?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            // Asked again on every window change: SwiftUI is free to move a representable between
            // containers, and re-asking is free (install is a no-op once it has one).
            if window == nil { coordinator?.uninstall() } else { coordinator?.install(from: self) }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var target: (CGPoint) -> StoryMenuTarget?
        private weak var overlay: CMOverlay?
        private weak var host: UIView?
        private var press: UILongPressGestureRecognizer?

        init(target: @escaping (CGPoint) -> StoryMenuTarget?) { self.target = target }

        func install(from view: UIView) {
            guard press == nil else { return }
            // ONLY the row's own scroll view. Falling back to the window would put a press
            // recogniser over the whole app, and the first thing it would do on recognising is
            // cancel the touch of whatever was actually being pressed — a chat bubble, a settings
            // row. No anchor is better than the wrong one: the row simply keeps its tap.
            var next: UIView? = view.superview
            var scroll: UIScrollView?
            while let v = next {
                if let s = v as? UIScrollView { scroll = s; break }
                next = v.superview
            }
            guard let anchor = scroll else { return }
            let g = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
            g.minimumPressDuration = 0.2      // the reference app's number, and the chat menu's
            g.delegate = self
            anchor.addGestureRecognizer(g)
            host = anchor
            press = g
        }

        func uninstall() {
            if let press, let host { host.removeGestureRecognizer(press) }
            press = nil
            host = nil
            overlay?.dismiss(animated: false)
        }

        /// Let the scroll view's pan and the cards' own taps carry on. A horizontal scroll cancels
        /// the press by itself, which is the behaviour a row of cards should have.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        @objc private func pressed(_ g: UILongPressGestureRecognizer) {
            let p = g.location(in: nil)
            switch g.state {
            case .began:
                guard overlay == nil,
                      let window = g.view?.window,
                      let t = target(p),
                      let shot = StoryCardShot.crop(t.rect, in: window) else { return }
                let image = UIImageView(image: shot)
                image.frame = CGRect(origin: .zero, size: t.rect.size)
                image.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                image.contentMode = .scaleAspectFill   // only ever scales uniformly; belt anyway
                image.layer.cornerRadius = 24
                image.layer.cornerCurve = .continuous   // every card in this app is continuous
                image.layer.masksToBounds = true
                let container = UIView(frame: CGRect(origin: .zero, size: t.rect.size))
                container.backgroundColor = .clear
                container.addSubview(image)

                let o = CMOverlay(previewView: container,
                                  sourceFrame: t.rect,
                                  // The menu hugs the side the card is on, the way the chat's hugs
                                  // the side the bubble is on.
                                  alignRight: t.rect.midX > window.bounds.midX,
                                  actions: t.actions,
                                  react: nil) { [weak self] in
                    self?.overlay = nil
                }
                // The card comes back as the return spring STARTS, not after the lift is gone — a
                // SwiftUI reveal paints on the next pass, and waiting would leave one frame with an
                // empty slot in the row. See `CMOverlay.onWillDismiss`.
                o.onWillDismiss = { MediaSourceVisibility.shared.reveal() }
                overlay = o
                // The real card steps aside for the lift, exactly as the chat hides the pressed
                // bubble: the same picture must never be on screen twice at the hand-over.
                MediaSourceVisibility.shared.hide(t.key)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.8)
                o.present(in: window, startAtSqueeze: true)

            case .changed:
                overlay?.fingerMoved(to: p)

            case .ended, .cancelled, .failed:
                overlay?.fingerEnded(at: p)

            default:
                break
            }
        }
    }
}
