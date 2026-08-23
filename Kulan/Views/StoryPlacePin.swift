import SwiftUI

/// ⛔ THE LOCATION BADGE'S PIN, DRAWN FROM THE OWNER'S OWN ARTWORK — his 2026-08-23 order, with the
/// vector attached: "in story location icon update … also make Blue and use this icon".
///
/// It replaces `mappin.and.ellipse`, which is a SOLID glyph with a shadow ellipse under it. His is an
/// outline: a teardrop drawn as a 1.5-wide ring with a ring inside it, and nothing filled. There is no
/// SF Symbol that is this shape, so it is transcribed rather than substituted — a near-miss symbol
/// would be a different drawing wearing the same name, and that is the sort of thing he notices.
///
/// ⚠️ IT NEEDS `FillStyle(eoFill: true)` AND THAT IS NOT A PREFERENCE. Every part of this is two
/// closed outlines with the gap between them as the ink: the teardrop's outer edge against its inner
/// edge, and the same for the small circle. Filled the ordinary way the two circles are one solid
/// disc and the pin is a solid blob — the whole drawing collapses into the glyph it is replacing.
///
/// The path is his 24x24 viewBox, scaled to whatever rect it is given and centred in it, so a caller
/// only ever picks a size. The two circles are `addEllipse` rather than the four Béziers his file
/// spells them with: both are perfect circles on (12, 10) at r 2.25 and r 3.75, so this is the exact
/// same shape with the approximation taken out.
struct StoryPlacePin: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()

        // The teardrop, outer edge.
        p.move(to: CGPoint(x: 3.25, y: 10.1433))
        p.addCurve(to: CGPoint(x: 12, y: 1.25),
                   control1: CGPoint(x: 3.25, y: 5.24427), control2: CGPoint(x: 7.15501, y: 1.25))
        p.addCurve(to: CGPoint(x: 20.75, y: 10.1433),
                   control1: CGPoint(x: 16.845, y: 1.25), control2: CGPoint(x: 20.75, y: 5.24427))
        p.addCurve(to: CGPoint(x: 18.8844, y: 17.2419),
                   control1: CGPoint(x: 20.75, y: 12.5084), control2: CGPoint(x: 20.076, y: 15.0479))
        p.addCurve(to: CGPoint(x: 13.7805, y: 22.3539),
                   control1: CGPoint(x: 17.6944, y: 19.4331), control2: CGPoint(x: 15.9556, y: 21.3372))
        p.addCurve(to: CGPoint(x: 10.2195, y: 22.3539),
                   control1: CGPoint(x: 12.6506, y: 22.882), control2: CGPoint(x: 11.3494, y: 22.882))
        p.addCurve(to: CGPoint(x: 5.11556, y: 17.2419),
                   control1: CGPoint(x: 8.04437, y: 21.3372), control2: CGPoint(x: 6.30562, y: 19.4331))
        p.addCurve(to: CGPoint(x: 3.25, y: 10.1433),
                   control1: CGPoint(x: 3.92403, y: 15.0479), control2: CGPoint(x: 3.25, y: 12.5084))
        p.closeSubpath()

        // The teardrop, inner edge. Against the one above, this is the stroke.
        p.move(to: CGPoint(x: 12, y: 2.75))
        p.addCurve(to: CGPoint(x: 4.75, y: 10.1433),
                   control1: CGPoint(x: 8.00843, y: 2.75), control2: CGPoint(x: 4.75, y: 6.04748))
        p.addCurve(to: CGPoint(x: 6.4337, y: 16.526),
                   control1: CGPoint(x: 4.75, y: 12.2404), control2: CGPoint(x: 5.35263, y: 14.5354))
        p.addCurve(to: CGPoint(x: 10.8546, y: 20.995),
                   control1: CGPoint(x: 7.51624, y: 18.5192), control2: CGPoint(x: 9.04602, y: 20.1496))
        p.addCurve(to: CGPoint(x: 13.1454, y: 20.995),
                   control1: CGPoint(x: 11.5821, y: 21.335), control2: CGPoint(x: 12.4179, y: 21.335))
        p.addCurve(to: CGPoint(x: 17.5663, y: 16.526),
                   control1: CGPoint(x: 14.954, y: 20.1496), control2: CGPoint(x: 16.4838, y: 18.5192))
        p.addCurve(to: CGPoint(x: 19.25, y: 10.1433),
                   control1: CGPoint(x: 18.6474, y: 14.5354), control2: CGPoint(x: 19.25, y: 12.2404))
        p.addCurve(to: CGPoint(x: 12, y: 2.75),
                   control1: CGPoint(x: 19.25, y: 6.04748), control2: CGPoint(x: 15.9916, y: 2.75))
        p.closeSubpath()

        // The eye, outer then inner — same trick, same reason.
        p.addEllipse(in: CGRect(x: 8.25, y: 6.25, width: 7.5, height: 7.5))
        p.addEllipse(in: CGRect(x: 9.75, y: 7.75, width: 4.5, height: 4.5))

        // Fitted and centred. Scale first, then move — the same order `ZoomableImageView` builds its
        // own transforms in, and the only order that puts the drawing where the rect says.
        let s = min(rect.width, rect.height) / 24
        return p.applying(CGAffineTransform(translationX: rect.midX - 12 * s, y: rect.midY - 12 * s)
            .scaledBy(x: s, y: s))
    }
}
