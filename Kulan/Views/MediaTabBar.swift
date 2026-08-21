import SwiftUI
import UIKit

// The Media / Files / Voice / Links / GIFs row on the All Media page.
//
// ⛔ IT IS APPLE'S SEGMENTED CONTROL AND NOTHING ELSE, WHICH IS WHERE THIS SHOULD HAVE STOPPED FOUR
// ROUNDS AGO. Owner, 2026-08-21, holding it beside the story picker: "why can't this bar be like the
// Photos/Collections bar". It can. That bar is three lines —
//
//     Picker("", selection: $tab) { Text("Photos").tag(0); Text("Collections").tag(1) }
//         .pickerStyle(.segmented)
//         .frame(width: 220)
//
// — with no customisation of any kind, and it has never once been reported broken. This is now the
// same three lines.
//
// ⛔ THE HISTORY, BECAUSE IT IS THE REASON THIS FILE MUST NOT GROW AGAIN. Every failure here came
// from one idea: put OUR glass capsule behind APPLE'S control. To see the glass, the control's own
// track had to be erased; erasing the track erased the selected pill with it, twice, and both times
// cost a build ("Active tab Is gone"). The third attempt added `selectedSegmentTintColor` to bring
// the pill back and that is genuinely how the property works — but only while the control is in its
// DEFAULT state. Setting any background image switches UIKit to its customised path, where the tint
// is ignored and the selection comes from `setBackgroundImage(for: .selected)`. So clearing the
// track and setting a tint are mutually exclusive, and the fourth attempt supplied both images
// explicitly.
//
// ⚠️ THAT FOURTH ATTEMPT IS WHAT HE PHOTOGRAPHED TODAY, AND IT WAS WORSE THAN ALL OF THEM. The
// selected pill drew as a half-shape and every label truncated to "Vo…", "Li…", "(". The cause was
// the divider: a resizable 42x42 image handed to `setDividerImage` makes each divider FORTY-TWO
// POINTS WIDE, so four of them ate 168 of the bar's 330 and left the five segments about thirty
// points each. A control cannot be customised in one place without being measured in every other.
//
// So: no glass capsule, no background images, no divider images, no title attributes, no
// UIViewRepresentable reaching into the control. The stock control draws its own track, its own
// pill and its own labels, at its own metrics, and it is the same control the other two bars in the
// app already are.
//
// ⚠️ THE POSITION AND THE SLOT ARE UNCHANGED, which was his condition. `barHeight` and `slotHeight`
// are the numbers the scroll views reserve their top margin from, and they are the same numbers as
// before — the control is simply given that height instead of being decorated inside it.
struct MediaTabBar: View {
    let titles: [String]
    @Binding var selection: Int

    /// The bar's own height. Stated so the scroll views can reserve a matching top margin — a
    /// floating bar and the content that must clear it cannot each guess. 42 on the owner's spec.
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
        .frame(height: Self.barHeight)
        // ⛔ A COMPACT CENTRED PILL, which is the last thing separating this from the other two bars
        // (owner, 2026-08-21: "make it use the same design as the Photo/Collection or All/Missed
        // bars … do not change its position").
        //
        // Both of those set their own width — 150 for All/Missed, 220 for Photos/Collections — and
        // sit in the middle of their row. This one stretched the full 361pt of the page, and a
        // segmented control pulled that wide stops reading as a control and starts reading as a grey
        // band across the screen.
        //
        // 330 rather than a fixed number like theirs, because five words need about 303 and the rest
        // is room for larger text before anything truncates. It is a CEILING, not a width, so a
        // narrow phone simply takes what it has instead of overflowing.
        .frame(maxWidth: 330)
        .frame(maxWidth: .infinity)   // …and centred in whatever is left
    }
}
