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
    /// ⛔ WHERE THE PAGER ACTUALLY IS, IN PAGE UNITS — owner, 2026-08-23: "0% swipe → indicator is
    /// 100% on Media, 10% swipe → indicator should already move approximately 10% toward Files …
    /// if I move my finger slowly, the indicator must move slowly".
    ///
    /// 1.5 means halfway between the second and third segments, and the pill is drawn there. This is
    /// the only thing the pill's position depends on; `selection` decides which label is bold and
    /// which segment the bar scrolls to, and nothing else.
    var progress: CGFloat = 0

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

    /// Each segment's frame inside the row, measured once the row has laid out. The pill reads two
    /// of these and interpolates between them.
    ///
    /// ⚠️ A PREFERENCE IS ONE LAYOUT PASS LATE, and that is harmless HERE and only here: these frames
    /// depend on the titles and the font, both of which are fixed for the life of the screen. The
    /// same mechanism is fatal for anything measured per-keystroke — the story text badge carries
    /// that warning for the case where it bit.
    @State private var frames: [Int: CGRect] = [:]
    /// True only between a segment tap and the auto-scroll that answers it — see the note on
    /// `onChange(of: selection)`. A swipe never sets it, which is what keeps the commit frame cheap.
    @State private var tapDriven = false

    /// The pill's rect for a given travel. Between two segments it is a straight blend of both their
    /// positions AND both their widths, which is what makes a short label growing into a long one
    /// read as one shape moving rather than a box that jumps size on arrival.
    private func pillRect(_ p: CGFloat) -> CGRect? {
        guard !titles.isEmpty else { return nil }
        let clamped = min(max(p, 0), CGFloat(titles.count - 1))
        let lo = Int(clamped.rounded(.down)), hi = min(lo + 1, titles.count - 1)
        guard let a = frames[lo], let b = frames[hi] else { return nil }
        let t = clamped - CGFloat(lo)
        return CGRect(x: a.minX + (b.minX - a.minX) * t,
                      y: a.minY,
                      width: a.width + (b.width - a.width) * t,
                      height: a.height)
    }

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
                // ⛔ ONE PILL, BEHIND EVERY SEGMENT, PLACED BY `progress` — NOT A PILL PER SEGMENT AND
                // NOT `matchedGeometryEffect` ANY MORE.
                //
                // The effect it replaces could only interpolate between two finished layouts, and
                // only when the change that produced them sat inside an animation. That is a
                // handsome jump; it is not a follow. His report is precisely about the difference:
                // at 10% of a swipe the pill had not moved at all, because nothing had changed yet
                // for it to interpolate FROM. Now the position IS the drag.
                //
                // The spring that used to live here is gone with it. A spring on a value that
                // already arrives once per frame is a second clock running beside the finger, which
                // is the lag it was added to cure. A TAP still needs one, and gets it below, where
                // there is no drag to fight.
                .background(alignment: .topLeading) {
                    if let r = pillRect(progress) {
                        Capsule()
                            // The system's own selected-segment fill rather than a hand-mixed
                            // opacity: it is already defined against both appearances and against
                            // glass, which a `primary.opacity` is not.
                            .fill(Color(uiColor: .tertiarySystemFill))
                            .frame(width: r.width, height: r.height)
                            .offset(x: r.minX, y: r.minY)
                    }
                }
                .coordinateSpace(.named("mediaTabRow"))
                .onPreferenceChange(MediaTabSegmentFrames.self) { frames = $0 }
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
            // ⛔ THE AUTO-SCROLL ANIMATES FOR A TAP AND NEVER FOR A SWIPE, AND THAT SPLIT IS A BUG FIX.
            //
            // The gallery hosting this bar carries a warning in its own file that I then walked
            // straight into: a paged `TabView` flips its selection AS YOUR FINGER CROSSES THE
            // MIDPOINT, while the drag is still live, so anything animated hung off that value runs
            // on the commit frame — the one frame that is already the most expensive of the gesture.
            // Its note ends "nothing heavy on the commit frame", and an animated `scrollTo` is heavy.
            // That is his "swiping pages lags".
            //
            // A swipe needs no animation anyway: the page is already moving under the finger and the
            // pill is drawn at the offset that drag reports, so the bar tracks it either way. The
            // animation only ever existed for the other case — tapping a segment that is half off
            // the right edge, where the scroll is the whole feedback and a jump would read as a
            // glitch. (This is the BAR scrolling sideways, which is a separate motion from the pill
            // sliding along it; only the pill follows `progress`.)
            //
            // `tapDriven` is set by the segment button one line before it writes the selection, so it
            // is true only on that path and is cleared the moment it is spent.
            .onChange(of: selection) { _, i in
                if tapDriven {
                    tapDriven = false
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(i, anchor: .center) }
                } else {
                    proxy.scrollTo(i, anchor: .center)
                }
            }
        }
    }

    /// ⚠️ THE BOLD FOLLOWS `progress`, NOT `selection`. They agree at rest and disagree for the whole
    /// length of a drag: `selection` flips at the midpoint, so the words used to change weight a beat
    /// after the pill had already arrived under them. Rounding the travel puts both on one clock.
    private func segment(_ title: String, index: Int) -> some View {
        let on = Int(progress.rounded()) == index
        return Button {
            // Set BEFORE the write, because the write is what fires the `onChange` that reads it.
            tapDriven = true
            // ⛔ ANIMATED, AND THIS IS NOW THE PAGER'S ANIMATION RATHER THAN THE PILL'S. The gallery
            // scrolls to the tapped page off this value, and a scroll made inside an animation
            // travels instead of jumping — so it reports itself frame by frame on the way, and the
            // pill follows the same number it follows under a finger. One rule for both paths, which
            // is what every previous round here was trying to buy with a second animation.
            withAnimation(.snappy(duration: 0.3)) { selection = index }
        } label: {
            Text(title)
                .font(.system(size: 16, weight: on ? .semibold : .regular))
                // ⛔ THE SYSTEM LABEL COLOURS, AND HARDCODED WHITE WAS THE BUG HE PHOTOGRAPHED.
                //
                // These were `Color.white` and `Color.white.opacity(0.55)`, which is fine on a dark
                // page and invisible on a light one: his light-mode screenshot is a glass capsule
                // with nothing legible in it at all, "Media" included, because white text on
                // near-white glass has no contrast to give. Real system glass adapts and so must
                // whatever sits on it — that is most of what he means by "native, not custom".
                //
                // ⚠️ STILL NOT `.primary` / `.secondary`, and the old note's reason stands: those are
                // HIERARCHICAL styles that resolve against a Button's tint, so inside a tinted
                // container they come out coloured — the trap the archive's context-menu icons fell
                // into. `UIColor.label` and `.secondaryLabel` are concrete adaptive colours, not
                // hierarchy, so they follow light and dark WITHOUT following the tint. Both problems,
                // one substitution.
                .foregroundStyle(on ? Color(uiColor: .label) : Color(uiColor: .secondaryLabel))
                .lineLimit(1)
                .fixedSize()                       // each segment is as wide as its own words
                .padding(.horizontal, Self.segmentHPad)
                .frame(height: Self.barHeight - Self.pillInset * 2)
                // The pill is drawn once, behind the whole row (see `body`). All a segment does now
                // is say where it is.
                .background {
                    GeometryReader { g in
                        Color.clear.preference(key: MediaTabSegmentFrames.self,
                                               value: [index: g.frame(in: .named("mediaTabRow"))])
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Every segment's frame in the row's own space, keyed by index. Merged rather than replaced, since
/// each segment contributes exactly one entry and they arrive separately.
private struct MediaTabSegmentFrames: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}
