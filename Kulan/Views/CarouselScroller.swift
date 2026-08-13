import SwiftUI
import UIKit

// The my-stories carousel's ENGINE, built the way the reference app builds theirs — read from
// the reference implementation, not guessed: a hidden UIScrollView ("Scroller" in their source)
// whose pan gesture is attached to the row, native deceleration, and a scrollViewWillEndDragging
// snap to whole cards. The cards themselves keep being drawn by SwiftUI from ONE continuous
// position; this only replaces the finger half.
//
// WHY: the row used to run on a SwiftUI DragGesture plus a hand-rolled momentum formula (predicted
// translation → card steps → withAnimation spring). Every frame of both the drag and the glide was
// a SwiftUI re-render through @State, the release physics were an imitation, and the owner called
// the result laggy and unclear ("make it exactly like the reference app"). A UIScrollView's pan and deceleration
// ARE the native physics — the same curve every list in iOS glides on — and driving the row from
// its contentOffset makes the drag and the glide one continuous number with no imitation anywhere.
struct CarouselScroller: UIViewRepresentable {
    let count: Int
    /// Points of travel per card step — the same `fullDist` the SwiftUI layout derives positions
    /// from, so offset/fullDist IS the card position with no second geometry to agree with.
    let fullDist: CGFloat
    /// Continuous card position (0 = first card centred, 1.5 = halfway between cards 1 and 2).
    @Binding var scroll: CGFloat
    /// A finger or the glide owns the row right now (the host hides the live story for the swap).
    var onInteracting: (Bool) -> Void = { _ in }
    /// The row settled with this index centred.
    var onSettled: (Int) -> Void = { _ in }
    /// Tap, in card-steps from the centre (0 = the centred card, -1 = the left neighbour…).
    var onTap: (Int) -> Void = { _ in }

    func makeUIView(context: Context) -> CarouselScrollerView {
        let v = CarouselScrollerView()
        v.configure(coordinator: context.coordinator)
        context.coordinator.view = v
        context.coordinator.parent = self
        return v
    }

    func updateUIView(_ v: CarouselScrollerView, context: Context) {
        context.coordinator.parent = self
        v.sync(count: count, fullDist: fullDist, scroll: scroll)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: CarouselScroller
        weak var view: CarouselScrollerView?
        /// True while WE push the binding, so updateUIView does not push the same value back into
        /// the scroller mid-gesture (the classic representable feedback loop).
        var applying = false

        init(_ parent: CarouselScroller) { self.parent = parent }

        func scrollViewDidScroll(_ s: UIScrollView) {
            guard parent.fullDist > 0.5 else { return }
            // Only the finger/glide reports; a programmatic sync must not echo.
            guard s.isTracking || s.isDragging || s.isDecelerating || view?.animating == true else { return }
            applying = true
            parent.scroll = max(0, min(CGFloat(parent.count - 1), s.contentOffset.x / parent.fullDist))
            applying = false
        }

        func scrollViewWillBeginDragging(_ s: UIScrollView) {
            parent.onInteracting(true)
        }

        /// THE REFERENCE APP'S SNAP: the deceleration target is rounded to a whole card, so the native glide
        /// lands centred — their scrollViewWillEndDragging + snapScrolling, in one line.
        func scrollViewWillEndDragging(_ s: UIScrollView, withVelocity velocity: CGPoint,
                                       targetContentOffset: UnsafeMutablePointer<CGPoint>) {
            guard parent.fullDist > 0.5 else { return }
            let step = (targetContentOffset.pointee.x / parent.fullDist).rounded()
            let clamped = max(0, min(CGFloat(parent.count - 1), step))
            targetContentOffset.pointee.x = clamped * parent.fullDist
        }

        func scrollViewDidEndDragging(_ s: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { settle(s) }
        }
        func scrollViewDidEndDecelerating(_ s: UIScrollView) { settle(s) }
        func scrollViewDidEndScrollingAnimation(_ s: UIScrollView) {
            view?.animating = false
            settle(s)
        }

        private func settle(_ s: UIScrollView) {
            guard parent.fullDist > 0.5 else { return }
            let i = Int((s.contentOffset.x / parent.fullDist).rounded())
            let idx = max(0, min(parent.count - 1, i))
            // Land EXACTLY on the card: the drawing derives scale from this number, and 1.996
            // cards leaves the centre card a hair small forever.
            applying = true
            parent.scroll = CGFloat(idx)
            applying = false
            parent.onSettled(idx)
            parent.onInteracting(false)
        }
    }
}

/// The row's touch surface. The hidden scroller is a subview only so UIKit runs its machinery; its
/// PAN GESTURE is attached to THIS view (the reference app's exact trick), so fingers land here and the
/// scroller does the physics. Taps are ours too — the SwiftUI cards underneath draw and nothing else.
final class CarouselScrollerView: UIView {
    let scroller = UIScrollView()
    private weak var coordinator: CarouselScroller.Coordinator?
    /// A tap-started setContentOffset animation is running (didScroll must report during it).
    var animating = false

    func configure(coordinator: CarouselScroller.Coordinator) {
        self.coordinator = coordinator
        backgroundColor = .clear
        scroller.isHidden = true
        scroller.showsHorizontalScrollIndicator = false
        scroller.decelerationRate = .normal          // the reference app's; .fast overshoots the snap feel
        scroller.alwaysBounceVertical = false
        scroller.alwaysBounceHorizontal = true
        scroller.contentInsetAdjustmentBehavior = .never
        scroller.delegate = coordinator
        addSubview(scroller)
        // THE TRICK: the scroller's own pan, re-homed onto the visible row. The scroll view still
        // drives it (targets are unchanged), but the touches it responds to are the row's.
        addGestureRecognizer(scroller.panGestureRecognizer)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
    }

    /// ⚠️ THE HAND-OVER STARTS ON TOUCH-DOWN, NOT ON THE DRAG (owner 2026-08-11: swipe the sheet's
    /// cards SLOWLY and everything is right; FLICK the first one and the preview cards stack on top
    /// of each other).
    ///
    /// The live story card sits in the centre slot and cannot slide, so for the length of a swipe the
    /// row draws its OWN card there and the live one stands aside — `carouselOwnsSlot` →
    /// `hideActiveContent`. That signal was raised in `scrollViewWillBeginDragging`, which UIKit only
    /// calls once the pan has passed its recognition threshold, and it then has to cross a SwiftUI
    /// update before the live card actually hides.
    ///
    /// A slow drag has moved a few points in that window, so the swap is invisible. A FLICK has
    /// already carried the row a long way: for those frames the carousel's card and the live card are
    /// both on screen, side by side and overlapping — which is exactly what he photographed.
    ///
    /// Touch-down happens BEFORE the threshold, so the same signal now has the whole
    /// finger-down-to-recognised window to land, and the flick can no longer outrun it. Nothing else
    /// changes: `settle` still lowers it, and a touch that never becomes a drag is a TAP, which is
    /// handled here too and ends in `settle` either way.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        coordinator?.parent.onInteracting(true)
    }

    /// A finger that lands and lifts without dragging and without hitting the tap recogniser would
    /// otherwise leave the live card standing aside for good. `settle` is the one place that lowers
    /// the flag, so a cancelled touch has to reach it.
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        guard !scroller.isTracking, !scroller.isDragging, !scroller.isDecelerating, !animating else { return }
        coordinator?.parent.onInteracting(false)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scroller.frame = bounds
        coordinator.map { sync(count: $0.parent.count, fullDist: $0.parent.fullDist, scroll: $0.parent.scroll) }
    }

    func sync(count: Int, fullDist: CGFloat, scroll: CGFloat) {
        guard fullDist > 0.5, bounds.width > 0 else { return }
        let want = CGSize(width: CGFloat(max(0, count - 1)) * fullDist + bounds.width, height: bounds.height)
        if abs(scroller.contentSize.width - want.width) > 0.5 { scroller.contentSize = want }
        // Push the outside world's position in only while the finger is NOT down — mid-gesture the
        // scroller is the truth and SwiftUI is the echo.
        let target = scroll * fullDist
        if !scroller.isTracking, !scroller.isDragging, !scroller.isDecelerating, !animating,
           abs(scroller.contentOffset.x - target) > 0.5 {
            scroller.contentOffset = CGPoint(x: target, y: 0)
        }
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard let c = coordinator, c.parent.fullDist > 0.5 else { return }
        let x = g.location(in: self).x
        let steps = Int(((x - bounds.width / 2) / c.parent.fullDist).rounded())
        if steps == 0 {
            c.parent.onTap(0)
        } else {
            // A side card: glide to it on the scroller's own animation — native curve, and
            // didScroll keeps reporting so the cards ride along.
            let target = max(0, min(CGFloat(c.parent.count - 1), c.parent.scroll.rounded() + CGFloat(steps)))
            // A NO-OP TARGET NEVER TOUCHES STATE. Tapping past the ends clamps to where the row
            // already is, and `setContentOffset(animated:)` with an unchanged offset performs no
            // animation and never calls scrollViewDidEndScrollingAnimation — so settle() never ran,
            // `animating` and the host's `carouselInteracting` stuck TRUE, and the LIVE story card
            // stayed alpha-0 behind the copy. The first sheet scroll then faded the copy out and
            // he was looking at pure black where his story was.
            guard abs(target * c.parent.fullDist - scroller.contentOffset.x) > 0.5 else {
                c.parent.onTap(steps)
                return
            }
            animating = true
            c.parent.onInteracting(true)
            scroller.setContentOffset(CGPoint(x: target * c.parent.fullDist, y: 0), animated: true)
            c.parent.onTap(steps)
        }
    }
}
