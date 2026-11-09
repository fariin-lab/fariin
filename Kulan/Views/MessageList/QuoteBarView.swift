import UIKit

/// ⛔ "N QUOTES" ALONG A CHANNEL POST'S BOTTOM (owner 2026-11-06, his pick of the previews): a
/// hairline, up to three photos of public channels that quoted the post, the count in blue, and a
/// chevron. Laid out by `MessageRowLayout.decorations` (`BubblePlan.quoteBar`); the cell routes the
/// tap (`hitsQuoteBar`), so this view takes no touches itself.
final class QuoteBarView: UIView {
    private let divider = UIView()
    private let faces = PollFaceStack()
    /// Face size, and the gap after the faces or icon. `MessageRowLayout` sizes the bubble with these.
    static let faceSide: CGFloat = 30
    static let gap: CGFloat = 10
    /// The width of the faces (or the 24 pt icon) plus the gap after them.
    static func lead(faces n: Int, icon: Bool) -> CGFloat {
        if icon { return 24 + gap }
        guard n > 0 else { return 0 }
        return faceSide + CGFloat(n - 1) * (faceSide * 0.68) + gap   // PollFaceStack's step
    }
    private let label = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.right",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)))

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        divider.backgroundColor = UIColor.label.withAlphaComponent(0.12)
        chevron.tintColor = .tertiaryLabel
        chevron.contentMode = .center
        [divider, faces, label, chevron].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The reply icon (owner's own SVG, 2026-11-07), shown while a post has no replies yet.
    private let icon: UIImageView = {
        let v = UIImageView(image: UIImage(named: "ic_reply_comment")?.withRenderingMode(.alwaysTemplate))
        v.tintColor = .label
        v.contentMode = .scaleAspectFit
        return v
    }()

    func set(_ attr: NSAttributedString, faces urls: [String], icon showIcon: Bool = false, people: Bool = false) {
        label.attributedText = attr
        if icon.superview == nil { addSubview(icon) }
        icon.isHidden = !showIcon
        // Bigger (owner 2026-11-07: "text and avatar look small"; 2026-11-09 again "preview user size
        // looks small"): 30 pt faces, 15 pt words.
        faces.set(showIcon ? [] : urls.prefix(3).map { (people ? "?" : "Channel", $0.isEmpty ? nil : $0) }, side: Self.faceSide)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let pad = BubbleMetrics.hPad
        divider.frame = CGRect(x: 0, y: 0, width: bounds.width, height: BubbleMetrics.hairline)
        var x = pad
        if !icon.isHidden {
            icon.frame = CGRect(x: x, y: (bounds.height - 24) / 2, width: 24, height: 24)
            x += 24 + Self.gap
        } else if !faces.isHidden, faces.frame.width > 0 {
            faces.frame.origin = CGPoint(x: x, y: (bounds.height - faces.frame.height) / 2)
            x += faces.frame.width + Self.gap
        }
        let size = label.sizeThatFits(CGSize(width: bounds.width, height: bounds.height))
        label.frame = CGRect(x: x, y: (bounds.height - size.height) / 2,
                             width: max(0, min(size.width, bounds.width - x - pad - 16)), height: size.height)
        chevron.frame = CGRect(x: bounds.width - pad - 12, y: (bounds.height - 16) / 2, width: 12, height: 16)
    }
}
