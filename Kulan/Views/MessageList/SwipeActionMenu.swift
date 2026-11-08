import UIKit

// ⛔ MULTI-ACTION SWIPE (owner 2026-11-08). The reply swipe, extended: past the reply threshold a
// vertical capsule of TWO slots grows UPWARD out of the reply arrow. Reply is the bottom slot and
// the default; the slot above it is the person's own pick in Settings > Chats > Swipe Actions:
// Copy (default), Forward, Share or Quote. Reply sits below so a plain swipe, or a finger that
// drifts down, always replies; only a deliberate slide UP picks the other action (owner: "if Reply
// is first and the other below, people slide down by mistake").
//
// The top slot falls back by kind when the pick does not apply to a message (ThreadView
// `multiSwipeTop`): Copy on a photo, video or album is Save, on a document Save to Files; Forward,
// Share or Quote where they are not possible fall back the same way. When nothing applies (voice
// notes, polls, stickers...) the slot is dimmed and cannot be picked.
//
// The list does the gesture (`handleSwipePan`); this file only holds the rules and the drawing, so
// the pan keeps one shape for both paths.
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
    static let choiceKey = "swipeActions.top"

    /// What the person picked for the top slot in Settings.
    enum Choice: String, CaseIterable, Identifiable {
        case copy, forward, share, quote
        var id: String { rawValue }
        var title: String {
            switch self {
            case .copy: return "Copy"
            case .forward: return "Forward"
            case .share: return "Share"
            case .quote: return "Quote"
            }
        }
        static var current: Choice {
            UserDefaults.standard.string(forKey: choiceKey).flatMap(Choice.init(rawValue:)) ?? .copy
        }
    }

    /// What the finger is resting on. `rawValue` is the slot's row: -1 top, 0 the reply circle.
    enum Slot: Int { case top = -1, reply = 0 }

    /// The top slot for one message, after the fallbacks.
    enum Top: Equatable {
        case none
        case copy
        case save(count: Int)   // a single photo or video is 1; an album says "Save N Items"
        case saveToFiles
        case forward
        case share
        case quote

        var title: String {
            switch self {
            case .none: return ""
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
        var top: Top

        func allows(_ s: Slot) -> Bool {
            switch s {
            case .reply: return true
            case .top: return top != .none
            }
        }
    }

    /// Numbers for the slot pick. A plain reply must stay a reply when the finger wobbles, hence the
    /// dead zone; the hysteresis stops a finger resting on the boundary from flickering.
    static let deadZone: CGFloat = 12
    static let slotStep: CGFloat = 44
    static let hysteresis: CGFloat = 6
    static let animation: TimeInterval = 0.3

    /// The slot for a vertical offset `dy` (points, down positive) from where the threshold was
    /// crossed, given the slot currently picked. UPWARD ONLY: any downward movement stays on Reply.
    /// A slot the menu does not allow is never returned.
    static func slot(for dy: CGFloat, current: Slot, menu: Menu) -> Slot {
        guard menu.allows(.top) else { return .reply }
        let up = max(0, -dy - deadZone) / slotStep   // in slot rows, upward
        let margin = hysteresis / slotStep
        switch current {
        case .reply: return up > 0.5 + margin ? .top : .reply
        case .top: return up < 0.5 - margin ? .reply : .top
        }
    }
}

/// The capsule drawn above the reply arrow. Two icons in a column, a filled circle behind the
/// picked one. The reply circle sits on the arrow; the capsule grows upward out of it and shrinks
/// back into it (the layer's anchor is the reply circle, so `center` places that circle).
final class SwipeActionCapsule: UIView {
    static let width: CGFloat = 44
    static var height: CGFloat { MultiSwipe.slotStep * 2 }
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
        // The reply circle is the anchor: it stays on the arrow while the capsule scales open.
        layer.anchorPoint = CGPoint(x: 0.5, y: Self.replyY / Self.height)
        isUserInteractionEnabled = false
        blur.frame = bounds
        blur.cornerConfiguration = .capsule()
        addSubview(blur)
        highlight.frame = CGRect(x: 0, y: 0, width: Self.circle, height: Self.circle)
        highlight.layer.cornerRadius = Self.circle / 2
        highlight.backgroundColor = .fariinAction
        addSubview(highlight)
        let config = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        let topImage: UIImage? = menu.top.isAsset
            ? UIImage(named: menu.top.icon)?.withRenderingMode(.alwaysTemplate)
            : UIImage(systemName: menu.top.icon, withConfiguration: config)
        let images: [(MultiSwipe.Slot, UIImage?)] = [
            (.top, topImage),
            (.reply, UIImage(systemName: "arrowshape.turn.up.left.fill", withConfiguration: config)),
        ]
        for (slot, image) in images {
            let v = UIImageView(image: image)
            v.contentMode = slot == .top && menu.top.isAsset ? .scaleAspectFit : .center
            v.frame = slot == .top && menu.top.isAsset
                ? CGRect(x: 0, y: 0, width: 18, height: 18)
                : CGRect(x: 0, y: 0, width: Self.circle, height: Self.circle)
            v.center = center(of: slot)
            v.accessibilityLabel = Self.label(slot, menu: menu)
            addSubview(v)
            icons[slot] = v
        }
        highlight.center = center(of: .reply)
        paint()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The reply circle's height inside the capsule: the lower slot.
    private static var replyY: CGFloat { MultiSwipe.slotStep * 1.5 }

    private func center(of slot: MultiSwipe.Slot) -> CGPoint {
        CGPoint(x: Self.width / 2, y: Self.replyY + CGFloat(slot.rawValue) * MultiSwipe.slotStep)
    }

    static func label(_ slot: MultiSwipe.Slot, menu: MultiSwipe.Menu) -> String {
        switch slot {
        case .top: return menu.top.title
        case .reply: return "Reply"
        }
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

    /// Open (grown up out of the arrow) or folded back into it.
    func setOpen(_ open: Bool, animated: Bool) {
        let apply = {
            self.alpha = open ? 1 : 0
            self.transform = open ? .identity : CGAffineTransform(scaleX: 0.6, y: 0.3)
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
