import SwiftUI
import UIKit

// The Media / Files / Voice / Links / GIFs row on the All Media page: a Liquid Glass capsule with a
// lighter capsule on the selected tab. Same place, same size, same behaviour as before — only the
// surface changed. It is the Avatar / Poster switch from the photo picker, with five segments
// instead of two, which is what the owner asked for.
//
// WHY THIS IS NOT THE SYSTEM CONTROL ANY MORE, having deliberately been one until now.
//
// Signal's version of this bar IS a plain UISegmentedControl, and their entire styling is
// `backgroundColor = .clear`. It looks like glass because they hand it to the navigation bar as its
// titleView, and it inherits the glass the bar already has. Ours lives on the page, where there is
// no glass behind it to show through, so that same control can only ever draw the stock grey track.
// Glass in this position has to be drawn underneath, and making the system control transparent
// enough to reveal it means erasing its background images — which is exactly what took the active
// tab away the last time this was attempted ("Active tab Is gone… is looks like liquid glass but is
// not really"), because iOS draws the selected pill onto that same surface.
//
// SO THE PILL IS NOT THE SYSTEM'S ANY MORE, AND IT CANNOT GO MISSING. It is ONE capsule that moves
// to an offset computed from the selected index. It is never created inside the chosen segment and
// never removed from the others, so there is no state in which it fails to exist. That was the flaw
// in the hand-built bar that got reverted; this is the shape that replaced it in the photo picker.
//
// The other fault of that old bar is closed too: every segment is an equal share of the width, so
// the selected label going semibold cannot resize anything.
struct MediaTabBar: View {
    let titles: [String]
    @Binding var selection: Int

    /// Inset of the moving pill inside the track, per side.
    private let pad: CGFloat = 3

    var body: some View {
        // The width comes from the reader rather than from measured state, so the pill is in the
        // right place on the very first frame — there is no moment where it sits at zero width.
        GeometryReader { g in
            let seg = titles.isEmpty ? g.size.width : g.size.width / CGFloat(titles.count)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.22))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 0.5))
                    .frame(width: max(0, seg - pad * 2), height: max(0, g.size.height - pad * 2))
                    .offset(x: CGFloat(selection) * seg + pad, y: pad)

                HStack(spacing: 0) {
                    ForEach(Array(titles.enumerated()), id: \.offset) { i, title in
                        Text(title)
                            .font(.system(size: 13, weight: i == selection ? .semibold : .regular))
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
            .liquidGlass(Capsule())
            .animation(.snappy(duration: 0.25), value: selection)
        }
    }
}
