import UIKit

// ⛔ THE STICKER PANEL — owner 2026-10-17 ("go build"). It takes the KEYBOARD'S PLACE: the composer
// sets it as the field's `inputView` and calls `reloadInputViews`, so the system animates the swap
// and the bar (pinned to keyboardLayoutGuide) rides it for free. Shape and numbers from the
// reference app: a "GIFs | Stickers" switch on top, a strip of pack icons, then one scrolling grid
// with a section per shelf (Recently Used, Favorites, each pack). Only tiles on screen animate.
// GIFs keeps today's picker (its search field needs the real keyboard, which an inputView cannot
// host), so that tab hands back to the old GIF path.

/// The panel's height: the last real keyboard's, so the swap does not jump; a per-phone default
/// until a keyboard has been seen.
enum StickerPanelHeight {
    private static var lastKeyboard: CGFloat = 0
    private static var observer: NSObjectProtocol?

    /// Starts listening once; every later call is free.
    static func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillShowNotification,
                                                          object: nil, queue: .main) { n in
            guard let f = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            // A panel's own show also posts this; only a real keyboard (taller than a bar) counts,
            // and our panel reports the same height it was given, so it cannot drift.
            if f.height > 170 { lastKeyboard = f.height }
        }
    }

    static var current: CGFloat {
        if lastKeyboard > 170 { return lastKeyboard }
        let screen = UIScreen.main.bounds.size
        let longSide = max(screen.width, screen.height)
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        let homeIndicator = (window?.safeAreaInsets.bottom ?? 0) > 0
        if !homeIndicator { return 260 }          // SE-size, Touch ID phones
        return longSide >= 926 ? 345 : 335        // Max / Plus, then every other notch phone
    }
}

final class StickerKeyboardView: UIInputView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    var onSend: (Sticker) -> Void = { _ in }
    var onCreate: () -> Void = {}
    /// The GIFs tab: the composer closes the panel and opens today's GIF picker.
    var onGifs: () -> Void = {}

    private enum Shelf: Equatable {
        case recents, favorites, pack(StickerPack)
        var title: String {
            switch self {
            case .recents: return "Recently Used"
            case .favorites: return "Favorites"
            case .pack(let p): return p.title
            }
        }
    }
    private struct Section { let shelf: Shelf; let stickers: [Sticker] }

    private let height: CGFloat
    private var sections: [Section] = []
    private var editing: Shelf?            // .recents or .favorites while choosing what to remove
    private var picked: Set<String> = []

    private let tabs = UISegmentedControl(items: ["GIFs", "Stickers"])
    private let strip = UIScrollView()
    private var stripButtons: [UIButton] = []
    private let grid: UICollectionView
    private let deleteBar = UIView()
    private let deleteButton = UIButton(type: .system)

    // Reference numbers (owner-approved report, 2026-10-17).
    private enum M {
        static let item: CGFloat = 70, spacing: CGFloat = 12, side: CGFloat = 10, row: CGFloat = 2
        static let header: CGFloat = 24, packGap: CGFloat = 18
        static let stripCell: CGFloat = 40, stripInset: CGFloat = 6, stripSpacing: CGFloat = 4
        static let top: CGFloat = 8, tabsH: CGFloat = 32, stripH: CGFloat = 44
    }

    init(height: CGFloat) {
        self.height = height
        let layout = UICollectionViewFlowLayout()
        layout.sectionHeadersPinToVisibleBounds = false
        grid = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: height),
                   inputViewStyle: .keyboard)
        allowsSelfSizing = true
        autoresizingMask = [.flexibleWidth]

        tabs.selectedSegmentIndex = 1
        let normal = UIFont.systemFont(ofSize: 14, weight: .regular)
        let bold = UIFont.systemFont(ofSize: 14, weight: .semibold)
        tabs.setTitleTextAttributes([.font: normal, .foregroundColor: UIColor.secondaryLabel], for: .normal)
        tabs.setTitleTextAttributes([.font: bold, .foregroundColor: UIColor.label], for: .selected)
        tabs.addTarget(self, action: #selector(tabChanged), for: .valueChanged)
        addSubview(tabs)

        strip.showsHorizontalScrollIndicator = false
        strip.alwaysBounceHorizontal = true
        addSubview(strip)

        grid.backgroundColor = .clear
        grid.dataSource = self
        grid.delegate = self
        grid.alwaysBounceVertical = true
        grid.register(StickerCell.self, forCellWithReuseIdentifier: StickerCell.id)
        grid.register(ShelfHeader.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                      withReuseIdentifier: ShelfHeader.id)
        addSubview(grid)

        deleteBar.backgroundColor = .secondarySystemBackground
        deleteBar.isHidden = true
        deleteButton.setTitleColor(.systemRed, for: .normal)
        deleteButton.setTitleColor(.tertiaryLabel, for: .disabled)
        deleteButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        deleteBar.addSubview(deleteButton)
        addSubview(deleteBar)

        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: height) }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        tabs.frame = CGRect(x: (w - 220) / 2, y: M.top, width: 220, height: M.tabsH)
        strip.frame = CGRect(x: 0, y: tabs.frame.maxY + 4, width: w, height: M.stripH)
        layoutStrip()
        let gridTop = strip.frame.maxY
        grid.frame = CGRect(x: 0, y: gridTop, width: w, height: max(0, bounds.height - gridTop))
        grid.contentInset.bottom = safeAreaInsets.bottom + (editing == nil ? 0 : 44)
        let barH = 44 + safeAreaInsets.bottom
        deleteBar.frame = CGRect(x: 0, y: bounds.height - barH, width: w, height: barH)
        deleteButton.frame = CGRect(x: 0, y: 0, width: w, height: 44)
        if lastGridWidth != w { lastGridWidth = w; grid.collectionViewLayout.invalidateLayout() }
    }
    private var lastGridWidth: CGFloat = 0

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Back on screen: pick up what changed while away (a sticker just sent, one just made).
        if window != nil, editing == nil { reload() }
    }

    // MARK: Data

    @MainActor func reload() {
        let store = StickerStore.shared
        var s: [Section] = [Section(shelf: .recents, stickers: store.recents)]
        if !store.favorites.isEmpty { s.append(Section(shelf: .favorites, stickers: store.favorites)) }
        for p in store.packs { s.append(Section(shelf: .pack(p), stickers: p.stickers)) }
        sections = s
        if let e = editing, !sections.contains(where: { $0.shelf == e }) { endEditing() }
        grid.reloadData()
        buildStrip()
    }

    private func isCreate(_ ip: IndexPath) -> Bool { sections[ip.section].shelf == .recents && ip.item == 0 }

    private func sticker(at ip: IndexPath) -> Sticker? {
        let sec = sections[ip.section]
        let i = sec.shelf == .recents ? ip.item - 1 : ip.item
        return sec.stickers.indices.contains(i) ? sec.stickers[i] : nil
    }

    // MARK: Pack strip

    private func buildStrip() {
        stripButtons.forEach { $0.removeFromSuperview() }
        stripButtons = []
        for (i, sec) in sections.enumerated() {
            let b = UIButton(type: .system)
            b.tag = i
            b.tintColor = .secondaryLabel
            switch sec.shelf {
            case .recents:
                b.setImage(UIImage(systemName: "clock"), for: .normal)
                b.accessibilityLabel = "Recently Used"
            case .favorites:
                b.setImage(UIImage(systemName: "star"), for: .normal)
                b.accessibilityLabel = "Favorites"
            case .pack(let p):
                let player = StickerPlayerView()
                player.frame = CGRect(x: M.stripInset, y: M.stripInset,
                                      width: M.stripCell - 2 * M.stripInset, height: M.stripCell - 2 * M.stripInset)
                let px = Int((M.stripCell - 2 * M.stripInset) * min(UIScreen.main.scale, 2))
                player.setSticker(url: p.stickers.first.flatMap { StickerStore.shared.fileURL(for: $0) }, pixelSize: px)
                b.addSubview(player)   // still: the strip never animates
                b.accessibilityLabel = p.title
            }
            b.layer.cornerRadius = 10
            b.addTarget(self, action: #selector(stripTapped(_:)), for: .touchUpInside)
            strip.addSubview(b)
            stripButtons.append(b)
        }
        layoutStrip()
        markStrip(0)
    }

    private func layoutStrip() {
        var x = M.side
        let y = (M.stripH - M.stripCell) / 2
        for b in stripButtons {
            b.frame = CGRect(x: x, y: y, width: M.stripCell, height: M.stripCell)
            x += M.stripCell + M.stripSpacing
        }
        strip.contentSize = CGSize(width: x + M.side - M.stripSpacing, height: M.stripH)
    }

    private var markedStrip = -1
    private func markStrip(_ i: Int) {
        guard i != markedStrip else { return }
        markedStrip = i
        for b in stripButtons {
            b.backgroundColor = b.tag == i ? UIColor.label.withAlphaComponent(0.1) : .clear
        }
        if stripButtons.indices.contains(i) {
            strip.scrollRectToVisible(stripButtons[i].frame.insetBy(dx: -M.side, dy: 0), animated: true)
        }
    }

    @objc private func stripTapped(_ b: UIButton) {
        let sec = b.tag
        guard sections.indices.contains(sec) else { return }
        let ip = IndexPath(item: 0, section: sec)
        if let a = grid.layoutAttributesForSupplementaryElement(ofKind: UICollectionView.elementKindSectionHeader, at: ip),
           a.frame.height > 0 {
            let maxY = max(0, grid.contentSize.height - grid.bounds.height + grid.contentInset.bottom)
            grid.setContentOffset(CGPoint(x: 0, y: min(a.frame.minY, maxY)), animated: false)
        } else if grid.numberOfItems(inSection: sec) > 0 {
            grid.scrollToItem(at: ip, at: .top, animated: false)
        }
        markStrip(sec)
    }

    func scrollViewDidScroll(_ sv: UIScrollView) {
        guard sv === grid else { return }
        let top = grid.indexPathsForVisibleItems.min()
        if let s = top?.section { markStrip(s) }
    }

    // MARK: Tabs

    @objc private func tabChanged() {
        guard tabs.selectedSegmentIndex == 0 else { return }
        // Back to Stickers right away, so the panel reads correctly the next time it opens.
        tabs.selectedSegmentIndex = 1
        onGifs()
    }

    // MARK: Editing

    private func beginEditing(_ shelf: Shelf) {
        editing = shelf
        picked = []
        deleteBar.isHidden = false
        updateDeleteButton()
        setNeedsLayout()
        grid.reloadData()
    }

    private func endEditing() {
        editing = nil
        picked = []
        deleteBar.isHidden = true
        setNeedsLayout()
        grid.reloadData()
    }

    private func updateDeleteButton() {
        let base = editing == .recents ? "Remove from Recents" : "Remove from Favorites"
        deleteButton.setTitle(picked.isEmpty ? base : "\(base) (\(picked.count))", for: .normal)
        deleteButton.isEnabled = !picked.isEmpty
    }

    @objc @MainActor private func deleteTapped() {
        guard let e = editing, !picked.isEmpty else { return }
        if e == .recents { StickerStore.shared.removeFromRecents(picked) }
        else { StickerStore.shared.removeFavorites(picked) }
        editing = nil
        picked = []
        deleteBar.isHidden = true
        setNeedsLayout()
        reload()
    }

    // MARK: Grid

    func numberOfSections(in cv: UICollectionView) -> Int { sections.count }

    func collectionView(_ cv: UICollectionView, numberOfItemsInSection s: Int) -> Int {
        sections[s].stickers.count + (sections[s].shelf == .recents ? 1 : 0)
    }

    private var itemSide: CGFloat {
        let w = grid.bounds.width > 0 ? grid.bounds.width : bounds.width
        let cols = max(5, Int((w + M.spacing) / (M.item + M.spacing)))
        let side = (w - 2 * M.side - CGFloat(cols - 1) * M.spacing) / CGFloat(cols)
        return floor(min(M.item, max(1, side)))
    }

    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout,
                        sizeForItemAt ip: IndexPath) -> CGSize {
        CGSize(width: itemSide, height: itemSide)
    }

    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout,
                        minimumInteritemSpacingForSectionAt s: Int) -> CGFloat { M.spacing }

    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout,
                        minimumLineSpacingForSectionAt s: Int) -> CGFloat { M.row }

    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout,
                        insetForSectionAt s: Int) -> UIEdgeInsets {
        UIEdgeInsets(top: 0, left: M.side, bottom: s == sections.count - 1 ? 8 : M.packGap, right: M.side)
    }

    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout,
                        referenceSizeForHeaderInSection s: Int) -> CGSize {
        // Recently Used with nothing in it keeps only its Create tile, no title.
        if sections[s].shelf == .recents && sections[s].stickers.isEmpty { return .zero }
        return CGSize(width: cv.bounds.width, height: M.header)
    }

    func collectionView(_ cv: UICollectionView, viewForSupplementaryElementOfKind kind: String,
                        at ip: IndexPath) -> UICollectionReusableView {
        let h = cv.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: ShelfHeader.id, for: ip) as! ShelfHeader
        let shelf = sections[ip.section].shelf
        h.title.text = shelf.title
        let editable = shelf == .recents || shelf == .favorites
        h.edit.isHidden = !editable
        h.edit.setTitle(editing == shelf ? "Done" : "Edit", for: .normal)
        h.onEdit = { [weak self] in
            guard let self else { return }
            if self.editing == shelf { self.endEditing() } else { self.beginEditing(shelf) }
        }
        return h
    }

    func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
        let c = cv.dequeueReusableCell(withReuseIdentifier: StickerCell.id, for: ip) as! StickerCell
        if isCreate(ip) {
            c.showCreate()
            return c
        }
        guard let s = sticker(at: ip) else { return c }
        let px = Int(itemSide * min(UIScreen.main.scale, 2))
        c.show(url: StickerStore.shared.fileURL(for: s), pixelSize: px)
        let shelf = sections[ip.section].shelf
        c.setChecking(editing == shelf, on: picked.contains(s.id))
        c.accessibilityLabel = "Sticker \(s.emoji)"
        return c
    }

    func collectionView(_ cv: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt ip: IndexPath) {
        (cell as? StickerCell)?.player.play()
    }

    func collectionView(_ cv: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt ip: IndexPath) {
        (cell as? StickerCell)?.player.stop()
    }

    @MainActor func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) {
        cv.deselectItem(at: ip, animated: false)
        if isCreate(ip) {
            if editing == nil { onCreate() }
            return
        }
        guard let s = sticker(at: ip) else { return }
        if let e = editing {
            guard sections[ip.section].shelf == e else { return }
            if picked.contains(s.id) { picked.remove(s.id) } else { picked.insert(s.id) }
            (cv.cellForItem(at: ip) as? StickerCell)?.setChecking(true, on: picked.contains(s.id))
            updateDeleteButton()
            return
        }
        // Recents move on the next showing, not under the finger.
        StickerStore.shared.noteUsed(s)
        onSend(s)
    }
}

// MARK: - Cells

private final class StickerCell: UICollectionViewCell {
    static let id = "StickerCell"
    let player = StickerPlayerView()
    private let plus = UIImageView(image: UIImage(systemName: "plus",
                                                  withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .medium)))
    private let check = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(player)
        plus.tintColor = .secondaryLabel
        plus.contentMode = .center
        contentView.addSubview(plus)
        check.contentMode = .scaleAspectFit
        contentView.addSubview(check)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        player.frame = contentView.bounds.insetBy(dx: 2, dy: 2)
        plus.frame = contentView.bounds.insetBy(dx: 4, dy: 4)
        check.frame = CGRect(x: contentView.bounds.width - 22, y: contentView.bounds.height - 22, width: 20, height: 20)
    }

    func showCreate() {
        player.setSticker(url: nil, pixelSize: 0)
        player.isHidden = true
        plus.isHidden = false
        plus.backgroundColor = UIColor.label.withAlphaComponent(0.06)
        plus.layer.cornerRadius = 14
        plus.layer.cornerCurve = .continuous
        plus.clipsToBounds = true
        check.isHidden = true
        accessibilityLabel = "Create Sticker"
        isAccessibilityElement = true
    }

    func show(url: URL?, pixelSize: Int) {
        player.isHidden = false
        plus.isHidden = true
        player.setSticker(url: url, pixelSize: pixelSize)
        isAccessibilityElement = true
    }

    func setChecking(_ on: Bool, on picked: Bool) {
        check.isHidden = !on
        check.image = UIImage(systemName: picked ? "checkmark.circle.fill" : "circle")
        check.tintColor = picked ? .systemBlue : .white
        check.backgroundColor = picked ? .white : UIColor.black.withAlphaComponent(0.25)
        check.layer.cornerRadius = 10
        check.clipsToBounds = true
        player.alpha = on && !picked ? 0.75 : 1
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        player.stop()
        check.isHidden = true
        player.alpha = 1
    }
}

private final class ShelfHeader: UICollectionReusableView {
    static let id = "ShelfHeader"
    let title = UILabel()
    let edit = UIButton(type: .system)
    var onEdit: () -> Void = {}

    override init(frame: CGRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .secondaryLabel
        addSubview(title)
        edit.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        edit.addTarget(self, action: #selector(editTapped), for: .touchUpInside)
        addSubview(edit)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        title.frame = CGRect(x: 14, y: 0, width: bounds.width - 100, height: bounds.height)
        edit.frame = CGRect(x: bounds.width - 70, y: 0, width: 60, height: bounds.height)
        edit.contentHorizontalAlignment = .right
    }

    @objc private func editTapped() { onEdit() }
}
