import SwiftUI
import UIKit

// ⛔ THE SYSTEM'S OWN CHROME NUMBERS, READ FROM iOS INSTEAD OF WRITTEN BY US — owner, 2026-08-24:
// "I create the composer, iOS should determine where it is positioned", after three rounds of
// fixed insets (30/16) behaving differently across his two phones.
//
// The native bottom search bar is balanced on every iPhone because none of its numbers exist in
// app code: the sides come from the LAYOUT-MARGIN system (16pt on narrow phones, 20pt on wider
// ones, chosen by iOS per device) and the bottom comes from the bar being EDGE-ATTACHED CHROME
// that dips into the home-indicator band rather than stacking on top of the safe area. Both of
// those inputs are public; SwiftUI just has no modifier that hands them over. This probe is the
// bridge: an invisible UIView that asks UIKit and reports back.
//
// ⚠️ `systemMinimumLayoutMargins` is the device-adaptive margin (the search bar's sides).
// ⚠️ `window.safeAreaInsets.bottom` is the home-indicator band (34 on indicator phones, 0 on
//    home-button phones) and NEVER includes the keyboard — UIKit keeps the keyboard out of window
//    safe areas — so it is the stable rest-geometry number even while typing.
struct SystemChromeReader: UIViewRepresentable {
    @Binding var margin: CGFloat
    @Binding var bottomInset: CGFloat

    func makeUIView(context: Context) -> ChromeProbeView {
        let v = ChromeProbeView()
        v.isUserInteractionEnabled = false
        v.isAccessibilityElement = false
        v.onRead = { m, b in
            // Async so a report from inside a layout pass never mutates state mid-layout.
            DispatchQueue.main.async {
                if margin != m { margin = m }
                if bottomInset != b { bottomInset = b }
            }
        }
        return v
    }

    func updateUIView(_ v: ChromeProbeView, context: Context) {}
}

final class ChromeProbeView: UIView {
    var onRead: ((CGFloat, CGFloat) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        report()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        report()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        report()
    }

    private func report() {
        guard let window else { return }
        // The ROOT controller's minimums, not our own hosting view's margins: SwiftUI hosts set
        // their own layoutMargins and would hand back whatever we last influenced. The root's
        // systemMinimumLayoutMargins is the untouched per-device value the system bars align to.
        let margin = window.rootViewController?.systemMinimumLayoutMargins.leading ?? 16
        onRead?(margin, window.safeAreaInsets.bottom)
    }
}
