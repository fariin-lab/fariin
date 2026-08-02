import SwiftUI
import UIKit

// The Media / Files / Voice / Links / GIFs row on the All Media page: APPLE'S OWN segmented control,
// drawn by iOS 26, with nothing repainted.
//
// This file has now been three things, and the reason it is back to the system control is worth
// keeping, because the temptation to paint it will come round again.
//
// It was the system control with a flat dark track and a lighter selected slab, which is what the
// owner asked for in August from a Telegram reference. Then he asked for Signal's Liquid Glass, and
// since Signal only gets glass by handing their control to the navigation bar as its titleView —
// which we cannot do without giving up the title and the live count — the bar was hand-drawn: a
// glass capsule with a moving pill. It looked hand-drawn, and he said so.
//
// THE SURFACE WAS NEVER THE PROBLEM. Glass only shows when there is something behind it to bend, and
// this bar sat in a stack ABOVE the grid, so the grid stopped where the bar began and the only thing
// behind it was flat page. The navigation bar's own back and "..." buttons look right for one reason:
// the photos scroll underneath them. Fixed where it belonged, in the layout — the bar now floats over
// the content (`floatingTopBar`) and the grid passes beneath it.
//
// With that fixed there is nothing left to hand-draw. Apple's control brings its own iOS 26 glass,
// its selection indicator, its sliding animation, its hit targets, its Dynamic Type and its VoiceOver
// traits, none of which can drift from the OS and none of which we then owe by hand. Every colour and
// font override is gone on purpose: each one was a step away from the thing being asked for.
//
// DO NOT ERASE ITS BACKGROUND IMAGES to force something else behind it. iOS paints the selected pill
// onto that same surface, and erasing it is what made the active tab vanish once already ("Active tab
// Is gone… is looks like liquid glass but is not really").
struct MediaTabBar: UIViewRepresentable {
    let titles: [String]
    @Binding var selection: Int

    func makeUIView(context: Context) -> UISegmentedControl {
        let control = UISegmentedControl(items: titles)
        control.selectedSegmentIndex = selection
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        // Equal shares rather than label-sized segments, so the selected word going bold cannot
        // resize anything. This is a layout rule, not a repaint.
        control.apportionsSegmentWidthsByContent = false
        return control
    }

    func updateUIView(_ control: UISegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        if control.selectedSegmentIndex != selection { control.selectedSegmentIndex = selection }
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    final class Coordinator: NSObject {
        var selection: Binding<Int>
        init(selection: Binding<Int>) { self.selection = selection }
        @objc func changed(_ sender: UISegmentedControl) { selection.wrappedValue = sender.selectedSegmentIndex }
    }
}
