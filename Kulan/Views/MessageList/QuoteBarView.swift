import UIKit

/// ⛔ "N QUOTES" ALONG A CHANNEL POST'S BOTTOM (owner 2026-11-06, his pick of the previews): a
/// hairline, up to three photos of public channels that quoted the post, the count in blue, and a
/// chevron. Laid out by `MessageRowLayout.decorations` (`BubblePlan.quoteBar`); the cell routes the
/// tap (`hitsQuoteBar`), so this view takes no touches itself.
final class QuoteBarView: UIView {
    private let divider = UIView()
    private let faces = PollFaceStack()
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
        faces.set(showIcon ? [] : urls.prefix(3).map { (people ? "?" : "Channel", $0.isEmpty ? nil : $0) }, side: 22)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let pad = BubbleMetrics.hPad
        divider.frame = CGRect(x: 0, y: 0, width: bounds.width, height: BubbleMetrics.hairline)
        var x = pad
        if !icon.isHidden {
            icon.frame = CGRect(x: x, y: (bounds.height - 22) / 2, width: 22, height: 22)
            x += 22 + 8
        } else if !faces.isHidden, faces.frame.width > 0 {
            faces.frame.origin = CGPoint(x: x, y: (bounds.height - faces.frame.height) / 2)
            x += faces.frame.width + 8
        }
        let size = label.sizeThatFits(CGSize(width: bounds.width, height: bounds.height))
        label.frame = CGRect(x: x, y: (bounds.height - size.height) / 2,
                             width: max(0, min(size.width, bounds.width - x - pad - 16)), height: size.height)
        chevron.frame = CGRect(x: bounds.width - pad - 12, y: (bounds.height - 16) / 2, width: 12, height: 16)
    }
}
