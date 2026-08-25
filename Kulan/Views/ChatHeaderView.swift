import SwiftUI
import UIKit

// ⛔ THE CHAT HEADER IS UIKIT, PORTED LINE FOR LINE FROM THE REFERENCE APP — owner, 2026-08-25:
// "match [it] 100%, not 99%. If [the reference] uses UIKit for its top header, use UIKit for my top
// header as well. Do not keep using SwiftUI for the header just because my current implementation
// uses SwiftUI."
//
// Their `ConversationHeaderView` is a plain `UIView` holding two `UILabel`s and three nested
// `UIStackView`s, installed as `navigationItem.titleView`. This file is that view with their
// numbers, in their order, with their comments where they explain a number. What was here before —
// a SwiftUI `HStack` hosted in a `UIHostingController` and wrapped in a width-forcing container —
// produced a header that measured the same and behaved differently: it sized itself through the
// hosting controller's intrinsic size, its width came from a 10,000pt trick instead of the bar,
// and its light/dark answer came from SwiftUI's environment rather than from the glass it sits on.
//
// THEIR NUMBERS, STATED ONCE HERE:
//   title      17pt semibold, full-opacity label colour, truncating tail, hugs
//   subtitle   13pt medium,   truncating tail, hugs (colour: ours is secondary, see the label)
//   title icon 16 × 16 slot, hidden when nil (content mode: ours is centred, see makeIconView)
//   avatar     40pt on iOS 26 ("one size for the navigation bar on iOS 26")
//   root stack margins h 0 / v 4, leading 4 on iOS 26; spacing 12 on iOS 26; alignment centre
//   title row spacing 5, min height = title font line height rounded up
//   text rows  vertical, leading, fillProportionally
//   height     >= 44 on iOS 26
//   intrinsic  width .greatestFiniteMagnitude, height noIntrinsicMetric ("grow to fill the navbar")
//
// ⚠️ THE ONE DELIBERATE ADDITION: a second 16×16 slot in the title row for the disappearing-messages
// timer. Theirs puts the timer in the SUBTITLE (icon + duration) because their subtitle is a status
// row; ours carries presence text ("last seen…"), which he did not ask to lose, so the timer needs
// somewhere else to stand. Same size and spacing as their title icon, so it reads as one of them.
final class ChatHeaderView: UIView {

    var onTap: (() -> Void)?
    var onTapAvatar: (() -> Void)?

    /// Their `titleIcon`: setting nil hides the slot so the row closes up.
    var titleIcon: UIImage? {
        get { titleIconView.image }
        set {
            titleIconView.image = newValue
            titleIconView.isHidden = newValue == nil
        }
    }

    /// The addition described above, with the same hide-when-nil rule.
    var secondaryTitleIcon: UIImage? {
        get { secondaryIconView.image }
        set {
            secondaryIconView.image = newValue
            secondaryIconView.isHidden = newValue == nil
        }
    }

    let titleLabel: UILabel = {
        let label = UILabel()
        label.textColor = .label
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        label.setContentHuggingPriority(.defaultHigh, for: .vertical)
        return label
    }()

    let subtitleLabel: UILabel = {
        let label = UILabel()
        // Secondary, not their full-opacity label: owner, 2026-08-25, with the header on his phone.
        // The one place this port departs from their numbers on purpose; everything else about the
        // line (13 medium, its slot, its spacing) is theirs.
        label.textColor = .secondaryLabel
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        label.setContentHuggingPriority(.defaultHigh, for: .vertical)
        return label
    }()

    private static func makeIconView() -> UIImageView {
        let v = UIImageView()
        v.isHidden = true
        // `.center`, NOT `.scaleAspectFit`: owner, 2026-08-25, "the icons next to the name are too
        // large". Theirs are aspect-fit because their icons are 16pt assets that fill the slot by
        // design. Ours are SF Symbols configured at 13-14pt, and aspect-fit was scaling them UP to
        // the 16pt slot, which is why the timer read bigger here than it did in the SwiftUI header.
        // Centred, the glyph draws at the size it was configured with and the slot stays their 16.
        v.contentMode = .center
        v.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }
    private let titleIconView = ChatHeaderView.makeIconView()
    private let secondaryIconView = ChatHeaderView.makeIconView()

    /// "One size for the navigation bar on iOS 26." This app is iOS 26+, so the compact-height 24
    /// and the pre-26 36 they also carry have no branch to live in here.
    static let avatarSize: CGFloat = 40

    private(set) lazy var avatarView = HeaderAvatarView(size: Self.avatarSize)

    /// Kept so the glass-tracking handler can reach it; see init.
    private let textRows = UIStackView()
    /// What the model said the backdrop is. `.unspecified` means "not known": no wallpaper, so the
    /// glass probe below is allowed to decide. Anything else is a measured answer and the probe
    /// must not overwrite it — see `WallpaperBlur.headerBackdrop`.
    private var statedBackdrop: UIUserInterfaceStyle = .unspecified

    override init(frame: CGRect) {
        super.init(frame: frame)

        translatesAutoresizingMaskIntoConstraints = false

        let titleColumns = UIStackView(arrangedSubviews: [titleLabel, titleIconView, secondaryIconView])
        titleColumns.spacing = 5
        titleColumns.translatesAutoresizingMaskIntoConstraints = false
        // Theirs: "There is a strange bug where an initial height of 0 breaks the layout, so set an
        // initial height."
        titleColumns.heightAnchor.constraint(
            greaterThanOrEqualToConstant: titleLabel.font.lineHeight.rounded(.up)).isActive = true

        textRows.addArrangedSubview(titleColumns)
        textRows.addArrangedSubview(subtitleLabel)
        textRows.axis = .vertical
        textRows.alignment = .leading
        textRows.distribution = .fillProportionally

        let rootStack = UIStackView(arrangedSubviews: [avatarView, textRows])
        rootStack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)
        // Theirs: "Default iOS 26 spacing between round back button and this view's leading edge is
        // 12 pts. We want 16 pts between back button and profile picture."
        rootStack.directionalLayoutMargins.leading = 4
        rootStack.isLayoutMarginsRelativeArrangement = true
        rootStack.axis = .horizontal
        rootStack.alignment = .center
        // Theirs: "Larger profile picture on iOS 26 requires larger padding on both sides."
        rootStack.spacing = 12

        addSubview(rootStack)
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            titleIconView.heightAnchor.constraint(equalToConstant: 16),
            titleIconView.widthAnchor.constraint(equalTo: titleIconView.heightAnchor),
            secondaryIconView.heightAnchor.constraint(equalToConstant: 16),
            secondaryIconView.widthAnchor.constraint(equalTo: secondaryIconView.heightAnchor),

            rootStack.topAnchor.constraint(equalTo: topAnchor),
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Theirs, verbatim in intent: "Embed a small glass view behind the avatar so that it's never
        // visible to the user. Glass views react to content underneath and update appearance
        // (light / dark) automatically … attach a small handler that will force UILabels to have the
        // same light or dark style as the glass view." This is how the name stays readable over a
        // bright wallpaper without anyone choosing a colour for it.
        let glassTrackingView = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        rootStack.insertSubview(glassTrackingView, at: 0)
        glassTrackingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            glassTrackingView.widthAnchor.constraint(equalToConstant: 10),
            glassTrackingView.heightAnchor.constraint(equalToConstant: 10),
            glassTrackingView.centerXAnchor.constraint(equalTo: avatarView.centerXAnchor),
            glassTrackingView.centerYAnchor.constraint(equalTo: avatarView.centerYAnchor),
        ])
        glassTrackingView.contentView.registerForTraitChanges(
            [UITraitUserInterfaceStyle.self],
            handler: { [weak self] (view: UIView, _) in
                // The probe answers only when nothing measured has. On his phone it did not fire over
                // a black wallpaper at all; where a wallpaper exists the model carries a measured
                // answer, and this is the fallback for a chat drawn on the plain theme background.
                guard let self, self.statedBackdrop == .unspecified else { return }
                self.textRows.overrideUserInterfaceStyle = view.traitCollection.userInterfaceStyle
            }
        )

        heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        rootStack.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(didTapView)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Configure

    func configure(_ model: ChatHeaderModel) {
        titleLabel.text = model.name
        subtitleLabel.text = model.subtitle
        subtitleLabel.isHidden = model.subtitle == nil
        // Typing is the one state that colours the line; everything else is their full-opacity label.
        // `.tintColor` is UIKit's `Color.accentColor`, which is what the SwiftUI line used for typing.
        subtitleLabel.textColor = model.subtitleIsLive ? .tintColor : .secondaryLabel
        titleIcon = model.titleIcon
        secondaryTitleIcon = model.secondaryIcon
        // The measured answer wins; `.unspecified` hands the decision back to the glass probe.
        statedBackdrop = model.backdrop
        if model.backdrop != .unspecified { textRows.overrideUserInterfaceStyle = model.backdrop }
        // The timer glyph is a template so it re-resolves through `textRows`' style like the labels
        // do; a pre-tinted image would keep light-mode grey over a black wallpaper.
        secondaryIconView.tintColor = .secondaryLabel
        avatarView.configure(name: model.name, photoUrl: model.photoUrl, asset: model.avatarAsset)
        accessibilityLabel = model.name
    }

    // Theirs: "Grow to fill as much of the navbar as possible."
    override var intrinsicContentSize: CGSize {
        CGSize(width: .greatestFiniteMagnitude, height: UIView.noIntrinsicMetric)
    }

    // MARK: Tap

    /// Theirs splits the tap by whether it landed on the avatar, and so does this.
    @objc private func didTapView(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .recognized else { return }
        if avatarView.bounds.contains(gesture.location(in: avatarView)) {
            (onTapAvatar ?? onTap)?()
        } else {
            onTap?()
        }
    }
}

/// What the header shows. Built by the screen, handed to the bridge, applied by `configure`.
struct ChatHeaderModel: Equatable {
    var name: String
    var photoUrl: String?
    /// A bundled image instead of a photo (the official channel's mark). Wins over `photoUrl`.
    var avatarAsset: UIImage?
    var subtitle: String?
    /// True while the line is "typing…", which is the one state drawn in the accent.
    var subtitleIsLive = false
    /// Their `titleIcon` slot: the verified mark, when there is one.
    var titleIcon: UIImage?
    /// The disappearing-messages timer. See the file comment for why it is a second slot.
    var secondaryIcon: UIImage?
    /// The interface style the text needs over the wallpaper under the bar, or `.unspecified` to let
    /// the header's own glass probe decide. From `WallpaperBlur.headerBackdrop`.
    var backdrop: UIUserInterfaceStyle = .unspecified

    /// The verified mark drawn the way `VerifiedMark` draws it in SwiftUI — a palette seal, white
    /// tick on the brand blue — so the UIKit header and every SwiftUI badge in the app agree.
    static func verifiedMark() -> UIImage? {
        let config = UIImage.SymbolConfiguration(paletteColors: [.white, UIColor(Color(hex: 0x3DA1FD))])
            .applying(UIImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        return UIImage(systemName: "checkmark.seal.fill", withConfiguration: config)?
            .withRenderingMode(.alwaysOriginal)
    }

    /// The official channel's tick, as `VerifiedTick` draws it (system blue, semibold).
    static func officialTick() -> UIImage? {
        let config = UIImage.SymbolConfiguration(paletteColors: [.white, UIColor(Color(hex: 0x0A84FF))])
            .applying(UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        return UIImage(systemName: "checkmark.seal.fill", withConfiguration: config)?
            .withRenderingMode(.alwaysOriginal)
    }

    /// The timer, as the old SwiftUI header drew it: 13pt semibold. A TEMPLATE, tinted by the image
    /// view, so it follows the header's light/dark decision instead of freezing one appearance in.
    static func disappearingTimer() -> UIImage? {
        let config = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        return UIImage(systemName: "timer", withConfiguration: config)?
            .withRenderingMode(.alwaysTemplate)
    }

    static func == (a: ChatHeaderModel, b: ChatHeaderModel) -> Bool {
        a.name == b.name && a.photoUrl == b.photoUrl && a.subtitle == b.subtitle
            && a.subtitleIsLive == b.subtitleIsLive && a.backdrop == b.backdrop
            && (a.titleIcon == nil) == (b.titleIcon == nil)
            && (a.secondaryIcon == nil) == (b.secondaryIcon == nil)
            && (a.avatarAsset == nil) == (b.avatarAsset == nil)
    }
}

/// The header's avatar as a UIKit view: their `ConversationAvatarView` stood in for by the same
/// circle `AvatarView` draws in SwiftUI — cached photo when there is one, the name's gradient and
/// initial when there is not — so a person's avatar is the same picture in the header as in the list.
///
/// Loading follows `AvatarView` exactly: memory/disk seed synchronously for the first frame (the
/// letter-flash fix), then the async cache, then the network, stored on the way back.
final class HeaderAvatarView: UIView {
    private let size: CGFloat
    private let imageView = UIImageView()
    private let gradient = CAGradientLayer()
    private let initialLabel = UILabel()
    private var loadedFor: String?
    private var loadTask: Task<Void, Never>?

    init(size: CGFloat) {
        self.size = size
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
        ])
        layer.cornerRadius = size / 2
        layer.masksToBounds = true

        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        layer.addSublayer(gradient)

        initialLabel.textColor = .white
        initialLabel.font = .systemFont(ofSize: size * 0.42, weight: .bold)
        initialLabel.textAlignment = .center
        addSubview(initialLabel)

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
        initialLabel.frame = bounds
        imageView.frame = bounds
    }

    func configure(name: String, photoUrl: String?, asset: UIImage?) {
        let colors = AvatarPalette.gradient(for: name).map { UIColor($0).cgColor }
        gradient.colors = colors
        let first = name.trimmingCharacters(in: .whitespaces).first
        initialLabel.text = first.map { String($0).uppercased() } ?? "?"

        if let asset {
            loadTask?.cancel(); loadTask = nil; loadedFor = nil
            imageView.image = asset
            imageView.isHidden = false
            return
        }
        guard let url = photoUrl, !url.isEmpty else {
            loadTask?.cancel(); loadTask = nil; loadedFor = nil
            imageView.image = nil
            imageView.isHidden = true
            return
        }
        guard url != loadedFor else { return }
        loadedFor = url
        // First frame: memory, then disk, synchronously — the same seed AvatarView.init takes.
        if let warm = DiskImageCache.shared.smallImageSync(url) {
            imageView.image = warm
            imageView.isHidden = false
            return
        }
        imageView.image = nil
        imageView.isHidden = true
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            var found: UIImage?
            if let cached = await DiskImageCache.shared.image(for: url) {
                found = cached
            } else if let real = URL(string: url),
                      let (data, _) = try? await MediaSession.shared.data(from: real),
                      let ui = UIImage(data: data) {
                DiskImageCache.shared.store(ui, data: data, for: url)
                found = ui
            }
            guard !Task.isCancelled, let self, self.loadedFor == url, let found else { return }
            self.imageView.image = found
            self.imageView.alpha = 0
            self.imageView.isHidden = false
            UIView.animate(withDuration: 0.25) { self.imageView.alpha = 1 }   // AvatarView's cross-fade
        }
    }
}
