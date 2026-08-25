import SwiftUI
import UIKit

// ⛔ THE REFERENCE APP'S PANEL BLUR, PORTED FROM ITS SOURCE — owner, 2026-08-25: "go read [the
// reference] then copy, the blur it is using [on the] attach bar, then use [it in] my app['s]
// attach bar and caption bar in [the] attach sheet."
//
// WHAT THEY ACTUALLY DO, which is not "a blurred material":
//
//   1. `UIVisualEffectView(effect: UIBlurEffect(style: .light))` — ALWAYS `.light`, in both their
//      day and night themes. The theme never reaches the effect; it reaches the fill in step 4.
//   2. Every subview whose description contains "VisualEffectSubview" is HIDDEN. That is UIKit's
//      own tint/vibrancy plate, and hiding it is what stops the blur adding a colour of its own.
//   3. On the backdrop sublayer, the CAFilter list is cut down to `gaussianBlur` and `colorSaturate`
//      and NOTHING else — the `luminanceCurveMap`, `colorBrightness` and `colorMatrix` UIKit stacks
//      on top of the blur are dropped, and the layer is made non-opaque with no background colour.
//      Those discarded filters are exactly what makes a stock material look milky; without them you
//      get the picture behind, blurred and slightly saturated, and nothing else.
//   4. A translucent fill goes over it, and it is the fill that carries the theme:
//         light  #F2F2F2 @ 0.9      dark  #1D1D1D @ 0.9
//      (their `rootNavigationBar.blurredBackgroundColor`, which their tab bar and their attachment
//      panel both read.) 0.9 is not arbitrary either: their own guard only keeps the blur alive
//      while the fill's alpha is under 0.95, so the number and the blur are one decision.
//   5. Reduce Transparency: no effect view at all, just the fill. Theirs checks this before it
//      builds anything, so it is part of the port rather than a nicety added on top.
//
// ⚠️ THIS IS NOT LIQUID GLASS, AND THAT IS THE POINT OF THE REQUEST. iOS 26's `glassEffect` is a
// lens with a specular edge that moves; this is a flat, quiet blur with a colour wash. They are
// different materials and the app now uses both — glass on the composer, this on the two attach
// sheet bars, which is what he asked for after looking at the two apps side by side.
//
// ⚠️ `layer.sublayers[0].filters` is undocumented territory, not private API: the filters are read
// and rewritten through public `CALayer` properties, and the whole block is guarded. If a future
// iOS stops exposing them the guard simply fails and the stock blur is what shows — degraded, never
// broken. This is the same bet the reference app has been shipping for years.
struct PanelBlur: UIViewRepresentable {
    var dark: Bool

    func makeUIView(context: Context) -> PanelBlurView { PanelBlurView() }

    func updateUIView(_ view: PanelBlurView, context: Context) {
        view.update(dark: dark)
    }
}

final class PanelBlurView: UIView {
    /// Their fill, both themes. Stated here rather than pulled from `Theme` because it is THEIR
    /// number and the point of the port is that it is theirs; a value that tracked our palette
    /// would drift away from the thing he asked to copy.
    private static let lightFill = UIColor(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF2 / 255, alpha: 0.9)
    private static let darkFill  = UIColor(red: 0x1D / 255, green: 0x1D / 255, blue: 0x1D / 255, alpha: 0.9)

    private var effectView: UIVisualEffectView?
    private let fillView = UIView()
    private var appliedDark: Bool?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false   // pure background; the bar's own controls take the taps
        fillView.isUserInteractionEnabled = false
        addSubview(fillView)
        buildEffectIfWanted()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        effectView?.frame = bounds
        fillView.frame = bounds
    }

    func update(dark: Bool) {
        guard appliedDark != dark else { return }
        appliedDark = dark
        fillView.backgroundColor = dark ? Self.darkFill : Self.lightFill
    }

    /// Step 5 first: with Reduce Transparency on there is no effect view, only the fill.
    private func buildEffectIfWanted() {
        guard !UIAccessibility.isReduceTransparencyEnabled else { return }

        let effectView = UIVisualEffectView(effect: UIBlurEffect(style: .light))

        // 2 — UIKit's own tint plate, hidden so the blur contributes no colour.
        for subview in effectView.subviews where subview.description.contains("VisualEffectSubview") {
            subview.isHidden = true
        }

        // 3 — cut the filter stack down to the blur and the saturation.
        if let backdrop = effectView.layer.sublayers?.first, let filters = backdrop.filters {
            backdrop.backgroundColor = nil
            backdrop.isOpaque = false
            let allowed = ["gaussianBlur", "colorSaturate"]
            backdrop.filters = filters.filter { filter in
                guard let filter = filter as? NSObject else { return true }
                return allowed.contains(String(describing: filter))
            }
        }

        effectView.isUserInteractionEnabled = false
        self.effectView = effectView
        // Under the fill, which is the order their node builds: blurred picture, then the wash.
        insertSubview(effectView, belowSubview: fillView)
    }
}

extension View {
    /// The reference app's panel background: their stripped blur, their fill, clipped to `shape`.
    ///
    /// Takes a shape rather than a corner radius because the two bars that use it are different
    /// shapes — a capsule and a 23pt rounded rectangle — and a radius would have made the capsule
    /// a number somebody has to keep in step with the bar's height.
    func panelBlur(_ shape: some Shape, dark: Bool) -> some View {
        background { PanelBlur(dark: dark).clipShape(shape) }
    }
}
