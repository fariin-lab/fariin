import SwiftUI
import UIKit

// The Media / Files / Voice / Links / GIFs row on the All Media page.
//
// IT IS APPLE'S SEGMENTED CONTROL, AND THAT IS THE OWNER'S DECISION (2026-08-03): "make it native
// like Call page top head has bar is called All/Missed, that bar is real Apple style… Active tab
// highlight is fake and custom, is not real apple". The Calls page bar he is pointing at is a plain
// `Picker` with `.pickerStyle(.segmented)`, so this is now the same control with the same style.
//
// THIS FILE HAS BEEN THE SYSTEM CONTROL TWICE AND OURS TWICE. The loop ends here, and the reason is
// worth keeping: a hand-drawn track cannot be Apple's control, and Apple's control cannot be Liquid
// Glass on a page. It paints its own track, and iOS draws the selected pill onto that same surface,
// so erasing the track to let glass through also erases the pill — that was "Active tab Is gone".
// Every version of ours since has been an imitation of the platter, and an imitation one screen away
// from the real thing is what he keeps recognising. Do not draw it by hand again.
//
// THE BAR FLOATS OVER THE GRID as an overlay, and the scroll views carry a matching top content
// margin (`MediaTabBar.slotHeight`). `safeAreaBar` was tried and reported wrong on the phone: this
// content is a paged TabView, so the inset reached the TabView rather than the scroll views inside
// it, and all it did was reserve a strip.
struct MediaTabBar: View {
    let titles: [String]
    @Binding var selection: Int

    /// The system segmented control's own height. Stated so the scroll views can reserve a matching
    /// top margin — a floating bar and the content that must clear it cannot each guess.
    static let barHeight: CGFloat = 32
    /// Full vertical slot the bar occupies, including the air above and below it.
    static let slotHeight: CGFloat = barHeight + 16

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(Array(titles.enumerated()), id: \.offset) { i, title in
                Text(title).tag(i)
            }
        }
        .pickerStyle(.segmented)
        .frame(height: Self.barHeight)
    }
}
