import UIKit

// A panel that IS a keyboard, rather than a view pretending to be one.
//
// This is the mechanism Signal uses, read from their source rather than guessed: the panel is a real
// `UIInputView` assigned to the composer's text view via `.inputView`, then `reloadInputViews()`.
// Everything that makes it feel right comes from that one decision:
//
//   • The slide up, the slide down, and the in-place swap between the system keyboard and this panel
//     are performed by UIKit. There is no animation code here and there must not be. Signal has none
//     either: their conversation screen never reads the keyboard's duration or curve anywhere. A
//     hand-animated panel would be trying to match a curve Apple does not publish.
//   • Interactive drag-to-dismiss works for free, because the chat already sets
//     `keyboardDismissMode = .interactive` and UIKit treats this as the keyboard.
//   • Nothing inside the panel can dismiss or resize it, because the height constraint lives out
//     here and the content is pinned inside `contentView`. Switching tabs is structurally safe.
//
// Deliberately knows NOTHING about stickers. It is a container with a keyboard's height and a
// keyboard's lifecycle; the content goes in `contentView`.
class ComposerKeyboardPanel: UIInputView {

    /// Put content here, pinned to all four edges. Never set a height on the content: the height
    /// belongs to this view, and is applied BEFORE it is installed as an inputView.
    let contentView = UIView()

    private lazy var heightConstraint = heightAnchor.constraint(equalToConstant: 0)

    init() {
        super.init(frame: .zero, inputViewStyle: .default)
        translatesAutoresizingMaskIntoConstraints = false
        // Self-sizing OFF by default. UIKit's own sizing is not a match for the system keyboard and
        // does not account for the predictive-text bar, so we drive the height ourselves and only
        // fall back to self-sizing when we have no number at all (see updateHeight).
        allowsSelfSizing = false
        addSubview(contentView)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        updateHeight()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Presentation lifecycle
    //
    // There is no "present" call to hook: the panel appears because it became someone's inputView.
    // Superview changes are the only signal, and the async hop is what lets `wasPresented` run after
    // the hierarchy has actually settled rather than mid-change.

    open func willPresent() {}
    open func wasPresented() {}
    open func willDismiss() {}
    open func wasDismissed() {}

    override func willMove(toSuperview newSuperview: UIView?) {
        super.willMove(toSuperview: newSuperview)
        if newSuperview == nil { willDismiss() } else { willPresent() }
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        let presented = superview != nil
        DispatchQueue.main.async { [weak self] in
            presented ? self?.wasPresented() : self?.wasDismissed()
        }
    }

    // MARK: Height

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        guard traitCollection.horizontalSizeClass != previous?.horizontalSizeClass
                || traitCollection.verticalSizeClass != previous?.verticalSizeClass else { return }
        updateHeight()
    }

    func updateHeight() {
        let key = SizeKey(traitCollection)
        // Measured beats estimated beats letting UIKit guess.
        guard let h = Self.measured[key] ?? key.estimate() else {
            heightConstraint.isActive = false
            allowsSelfSizing = true
            return
        }
        allowsSelfSizing = false
        heightConstraint.constant = h
        heightConstraint.isActive = true
    }

    // MARK: The keyboard height, measured once per size class

    private static var measured: [SizeKey: CGFloat] = [:]

    /// Record the real keyboard height for this size class.
    ///
    /// MUST be called while the SYSTEM keyboard is still up and the text view is still first
    /// responder — Signal takes it from `view.keyboardLayoutGuide.layoutFrame.height` at the moment
    /// of switching away, never from a notification, because a notification's frame includes states
    /// (undocked, floating, mid-dismissal) that produce nonsense.
    ///
    /// FIRST GOOD VALUE WINS. A later measurement can be taken mid-animation and be smaller; the
    /// panel jumping height on the second use is worse than being a point or two off.
    static func recordKeyboardHeight(_ height: CGFloat, for traits: UITraitCollection) {
        // Anything this short is not a keyboard: it is a dismissal in progress, or a hardware
        // keyboard leaving only the shortcut bar.
        guard height > 170 else { return }
        let key = SizeKey(traits)
        if measured[key] == nil { measured[key] = height }
    }

    /// Nothing is persisted between launches, deliberately: a stale height from an old OS or an old
    /// keyboard setting would be worse than the estimate below, which is at least self-consistent.
    private struct SizeKey: Hashable {
        let h: UIUserInterfaceSizeClass
        let v: UIUserInterfaceSizeClass
        let idiom: UIUserInterfaceIdiom
        let screen: CGSize

        init(_ t: UITraitCollection) {
            h = t.horizontalSizeClass
            v = t.verticalSizeClass
            idiom = t.userInterfaceIdiom
            screen = UIScreen.main.bounds.size
        }

        /// Cold start, before the keyboard has ever been seen this session. Without this the FIRST
        /// tap of a session opens a wrong-height panel and then snaps to the right one.
        func estimate() -> CGFloat? {
            switch idiom {
            case .phone:
                if v == .compact { return 208 }            // landscape
                let longest = max(screen.width, screen.height)
                if longest >= 900 { return 345 }           // Pro Max / Plus
                if longest >= 800 { return 335 }           // notched
                return 260                                 // SE and friends
            case .pad:
                return v == .compact ? 422 : 337
            default:
                return nil                                  // unknown → let UIKit self-size
            }
        }
    }
}
