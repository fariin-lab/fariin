import SwiftUI

/// The chat bubble, with the little tail on the last message of a run.
///
/// HIS ASK, 2026-08-13, pointing at a zoomed corner of theirs: "what is this one" → the tail → "yes
/// please make how they do it". Their rule, and ours: only the LAST bubble of a run carries it. Send
/// five in a row and the first four are plain; the fifth points at you.
///
/// THE GEOMETRY IS THEIRS, read from their source rather than eyeballed
/// (`TelegramPresentationData/Sources/ChatMessageBubbleImages.swift`). They draw the bubble once into
/// a 33pt-square template and stretch it, so every number there is in 33ths of a bubble:
///
///   * the body is `fixedMainDiameter` = 33 wide, and the image around it is 39 — the tail lives in
///     the 6pt beyond the body's edge, which is why it never stretches with the bubble
///   * the tail itself is the bottom half of `bottomEllipse` (x 24…51, y 16…33) with `topEllipse`
///     (x 33…56, y 14…35) CUT OUT of it — a convex sweep out to the tip, then a concave hook back in.
///     That subtraction is what makes it a hook rather than a triangle.
///   * so: 6pt out, and about 9pt of height (from the ellipse's middle, y 24.5, to the bubble's
///     bottom edge at 33)
///
/// Two quadratic curves reproduce the same silhouette without carrying their ellipse-subtraction
/// machinery into SwiftUI: one bulging out to the tip, one hooking back under.
///
/// ⚠️ THE TAIL LIVES INSIDE THE VIEW'S OWN WIDTH, not outside it. A shape that draws past `rect` is
/// simply clipped by the frame, so the body is inset by the tail's width instead and the hook fills
/// that strip. Nothing at the ten call sites has to change its padding, and the bubble's overall
/// width is exactly what it was — the text just sits 6pt nearer the tail side than theirs does.
struct ChatBubbleShape: Shape {
    var corners: RectangleCornerRadii
    /// Which side the tail hangs off: mine = bottom trailing, theirs = bottom leading.
    var mine: Bool
    /// Last in a run. False on every bubble above it.
    var tail: Bool

    static let tailWidth: CGFloat = 6
    static let tailHeight: CGFloat = 9

    func path(in rect: CGRect) -> Path {
        let t = tail ? Self.tailWidth : 0
        let body = CGRect(x: rect.minX + (mine ? 0 : t), y: rect.minY,
                          width: max(0, rect.width - t), height: rect.height)

        // With a tail the corner it grows from goes small — theirs does the same
        // (`minRadiusForFullTailCorner`), because a full 18pt round would swallow the hook.
        var c = corners
        if tail {
            if mine { c.bottomTrailing = min(c.bottomTrailing, 6) }
            else { c.bottomLeading = min(c.bottomLeading, 6) }
        }

        var p = Path()
        p.addPath(UnevenRoundedRectangle(cornerRadii: c, style: .continuous).path(in: body))
        guard tail, body.width > 0 else { return p }

        let bottom = body.maxY
        if mine {
            let edge = body.maxX
            p.move(to: CGPoint(x: edge, y: bottom - Self.tailHeight))
            // Out to the tip, level with the bubble's own bottom edge.
            p.addQuadCurve(to: CGPoint(x: edge + Self.tailWidth, y: bottom),
                           control: CGPoint(x: edge, y: bottom - 2))
            // And back in under itself — the concave half, their erased ellipse.
            p.addQuadCurve(to: CGPoint(x: edge - 9, y: bottom),
                           control: CGPoint(x: edge - 1, y: bottom - 1))
            p.closeSubpath()
        } else {
            let edge = body.minX
            p.move(to: CGPoint(x: edge, y: bottom - Self.tailHeight))
            p.addQuadCurve(to: CGPoint(x: edge - Self.tailWidth, y: bottom),
                           control: CGPoint(x: edge, y: bottom - 2))
            p.addQuadCurve(to: CGPoint(x: edge + 9, y: bottom),
                           control: CGPoint(x: edge + 1, y: bottom - 1))
            p.closeSubpath()
        }
        return p
    }
}
