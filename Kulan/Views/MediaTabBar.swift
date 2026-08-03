import SwiftUI
import UIKit

// The Media / Files / Voice / Links / GIFs row on the All Media page: a Liquid Glass capsule with a
// lighter capsule on the selected tab, matching the glass on the Back and "..." buttons above it.
//
// THIS FILE HAS BEEN THE SYSTEM CONTROL TWICE AND OUR OWN TWICE. The reason it is ours, written down
// so the loop stops here.
//
// The system UISegmentedControl paints its OWN track, and that track is what you see — a solid
// capsule with a white pill on it, exactly what the owner photographed and called "a standard
// segmented control, not glass". Glass cannot show through a surface that is painted over it. The
// only way to clear that track is to erase the control's background images, and iOS draws the
// selected pill onto those same images, which is what made the active tab disappear the first time
// ("Active tab Is gone… is looks like liquid glass but is not really"). So: system control, or
// glass. Not both. Signal escapes that choice only by mounting their control as the navigation bar's
// titleView, where the BAR supplies the glass; we keep our title and our live count, so we cannot.
//
// The other half of the loop was mine. Glass shows nothing unless something passes behind it, and
// this bar sat in a stack ABOVE the grid, so the photos stopped where the bar began. I moved it to
// `safeAreaBar`, which reserves a strip rather than floating when the content is a paged TabView —
// the owner checked and reported the photos still did not pass under it. It is an overlay now, with
// the scroll views carrying a matching top content margin, which is what the navigation bar does and
// the reason ITS glass has always looked right on this screen.
//
// THE PILL IS ONE CAPSULE THAT MOVES. It is never created inside the chosen segment and never
// removed from the others, so there is no state in which it can fail to exist. Segments are equal
// shares of the width, so the selected label going semibold cannot resize anything.
//
// What we owe by hand, having left the system control: Dynamic Type and VoiceOver. The labels carry
// button and selected traits explicitly and shrink rather than truncate.
struct MediaTabBar: View {
    let titles: [String]
    @Binding var selection: Int
    @Environment(\.colorScheme) private var scheme

    /// Height of the capsule itself. Stated so the scroll views can reserve a matching top margin —
    /// a floating bar and the content that must clear it cannot each guess.
    static let barHeight: CGFloat = 42
    /// Full vertical slot the bar occupies, including the air above and below it.
    static let slotHeight: CGFloat = barHeight + 16

    /// Inset of the moving pill inside the track, per side.
    private let pad: CGFloat = 3

    var body: some View {
        // The width comes from the reader rather than from measured state, so the pill is in the
        // right place on the very first frame — there is no moment where it sits at zero width.
        GeometryReader { g in
            let seg = titles.isEmpty ? g.size.width : g.size.width / CGFloat(titles.count)
            ZStack(alignment: .leading) {
                Capsule()
                    // The SYSTEM segmented control's selected platter (owner order: match the
                    // Calls bar's All/Missed): a SOLID elevated pill — white in light, Apple's
                    // #636366 in dark — with the platter's soft drop shadow. The old translucent
                    // white-0.22 wash read as a different design one screen away from the native
                    // control. No stroke: the platter's edge is its elevation, not a border.
                    .fill(scheme == .dark ? Color(red: 0.388, green: 0.388, blue: 0.4) : .white)
                    .shadow(color: .black.opacity(scheme == .dark ? 0.28 : 0.12), radius: 4, y: 2)
                    .frame(width: max(0, seg - pad * 2), height: max(0, g.size.height - pad * 2))
                    // X ONLY. A leading-aligned ZStack still centres its children VERTICALLY, so the
                    // pill already has `pad` of air above and below it — the `y: pad` that used to be
                    // here pushed it down onto the bottom of the track and left a double gap at the
                    // top. That lopsided pill is the "active bar position is wrong" the owner saw.
                    .offset(x: CGFloat(selection) * seg + pad)

                HStack(spacing: 0) {
                    ForEach(Array(titles.enumerated()), id: \.offset) { i, title in
                        Text(title)
                            .font(.system(size: 14, weight: i == selection ? .semibold : .regular))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .onTapGesture { selection = i }
                            .accessibilityAddTraits(i == selection ? [.isButton, .isSelected] : .isButton)
                    }
                }
            }
            .frame(width: g.size.width, height: g.size.height)
            // Belt and braces on the pill: at the track's widest corner it clears the edge by under a
            // point, so a rounding error is enough to make it poke out. Clipping makes that impossible.
            .clipShape(Capsule())
            // The same call the Back button's circle makes, so the two read as one material.
            .liquidGlass(Capsule(), interactive: true)
            .animation(.snappy(duration: 0.25), value: selection)
        }
        .frame(height: Self.barHeight)
    }
}
