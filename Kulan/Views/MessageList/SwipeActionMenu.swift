import UIKit

// ⛔ MULTI-ACTION SWIPE (owner 2026-11-08). The reply swipe, extended: past the reply threshold a
// vertical capsule of three slots grows around the reply arrow. Forward on top, Reply in the middle
// (the default), and a bottom action that depends on what the message is: Copy for text, Save for a
// photo, video or album, Save to Files for a document. Kinds with nothing sensible to put there
// (voice notes, polls, stickers...) show that slot dimmed, and it cannot be picked.
//
// Moving the finger up or down while it stays down picks a slot, counted from where the threshold
// was crossed. The list does the gesture (`handleSwipePan`); this file only holds the rules and the
// drawing, so the pan keeps one shape for both paths.
//
// GATED to @v for now, like `CustomReaction.canChoose`. Everyone else gets the plain reply swipe,
// which takes the old code path untouched (`swipeMenu` stays nil).
enum MultiSwipe {
    private static let uid = "SVf0zxDVZzO8oLbGvM150QWgIWd2"
    @MainActor static var enabled: Bool { AuthService.shared.uid == uid }

    /// What the finger is resting on. `rawValue` is the slot's row: -1 top, 0 middle, 1 bottom.
    enum Slot: Int { case forward = -1, reply = 0, bottom = 1 }

    enum Bottom: Equatable {
        case none
        case copy
        case save(count: Int)   // a single photo or video is 1; an album says "Save N Items"
        case saveToFiles

        var title: String {
            switch self {
            case .none: return ""
            case .copy: return "Copy"
            case .save(let n): return n > 1 ? "Save \(n) Items" : "Save"
            case .saveToFiles: return "Save to Files"
            }
        }
        var icon: String {
            switch self {
            case .none: return "nosign"
            case .copy: return "doc.on.doc"
            case .save: return "square.and.arrow.down"
            case .saveToFiles: return "folder"
            }
        }
    }

    /// The menu one row offers. Built by ThreadView from the same rules as the long-press menu.
    struct Menu {
        var canForward: Bool
        var bottom: Bottom

        func allows(_ s: Slot) -> Bool {
            switch s {
            case .reply: return true
            case .forward: return canForward
            case .bottom: return bottom != .none
            }
        }
    }

    /// Numbers for the slot pick. A plain reply must stay a reply when the finger wobbles, hence the
    /// dead zone; the hysteresis stops a finger resting on a boundary from flickering between two.
    static let deadZone: CGFloat = 12
    static let slotStep: CGFloat = 44
    static let hysteresis: CGFloat = 6
    static let animation: TimeInterval = 0.3

    /// The slot for a vertical offset `dy` (points, down positive) from where the threshold was
    /// crossed, given the slot currently picked. Slots the menu does not allow are never returned.
    static func slot(for dy: CGFloat, current: Slot, menu: Menu) -> Slot {
        let mag = max(0, abs(dy) - deadZone)
        let pos = (dy < 0 ? -mag : mag) / slotStep            // in slot rows
        let nearest = Int(max(-1, min(1, pos.rounded())))
        guard nearest != current.rawValue else { return current }
        // Leave the current slot only once the boundary is passed by the hysteresis margin.
        let margin = 0.5 + hysteresis / slotStep
        guard abs(pos - CGFloat(current.rawValue)) > margin else { return current }
        guard let s = Slot(rawValue: nearest), menu.allows(s) else {
            // A dimmed slot is skipped: the pick falls back to Reply, never to "nothing".
            return .reply
        }
        return s
    }
}

/// The capsule drawn around the reply arrow. Three icons in a column, a filled circle behind the
/// picked one. Grows out of the arrow and shrinks back into it.
final class SwipeActionCapsule: UIView {
    static let width: CGFloat = 44
    static var height: CGFloat { MultiSwipe.slotStep * 3 }
    private static let circle: CGFloat = 36

    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    private let highlight = UIView()
    private var icons: [MultiSwipe.Slot: UIImageView] = [:]
    private(set) var selected: MultiSwipe.Slot = .reply
    private let menu: MultiSwipe.Menu

    init(menu: MultiSwipe.Menu) {
        self.menu = menu
        super.init(frame: CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
        isUserInteractionEnabled = false
        blur.frame = bounds
        blur.layer.cornerRadius = Self.width / 2
        blur.layer.cornerCurve = .continuous
        blur.clipsToBounds = true
        addSubview(blur)
        highlight.frame = CGRect(x: 0, y: 0, width: Self.circle, height: Self.circle)
        highlight.layer.cornerRadius = Self.circle / 2
        highlight.backgroundColor = .fariinAction
        addSubview(highlight)
        let names: [(MultiSwipe.Slot, String)] = [
            (.forward, "arrowshape.turn.up.right.fill"),
            (.reply, "arrowshape.turn.up.left.fill"),
            (.bottom, menu.bottom.icon),
        ]
        for (slot, name) in names {
            let v = UIImageView(image: UIImage(systemName: name,
                                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)))
            v.contentMode = .center
            v.frame = CGRect(x: 0, y: 0, width: Self.circle, height: Self.circle)
            v.center = center(of: slot)
            v.accessibilityLabel = Self.label(slot, menu: menu)
            addSubview(v)
            icons[slot] = v
        }
        highlight.center = center(of: .reply)
        paint()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func center(of slot: MultiSwipe.Slot) -> CGPoint {
        CGPoint(x: Self.width / 2, y: Self.height / 2 + CGFloat(slot.rawValue) * MultiSwipe.slotStep)
    }

    static func label(_ slot: MultiSwipe.Slot, menu: MultiSwipe.Menu) -> String {
        switch slot {
        case .forward: return "Forward"
        case .reply: return "Reply"
        case .bottom: return menu.bottom.title
        }
    }

    private func paint() {
        for (slot, v) in icons {
            if slot == selected {
                v.tintColor = .onFariinAction
                v.alpha = 1
            } else {
                v.tintColor = .label
                v.alpha = menu.allows(slot) ? 0.85 : 0.25   // dimmed: offered by nobody, does nothing
            }
        }
    }

    func select(_ slot: MultiSwipe.Slot, animated: Bool) {
        guard slot != selected else { return }
        selected = slot
        let move = { self.highlight.center = self.center(of: slot); self.paint() }
        if animated {
            UIView.animate(withDuration: MultiSwipe.animation, delay: 0,
                           usingSpringWithDamping: 0.85, initialSpringVelocity: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState], animations: move)
        } else {
            move()
        }
    }

    /// Open (grown out of the arrow) or folded back into it.
    func setOpen(_ open: Bool, animated: Bool) {
        let apply = {
            self.alpha = open ? 1 : 0
            self.transform = open ? .identity : CGAffineTransform(scaleX: 0.5, y: 0.3)
        }
        if animated {
            UIView.animate(withDuration: MultiSwipe.animation, delay: 0,
                           usingSpringWithDamping: 0.82, initialSpringVelocity: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState], animations: apply)
        } else {
            apply()
        }
    }
}
