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
    /// ⛔ THE CHAT'S BAR IS THE SHEET'S HANDLE — owner 2026-10-16, twice: a chat opened from a profile
    /// that is a sheet over a story. The sheet's own drag is OFF while the chat is up (ContactInfoView)
    /// so the message list scrolls; a touch that lands on this navigation bar switches it back ON for
    /// that one touch, so Apple's own sheet drag takes it: follows the finger, springs back or closes,
    /// exactly as on the profile. The first try moved the sheet by hand and did not follow the
    /// finger. Non-nil = enabled; every other chat's bar is untouched.
    ///
    /// ⚠️ 2026-10-16 second pass: the flag that matters is SwiftUI's `interactiveDismissDisabled`,
    /// which it answers through the presentation delegate; flipping UIKit's `isModalInPresentation`
    /// alone left the sheet rubber-banding a little and stopping. So this hands the answer to the
    /// sheet's owner: true = the bar is held, the sheet may close; false = locked again.
    var onPullDown: ((Bool) -> Void)? { didSet { attachSheetHandle() } }

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

    /// ⛔ SOLID, NOT `.secondaryLabel` — owner, 2026-09-27, a yellow wallpaper: "last seen" came out
    /// yellow. `.secondaryLabel` is a 60%-opaque colour, so over a wallpaper the picture shows through
    /// the letters and the line takes its hue, while the fully opaque name beside it stays white. The
    /// same dimmer grey he asked for in August, made opaque: nothing behind it can tint it. Resolves
    /// through `textRows`' light/dark like the labels, so it follows the backdrop decision.
    static let subtitleColor = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.82, alpha: 1) : UIColor(white: 0.32, alpha: 1)
    }

    /// A group's member count: soft black / soft white, between the grey and the name (owner
    /// 2026-10-26: "not too white or too black, not the same as the name"). Solid for the same reason.
    static let subtitleStrongColor = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.9, alpha: 1) : UIColor(white: 0.18, alpha: 1)
    }

    let subtitleLabel: UILabel = {
        let label = UILabel()
        // Secondary, not their full-opacity label: owner, 2026-08-25, with the header on his phone.
        // The one place this port departs from their numbers on purpose; everything else about the
        // line (13 medium, its slot, its spacing) is theirs.
        label.textColor = ChatHeaderView.subtitleColor
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
    /// A group's first faces in front of "N members" (owner 2026-10-26, as on the group page).
    private let facesView = HeaderFacesView()
    private lazy var subtitleRow: UIStackView = {
        let row = UIStackView(arrangedSubviews: [facesView, subtitleLabel])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 5
        return row
    }()
    /// True once the glass probe (see init) has resolved a light/dark style. Until then `configure`
    /// seeds the measured answer from `WallpaperBlur.headerBackdrop` so the first frame reads
    /// right; from then on the probe alone decides, as in the reference app.
    private var probeHasDecided = false
    /// The measured seed from the last `configure`, re-applied when the app's appearance flips.
    private var lastBackdrop: UIUserInterfaceStyle = .unspecified

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
        textRows.addArrangedSubview(subtitleRow)
        textRows.axis = .vertical
        textRows.alignment = .leading
        // ⛔ `.fill`, NOT `.fillProportionally` — owner, 2026-08-26: "name and subtitle has bug
        // sometimes losing space".
        //
        // `.fillProportionally` divides the stack's height between its arranged views IN PROPORTION
        // to their intrinsic heights, and it always consumes exactly the height it is given. So the
        // name and the "last seen" line were not sized by their own text at all — they were sized by
        // whatever height the navigation bar handed the title view at that moment, which is not a
        // constant (it changes with the bar's state and between pushes). When that height came up
        // short the two labels were squeezed together, and the title row's
        // `heightAnchor >= lineHeight` floor meant the SUBTITLE gave up the space first: exactly the
        // cramped pair in his screenshot, and exactly why it was intermittent.
        //
        // `.fill` gives each label its own intrinsic height and lets the stack be their sum, so the
        // pair looks the same whatever the bar does.
        textRows.distribution = .fill

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

            // ⛔ CENTRED AT ITS OWN HEIGHT, NOT PINNED TO THE BAR'S — owner, 2026-09-28, the
            // official chat's header: "sometimes the space between the name and last seen is lost".
            // The second report (08-26 fixed the stack's distribution). The row was pinned top and
            // bottom to this view, whose height is whatever the navigation bar hands the title view
            // at that moment; less its 4 + 4 margins that left 36pt for a name line (21) and a
            // subtitle line (15.5) that need 36.5, beside a 40pt avatar, and less still whenever the
            // bar offered under 44. The title row's height floor is required, so the SUBTITLE was
            // the one squeezed, drawn up into the name. Centred and unpinned vertically, the row
            // takes its natural height every time and the two lines keep their spacing; any excess
            // over the bar's height spills evenly above and below, which nothing clips.
            rootStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        subtitleLabel.setContentCompressionResistancePriority(.required, for: .vertical)

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
                // ⛔ THE PROBE IS THE DECIDER, as in the reference app: whatever light/dark the glass
                // resolves from what lies under the bar, the labels take, every time it fires.
                // Until 2026-09-24 this handler yielded to the measured answer in `configure`,
                // because on 2026-08-25 the probe did not fire over a black wallpaper. The reference
                // app relies on the probe alone, so it decides here too, now that the bar is the
                // bare system glass with the message list registered under it (see
                // `ChatNavigationItem` and `MessageListController.registerAsContentScrollView`).
                // `configure` still seeds the measured answer before the first resolution, so the
                // name is readable on the first frame and stays so if the probe never speaks.
                guard let self else { return }
                self.probeHasDecided = true
                // ⛔ ONLY WITH NO WALLPAPER — owner, 2026-09-29: dark name and "online" on a dark
                // wallpaper after switching light/dark or picking a photo wallpaper. Over a
                // wallpaper the probe kept its old answer (or read the glass wrong) and overrode the
                // measured one for good. With a wallpaper the measured backdrop decides (`configure`).
                guard self.lastBackdrop == .unspecified else { return }
                self.textRows.overrideUserInterfaceStyle = view.traitCollection.userInterfaceStyle
            }
        )

        // ⛔ THE APP'S OWN LIGHT ↔ DARK STARTS THE DECISION AGAIN — owner, 2026-09-29, a chat in
        // dark mode after switching from light: "last seen" drawn in light-mode grey on the dark
        // wallpaper. The probe's answer from before the switch outlived it, and `configure` had
        // stopped seeding once the probe spoke. The switch re-draws the wallpaper in its other
        // palette, so the old answer is about a picture that is gone: forget it, take the fresh
        // measured seed from the next `configure`, and let the probe decide again when it fires.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: ChatHeaderView, _) in
            self.probeHasDecided = false
            self.textRows.overrideUserInterfaceStyle = self.lastBackdrop
        }

        heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        rootStack.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(didTapView)))
    }


    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Configure

    func configure(_ model: ChatHeaderModel) {
        titleLabel.text = model.name
        subtitleLabel.text = model.subtitle
        subtitleLabel.isHidden = model.subtitle == nil
        subtitleRow.isHidden = model.subtitle == nil
        // Not over "typing…": the faces belong to the member count.
        facesView.set(model.subtitleIsLive ? [] : model.subtitleFaces)
        // Typing is the one state that colours the line; everything else is their full-opacity label.
        // `.tintColor` is UIKit's `Color.accentColor`, which is what the SwiftUI line used for typing.
        subtitleLabel.textColor = model.subtitleIsLive ? .tintColor : model.subtitleIsStrong ? Self.subtitleStrongColor : Self.subtitleColor
        titleIcon = model.titleIcon
        secondaryTitleIcon = model.secondaryIcon
        // The measured answer is only the SEED for the first frame; once the glass probe has
        // resolved (see init) it alone decides, and this line stops writing. `.unspecified` means
        // no wallpaper, so the app's own appearance stands until the probe says otherwise.
        // The wallpaper just went away: the old forced style must not outlive it.
        if model.backdrop == .unspecified, lastBackdrop != .unspecified { probeHasDecided = false }
        lastBackdrop = model.backdrop
        // With a wallpaper, the measured backdrop is the answer every time it arrives: it is
        // re-measured whenever the wallpaper or the appearance changes (`WallpaperBlur.headerBackdrop`
        // keys on both), so the name and subtitle follow a switch or a new photo live (2026-09-29).
        if model.backdrop != .unspecified {
            textRows.overrideUserInterfaceStyle = model.backdrop
        } else if !probeHasDecided {
            // `.unspecified` (no wallpaper) hands the labels back to the app's own appearance,
            // which after a light ↔ dark switch is the one thing they must follow.
            textRows.overrideUserInterfaceStyle = model.backdrop
        }
        // The timer glyph is a template so it re-resolves through `textRows`' style like the labels
        // do; a pre-tinted image would keep light-mode grey over a black wallpaper.
        secondaryIconView.tintColor = Self.subtitleColor
        avatarView.setSquircle(model.squircle)
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
    /// A channel: the avatar is a squircle (2026-10-29).
    var squircle = false
    var subtitle: String?
    /// True while the line is "typing…", which is the one state drawn in the accent.
    var subtitleIsLive = false
    /// Drawn in `subtitleStrongColor`, not the dimmer grey: a group's member count (owner 2026-10-26).
    var subtitleIsStrong = false
    /// Their `titleIcon` slot: the verified mark, when there is one.
    var titleIcon: UIImage?
    /// The disappearing-messages timer. See the file comment for why it is a second slot.
    var secondaryIcon: UIImage?
    /// A group's first member photos (up to three), drawn overlapping before the subtitle.
    var subtitleFaces: [String] = []
    /// The measured interface style of the wallpaper band under the bar, from
    /// `WallpaperBlur.headerBackdrop`, or `.unspecified` when there is no wallpaper. The header uses
    /// it only to seed the first frame; its own glass probe decides from then on.
    var backdrop: UIUserInterfaceStyle = .unspecified

    /// The verified mark drawn the way `VerifiedMark` draws it in SwiftUI — a palette seal, white
    /// tick on the brand blue — so the UIKit header and every SwiftUI badge in the app agree.
    static func verifiedMark(color: UIColor = VerifiedMark.blue) -> UIImage? {
        // One badge for everybody (`VerifiedMark.blue/scale/weight`, owner 2026-10-13); gold for a company.
        VerifiedMark.badge(size: 15 * VerifiedMark.scale, blue: color, weight: VerifiedMark.weight)
    }

    /// ⛔ A PLAIN BITMAP, NOT A SYMBOL — owner, 2026-09-27: "the verify badge in the chat header
    /// looks black, make it always blue". A symbol image inside the iOS 26 bar is re-rendered by
    /// the bar as a one-colour glyph (black in light mode, white in dark), palette or not. Drawn
    /// once into a bitmap there is no symbol left for the bar to treat, so it stays blue.
    private static func flat(_ symbol: UIImage?) -> UIImage? {
        guard let symbol else { return nil }
        let fmt = UIGraphicsImageRendererFormat.preferred()
        fmt.opaque = false
        return UIGraphicsImageRenderer(size: symbol.size, format: fmt)
            .image { _ in symbol.draw(at: .zero) }
            .withRenderingMode(.alwaysOriginal)
    }

    /// The official channel's tick: the SAME badge as everybody's since 2026-10-13 (owner: two sizes
    /// and two blues side by side). Kept as its own name so the call sites read as they did.
    static func officialTick() -> UIImage? {
        guard let color = OfficialConfig.shared.badge.color else { return nil }   // the owner's choice
        return verifiedMark(color: color)
    }

    /// 2026-10-18 group moderation: the mark beside a group Fariin labelled Scam or Fake. A red
    /// warning triangle, flattened like the badge so the bar cannot recolour it.
    static func warningMark() -> UIImage? {
        let config = UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)
            .applying(UIImage.SymbolConfiguration(paletteColors: [.white, .systemRed]))
        return flat(UIImage(systemName: "exclamationmark.triangle.fill", withConfiguration: config))
    }

    /// The timer, as the old SwiftUI header drew it: 13pt semibold. A TEMPLATE, tinted by the image
    /// view, so it follows the header's light/dark decision instead of freezing one appearance in.
    static func disappearingTimer() -> UIImage? {
        let config = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        return UIImage(systemName: "timer", withConfiguration: config)?
            .withRenderingMode(.alwaysTemplate)
    }

    static func == (a: ChatHeaderModel, b: ChatHeaderModel) -> Bool {
        a.name == b.name && a.photoUrl == b.photoUrl && a.subtitle == b.subtitle && a.squircle == b.squircle
            && a.subtitleIsLive == b.subtitleIsLive && a.subtitleIsStrong == b.subtitleIsStrong && a.backdrop == b.backdrop
            && (a.titleIcon == nil) == (b.titleIcon == nil)
            && (a.secondaryIcon == nil) == (b.secondaryIcon == nil)
            && (a.avatarAsset == nil) == (b.avatarAsset == nil)
            && a.subtitleFaces == b.subtitleFaces
    }
}

/// Up to three small round photos, each overlapping the one before by a third, the group page's
/// faces beside its member count. Photos come from the app's image cache; a face that has not
/// loaded yet is a grey circle until it does.
final class HeaderFacesView: UIView {
    private static let side: CGFloat = 18
    private static let step: CGFloat = 12
    private var views: [UIImageView] = []
    private var urls: [String] = []
    private var width: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        width = widthAnchor.constraint(equalToConstant: 0)
        width.isActive = true
        heightAnchor.constraint(equalToConstant: Self.side).isActive = true
        isHidden = true
        isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ new: [String]) {
        let list = Array(new.prefix(3))
        guard list != urls else { return }
        urls = list
        views.forEach { $0.removeFromSuperview() }
        views = []
        isHidden = list.isEmpty
        width.constant = list.isEmpty ? 0 : Self.side + Self.step * CGFloat(list.count - 1)
        for (i, url) in list.enumerated() {
            let v = UIImageView(frame: CGRect(x: Self.step * CGFloat(i), y: 0, width: Self.side, height: Self.side))
            v.contentMode = .scaleAspectFill
            v.clipsToBounds = true
            v.layer.cornerRadius = Self.side / 2
            v.layer.borderWidth = 1
            v.layer.borderColor = UIColor.systemBackground.withAlphaComponent(0.8).cgColor
            v.backgroundColor = .systemGray4
            // The first face on top, as on the group page.
            insertSubview(v, at: 0)
            views.append(v)
            if let img = DiskImageCache.shared.memoryImage(url) {
                v.image = img
            } else {
                Task { [weak self, weak v] in
                    let img = await DiskImageCache.shared.image(for: url)
                    await MainActor.run {
                        guard let self, let v, self.urls.contains(url) else { return }
                        v.image = img
                    }
                }
            }
        }
    }
}

/// The header's avatar as a UIKit view: their `ConversationAvatarView` stood in for by the same
/// circle `AvatarView` draws in SwiftUI — cached photo when there is one, `AvatarPalette`'s shared
/// silhouette when there is not — so a person's avatar is the same picture in the header as in the list.
///
/// Loading follows `AvatarView` exactly: memory/disk seed synchronously for the first frame (the
/// letter-flash fix), then the async cache, then the network, stored on the way back.
final class HeaderAvatarView: UIView {
    private let size: CGFloat
    private let imageView = UIImageView()
    // ⛔ ONE SILHOUETTE, NOT A COLOURED LETTER — owner, 2026-09-16, "make one type". The gradient
    // layer and the initial label are gone; the fill and the glyph both come from `AvatarPalette`,
    // which is the only place that decides how a faceless account looks.
    private var loadedFor: String?
    private var loadTask: Task<Void, Never>?
    /// The last URL that failed and when, so a retry waits a few seconds instead of firing on
    /// every header update while offline.
    private var failed: (url: String, at: Date)?

    init(size: CGFloat) {
        self.size = size
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
        ])
        // ⛔ NO FILL, NO CLIP, NO GLYPH VIEW — owner, 2026-09-27, the two grey lines beside the
        // silhouette a FOURTH time, "only on the message list page", i.e. only inside this bar.
        // Flattening the glyph (09-26) left three composited things: a translucent fill, a corner
        // clip and an image view, and the iOS 26 bar treats the edges of what it composites. The
        // no-photo state is now ONE pre-drawn disc (fill + silhouette, the same picture
        // `AvatarView` draws) set as this view's own layer contents. The photo keeps its own round
        // image view, which never shows the placeholder.
        backgroundColor = .clear
        layer.contentsGravity = .resizeAspectFill
        applyPlaceholder()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (v: HeaderAvatarView, _) in
            v.applyPlaceholder()
        }

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = size / 2
        addSubview(imageView)
    }

    /// A channel's photo is a squircle (owner 2026-10-29, `AvatarShape`): the photo's corner and the
    /// pre-drawn placeholder both change; still one picture as layer contents, no fill or clip view.
    private var squircle = false

    func setSquircle(_ on: Bool) {
        guard on != squircle else { return }
        squircle = on
        imageView.layer.cornerCurve = on ? .continuous : .circular
        imageView.layer.cornerRadius = on ? size * AvatarShape.cornerFraction : size / 2
        applyPlaceholder()
    }

    private func applyPlaceholder() {
        let dark = traitCollection.userInterfaceStyle == .dark
        if squircle {
            let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
            let fill = AvatarPalette.placeholderFillUI.resolvedColor(with: traits)
            let box = CGRect(x: 0, y: 0, width: size, height: size)
            layer.contents = UIGraphicsImageRenderer(size: box.size).image { _ in
                fill.setFill()
                UIBezierPath(roundedRect: box, cornerRadius: size * AvatarShape.cornerFraction).fill()
            }.cgImage
            layer.contentsScale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
            return
        }
        layer.contents = AvatarPalette.placeholderDisc(size: size, dark: dark)?.cgImage
        layer.contentsScale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
    }

    func configure(name: String, photoUrl: String?, asset: UIImage?) {
        // The fallback no longer depends on the name; it is the same silhouette for everyone. The
        // name is still taken for the accessibility label.
        accessibilityLabel = name

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
        if let f = failed, f.url == url, Date().timeIntervalSince(f.at) < 5 { return }
        loadedFor = url
        // First frame: memory, then disk, synchronously — through `ProfilePhotoLoader`, the one
        // avatar pipeline (2026-09-25), which also shares the download with every other screen.
        if let warm = ProfilePhotoLoader.shared.cachedAvatar(url) {
            imageView.image = warm
            imageView.isHidden = false
            failed = nil
            return
        }
        imageView.image = nil
        imageView.isHidden = true
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let found = await ProfilePhotoLoader.shared.avatar(url)
            guard !Task.isCancelled, let self, self.loadedFor == url else { return }
            // ⛔ A FAILED LOAD FORGETS ITS URL — 2026-09-25. `loadedFor` was set before the download
            // and kept after a failure, so `guard url != loadedFor` turned every later configure into
            // a no-op: one dropped request meant the placeholder for the life of the screen. Cleared,
            // the next header update (frequent: presence, typing) asks again, at most every 5s.
            guard let found else { self.loadedFor = nil; self.failed = (url, Date()); return }
            self.failed = nil
            self.imageView.image = found
            self.imageView.alpha = 0
            self.imageView.isHidden = false
            UIView.animate(withDuration: 0.25) { self.imageView.alpha = 1 }   // AvatarView's cross-fade
        }
    }
}

extension ChatHeaderView {
    /// The presented controller this chat sits in (the sheet), found from the bar up.
    fileprivate var sheetController: UIViewController? {
        var vc = owningViewController
        while let p = vc?.parent { vc = p }
        return vc?.presentingViewController == nil ? nil : vc
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attachSheetHandle()
    }

    /// From either moment: the closure can arrive before or after this view reaches the bar.
    fileprivate func attachSheetHandle() {
        guard window != nil, onPullDown != nil else { return }
        // The whole bar, not just the name: find the navigation bar this title view sits in.
        var v: UIView? = superview
        while let cur = v, !(cur is UINavigationBar) { v = cur.superview }
        guard let bar = v as? UINavigationBar,
              !(bar.gestureRecognizers ?? []).contains(where: { $0 is SheetHandleTouch }) else { return }
        bar.addGestureRecognizer(SheetHandleTouch(header: self))
    }
}

/// Watches touches on the chat's bar without taking them: down → the sheet may be dragged away,
/// up → it may not (the list's drag belongs to the list again). Never recognises, so taps on the
/// back button, the name and the call buttons are untouched.
private final class SheetHandleTouch: UIGestureRecognizer {
    weak var header: ChatHeaderView?
    init(header: ChatHeaderView) {
        self.header = header
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }
    private var relock: DispatchWorkItem?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let h = header, let unlock = h.onPullDown, let sheet = h.sheetController else { return }
        relock?.cancel()
        unlock(true)
        sheet.isModalInPresentation = false
    }
    /// Locked again a moment AFTER the finger lifts, not at the lift: the sheet decides close or
    /// spring-back at that same instant, and a lock landing first would cancel a close in progress.
    /// A sheet that has gone (`presentingViewController` nil) is left alone.
    private func lockSoon() {
        state = .failed
        guard let h = header, let sheet = h.sheetController else { return }
        relock?.cancel()
        let unlock = h.onPullDown
        let work = DispatchWorkItem { [weak sheet] in
            guard let sheet, sheet.presentingViewController != nil, !sheet.isBeingDismissed else { return }
            unlock?(false)
            sheet.isModalInPresentation = true
        }
        relock = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lockSoon() }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { lockSoon() }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}
