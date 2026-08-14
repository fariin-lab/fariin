import SwiftUI
import UIKit

// The Media / Files / Voice / Links / GIFs row on the All Media page.
//
// IT IS APPLE'S SEGMENTED CONTROL, AND THAT IS THE OWNER'S DECISION (2026-08-03): "make it native
// like Call page top head has bar is called All/Missed, that bar is real Apple style… Active tab
// highlight is fake and custom, is not real apple". The Calls page bar he is pointing at is a plain
// `Picker` with `.pickerStyle(.segmented)`, so this is the same control with the same style.
//
// THE TRACK IS THE CONTROL'S OWN AGAIN, AND THE FOURTH SWING IS OVER. His follow-up back then was
// "the bar is looks grey… make it like the calls page", and the answer was `ClearSegmentedTrack`,
// which erased the control's `.normal` background image so a glass capsule behind it could show.
//
// THAT ERASE TOOK THE SELECTED PILL WITH IT, both times. It had already cost one build once ("Active
// tab Is gone"), and the comment that used to sit here argued the second attempt was safe because on
// iOS 26 the pill looked like a separate, taller layer in a screenshot. It is not. He is on iOS 26,
// the erase was gated to iOS 26, and he has now photographed the same bar with no selection on any
// tab. The screenshot reasoning was wrong and it cost a second round.
//
// MediaGalleryView's own comment already said this deletion had happened and that "nothing replaces
// it" — but the call was only removed from that file's notes, never from this one, so the bug it
// describes stayed live. Do not add it back. A grey track with a visible selection beats a glass
// track with none, and that is the whole trade.
//
// STILL TRUE, AND THE REASON THIS FILE HAS SWUNG FOUR TIMES: do not hand-draw the control itself.
// A drawn track with a drawn pill is an imitation of Apple's, and he recognises it from one screen
// away. The control here is real; only the surface behind it is ours.
//
// THE BAR FLOATS OVER THE GRID as an overlay, and the scroll views carry a matching top content
// margin (`MediaTabBar.slotHeight`). `safeAreaBar` was tried and reported wrong on the phone: this
// content is a paged TabView, so the inset reached the TabView rather than the scroll views inside
// it, and all it did was reserve a strip.
struct MediaTabBar: View {
    let titles: [String]
    @Binding var selection: Int

    /// The bar's own height. Stated so the scroll views can reserve a matching top margin — a
    /// floating bar and the content that must clear it cannot each guess. 42 on the owner's spec
    /// (was the segmented control's natural 32).
    static let barHeight: CGFloat = 42
    /// Full vertical slot the bar occupies, including the air above and below it.
    static let slotHeight: CGFloat = barHeight + 16

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(Array(titles.enumerated()), id: \.offset) { i, title in
                Text(title).tag(i)
            }
        }
        .pickerStyle(.segmented)
        // NO `ClearSegmentedTrack` HERE ANY MORE, AND THAT IS THE MISSING HIGHLIGHT.
        //
        // It erased the control's `.normal` background image so a hand-made glass capsule behind it
        // could show through. iOS draws the SELECTED PILL as part of that same surface, so clearing
        // it took the pill with it and every tab looked unselected — which is exactly what the owner
        // photographed. MediaGalleryView's own comment already records this and says "nothing
        // replaces it", but the call was only removed from that file's notes and not from here, so
        // the bug it describes has been live the whole time.
        .frame(height: Self.barHeight)
        // FIFTH SWING, AND IT IS THE LAST SHAPE COMING OFF (owner 2026-08-13, our bar beside theirs:
        // "it has duplicate… it has both, one and the other one").
        //
        // `.liquidGlass(Capsule())` used to sit here. It made sense only while `ClearSegmentedTrack`
        // was erasing the control's own track — capsule outside, nothing inside. That erase was
        // removed two rounds ago because it took the selected pill with it, and the capsule was left
        // behind. So the bar has been drawing OUR rounded shape with APPLE'S rounded track nested
        // inside it, one pill inside another, which is exactly what he circled.
        //
        // Nothing replaces it. The slot already carries `.background(.bar)` across its full width
        // (see MediaGalleryView.tabBar), which is the material the nav bar above uses, so the strip
        // still reads as one surface with the header — and what sits on it is one control with one
        // track and one pill, the same as the Calls page bar he pointed at in the first place.
    }
}
