import SwiftUI
import UIKit

// The Media / Files / Voice / Links / GIFs row on the All Media page, in the Telegram style the
// owner asked for: a flat dark capsule track with a lighter capsule on the selected tab, rather
// than iOS 26's bright reflective glass.
//
// THIS IS STILL THE REAL UISegmentedControl, and that is the whole point.
//
// A hand-rolled version of this bar was built once and reverted. It drew its own glass capsule, and
// to let that capsule show it had to erase the control's background images — which is what took the
// active-tab indicator away, because iOS draws the selected pill as part of that same surface. The
// owner's report was exactly that: "Active tab Is gone… is looks like liquid glass but is not
// really." One fake surface can only be seen by deleting the real one.
//
// So nothing is erased here. The system control keeps drawing, sliding and animating its own
// selected pill, and keeps its hit targets, Dynamic Type and VoiceOver traits. All that changes is
// which colours it draws with, through the control's own public API. Restyling cannot remove an
// indicator the system is still in charge of.
struct MediaTabBar: UIViewRepresentable {
    let titles: [String]
    @Binding var selection: Int

    func makeUIView(context: Context) -> UISegmentedControl {
        let control = CapsuleSegmentedControl(items: titles)
        control.selectedSegmentIndex = selection
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)

        // Flat, not glass. Assigning these two replaces the material with plain colour, which is the
        // difference the owner is pointing at — Telegram's bar is a dark surface, not a reflective one.
        control.backgroundColor = .secondarySystemFill
        control.selectedSegmentTintColor = UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.22)     // a lighter slab ON the dark track, as in the picture
            : .white }                           // in light mode the selected tab is the familiar white pill

        // White-on-dark either way, with the selected tab carrying the weight rather than a colour.
        // Weight changes only the SELECTED segment, and segment widths here are equal shares of the
        // bar rather than label-sized, so a bolder word cannot resize anything (that was one of the
        // faults in the hand-built bar).
        control.setTitleTextAttributes([.foregroundColor: UIColor.label,
                                        .font: UIFont.systemFont(ofSize: 13, weight: .regular)], for: .normal)
        control.setTitleTextAttributes([.foregroundColor: UIColor.label,
                                        .font: UIFont.systemFont(ofSize: 13, weight: .semibold)], for: .selected)
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

/// A capsule track, which is the shape in the reference. Rounding happens in layout because the
/// radius depends on the height, and the height is the system's to decide.
///
/// Only the control's OWN layer is touched. The selected pill is a system-owned subview and is left
/// alone deliberately — reaching into it is how the previous attempt broke.
private final class CapsuleSegmentedControl: UISegmentedControl {
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
    }
}
