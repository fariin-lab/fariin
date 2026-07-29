import UIKit

// THE FLOATING REACTIONS BAR — Signal's, rebuilt in our code, sitting ABOVE the long-pressed message
// while Apple's native context menu keeps working underneath it, untouched.
//
// WHY IT IS BUILT THIS WAY (read 2026-07-29 from Signal-iOS):
//   MessageReactionPicker.swift        — the bar itself: every number below is theirs.
//   ContextMenuReactionBarAccessory.swift — how they place it relative to the message.
//
// Signal presents the bar as an ACCESSORY of their OWN context menu (they reimplemented Apple's menu
// in ContextMenuController). We deliberately do NOT do that — the user's requirement is to keep
// `UIContextMenuInteraction` exactly as it is, because matching Apple's menu behaviour by hand is a
// trap. So the bar lives in its own window ABOVE the system menu's own window, driven only by the two
// UIKit callbacks that tell us the menu appeared and is going away. Neither side controls the other:
// the menu does not know the bar exists, and the bar never touches the menu.
//
// Signal's exact geometry and motion, kept:
//   • bar height 56 (50 on a narrow phone), inner padding 6 → 44pt tap targets
//   • capsule glass on iOS 26+, else a solid card with the same two-shadow recipe
//   • present: background fades in; each button starts 24pt low and transparent and rises with a
//     0.01s stagger, easeIn, 0.2s
//   • dismiss: the whole bar fades out over the menu's own dismissal duration
//   • placement: ABOVE the bubble (exterior top), aligned to the bubble's OWN side — trailing for my
//     messages, leading for theirs — with a 12pt gap
final class ReactionBarView: UIView {
    private enum L {
        static var height: CGFloat { UIScreen.main.bounds.width <= 375 ? 50 : 56 }
        static let padding: CGFloat = 6
        static var button: CGFloat { height - padding * 2 }
        static var selectedDisc: CGFloat { height - 4 }
    }

    private let stack = UIStackView()
    private var background: UIView?
    private var buttons: [UIView] = []
    private let onPick: (String?) -> Void      // nil = the "more" button
    private let selected: String?

    /// - Parameters:
    ///   - emojis: the quick set, in order.
    ///   - selected: the emoji I already reacted with, drawn on a filled disc (tapping it removes).
    init(emojis: [String], selected: String?, onPick: @escaping (String?) -> Void) {
        self.onPick = onPick
        self.selected = selected
        super.init(frame: .zero)

        // Background: Signal uses real glass on iOS 26 and a shadowed card before it.
        if #available(iOS 26.0, *) {
            let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
            glass.cornerConfiguration = .capsule()
            addSubview(glass)
            glass.frame = bounds
            glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            background = glass
        } else {
            let card = UIView()
            card.backgroundColor = .secondarySystemGroupedBackground
            card.layer.cornerRadius = L.height / 2
            card.layer.cornerCurve = .continuous
            card.layer.shadowColor = UIColor.black.cgColor
            card.layer.shadowRadius = 12
            card.layer.shadowOpacity = 0.3
            card.layer.shadowOffset = CGSize(width: 0, height: 4)
            addSubview(card)
            card.frame = bounds
            card.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            background = card
        }

        stack.axis = .horizontal
        stack.alignment = .center
        stack.distribution = .fillEqually
        stack.spacing = 0
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: L.padding, left: L.padding,
                                           bottom: L.padding, right: L.padding)
        addSubview(stack)

        for e in emojis { buttons.append(makeEmojiButton(e)) }
        buttons.append(makeMoreButton())
        buttons.forEach { stack.addArrangedSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        stack.frame = bounds
    }

    /// The bar's natural size for a given emoji count — the caller positions with this.
    static func size(emojiCount: Int) -> CGSize {
        let cells = CGFloat(emojiCount + 1)   // + the "more" button
        return CGSize(width: cells * L.button + L.padding * 2, height: L.height)
    }

    private func makeEmojiButton(_ emoji: String) -> UIView {
        let holder = UIView()
        // The already-chosen reaction sits on a filled disc, exactly like Signal's selected state.
        if emoji == selected {
            let disc = UIView()
            disc.backgroundColor = .tintColor.withAlphaComponent(0.18)
            disc.layer.cornerRadius = L.selectedDisc / 2
            disc.isUserInteractionEnabled = false
            holder.addSubview(disc)
            disc.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                disc.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
                disc.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
                disc.widthAnchor.constraint(equalToConstant: L.selectedDisc),
                disc.heightAnchor.constraint(equalToConstant: L.selectedDisc),
            ])
        }
        let label = UILabel()
        label.text = emoji
        label.font = .systemFont(ofSize: L.button * 0.72)
        label.textAlignment = .center
        label.isUserInteractionEnabled = false
        holder.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
        ])
        let tap = UITapGestureRecognizer(target: self, action: #selector(tappedEmoji(_:)))
        holder.addGestureRecognizer(tap)
        holder.accessibilityLabel = emoji
        return holder
    }

    private func makeMoreButton() -> UIView {
        let holder = UIView()
        let disc = UIView()
        disc.backgroundColor = UIColor.label.withAlphaComponent(0.08)
        disc.layer.cornerRadius = L.button * 0.42
        disc.isUserInteractionEnabled = false
        let glyph = UIImageView(image: UIImage(systemName: "ellipsis"))
        glyph.tintColor = .label
        glyph.contentMode = .center
        disc.addSubview(glyph)
        holder.addSubview(disc)
        disc.translatesAutoresizingMaskIntoConstraints = false
        glyph.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            disc.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            disc.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            disc.widthAnchor.constraint(equalToConstant: L.button * 0.84),
            disc.heightAnchor.constraint(equalToConstant: L.button * 0.84),
            glyph.centerXAnchor.constraint(equalTo: disc.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: disc.centerYAnchor),
        ])
        holder.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tappedMore)))
        holder.accessibilityLabel = "More reactions"
        return holder
    }

    @objc private func tappedEmoji(_ g: UITapGestureRecognizer) {
        guard let e = g.view?.accessibilityLabel else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onPick(e)
    }
    @objc private func tappedMore() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onPick(nil)
    }

    // MARK: - Signal's animations, verbatim

    func playPresentation(duration: TimeInterval = 0.2) {
        background?.alpha = 0
        UIView.animate(withDuration: duration) { self.background?.alpha = 1 }
        var delay: TimeInterval = 0
        for v in buttons {
            v.alpha = 0
            v.transform = CGAffineTransform(translationX: 0, y: 24)
            UIView.animate(withDuration: duration, delay: delay, options: .curveEaseIn) {
                v.transform = .identity
                v.alpha = 1
            }
            delay += 0.01
        }
    }

    func playDismissal(duration: TimeInterval = 0.2, completion: @escaping () -> Void) {
        UIView.animate(withDuration: duration) {
            if #available(iOS 26.0, *) { (self.background as? UIVisualEffectView)?.effect = nil }
            self.alpha = 0
        } completion: { _ in completion() }
    }
}

/// Owns the window the bar floats in, so the bar can sit ABOVE the system context menu without ever
/// touching it. One instance per app; the list controller drives it from the two menu callbacks.
@MainActor
final class ReactionBarPresenter {
    static let shared = ReactionBarPresenter()

    private var window: UIWindow?
    private var bar: ReactionBarView?
    private var follow: CADisplayLink?
    private var anchor: (() -> CGRect?)?
    private weak var hostWindow: UIWindow?   // the list's window — excluded from both searches
    private var alignTrailing = true
    private var followUntil: CFTimeInterval = 0

    var isShowing: Bool { bar != nil }

    /// THE LIFTED MESSAGE, not the bubble in the list.
    ///
    /// When the system menu opens, UIKit takes the bubble out of the list, puts a copy in its own
    /// container window and MOVES it to make room for the menu. Positioning against the bubble's
    /// original frame is therefore wrong the moment UIKit shifts anything — which is exactly what the
    /// user saw: the bar drawn on top of the menu. Signal never hits this because they own their menu
    /// and shift the preview themselves (`previewWillShift`); keeping Apple's menu means we have to
    /// READ where it put the message instead.
    ///
    /// `_UIMorphingPlatterView` is the container UIKit lifts the preview into. Found by walking the
    /// windows the MENU can be in — no private API is called, only public view geometry is read — and
    /// every caller falls back to the bubble's own frame if the lookup ever fails.
    ///
    /// THIS SEARCH USED TO FREEZE THE APP ON EVERY LONG PRESS (user report on build 400: "when i long
    /// press all the screen is frozen"), and the reason is worth keeping written down.
    ///
    /// It walked EVERY visible window's ENTIRE view hierarchy, and called `NSStringFromClass` — which
    /// allocates a String — on every view it touched. The app's own window is the expensive one: the
    /// conversation is a collection view whose cells each host a SwiftUI tree, so a full walk visits
    /// many thousands of views and finds nothing, because the menu is never in that window. Then a
    /// display link repeated the whole thing at 60fps for 0.6s to follow the lift. Tens of thousands of
    /// String allocations and view visits per second, on the main thread, during the menu's own
    /// animation. Three things fix it, all of them about not doing pointless work:
    ///
    ///  1. SKIP THE HOST WINDOW. The context menu is presented in its own UIWindow — the same fact
    ///     `menuWindowDidHide` already relies on — so the one window that costs the most to search is
    ///     the one window that can never contain the answer.
    ///  2. Compare against a resolved class OBJECT, looked up once, instead of building a String per
    ///     view. `NSClassFromString` is a public lookup; nothing private is called on the result.
    ///  3. Cap the depth. The platter sits a handful of levels below its window; nothing legitimate is
    ///     thousands deep, so a cap turns a pathological walk into a bounded one.
    ///
    /// The result is also cached weakly: while a menu is open the platter view does not change, so
    /// following it costs one `convert` per tick instead of a search.
    private static let platterClass: AnyClass? = NSClassFromString("_UIMorphingPlatterView")
    private static weak var cachedPlatter: UIView?
    private static let maxSearchDepth = 12

    static func liftedPreviewFrame(excluding host: UIWindow? = nil) -> CGRect? {
        if let v = cachedPlatter, v.window != nil, v.bounds.width > 1, v.bounds.height > 1 {
            return v.convert(v.bounds, to: nil)
        }
        cachedPlatter = nil
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for w in scene.windows where !w.isHidden && w !== host {
                if let v = firstPlatter(in: w, depth: maxSearchDepth),
                   v.bounds.width > 1, v.bounds.height > 1 {
                    cachedPlatter = v
                    return v.convert(v.bounds, to: nil)
                }
            }
        }
        return nil
    }

    private static func firstPlatter(in root: UIView, depth: Int) -> UIView? {
        if let cls = platterClass {
            if root.isKind(of: cls) { return root }
        } else if NSStringFromClass(type(of: root)).contains("MorphingPlatterView") {
            return root   // name lookup failed (renamed in a future iOS) — fall back to the old test
        }
        guard depth > 0 else { return nil }
        for s in root.subviews {
            if let hit = firstPlatter(in: s, depth: depth - 1) { return hit }
        }
        return nil
    }

    /// Show the bar above `bubbleFrame` (window coordinates).
    /// - Parameters:
    ///   - alignTrailing: my messages align to the bubble's right edge, theirs to the left — Signal's
    ///     `horizontalEdgeAlignment`, which is what makes the bar feel attached to that bubble.
    /// - Parameter hostWindow: the window the message list lives in. Excluded from the platter search,
    ///   which is what keeps that search cheap — see liftedPreviewFrame.
    func show(in scene: UIWindowScene,
              hostWindow: UIWindow?,
              bubbleFrame: CGRect,
              alignTrailing: Bool,
              selected: String?,
              onPick: @escaping (String?) -> Void) {
        hide(animated: false)

        let emojis = Array(QuickReaction.choices.prefix(6))
        let bar = ReactionBarView(emojis: emojis, selected: selected, onPick: onPick)
        let size = ReactionBarView.size(emojiCount: emojis.count)

        // A PASSTHROUGH **WINDOW**, not merely a passthrough root view — and that distinction was the
        // frozen screen (user, twice: "when i long press all the screen is frozen… if i touch
        // everywhere is not working").
        //
        // `UIView.hitTest` returns SELF when the point is inside it and no subview claims it. A window
        // is a view whose bounds are the whole screen, so every touch outside the bar walked: window
        // (inside → yes) → root view (passthrough → nil) → no subview took it → **the window returned
        // itself**. The bar's window sits above everything at `.alert + 1`, so from that moment every
        // touch on the device was delivered to an empty transparent window and nothing underneath ever
        // saw it. The screen looked perfectly normal and was completely dead, for as long as the window
        // existed. Making the root view transparent to touches was never enough; the window has to
        // decline the touch too.
        let w = PassthroughWindow(windowScene: scene)
        w.windowLevel = .alert + 1          // above the menu's own window
        w.backgroundColor = .clear
        w.isHidden = false
        let root = PassthroughView()
        w.rootViewController = PassthroughController(content: root)

        bar.frame = CGRect(origin: .zero, size: size)
        root.addSubview(bar)
        self.window = w
        self.bar = bar
        self.hostWindow = hostWindow
        self.alignTrailing = alignTrailing
        // Follow the lifted message while UIKit animates it into place; fall back to the bubble's own
        // frame whenever the lifted copy cannot be found.
        self.anchor = { [weak hostWindow] in
            ReactionBarPresenter.liftedPreviewFrame(excluding: hostWindow) ?? bubbleFrame
        }
        reposition()
        bar.playPresentation()

        // The menu's open animation moves the preview over ~0.4s, so the bar tracks it for that long
        // rather than guessing a final position — "follows the selected message", as asked.
        followUntil = CACurrentMediaTime() + 0.6
        follow?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        follow = link
    }

    @objc private func step() {
        guard bar != nil else { follow?.invalidate(); follow = nil; return }
        reposition()
        if CACurrentMediaTime() > followUntil { follow?.invalidate(); follow = nil }
    }

    /// iMessage's stacking, top to bottom: REACTION BAR · the message · the menu.
    ///
    /// Above the lifted message is the goal, and it is what happens for an ordinary message: UIKit
    /// lifts the bubble and puts its menu underneath, leaving the space above free.
    ///
    /// IT CANNOT BE GUARANTEED FOR EVERY MESSAGE, and that is a property of Apple's menu, not a bug
    /// here. UIKit decides where to put its own menu and knows nothing about this bar, so on a very
    /// tall message the preview fills the screen, the menu is laid over the preview itself, and there
    /// is no free space above it to sit in. Signal never meets this because Signal does not use Apple's
    /// menu — its ContextMenuController owns the accessory, the preview and the menu together, and it
    /// SHRINKS the preview until all three fit. Keeping the native menu, which is the standing
    /// instruction, means the third piece is not ours to move.
    ///
    /// So the rule is: prefer above the message; if that would sit off-screen or ON the menu, go below
    /// the message; if that also collides, sit clear of the menu's nearest edge. Never overlap the menu.
    private func reposition() {
        guard let bar, let w = window, let rect = anchor?() else { return }
        let size = bar.bounds.size
        let bounds = w.bounds
        let safeTop = w.safeAreaInsets.top
        let menu = ReactionBarPresenter.menuFrame(excluding: hostWindow)

        func collides(_ y: CGFloat) -> Bool {
            guard let menu else { return false }
            return menu.intersects(CGRect(x: 0, y: y, width: bounds.width, height: size.height))
        }

        let above = rect.minY - size.height - 12
        let below = rect.maxY + 12
        var y = above
        if above < safeTop + 8 || collides(above) {
            y = below
            // Below is no good either — tuck against whichever side of the menu has room.
            if below + size.height > bounds.maxY - 20 || collides(below), let menu {
                let overMenu = menu.minY - size.height - 12
                y = overMenu >= safeTop + 8 ? overMenu : menu.maxY + 12
            }
        }
        y = max(safeTop + 8, min(y, bounds.maxY - size.height - 20))

        var x = alignTrailing ? rect.maxX - size.width : rect.minX
        x = max(12, min(x, bounds.width - size.width - 12))
        let frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        if bar.frame != frame { bar.frame = frame }
    }

    /// Where UIKit put the MENU (not the preview), so the bar can refuse to sit on it. Same bounded
    /// search as `liftedPreviewFrame`, looking for the menu's own container instead of the platter.
    private static weak var cachedMenu: UIView?

    static func menuFrame(excluding host: UIWindow? = nil) -> CGRect? {
        if let v = cachedMenu, v.window != nil, v.bounds.width > 1, v.bounds.height > 1 {
            return v.convert(v.bounds, to: nil)
        }
        cachedMenu = nil
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for w in scene.windows where !w.isHidden && w !== host {
                if let v = firstNamed(in: w, "ContextMenuListView", depth: maxSearchDepth),
                   v.bounds.width > 1, v.bounds.height > 1 {
                    cachedMenu = v
                    return v.convert(v.bounds, to: nil)
                }
            }
        }
        return nil
    }

    private static func firstNamed(in root: UIView, _ name: String, depth: Int) -> UIView? {
        if NSStringFromClass(type(of: root)).contains(name) { return root }
        guard depth > 0 else { return nil }
        for sub in root.subviews {
            if let hit = firstNamed(in: sub, name, depth: depth - 1) { return hit }
        }
        return nil
    }

    func hide(animated: Bool = true) {
        follow?.invalidate(); follow = nil
        anchor = nil
        guard let bar, animated else { tearDown(); return }
        bar.playDismissal { [weak self] in self?.tearDown() }
    }

    private func tearDown() {
        follow?.invalidate(); follow = nil
        anchor = nil
        hostWindow = nil
        bar?.removeFromSuperview()
        bar = nil
        window?.isHidden = true
        window = nil
        // The menu is gone with the bar; a cached view from it would be stale next time.
        Self.cachedMenu = nil
        Self.cachedPlatter = nil
    }

    /// A window that only claims touches its CONTENT wants. Without this the window itself answers the
    /// hit test for every touch that misses the bar — see the note in `show`.
    private final class PassthroughWindow: UIWindow {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            let hit = super.hitTest(point, with: event)
            // Landing on the window or on its empty root means nothing here wanted this touch, so
            // report a miss and let it reach whatever is underneath.
            if hit === self || hit === rootViewController?.view { return nil }
            return hit
        }
    }

    /// A view that is invisible to touches unless one of its subviews wants them.
    private final class PassthroughView: UIView {
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            subviews.contains { !$0.isHidden && $0.alpha > 0.01 && $0.frame.contains(point) }
        }
    }
    private final class PassthroughController: UIViewController {
        private let content: UIView
        init(content: UIView) { self.content = content; super.init(nibName: nil, bundle: nil) }
        required init?(coder: NSCoder) { fatalError() }
        override func loadView() { view = content }
    }
}
