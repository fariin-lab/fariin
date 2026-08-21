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
        // ⛔ THE TRACK IS CLEARED AGAIN — AND THIS TIME THE PILL IS GIVEN A COLOUR OF ITS OWN.
        //
        // Clearing the track has been tried twice and cost a build both times: iOS draws the
        // selected pill as part of the same surface as the track, so erasing that surface erased the
        // selection with it and every tab looked unselected. The note that used to sit here said so
        // and concluded a grey track with a visible selection beats a glass track with none.
        //
        // ⚠️ THE CONCLUSION WAS RIGHT AND THE PREMISE WAS WRONG. Neither attempt set
        // `selectedSegmentTintColor`, which draws the selected capsule INDEPENDENTLY of the
        // background image — I checked both commits (`7a136a9d`, `eef48188`) and the property does
        // not appear in either. The trade was never "glass or a pill". It was "glass or forgetting
        // one line".
        //
        // So: the control's own track goes, our glass capsule is what you see behind the words, and
        // the pill is drawn by the control from the tint below. There is no second shape to nest
        // inside the first, which was his other complaint about this bar — the duplicate pill came
        // from our capsule sitting OUTSIDE the control's own opaque track, and there is no longer
        // one.
        .background { SegmentedGlassTrack() }
        .frame(height: Self.barHeight)
        // ⛔ A COMPACT CENTRED PILL, WHICH IS THE LAST THING SEPARATING THIS FROM THE OTHER TWO
        // (owner, 2026-08-21: "make it use the same design as the Photo/Collection or All/Missed
        // bars … do not change its position").
        //
        // Both of those set their own width — 150 for All/Missed, 220 for Photos/Collections — and
        // sit in the middle of their row. This one stretched the full 361pt of the page, and a
        // segmented control pulled that wide stops reading as a control and starts reading as a grey
        // band across the screen. Nothing moves: same row, same height, same vertical position, and
        // the strip it lives in is unchanged.
        //
        // 330 rather than a fixed number like theirs, because five words need about 303 and the
        // rest is room for larger text before anything truncates. It is a CEILING, not a width, so
        // a 320pt phone simply takes what it has instead of overflowing.
        .frame(maxWidth: 330)
        .frame(maxWidth: .infinity)   // ...and centred in whatever is left
        // THE HISTORY OF THIS ONE LINE, because it has been added and removed twice (owner
        // 2026-08-13, our bar beside theirs: "it has duplicate… it has both, one and the other
        // one").
        //
        // `.liquidGlass(Capsule())` used to sit here. It made sense only while `ClearSegmentedTrack`
        // was erasing the control's own track — capsule outside, nothing inside. That erase was
        // removed two rounds ago because it took the selected pill with it, and the capsule was left
        // behind. So the bar has been drawing OUR rounded shape with APPLE'S rounded track nested
        // inside it, one pill inside another, which is exactly what he circled.
        //
        // It is back, and the reason is at the top of `body`: with the control's own track cleared
        // there is nothing for it to nest inside, so this is the one surface behind the words — the
        // same shape the Photos/Collections bar wears in the navigation bar.
        .liquidGlass(Capsule())
    }
}

/// ⛔ CLEARS THE SEGMENTED CONTROL'S TRACK AND KEEPS ITS SELECTION.
///
/// Two things, and the second is the one both earlier attempts missed:
///
///   • `setBackgroundImage(UIImage(), for: .normal)` removes the opaque track, so the glass capsule
///     behind the control is what is seen rather than a grey slab sitting on top of it.
///   • `selectedSegmentTintColor` draws the selected capsule, and it does NOT come from the
///     background image — which is why clearing that image on its own left every tab looking
///     unselected, twice.
///
/// The tint is a translucent white so the glass reads THROUGH the pill rather than the pill being a
/// solid lid on it: nearly opaque on a light page where the glass is pale anyway, and a fifth of
/// white on a dark one, which is how the system's own glass segmented control sits on a bar.
///
/// ⚠️ `DispatchQueue.main.async` and a walk up from this background view, because SwiftUI's
/// `Picker` gives no handle on the UIKit control it builds. The traversal is the one from
/// `7a136a9d`, which did find the control — that attempt failed on the missing tint, not on this.
private struct SegmentedGlassTrack: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            guard let root = uiView.superview?.superview ?? uiView.superview else { return }
            Self.style(in: root)
        }
    }

    private static func style(in view: UIView) {
        if let seg = view as? UISegmentedControl {
            seg.backgroundColor = .clear
            seg.setBackgroundImage(UIImage(), for: .normal, barMetrics: .default)
            // THE LINE BOTH EARLIER ATTEMPTS WERE MISSING.
            seg.selectedSegmentTintColor = UIColor { t in
                t.userInterfaceStyle == .dark
                    ? UIColor.white.withAlphaComponent(0.20)
                    : UIColor.white.withAlphaComponent(0.92)
            }
            return
        }
        for sub in view.subviews { style(in: sub) }
    }
}
