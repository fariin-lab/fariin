import UIKit

/// ⛔ THE CHAT HEADER'S BACKGROUND IS OURS, AND IT IS PART OF THE PAGE — owner, 2026-10-03, after four
/// reports that the system header blur arrived only once the chat had finished opening: custom, but
/// looking 100% like the reference app's chat header, present from the first frame of the push.
///
/// ⛔ SECOND VERSION, FROM THE REFERENCE'S OWN SOURCE FILE, NOT A SUMMARY OF IT — owner, the same
/// night, on build 821: "the blur is not smooth, I see a line, it looks hard". The first version was a
/// FULL-strength system blur faded by opacity, and a strong blur seen half-transparent over sharp
/// content is exactly a visible edge. Read line by line, the reference's iOS 26 header edge effect is
/// almost no blur at all: a variable blur of radius 1 on a half-scale backdrop. What makes it smooth
/// is the TINT: the page colour at alpha 0.75, masked by an eased gradient of 90 stops, solid above
/// and fading to nothing over the bottom edge (64pt at most), reaching 24pt below the bar. Those 90
/// stops are copied below unchanged (alphas normalised by their maximum, exactly as theirs are). The
/// one-point blur is left out: it needs a private filter for a difference the eye cannot see.
final class ChatHeaderBlurView: UIView {
    /// Their numbers.
    static let tailBelowBar: CGFloat = 24
    static let maxEdgeSize: CGFloat = 64
    static let tintAlpha: CGFloat = 0.75

    private static let fadeAlphas: [CGFloat] = [1.00000, 0.99537, 0.99074, 0.98611, 0.98148, 0.97685, 0.97222, 0.96759, 0.96296, 0.95833, 0.95370, 0.94907, 0.94444, 0.93981, 0.93519, 0.93056, 0.92593, 0.92130, 0.91667, 0.91204, 0.90741, 0.90278, 0.89815, 0.89352, 0.88889, 0.88426, 0.87963, 0.87500, 0.87037, 0.86574, 0.86111, 0.85648, 0.85185, 0.84722, 0.84259, 0.83796, 0.82870, 0.81944, 0.81019, 0.80093, 0.79167, 0.77778, 0.76852, 0.75926, 0.74537, 0.73611, 0.72685, 0.71296, 0.70370, 0.69444, 0.68056, 0.66667, 0.65278, 0.63889, 0.62500, 0.61111, 0.59722, 0.58333, 0.57407, 0.56019, 0.54630, 0.53704, 0.52315, 0.50926, 0.49537, 0.48611, 0.47222, 0.45833, 0.44444, 0.43056, 0.41667, 0.40278, 0.38889, 0.37500, 0.36111, 0.34722, 0.33333, 0.31944, 0.30556, 0.28704, 0.27315, 0.25463, 0.23611, 0.21296, 0.18981, 0.16667, 0.13889, 0.10648, 0.05556, 0.00000]
    private static let fadeLocations: [NSNumber] = [0.00000, 0.02091, 0.05923, 0.08711, 0.10801, 0.12195, 0.13240, 0.14286, 0.15331, 0.16028, 0.17073, 0.18118, 0.19164, 0.20209, 0.20906, 0.21254, 0.21951, 0.22648, 0.23345, 0.23693, 0.24390, 0.24739, 0.25436, 0.25784, 0.26132, 0.26829, 0.27178, 0.27526, 0.28223, 0.28571, 0.28920, 0.29268, 0.29617, 0.29965, 0.30314, 0.30662, 0.31359, 0.32056, 0.32753, 0.33449, 0.34146, 0.34843, 0.35540, 0.36237, 0.36934, 0.37631, 0.37979, 0.38676, 0.39373, 0.39721, 0.40418, 0.41115, 0.41812, 0.42509, 0.43206, 0.43902, 0.44599, 0.45296, 0.45645, 0.46341, 0.47038, 0.47387, 0.48084, 0.48780, 0.49477, 0.49826, 0.50523, 0.51220, 0.51916, 0.52613, 0.53310, 0.54007, 0.54704, 0.55401, 0.56098, 0.56794, 0.57491, 0.58188, 0.58885, 0.59930, 0.60627, 0.61672, 0.62718, 0.64111, 0.65854, 0.67596, 0.69686, 0.72822, 0.79094, 1.00000]

    private let tint = UIView()
    private let tintMask = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        addSubview(tint)
        tint.layer.mask = tintMask
        tintMask.colors = Self.fadeAlphas.map { UIColor(white: 0, alpha: $0).cgColor }
        applyColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The reference's edge colour for a chat is the page colour.
    private func applyColors() {
        tint.backgroundColor = UIColor.systemBackground
        tint.alpha = Self.tintAlpha
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        applyColors()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        tint.frame = bounds
        // Solid above, the 90 stops over the bottom `edge` points: the stretched top row of their
        // resizable gradient image, expressed as gradient locations.
        let edge = min(Self.maxEdgeSize, bounds.height)
        let start = bounds.height > 0 ? max(0, (bounds.height - edge) / bounds.height) : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tintMask.frame = bounds
        tintMask.locations = Self.fadeLocations.map {
            NSNumber(value: Double(start) + (1 - Double(start)) * $0.doubleValue)
        }
        CATransaction.commit()
    }
}
