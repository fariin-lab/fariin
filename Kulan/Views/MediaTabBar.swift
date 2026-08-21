import SwiftUI
import UIKit

// The Media / Files / Voice / Links / GIFs row on the All Media page.
//
// ⛔ IT IS THE REFERENCE APP'S BAR, DRAWN BY US, AND THAT IS A REVERSAL OF THIS MORNING'S ANSWER.
// He asked earlier for "the same design as the Photos/Collections bar", which is Apple's stock
// segmented control, and that is what shipped. Then he sent a photograph of the bar he actually
// means — their profile's Posts / Gifts / Media / Music / Link row — and it is not Apple's control
// and cannot be made into it. Four things in that picture rule it out:
//
//   • THE SEGMENTS ARE NOT EQUAL WIDTH. Each one is as wide as its own words, so "Gifts 🤞🎁🎉"
//     takes three times the room of "Link". Apple's control divides its width evenly and has no
//     setting that does not.
//   • IT SCROLLS. "Link" is cut off at the right edge of his screenshot, which is the whole reason
//     the segments can be content-sized: the bar is not trying to fit.
//   • THE TRACK IS FULL WIDTH, edge to edge with a page margin, not a compact centred pill.
//   • The selected pill is inset INSIDE the track rather than filling its height.
//
// So this is ours. Not because ours is better — the note this file has carried for four rounds says
// the opposite — but because the thing he is pointing at is not the stock control, and dressing the
// stock control up to look like it is precisely the mistake that cost four builds. Drawing it
// outright is the honest version: nothing is fighting UIKit for ownership of the track, because
// UIKit is not involved.
//
// ⚠️ THE VERTICAL POSITION AND THE SLOT ARE UNCHANGED, which has been his condition every round.
// `barHeight` and `slotHeight` are what the scroll views reserve their top margin from and they are
// the same numbers as before.
struct MediaTabBar: View {
    let titles: [String]
    @Binding var selection: Int

    /// The bar's own height. Stated so the scroll views can reserve a matching top margin — a
    /// floating bar and the content that must clear it cannot each guess.
    static let barHeight: CGFloat = 42
    /// Full vertical slot the bar occupies, including the air above and below it.
    static let slotHeight: CGFloat = barHeight + 16

    /// The selected pill sits INSIDE the track rather than filling it — measured off his screenshot,
    /// where a band of track is visible above and below the pill on every side.
    private static let pillInset: CGFloat = 4
    /// What each segment adds around its own words. This is what makes a long label a long segment.
    private static let segmentHPad: CGFloat = 18
    /// The page margin the track itself keeps.
    private static let pageInset: CGFloat = 16

    @Namespace private var pill

    var body: some View {
        // ⚠️ A ScrollView, AND IT IS THE POINT RATHER THAN A PRECAUTION. Content-sized segments only
        // work if the bar is allowed to be wider than the screen; the moment it has to fit, every
        // label has to shrink and it becomes the equal-width control again. Theirs cuts "Link" off
        // at the edge and that is correct behaviour, not an overflow bug.
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(titles.enumerated()), id: \.offset) { i, title in
                        segment(title, index: i).id(i)
                    }
                }
                .padding(Self.pillInset)
            }
            .frame(height: Self.barHeight)
            // ⛔ GLASS, AND THE OLD "DO NOT PUT GLASS ON THIS" WARNING NO LONGER APPLIES.
            //
            // That warning is real and it is still in the gallery beside the call site, but it was
            // written about a DIFFERENT control. While this was Apple's stock segmented control, a
            // glass capsule around it drew our pill outside Apple's own track — one pill inside
            // another, which is what he circled on the fifth swing. There is no stock track any more.
            // This bar draws its own, so glass REPLACES the flat fill rather than wrapping a second
            // shape around a first, and there is nothing left to nest.
            //
            // The selected pill below stays a solid rather than becoming glass too: glass on glass
            // is what has no edge, and the pill is the one thing on this bar that must read at a
            // glance.
            .liquidGlass(Capsule())
            .padding(.horizontal, Self.pageInset)
            // Tapping a half-visible segment brings it into view, which is the only way the ones
            // past the right edge are reachable with a thumb.
            .onChange(of: selection) { _, i in
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(i, anchor: .center) }
            }
        }
    }

    private func segment(_ title: String, index: Int) -> some View {
        let on = selection == index
        return Button {
            // The pill travels on a spring; the label's weight changes with it rather than after.
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { selection = index }
        } label: {
            Text(title)
                .font(.system(size: 16, weight: on ? .semibold : .regular))
                // ⚠️ NOT `.primary` / `.secondary`. Those are HIERARCHICAL styles and resolve against
                // a Button's tint, so inside a tinted List they come out coloured — the same trap
                // the archive's context-menu icons fell into. Spelled explicitly, they cannot.
                .foregroundStyle(on ? Color.white : Color.white.opacity(0.55))
                .lineLimit(1)
                .fixedSize()                       // each segment is as wide as its own words
                .padding(.horizontal, Self.segmentHPad)
                .frame(height: Self.barHeight - Self.pillInset * 2)
                .background {
                    // ⛔ ONE PILL THAT MOVES, not one per segment fading in and out.
                    // `matchedGeometryEffect` is what makes it slide from the old segment to the new
                    // one; two pills cross-fading is the cheap version and reads as a blink.
                    if on {
                        Capsule()
                            .fill(Color.primary.opacity(0.16))
                            .matchedGeometryEffect(id: "mediaTabPill", in: pill)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
