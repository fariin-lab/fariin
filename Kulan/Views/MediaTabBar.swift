import SwiftUI
import UIKit

// The Media / Files / Voice / Links / GIFs row on the All Media page.
//
// IT IS APPLE'S SEGMENTED CONTROL, AND THAT IS THE OWNER'S DECISION (2026-08-03): "make it native
// like Call page top head has bar is called All/Missed, that bar is real Apple style… Active tab
// highlight is fake and custom, is not real apple". The Calls page bar he is pointing at is a plain
// `Picker` with `.pickerStyle(.segmented)`, so this is the same control with the same style.
//
// THE TRACK IS OURS, THE CONTROL AND ITS MOVING PILL ARE APPLE'S. His follow-up: "the bar is looks
// grey… make it like the calls page, and All Media bar and Back button it most be same". On the Calls
// page that control lives INSIDE the navigation bar, so the bar supplies the glass and the control
// never draws a track of its own. On a page there is no bar to inherit from, so it paints the grey
// capsule he photographed. `ClearSegmentedTrack` takes that track away and `liquidGlass` puts the
// Back button's own material in its place.
//
// WHY THIS IS SAFE NOW AND WAS NOT BEFORE, because it has already cost one build. Erasing the track
// used to erase the selected pill with it — "Active tab Is gone" — since iOS drew the pill INTO the
// track's background image. On iOS 26 it does not: in his own screenshot the glass pill is visibly
// TALLER than the grey capsule and floats over it, which is only possible if they are separate
// layers. So the erase is gated to iOS 26 and up. Below that the pill is still part of the track and
// the grey stays, which is the correct trade: a dull bar beats a bar with no selection on it.
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
        .background { ClearSegmentedTrack() }
        .frame(height: Self.barHeight)
        // The same call the Back button's circle makes, so the two read as one material.
        .liquidGlass(Capsule())
    }
}

/// Clears the grey capsule a standalone `UISegmentedControl` paints for itself, leaving Apple's
/// control and Apple's moving pill untouched.
///
/// A zero-size, non-interactive view planted behind the picker: from its own place in the hierarchy
/// it can reach the control SwiftUI built and change that ONE instance. The appearance proxy would
/// have been fewer lines and would also have reached the Calls page, Edit Profile and Add Story,
/// where the bar is correct already and must stay that way.
///
/// It touches the `.normal` background only. `.selected`, the divider images and the tint are left
/// exactly as the system set them, because those are what the pill is made of.
private struct ClearSegmentedTrack: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard #available(iOS 26.0, *) else { return }
        // Next runloop: on the first pass this view exists before the picker's own host does, so the
        // search finds nothing and the track stays grey until something else redraws it.
        DispatchQueue.main.async {
            guard let root = uiView.superview?.superview ?? uiView.superview else { return }
            clear(in: root)
        }
    }

    private func clear(in view: UIView) {
        if let seg = view as? UISegmentedControl {
            seg.backgroundColor = .clear
            seg.setBackgroundImage(UIImage(), for: .normal, barMetrics: .default)
            return
        }
        for sub in view.subviews { clear(in: sub) }
    }
}
