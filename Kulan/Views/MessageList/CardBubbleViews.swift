import UIKit

// ===== The card bubbles =====
//
// A shared place and a shared contact. Both are static pictures over a plan; neither owns any
// state, and every tap is hit-tested from the plan by the cell.

/// A shared place: the map picture flush to the top and the sides, the label under it.
///
/// ⚠️ IT IS A STILL, NOT AN EMBEDDED MAP, and it goes through the SAME `MapSnapshotCache` the
/// SwiftUI card used. A live map view inside a recycled cell is a renderer per bubble; and sharing
/// the cache means a place that has already been drawn once — including by the old path — costs
/// nothing to draw again.
final class LocationBubbleView: UIView {
    private let map = UIImageView()
    private let pin = UIImageView()
    private let label = UILabel()
    private let chevron = UIImageView()
    private var renderedKey: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        map.contentMode = .scaleAspectFill
        map.clipsToBounds = true
        map.backgroundColor = .secondarySystemFill
        addSubview(map)
        pin.contentMode = .scaleAspectFit
        addSubview(pin)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        chevron.contentMode = .scaleAspectFit
        addSubview(chevron)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ l: BubbleBody.LocationBody, plan: LocationPlan, tint: UIColor, dark: Bool) {
        map.frame = plan.map
        label.frame = plan.label
        label.attributedText = plan.labelAttr
        pin.frame = plan.pin
        // Palette, so the pin is a RED head on a light disc rather than one flat colour.
        pin.image = UIImage(systemName: "mappin.circle.fill", withConfiguration:
            UIImage.SymbolConfiguration(pointSize: 22)
                .applying(UIImage.SymbolConfiguration(paletteColors: [.systemRed, tint])))
        chevron.frame = plan.chevron
        chevron.image = UIImage(systemName: "chevron.right",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        chevron.tintColor = tint.withAlphaComponent(0.7)

        let key = MapSnapshotCache.key(lat: l.lat, lon: l.lon, size: plan.map.size, dark: dark)
        if let hit = MapSnapshotCache.cached(key) {
            renderedKey = key
            map.image = hit
            return
        }
        guard renderedKey != key else { return }   // already asked for this one
        renderedKey = key
        map.image = nil
        MapSnapshotCache.render(lat: l.lat, lon: l.lon, size: plan.map.size, dark: dark,
                                key: key) { [weak self] image in
            // The view may have been recycled onto another place while the snapshotter worked.
            guard let self, self.renderedKey == key, let image else { return }
            self.map.image = image
            self.map.alpha = 0
            UIView.animate(withDuration: 0.2) { self.map.alpha = 1 }
        }
    }

    func prepareForReuse() {
        renderedKey = nil
        map.image = nil
    }
}

/// A shared contact: the avatar row, then a full-width "message" button.
final class ContactBubbleView: UIView {
    private let avatar = RowAvatarView()
    private let name = UILabel()
    private let chevron = UIImageView()
    private let button = UIView()
    private let buttonLabel = UILabel()
    private let divider = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        addSubview(avatar)
        name.lineBreakMode = .byTruncatingTail
        addSubview(name)
        chevron.contentMode = .scaleAspectFit
        addSubview(chevron)
        button.layer.cornerRadius = 10
        button.layer.cornerCurve = .continuous
        addSubview(button)
        buttonLabel.textAlignment = .center
        addSubview(buttonLabel)
        addSubview(divider)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ c: BubbleBody.ContactBody, plan: ContactPlan, tint: UIColor) {
        avatar.frame = plan.avatar
        avatar.configure(name: c.name, photoUrl: c.photo)
        name.frame = plan.name
        name.attributedText = plan.nameAttr
        chevron.frame = plan.chevron
        chevron.image = UIImage(systemName: "chevron.right",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        chevron.tintColor = tint.withAlphaComponent(0.7)

        if let rect = plan.button, let attr = plan.buttonAttr, let labelRect = plan.buttonLabel {
            button.isHidden = false; buttonLabel.isHidden = false; divider.isHidden = false
            button.frame = rect
            // Tinted from the bubble's own text colour, so it reads on a blue bubble, a custom chat
            // colour and the incoming grey without anyone picking three values.
            button.backgroundColor = tint.withAlphaComponent(0.12)
            buttonLabel.frame = labelRect
            buttonLabel.attributedText = attr
            divider.frame = CGRect(x: rect.minX, y: rect.minY - 5, width: rect.width,
                                   height: BubbleMetrics.hairline)
            divider.backgroundColor = tint.withAlphaComponent(0.15)
        } else {
            button.isHidden = true; buttonLabel.isHidden = true; divider.isHidden = true
        }
    }
}
