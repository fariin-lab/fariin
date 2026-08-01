import UIKit

// The sticker picker, and it IS a keyboard.
//
// Built in UIKit rather than SwiftUI on purpose. This is a grid that has to stay perfectly smooth
// under a fast flick with a hundred images in it, which is the same reason the message list is a
// UICollectionView (see NativeMessageList) and the same reason UIKitBubbleCell exists. It also
// sidesteps hosting a UIHostingController inside a UIInputView, which has no view controller to
// parent it to.
//
// Layout, which is the shape every sticker keyboard converges on:
//   • the grid scrolls
//   • the tab row is PINNED at the bottom and never moves, with a hairline above it
//   • switching tabs cannot dismiss the panel, guaranteed by construction — the height constraint
//     and the inputView assignment both live outside this view, so nothing in here can reach them
final class StickerKeyboard: ComposerKeyboardPanel {

    /// Tap: send it, and the panel stays open. Sending is not a reason to close a keyboard.
    var onPick: ((StickerPack.Sticker, String) -> Void)?

    // A tab is favourites, recents, or one installed pack. Favourites and recents only appear once
    // they have something in them: an empty tab you cannot fill yet is just a dead end.
    private enum Tab: Equatable {
        case favourites, recents, pack(StickerPack)
        static func == (a: Tab, b: Tab) -> Bool {
            switch (a, b) {
            case (.favourites, .favourites), (.recents, .recents): return true
            case let (.pack(x), .pack(y)): return x.id == y.id
            default: return false
            }
        }
    }

    private var tabs: [Tab] = []
    private var selected = 0
    private var stickers: [StickerPack.Sticker] = []

    private lazy var grid: UICollectionView = {
        let cv = UICollectionView(frame: .zero, collectionViewLayout: Self.makeLayout())
        cv.backgroundColor = .clear
        cv.alwaysBounceVertical = true
        cv.showsVerticalScrollIndicator = false
        cv.register(StickerCell.self, forCellWithReuseIdentifier: StickerCell.id)
        cv.delegate = self
        cv.dataSource = self
        cv.prefetchDataSource = self
        cv.contentInsetAdjustmentBehavior = .never
        return cv
    }()

    private let tabBar = UIScrollView()
    private let tabRow = UIStackView()
    private let hairline = UIView()
    private let emptyLabel = UILabel()

    private static let tabBarHeight: CGFloat = 46

    override init() {
        super.init()
        build()
        reloadTabs()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Build

    private func build() {
        contentView.addSubview(grid)
        contentView.addSubview(hairline)
        contentView.addSubview(tabBar)
        contentView.addSubview(emptyLabel)

        tabBar.showsHorizontalScrollIndicator = false
        tabBar.addSubview(tabRow)
        tabRow.axis = .horizontal
        tabRow.alignment = .center
        tabRow.spacing = 2

        hairline.backgroundColor = .separator

        emptyLabel.text = "No sticker packs yet."
        emptyLabel.font = .systemFont(ofSize: 15)
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.textAlignment = .center
        emptyLabel.isHidden = true

        for v in [grid, hairline, tabBar, tabRow, emptyLabel] { v.translatesAutoresizingMaskIntoConstraints = false }

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: contentView.topAnchor),
            grid.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: hairline.topAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: grid.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: grid.centerYAnchor),

            hairline.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: tabBar.topAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

            // Pinned to the BOTTOM of the panel, which is the bottom of the keyboard. The panel sits
            // over the home indicator exactly as the keyboard does, so no safe-area inset here.
            tabBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            tabBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: Self.tabBarHeight),

            // contentLayoutGuide, NOT the scroll view's own edges. Pinned to the frame the row can
            // never be wider than the bar, so a long pack list would break its constraints instead
            // of scrolling — which is the one thing this row exists to do.
            tabRow.topAnchor.constraint(equalTo: tabBar.contentLayoutGuide.topAnchor),
            tabRow.bottomAnchor.constraint(equalTo: tabBar.contentLayoutGuide.bottomAnchor),
            tabRow.leadingAnchor.constraint(equalTo: tabBar.contentLayoutGuide.leadingAnchor, constant: 6),
            tabRow.trailingAnchor.constraint(equalTo: tabBar.contentLayoutGuide.trailingAnchor, constant: -6),
            tabRow.heightAnchor.constraint(equalTo: tabBar.frameLayoutGuide.heightAnchor),
        ])
    }

    /// Adaptive columns instead of a fixed count: one number that looks right on an SE looks sparse
    /// on a Pro Max. Aim at a target cell size and take however many fit.
    private static func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, env in
            let target: CGFloat = 84
            let columns = max(4, min(7, Int(env.container.effectiveContentSize.width / target)))
            let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1),
                                                                heightDimension: .fractionalHeight(1)))
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: .init(widthDimension: .fractionalWidth(1),
                                  heightDimension: .fractionalWidth(1 / CGFloat(columns))),
                repeatingSubitem: item, count: columns)
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = .init(top: 6, leading: 6, bottom: 6, trailing: 6)
            return section
        }
    }

    // MARK: Data

    /// Rebuilt whenever the installed packs change. Keeps you on the SAME tab across a reload where
    /// it still exists — losing your place because a pack list refreshed in the background is the
    /// kind of small betrayal that makes a panel feel unreliable.
    func reloadTabs() {
        let previous: Tab? = tabs.indices.contains(selected) ? tabs[selected] : nil
        var next: [Tab] = []
        if !StickerRecents.favourites.all().isEmpty { next.append(.favourites) }
        if !StickerRecents.recents.all().isEmpty { next.append(.recents) }
        next.append(contentsOf: StickerService.shared.installed.map { Tab.pack($0) })
        tabs = next
        selected = previous.flatMap { p in next.firstIndex(where: { $0 == p }) } ?? 0
        buildTabButtons()
        loadSelected()
    }

    private func buildTabButtons() {
        tabRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, tab) in tabs.enumerated() {
            let b: TabButton
            switch tab {
            case .favourites:  b = TabButton(symbol: "star.fill", selected: i == selected)
            case .recents:     b = TabButton(symbol: "clock.fill", selected: i == selected)
            case .pack(let p): b = TabButton(coverUrl: p.coverUrl.isEmpty ? p.stickers.first?.url : p.coverUrl,
                                             selected: i == selected)
            }
            b.addAction(UIAction { [weak self] _ in self?.select(i) }, for: .touchUpInside)
            tabRow.addArrangedSubview(b)
        }
        // No trailing spacer: the row sizes to its buttons and scrolls once they outgrow the bar.
        // A spacer would have no width of its own inside a scroll view's content guide.
    }

    private func select(_ i: Int) {
        guard tabs.indices.contains(i), i != selected else { return }
        selected = i
        buildTabButtons()
        loadSelected()
        grid.setContentOffset(.zero, animated: false)
    }

    private func loadSelected() {
        switch tabs.indices.contains(selected) ? tabs[selected] : nil {
        case .favourites: stickers = StickerRecents.favourites.all()
        case .recents:    stickers = StickerRecents.recents.all()
        case .pack(let p): stickers = p.stickers
        case nil:         stickers = []
        }
        emptyLabel.isHidden = !tabs.isEmpty
        grid.reloadData()
    }

    /// Called after a send so the recents tab is honest immediately, and after a favourite changes.
    func refreshLocalTabs() {
        let hadFavourites = tabs.contains(.favourites)
        let hadRecents = tabs.contains(.recents)
        let nowFavourites = !StickerRecents.favourites.all().isEmpty
        let nowRecents = !StickerRecents.recents.all().isEmpty
        // A tab appearing or disappearing changes the whole row; otherwise only the current tab's
        // contents can have moved, and reloading just that keeps the grid from flashing.
        if hadFavourites != nowFavourites || hadRecents != nowRecents { reloadTabs() }
        else if tabs.indices.contains(selected), tabs[selected] == .favourites || tabs[selected] == .recents {
            loadSelected()
        }
    }
}

// MARK: - Grid

extension StickerKeyboard: UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {

    func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int { stickers.count }

    func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
        let cell = cv.dequeueReusableCell(withReuseIdentifier: StickerCell.id, for: ip) as! StickerCell
        cell.show(stickers[ip.item])
        return cell
    }

    func collectionView(_ cv: UICollectionView, prefetchItemsAt paths: [IndexPath]) {
        for ip in paths where stickers.indices.contains(ip.item) {
            let url = stickers[ip.item].url
            Task { _ = await StickerImages.load(url) }
        }
    }

    func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) {
        guard stickers.indices.contains(ip.item), tabs.indices.contains(selected) else { return }
        let sticker = stickers[ip.item]
        // Sent from favourites or recents there is no pack in context. The message keeps its own url
        // and emoji either way, so an empty packId costs nothing at the receiving end.
        let packId: String
        if case .pack(let p) = tabs[selected] { packId = p.id } else { packId = "" }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // A quick press-in on the cell, so a tap that sends something invisible off-panel still has
        // a visible acknowledgement of its own.
        if let cell = cv.cellForItem(at: ip) as? StickerCell { cell.flash() }
        StickerRecents.recents.note(sticker)
        onPick?(sticker, packId)
        refreshLocalTabs()
    }

    /// Long press → the native context menu, with the sticker itself as the preview. Telegram's
    /// interaction, drawn by UIKit rather than reimplemented.
    func collectionView(_ cv: UICollectionView, contextMenuConfigurationForItemAt ip: IndexPath,
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard stickers.indices.contains(ip.item) else { return nil }
        let sticker = stickers[ip.item]
        let isFavourite = StickerRecents.favourites.contains(sticker.id)
        return UIContextMenuConfiguration(identifier: nil) {
            let preview = UIViewController()
            let iv = UIImageView(image: StickerImages.cached(sticker.url))
            iv.contentMode = .scaleAspectFit
            preview.view = iv
            preview.preferredContentSize = CGSize(width: 180, height: 180)
            return preview
        } actionProvider: { [weak self] _ in
            let favourite = UIAction(
                title: isFavourite ? "Remove from Favourites" : "Add to Favourites",
                image: UIImage(systemName: isFavourite ? "star.slash" : "star")) { _ in
                    if isFavourite { StickerRecents.favourites.remove(sticker.id) }
                    else { StickerRecents.favourites.note(sticker) }
                    self?.refreshLocalTabs()
                }
            return UIMenu(children: [favourite])
        }
    }
}

// MARK: - Cell

private final class StickerCell: UICollectionViewCell {
    static let id = "sticker"
    private let iv = UIImageView()
    /// Which sticker this cell is currently for. A recycled cell whose slow load lands late would
    /// otherwise paint the wrong sticker — the same bug AnimatedGifView documents for GIFs.
    private var showing: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(iv)
        NSLayoutConstraint.activate([
            iv.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            iv.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            iv.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            iv.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        iv.image = nil
        iv.alpha = 1
        showing = nil
    }

    func show(_ s: StickerPack.Sticker) {
        showing = s.url
        // The synchronous hit is the whole reason the grid is smooth: a sticker already on disk is
        // drawn in this pass, with no placeholder frame and nothing to fade.
        if let hit = StickerImages.cached(s.url) { iv.image = hit; return }
        iv.image = nil
        let wanted = s.url
        Task { [weak self] in
            let img = await StickerImages.load(wanted)
            guard let self, self.showing == wanted else { return }
            self.iv.image = img
            self.iv.alpha = 0
            UIView.animate(withDuration: 0.15) { self.iv.alpha = 1 }
        }
    }

    func flash() {
        iv.transform = CGAffineTransform(scaleX: 0.86, y: 0.86)
        UIView.animate(withDuration: 0.22, delay: 0, usingSpringWithDamping: 0.55,
                       initialSpringVelocity: 0.4) { self.iv.transform = .identity }
    }
}

// MARK: - Tab button

/// Favourites and recents are symbols; a pack is its own cover, because a cover is the only thing
/// that makes a row of packs readable at a glance.
///
/// The image lives in a UIImageView rather than the button's own image: a 512px cover handed to a
/// 38pt button draws at its natural size, and aspect-fitting it inside a pinned image view is the
/// short way to be sure both a symbol and a piece of art land at the same size.
private final class TabButton: UIButton {
    private let iv = UIImageView()
    private var coverUrl: String?
    private let isSelected_: Bool

    init(symbol: String? = nil, coverUrl: String? = nil, selected: Bool) {
        isSelected_ = selected
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 9
        layer.cornerCurve = .continuous
        backgroundColor = selected ? .tertiarySystemFill : .clear

        iv.contentMode = .scaleAspectFit
        iv.isUserInteractionEnabled = false
        iv.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iv)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 38),
            heightAnchor.constraint(equalToConstant: 38),
            iv.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            iv.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            iv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            iv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
        ])

        if let symbol {
            iv.image = UIImage(systemName: symbol)
            iv.tintColor = selected ? .label : .secondaryLabel
        }
        if let coverUrl { load(coverUrl) }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func load(_ url: String) {
        coverUrl = url
        if let hit = StickerImages.cached(url) { apply(hit); return }
        Task { [weak self] in
            let img = await StickerImages.load(url)
            guard let self, self.coverUrl == url else { return }
            self.apply(img)
        }
    }

    private func apply(_ image: UIImage?) {
        iv.image = image
        // A pack you are not on is dimmed, not greyed out: the cover is artwork, and flattening it
        // to a silhouette would make every pack look the same.
        iv.alpha = isSelected_ ? 1 : 0.55
    }
}
