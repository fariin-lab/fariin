import UIKit

/// ⛔ THE CHAT HEADER'S BLUR IS OURS, AND IT IS PART OF THE PAGE — owner, 2026-10-03, after four
/// reports that the header blur arrived only once the chat had finished opening: "remove the native
/// blur, use custom, but 100% looks like native; learn the reference app's chat header blur".
///
/// WHY CUSTOM. The system's iOS 26 edge effect is drawn from the scroll view UIKit links to the
/// navigation bar, and for a SwiftUI page with a UIKit list inside it UIKit makes that link only
/// when the push has finished. The reference app never has that problem because its header's
/// background is a view INSIDE the chat page (five research passes over its open iOS source,
/// 2026-10-03: the bar is a subnode of the chat's own node tree and slides in with it, always on,
/// with no fade-in tied to scrolling). This view is the same thing: a subview of the chat's list
/// controller, present from the first frame of the push.
///
/// HOW IT IS BUILT, from the reference's `EdgeEffectView` (its iOS 26 "glass" header):
///   • a blur that fades out over the bottom `edgeSize` (64pt at most) along an eased curve, and
///   • a tint over it at 0.75 of the page colour, faded along the same curve,
///   • reaching from the top of the screen to 24pt below the bar, with no separator line.
/// Their blur is a private `variableBlur` filter. This one is the system blur under the same eased
/// mask — the same look from public API, with no App Store exposure. Its tint layer is stripped the
/// reference's way (`NavigationBackgroundNode`): the effect's own colour subview hidden and its
/// backdrop left with only the blur and the saturation, so the colour on top is the only colour.
final class ChatHeaderBlurView: UIView {
    /// Their numbers.
    static let tailBelowBar: CGFloat = 24
    static let maxEdgeSize: CGFloat = 64
    static let tintAlpha: CGFloat = 0.75

    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .light))
    private let tint = UIView()
    private let blurMask = CAGradientLayer()
    private let tintMask = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        addSubview(blur)
        addSubview(tint)
        blur.layer.mask = blurMask
        tint.layer.mask = tintMask
        stripSystemTint()
        applyColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Leaves the effect as a pure blur (plus saturation), as the reference does, so our tint is
    /// the only colour in it. If a future iOS changes the effect's insides, the plain effect stays.
    private func stripSystemTint() {
        for sub in blur.subviews where String(describing: type(of: sub)).contains("VisualEffectSubview") {
            sub.isHidden = true
        }
        if let backdrop = blur.layer.sublayers?.first, let filters = backdrop.filters {
            backdrop.backgroundColor = nil
            backdrop.isOpaque = false
            backdrop.filters = filters.filter { f in
                let name = (f as AnyObject).value(forKey: "name") as? String ?? ""
                return name == "gaussianBlur" || name == "colorSaturate"
            }
        }
    }

    private func applyColors() {
        tint.backgroundColor = UIColor.systemBackground.withAlphaComponent(Self.tintAlpha)
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        applyColors()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        blur.frame = bounds
        tint.frame = bounds
        let edge = min(Self.maxEdgeSize, bounds.height)
        let (colors, locations) = Self.easedFade(height: bounds.height, edge: edge)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for mask in [blurMask, tintMask] {
            mask.frame = bounds
            mask.colors = colors
            mask.locations = locations
        }
        CATransaction.commit()
    }

    /// Solid down to `height - edge`, then an ease-out fade to nothing over `edge`: their curve is
    /// front-loaded (it drops fastest just below the solid part and tails off), which `(1 - t)^2`
    /// reproduces closely over a dozen stops.
    private static func easedFade(height: CGFloat, edge: CGFloat) -> ([CGColor], [NSNumber]) {
        guard height > 0 else { return ([UIColor.black.cgColor], [0]) }
        let start = max(0, (height - edge) / height)
        var colors: [CGColor] = [UIColor.black.cgColor]
        var locations: [NSNumber] = [0]
        let steps = 12
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let alpha = (1 - t) * (1 - t)
            colors.append(UIColor.black.withAlphaComponent(alpha).cgColor)
            locations.append(NSNumber(value: Double(start + (1 - start) * t)))
        }
        return (colors, locations)
    }
}
