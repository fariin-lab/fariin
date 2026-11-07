import SwiftUI
import UIKit

// ⛔ "NEW" ON ANY SPOT — owner 2026-11-07: the admin panel can put the green "New" on any card or row
// in `NewBadgeSpots`, with an end time. Nothing shows (and nothing moves) while a spot has no badge.
// Opening the spot does not remove it; it leaves when an admin removes it or the end time passes.

extension View {
    /// The "New" pill after this view (a row's title), while the panel has a badge on `id`.
    func newBadge(_ id: String?) -> some View { modifier(NewBadgeMark(id: id)) }

    /// A small "New" on the top-right corner, for icon tiles with no room beside a title.
    func newBadgeCorner(_ id: String?) -> some View { modifier(NewBadgeCornerMark(id: id)) }
}

struct NewBadgeMark: ViewModifier {
    let id: String?
    func body(content: Content) -> some View {
        if let id, let until = NewBadges.until(id) {
            HStack(spacing: 8) {
                content
                NewBadgePill(until: Date(timeIntervalSince1970: until / 1000))
            }
        } else {
            content
        }
    }
}

struct NewBadgeCornerMark: ViewModifier {
    let id: String?
    func body(content: Content) -> some View {
        if let id, let until = NewBadges.until(id) {
            content.overlay(alignment: .topTrailing) {
                NewBadgePill(until: Date(timeIntervalSince1970: until / 1000), small: true)
                    .offset(x: 6, y: -6)
                    .allowsHitTesting(false)
            }
        } else {
            content
        }
    }
}

/// A row title with the pill, for `Toggle(_:badge:isOn:)`.
struct NewBadgeTitle: View {
    let title: String
    let id: String
    var body: some View { Text(title).newBadge(id) }
}

extension Toggle where Label == NewBadgeTitle {
    /// `Toggle("Title", isOn:)` with a "New" badge spot.
    init(_ title: String, badge: String, isOn: Binding<Bool>) {
        self.init(isOn: isOn) { NewBadgeTitle(title: title, id: badge) }
    }
}

extension NewBadges {
    /// The UIKit pill (custom menus), or nil when `id` has no badge right now. Menus are built
    /// each time they open, so a check at build time is enough.
    @MainActor static func pillLabel(_ id: String?) -> UILabel? {
        guard let id, let end = until(id), Date().timeIntervalSince1970 * 1000 < end else { return nil }
        let l = PaddedPillLabel()
        l.text = "New"
        l.font = .systemFont(ofSize: 13, weight: .semibold)
        l.textColor = .systemGreen
        l.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.16)
        l.layer.masksToBounds = true
        l.textAlignment = .center
        l.sizeToFit()
        l.layer.cornerRadius = l.bounds.height / 2
        l.isAccessibilityElement = false
        return l
    }
}

/// A label with the pill's padding (8 across, 3 down, as `NewBadgePill`).
final class PaddedPillLabel: UILabel {
    private let inset = UIEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: inset)) }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + inset.left + inset.right, height: s.height + inset.top + inset.bottom)
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let s = super.sizeThatFits(size)
        return CGSize(width: s.width + inset.left + inset.right, height: s.height + inset.top + inset.bottom)
    }
}
