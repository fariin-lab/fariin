import SwiftUI

/// THE STORY CAMERA ARRIVES FROM THE LEFT, AND THE APP SLIDES OUT OF ITS WAY.
///
/// Owner, 2026-08-24, with the reference app's own transition on screen beside ours: "when i click
/// add story the camera page is coming from the bottom, i want it like the reference — camera comes
/// from the left side and the chat list goes right".
///
/// It used to be a `fullScreenCover`, which is why it came up from the bottom: that is the only
/// thing a cover knows how to do. Nothing here presents anything. The camera is a sibling of the
/// whole app inside one container, and a single number moves both.
///
/// ⛔ EVERY CONSTANT BELOW IS THEIRS, READ FROM THEIR CAMERA SCREEN'S OWN SOURCE. He asked for the
/// real numbers rather than for something that looks similar, and four things move at once — which
/// is the whole reason theirs reads as depth instead of as a slide:
///
///   camera x       (progress − 1) × width          full travel, off-left to home
///   camera scale   0.8 + 0.2 × progress            grows in as it arrives
///   camera inside  −(progress − 1) × width ÷ scale × 0.5   contents trail at HALF speed
///   camera dim     black 0.6 × (1 − progress)      lit as it lands
///   the app x      progress × width                pushed right, the card in his screenshot
///
/// ⚠️ THE PARALLAX IS THE HALF, AND IT IS EASY TO DROP. Their container moves the full width while
/// its contents move half of it, so the picture inside the camera lags behind the camera's own
/// frame. Take that line out and everything still slides, but it slides like one flat sheet of
/// paper — which is what ours would have been if the numbers had been guessed.
@MainActor @Observable final class StoryCameraDoorState {
    static let shared = StoryCameraDoorState()
    private init() {}

    /// 0 = the app owns the screen, 1 = the camera does. Every transform reads this and nothing
    /// else, exactly as their `transitionFraction` does, so a finger and a tap drive one system.
    var progress: CGFloat = 0

    /// Whether the camera EXISTS. Separate from `progress` on purpose: a camera holds a capture
    /// session, and one that is merely off-screen is still a camera that is running. Raised before
    /// the opening animation and dropped after the closing one finishes.
    var mounted = false

    /// Their settle, stated in their release handler: `duration: 0.4, curve: .spring`. Their spring
    /// lands without a visible overshoot, so this is the bounce-free one of the same length rather
    /// than a bouncier SwiftUI default dressed up as theirs.
    static let settle: Animation = .spring(duration: 0.4, bounce: 0)

    func open() {
        guard !mounted else { return }
        mounted = true
        withAnimation(Self.settle) { progress = 1 }
    }

    func close() {
        guard mounted else { return }
        withAnimation(Self.settle) { progress = 0 } completion: {
            // Only now is the capture session allowed to go. Unmounting on the first frame of the
            // animation would tear the preview down and animate an empty black rectangle out.
            if self.progress == 0 { self.mounted = false }
        }
    }

    /// The finger let go without going far enough — settle back to wide open.
    func settleOpen() { withAnimation(Self.settle) { progress = 1 } }
}

/// Wraps the whole app so both halves of the transition live in one place.
struct StoryCameraDoor<Camera: View>: ViewModifier {
    /// ⚠️ A `let`, NOT a `private var`. A struct's memberwise init takes the access level of its
    /// least visible stored property, and this modifier is constructed with an argument — the same
    /// trap that stopped `MainShell` from building `StoriesRow` once already.
    let state = StoryCameraDoorState.shared
    @ViewBuilder var camera: () -> Camera

    /// Measured, never read from `UIScreen`. The travel has to be the width of the thing actually
    /// moving; a screen-width constant is wrong the moment anything is not full width.
    @State private var width: CGFloat = 0
    /// True from the moment a drag is claimed as a dismissal, so the rest of that same drag keeps
    /// driving it even after the finger wanders back right. Theirs holds `isDismissing` for this.
    @State private var dismissing = false

    func body(content: Content) -> some View {
        ZStack {
            content
                .offset(x: state.progress * width)
                // The app is still mounted and still laid out underneath; it just must not answer a
                // finger while it is parked off to the side.
                .disabled(state.progress > 0)
                .background {
                    GeometryReader { g in
                        Color.clear.onChange(of: g.size.width, initial: true) { _, w in width = w }
                    }
                }
            if state.mounted { cameraLayer }
        }
    }

    private var cameraLayer: some View {
        let p = state.progress
        let scale = max(0.8, min(1.0, 0.8 + 0.2 * p))
        let offsetX = (p - 1) * width
        // Their `sublayerOffsetX`, which is what makes the contents trail the frame.
        let inner = -offsetX / scale * 0.5
        return camera()
            .offset(x: inner)
            .scaleEffect(scale)
            .offset(x: offsetX)
            .overlay(Color.black.opacity(0.6 * (1 - p)).ignoresSafeArea().allowsHitTesting(false))
            .ignoresSafeArea()
            .gesture(dismissDrag)
    }

    /// Drag left to put the camera away, tracking the finger with no curve at all — theirs updates
    /// with `.immediate` while the touch is down, and a curve there is what makes a drag feel like
    /// it is arguing with you.
    ///
    /// ⚠️ ONLY DISMISSAL LIVES ON A DRAG, AND THAT IS THEIRS TOO — their camera's pan handler has one
    /// story branch and it opens nothing. Opening stays a tap, which also keeps this away from the
    /// chat list, where a horizontal drag would be competing with the row swipe actions and the
    /// interactive back gesture (see the standing rule about deciding an axis in UIKit).
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { v in
                // Their threshold: the drag has to declare itself as a leftward one first.
                guard v.translation.width < -10 || dismissing else { return }
                dismissing = true
                state.progress = max(0, min(1, 1 - (-v.translation.width) / max(width, 1)))
            }
            .onEnded { v in
                guard dismissing else { return }
                dismissing = false
                // ⚠️ THEIR VELOCITY TEST IS DEAD CODE AND IS NOT COPIED. They pass `abs(velocity.x)`
                // and then test it against `< -1000`, which an absolute value can never satisfy, so
                // in their build the fraction alone decides. The 0.7 IS theirs and is kept; the flick
                // is written the way that test was plainly meant to read, so a fast throw completes
                // instead of springing back at 0.75.
                let flick = v.predictedEndTranslation.width - v.translation.width
                if state.progress < 0.7 || flick < -300 { state.close() } else { state.settleOpen() }
            }
    }
}

extension View {
    /// One call, and everything about the transition is inside the modifier.
    ///
    /// ⚠️ It has to stay one call. `MainShell`'s body has hit the type-checker's limit before —
    /// "unable to type-check this expression in reasonable time" cost three builds — so nothing
    /// about this belongs inline up there.
    func storyCameraDoor<Camera: View>(@ViewBuilder camera: @escaping () -> Camera) -> some View {
        modifier(StoryCameraDoor(camera: camera))
    }
}
