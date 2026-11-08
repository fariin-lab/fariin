import UIKit

// ⛔ MULTI-ACTION SWIPE (owner 2026-11-08). The reply swipe, extended: past the reply threshold a
// vertical capsule of three slots grows around the reply arrow, as in build 1129. Reply is the
// middle slot and the default (it sits where the threshold was crossed); the slot above and the
// slot below are the person's own picks in Settings > Chats > Swipe Actions: "Slide Up For"
// (Forward by default) and "Slide Down For" (Copy by default), each one of Copy, Forward, Share,
// Quote or None. Owner: "make it work exactly like before, 3 slots, but the user can still control
// and change it."
//
// Each pick falls back by kind when it does not apply to a message (ThreadView `multiSwipeAction`):
// Copy on a photo, video or album is Save, on a document Save to Files; Forward, Share or Quote
// where they are not possible fall back the same way. When nothing applies (voice notes, polls,
// stickers...), or the pick is None, the slot is dimmed and cannot be picked. Both picks may be
// the same action; that is harmless.
//
// Moving the finger up or down while it stays down picks a slot, counted from where the threshold
// was crossed. The list does the gesture (`handleSwipePan`); this file only holds the rules and the
// drawing, so the pan keeps one shape for both paths.
//
// GATED: the Settings switch (off by default), and on top of it the @v / @kream uid list, like
// `CustomReaction.canChoose`. Everyone else gets the plain reply swipe, which takes the old code path
// untouched (`swipeMenu` stays nil).
enum MultiSwipe {
    /// @v, and @kream (owner 2026-11-08: "also show that feature to @kream").
    private static let uids: Set<String> = ["SVf0zxDVZzO8oLbGvM150QWgIWd2", "a74hUgOoNYOmxMDoNCWI4nO81xH3"]
    /// Whether this account may see the feature at all (the Settings rows show only then).
    @MainActor static var allowed: Bool { AuthService.shared.uid.map(uids.contains) ?? false }
    /// Whether the swipe runs: allowed AND switched on in Settings.
    @MainActor static var enabled: Bool { allowed && UserDefaults.standard.bool(forKey: onKey) }

    /// Account-scoped like the other chat prefs: wiped at sign-out (SessionWipe.wipeAccountPrefs).
    static let onKey = "swipeActions.on"
    static let upKey = "swipeActions.up"
    static let downKey = "swipeActions.down"

    /// What the person picked for one slot in Settings.
    enum Choice: String, CaseIterable, Identifiable {
        case copy, forward, share, quote, none
        var id: String { rawValue }
        var title: String {
            switch self {
            case .copy: return "Copy"
            case .forward: return "Forward"
            case .share: return "Share"
            case .quote: return "Quote"
            case .none: return "None"
            }
        }
        static let upDefault: Choice = .forward
        static let downDefault: Choice = .copy
        /// The pick for the slot above Reply.
        static var up: Choice { stored(upKey) ?? upDefault }
        /// The pick for the slot below Reply.
        static var down: Choice { stored(downKey) ?? downDefault }
        private static func stored(_ key: String) -> Choice? {
            UserDefaults.standard.string(forKey: key).flatMap(Choice.init(rawValue:))
        }
    }

    /// What the finger is resting on. `rawValue` is the slot's row: -1 top, 0 middle, 1 bottom.
    enum Slot: Int { case top = -1, reply = 0, bottom = 1 }

    /// One outer slot for one message, after the fallbacks.
    enum Action: Equatable {
        case none
        case copy
        case save(count: Int)   // a single photo or video is 1; an album says "Save N Items"
        case saveToFiles
        case forward
        case share
        case quote

        var title: String {
            switch self {
            case .none: return "Unavailable"
            case .copy: return "Copy"
            case .save(let n): return n > 1 ? "Save \(n) Items" : "Save"
            case .saveToFiles: return "Save to Files"
            case .forward: return "Forward"
            case .share: return "Share"
            case .quote: return "Quote"
            }
        }
        /// SF Symbol name, except Quote, which is the app's own asset (`isAsset`).
        var icon: String {
            switch self {
            case .none: return "nosign"
            case .copy: return "doc.on.doc"
            case .save: return "square.and.arrow.down"
            case .saveToFiles: return "folder"
            case .forward: return "arrowshape.turn.up.right.fill"
            case .share: return "square.and.arrow.up"
            case .quote: return "ic_quote"
            }
        }
        var isAsset: Bool { self == .quote }
    }

    /// The menu one row offers. Built by ThreadView from the same rules as the long-press menu.
    struct Menu {
        var top: Action
        var bottom: Action

        func action(_ s: Slot) -> Action? {
            switch s {
            case .reply: return nil
            case .top: return top
            case .bottom: return bottom
            }
        }

        func allows(_ s: Slot) -> Bool {
            switch s {
            case .reply: return true
            case .top: return top != .none
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

    /// Liquid glass (owner 2026-11-08: "make it liquid glass"), the composer's own material.
    private let blur = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let highlight = UIView()
    private var icons: [MultiSwipe.Slot: UIImageView] = [:]
    private(set) var selected: MultiSwipe.Slot = .reply
    private let menu: MultiSwipe.Menu

    init(menu: MultiSwipe.Menu) {
        self.menu = menu
        super.init(frame: CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
        isUserInteractionEnabled = false
        blur.frame = bounds
        blur.cornerConfiguration = .capsule()
        addSubview(blur)
        highlight.frame = CGRect(x: 0, y: 0, width: Self.circle, height: Self.circle)
        highlight.layer.cornerRadius = Self.circle / 2
        highlight.backgroundColor = .fariinAction
        addSubview(highlight)
        let config = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        for slot in [MultiSwipe.Slot.top, .reply, .bottom] {
            let action = menu.action(slot)
            let v: UIImageView
            if let action, action.isAsset {
                // The app's own icon (Quote): drawn at the symbols' size, tinted like them.
                v = UIImageView(image: UIImage(named: action.icon)?.withRenderingMode(.alwaysTemplate))
                v.contentMode = .scaleAspectFit
                v.frame = CGRect(x: 0, y: 0, width: 18, height: 18)
            } else {
                let name = action?.icon ?? "arrowshape.turn.up.left.fill"
                v = UIImageView(image: UIImage(systemName: name, withConfiguration: config))
                v.contentMode = .center
                v.frame = CGRect(x: 0, y: 0, width: Self.circle, height: Self.circle)
            }
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
        menu.action(slot)?.title ?? "Reply"
    }

    private func paint() {
        for (slot, v) in icons {
            if slot == selected {
                v.tintColor = .onFariinAction
                v.alpha = 1
            } else {
                v.tintColor = .label
                v.alpha = menu.allows(slot) ? 0.85 : 0.25   // dimmed: nothing applies, does nothing
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
