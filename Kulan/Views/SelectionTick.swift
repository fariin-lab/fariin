import SwiftUI

// The multi-select tick, drawn by us.
//
// WHY IT IS OURS AT ALL. `List(selection:)` in edit mode draws its own circle, and the only things
// that circle exposes are the tint and the timing curve — so a tick that draws its check on, dips,
// and overshoots is simply not reachable through it. It also drew WHITE on white here until the tint
// fix, because this app tints itself `.primary`.
//
// Every number below is read from the reference app's own check node, not invented.
//
// ⚠️ SELECT AND DESELECT ARE NOT MIRROR IMAGES, AND THAT IS THE WHOLE POINT. The owner spotted the
// difference by eye before any source was read. Select is slower, eases OUT, and overshoots past
// full size; deselect is quicker, eases IN, and never overshoots. Ticking something is meant to feel
// like it landed. Un-ticking is meant to get out of the way. Do not "tidy" this into one animation
// played forwards and backwards.
//
//                      select                      deselect
//   progress           0 → 1                       1 → 0
//   curve              easeOut                     easeIn
//   duration           0.21s                       0.15s
//   scale legs         1 → 0.9 → 1.1 → 1           1 → 0.9 → 1
//   leg durations      0.08 / 0.13 / 0.10          0.08 / 0.13
//
struct SelectionTick: View {
    var selected: Bool
    var size: CGFloat = 22
    /// The filled state. Deliberately a real colour and not `Color.accentColor`: the accent here is
    /// `.primary`, which is WHITE at night, and a white disc with a white check inside it is the bug
    /// this whole tick exists to end.
    var fill: Color
    var ring: Color
    var check: Color = .white

    /// One value drives the fill, the check and nothing else. The bounce is a SEPARATE clock below,
    /// exactly as it is in their source — the scale outlasts the fill on purpose (0.31s against
    /// 0.21s), which is what stops the bounce reading as part of the drawing.
    private var progress: CGFloat { selected ? 1 : 0 }

    var body: some View {
        ZStack {
            Circle().strokeBorder(ring, lineWidth: 1.5)
            // The disc grows out of the centre rather than fading in. Theirs insets a fill rect by
            // (1 - progress) on both axes, which is this.
            Circle().fill(fill).scaleEffect(progress)
            CheckStroke(progress: progress)
                .stroke(check, style: StrokeStyle(lineWidth: max(1.5, size / 11),
                                                  lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .animation(selected ? .easeOut(duration: 0.21) : .easeIn(duration: 0.15), value: selected)
        // The three chained scale legs. `trigger:` means this fires on a CHANGE only, so a row
        // arriving already-selected (scrolling back to it) does not bounce on its own.
        // CGFloat spelled out. The implicit Double↔CGFloat bridge is legal and is also exactly the
        // kind of thing that costs this project type-checker time for nothing.
        .keyframeAnimator(initialValue: CGFloat(1), trigger: selected) { content, scale in
            content.scaleEffect(scale)
        } keyframes: { _ in
            if selected {
                LinearKeyframe(0.9, duration: 0.08, timingCurve: .easeOut)
                LinearKeyframe(1.1, duration: 0.13, timingCurve: .easeOut)
                LinearKeyframe(1.0, duration: 0.10, timingCurve: .easeIn)
            } else {
                LinearKeyframe(0.9, duration: 0.08, timingCurve: .easeOut)
                LinearKeyframe(1.0, duration: 0.13, timingCurve: .easeOut)
            }
        }
    }
}

/// The check as a stroke that TRAVELS, in two segments off one progress.
///
/// ⚠️ Not `trim(to:)` on a finished path. A trim walks the path at a constant rate along its total
/// length, so the short arm and the long arm would draw at the same speed and the corner would
/// arrive wherever the ratio of their lengths put it. Theirs spends the first THIRD of the animation
/// on the short arm and the remaining two thirds on the long one, which is why the corner snaps and
/// the tail flicks out. The two multipliers below (×3 and ×1.5) are that split.
private struct CheckStroke: Shape {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard progress > 0 else { return path }

        // Their geometry is authored against an 18pt box and scaled from there. Kept in their own
        // numbers (including the 4.0 - 0.3333) so it can be diffed against the source it came from.
        let k = rect.width / 18.0
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let start = CGPoint(x: centre.x - (4.0 - 0.3333) * k, y: centre.y + 0.5 * k)
        let arm1 = CGPoint(x: 2.5 * k, y: 3.0 * k)      // down-right, the short one
        let arm2 = CGPoint(x: 4.6667 * k, y: -6.0 * k)  // up-right, the long one

        let first = max(0, min(1, progress * 3.0))
        guard first > 0 else { return path }

        if first < 1 {
            // Still drawing the short arm. Drawn BACKWARDS, from the moving head to the fixed
            // start, so the round cap sits on the end that is moving.
            path.move(to: CGPoint(x: start.x + arm1.x * first, y: start.y + arm1.y * first))
            path.addLine(to: start)
        } else {
            let second = max(0, min(1, (progress - 0.33) * 1.5))
            let corner = CGPoint(x: start.x + arm1.x, y: start.y + arm1.y)
            path.move(to: CGPoint(x: corner.x + arm2.x * second, y: corner.y + arm2.y * second))
            path.addLine(to: corner)
            path.addLine(to: start)
        }
        return path
    }
}
