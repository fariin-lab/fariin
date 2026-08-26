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
    /// Optional: the chat's composer no longer needs the band (its controller reads the safe area
    /// itself); the stand-in bars still do.
    var bottomInset: Binding<CGFloat>? = nil

    func makeUIView(context: Context) -> ChromeProbeView {
        let v = ChromeProbeView()
        v.isUserInteractionEnabled = false
        v.isAccessibilityElement = false
        v.onRead = { m, b in
            // Async so a report from inside a layout pass never mutates state mid-layout.
            DispatchQueue.main.async {
                if margin != m { margin = m }
                if let bottomInset, bottomInset.wrappedValue != b { bottomInset.wrappedValue = b }
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

/// The composer's OWN edge geometry, for any bar that stands in place of the composer.
///
/// ⛔ SAME RULE, SAME NUMBERS — owner, 2026-08-25, on the official chat's "only Fariin can send
/// messages" strip and the blocked bar: "make it like input bar". They were glass in the composer's
/// shape already, but their insets were hand-written (12 at the sides, 6 at the bottom) while the
/// composer's come from the device. Two bars in the same slot on the same screen, one obeying iOS
/// and one obeying a number somebody typed, is exactly the mismatch the probe above was built for.
///
/// The distinction the owner drew:
///   · **App content** — anything inside the safe area, laid out against it.
///   · **System bar / system-positioned UI** — edge-attached chrome, which sits by the DEVICE's
///     margins and dips into the home-indicator band the way the native bottom search bar does.
/// These bars are the second kind, so they take the second kind's geometry.
///
/// No keyboard branch: none of these bars has a text field, so none of them is ever raised by one.
struct SystemBarChrome: ViewModifier {
    /// The gap a bar keeps above the keys, and above the physical edge on a home-button phone.
    static let keyboardGap: CGFloat = 8
    /// How far the bar sinks BELOW the safe-area line, into the indicator band, at rest.
    static let restDip: CGFloat = 5

    @State private var margin: CGFloat = 16
    @State private var bottomInset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            // At rest the sides match the resting gap under the bar, so the three gaps read as one.
            // The system margin is the floor, so a home-button phone (inset 0) keeps it.
            .padding(.horizontal, max(margin, bottomInset - Self.restDip))
            .padding(.top, 6)
            .padding(.bottom, bottomInset <= 0 ? Self.keyboardGap : -Self.restDip)
            .background { SystemChromeReader(margin: $margin, bottomInset: $bottomInset) }
    }
}

/// JUST THE BOTTOM INSET, for a bar that already has sides it is keeping.
///
/// ⛔ THE BOTTOM PADDING ONLY — owner, 2026-08-25, on the attach sheet's caption bar: "keep it at
/// 40pt and only change the spacing/positioning bottom padding behaviour to match the attach bar".
/// The caption bar is the composer's twin in a sheet, and it was sitting on a flat 4 while the
/// composer's bottom is device-derived — so the same control rested at two different heights above
/// the indicator depending on which screen you were looking at.
///
/// ⚠️ SIZE AND SIDES ARE NOT THIS MODIFIER'S BUSINESS, deliberately. `SystemBarChrome` above also
/// claims the horizontal margins, which is right for a bar standing in the composer's own slot and
/// wrong here: he asked for the bottom and said twice not to touch anything else.
///
/// `keyboardUp` is the composer's own branch — 8pt above the keys when they are up, and the dip into
/// the indicator band only at rest. Pass the KEYBOARD'S state, not a focus flag: focus and keyboard
/// geometry are not the same thing, which the composer learned the hard way.
struct SystemBarBottomChrome: ViewModifier {
    var keyboardUp: Bool

    @State private var margin: CGFloat = 16
    @State private var bottomInset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(.bottom, keyboardUp || bottomInset <= 0
                     ? SystemBarChrome.keyboardGap : -SystemBarChrome.restDip)
            .background { SystemChromeReader(margin: $margin, bottomInset: $bottomInset) }
    }
}

extension View {
    /// Position this view as edge-attached system chrome, the way the composer positions itself.
    func systemBarChrome() -> some View { modifier(SystemBarChrome()) }

    /// Take the composer's BOTTOM inset and nothing else — sides, height and corners stay yours.
    func systemBarBottomChrome(keyboardUp: Bool) -> some View {
        modifier(SystemBarBottomChrome(keyboardUp: keyboardUp))
    }
}
