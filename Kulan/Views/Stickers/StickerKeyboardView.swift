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
    /// Unused legacy hook kept for source compatibility; GIF search now expands in place.
    var onGifs: () -> Void = {}
    /// A GIF tapped in the panel's own GIFs tab.
    var onSendGif: (GiphyService.Gif) -> Void = { _ in }
    /// Host window & focus callbacks for expanding GIF search to full screen in place.
    var hostWindow: () -> UIWindow? = { nil }
    var onTouch: () -> Void = {}
    var onBeginGifSearch: () -> Void = {}
    var onWillCollapseGifSearch: () -> Void = {}
    var onRestorePanelFocus: () -> Void = {}
    var onDidCollapseGifSearch: () -> Void = {}

    private let cardView = UIView()
    private let backdrop = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    private let gifGrid = PanelGifGrid()
    private(set) var searchingGifs = false
    private var transitionGen = 0
    private var searchOverlay: PassthroughOverlayView?
    private var collapseWindow: PassthroughWindow?

    private enum Shelf: Equatable {
        case recents, favorites, pack(StickerPack)
        var title: String {
            switch self {
            case .recents: return "Recently Used"
            case .favorites: return "Favorites"
            case .pack(let p): return p.title
            }
        }
        /// Only my own shelves can lose stickers; the packs are everyone's.
        var editable: Bool { self == .recents || self == .favorites }
        var key: String { self == .recents ? "r" : "f" }
    }
    private struct Section { let shelf: Shelf; let stickers: [Sticker] }

    private let height: CGFloat
    private var sections: [Section] = []
    // ⛔ ONE PEN, NOT AN EDIT PER SHELF — owner 2026-10-17: a small pen beside the tabs; tapping it
    // makes every sticker in Recently Used and Favorites selectable at once, then Delete.
    private var editing = false
    /// "<shelf key>|<sticker id>": the same sticker can sit in both shelves and is picked per shelf.
    private var picked: Set<String> = []
    private let editButton = UIButton(type: .system)
    private let tabGlass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))

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

        cardView.layer.cornerRadius = 28
        cardView.layer.cornerCurve = .continuous
        cardView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        cardView.clipsToBounds = true
        addSubview(cardView)

        backdrop.contentView.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.65)
        backdrop.isHidden = true
        cardView.addSubview(backdrop)

        tabs.selectedSegmentIndex = 1
        let normal = UIFont.systemFont(ofSize: 14, weight: .regular)
        let bold = UIFont.systemFont(ofSize: 14, weight: .semibold)
        tabs.setTitleTextAttributes([.font: normal, .foregroundColor: UIColor.secondaryLabel], for: .normal)
        tabs.setTitleTextAttributes([.font: bold, .foregroundColor: UIColor.label], for: .selected)
        tabs.addTarget(self, action: #selector(tabChanged), for: .valueChanged)
        // ⛔ LIQUID GLASS UNDER THE SWITCH — owner 2026-10-17: the flat grey track read as a web control.
        // The system glass capsule is the track; the control's own track is cleared on top of it.
        tabGlass.clipsToBounds = true
        cardView.addSubview(tabGlass)
        tabs.setBackgroundImage(UIImage(), for: .normal, barMetrics: .default)
        tabs.setDividerImage(UIImage(), forLeftSegmentState: .normal, rightSegmentState: .normal, barMetrics: .default)
        tabs.selectedSegmentTintColor = UIColor.label.withAlphaComponent(0.12)
        cardView.addSubview(tabs)

        editButton.setImage(UIImage(systemName: "pencil",
                                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)), for: .normal)
        editButton.tintColor = .secondaryLabel
        editButton.accessibilityLabel = "Edit stickers"
        editButton.addTarget(self, action: #selector(editTapped), for: .touchUpInside)
        cardView.addSubview(editButton)

        strip.showsHorizontalScrollIndicator = false
        strip.alwaysBounceHorizontal = true
        cardView.addSubview(strip)

        grid.backgroundColor = .clear
        grid.dataSource = self
        grid.delegate = self
        grid.alwaysBounceVertical = true
        grid.register(StickerCell.self, forCellWithReuseIdentifier: StickerCell.id)
        grid.register(ShelfHeader.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                      withReuseIdentifier: ShelfHeader.id)
        cardView.addSubview(grid)

        gifGrid.isHidden = true
        gifGrid.onSend = { [weak self] g in self?.onSendGif(g) }
        gifGrid.onSearch = { [weak self] in self?.expandForGifSearch() }
        gifGrid.onCancelSearch = { [weak self] in self?.collapseGifSearch() }
        gifGrid.onSearchFieldEnded = { [weak self] in
            guard let self, self.searchingGifs else { return }
            self.collapseGifSearch()
        }
        cardView.addSubview(gifGrid)
        // The switch floats over both grids (it sits at their foot now).
        cardView.bringSubviewToFront(tabGlass)
        cardView.bringSubviewToFront(tabs)

        deleteBar.backgroundColor = .secondarySystemBackground
        deleteBar.isHidden = true
        deleteButton.setTitleColor(.systemRed, for: .normal)
        deleteButton.setTitleColor(.tertiaryLabel, for: .disabled)
        deleteButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        deleteBar.addSubview(deleteButton)
        cardView.addSubview(deleteBar)

        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        searchOverlay?.removeFromSuperview()
        collapseWindow?.isHidden = true
    }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: height) }

    override func layoutSubviews() {
        super.layoutSubviews()
        if cardView.superview === self {
            cardView.frame = bounds
        }
        layoutCardSubviews()
    }

    private func layoutCardSubviews() {
        let cb = cardView.bounds
        let w = cb.width
        let h = cb.height
        backdrop.frame = cb
        // Frames are only valid on an untransformed view; the hide lift is put back on below.
        for v in [tabs, tabGlass, editButton, strip] as [UIView] { v.transform = .identity }
        // ⛔ THE SWITCH SITS AT THE BOTTOM — owner 2026-10-17, as the reference app has it: the pack
        // strip (with the pen at its end) on top, GIFs | Stickers floating over the grid at the foot.
        // Scrolling into the grid sends the strip up and the switch down; scrolling back brings both.
        let bottomInset = max(safeAreaInsets.bottom, 8)
        strip.frame = CGRect(x: 0, y: M.top, width: w - 50, height: M.stripH)
        editButton.frame = CGRect(x: w - 44 - 6, y: M.top + (M.stripH - M.tabsH) / 2, width: 44, height: M.tabsH)
        layoutStrip()
        tabs.frame = CGRect(x: (w - 220) / 2, y: h - bottomInset - M.tabsH - 4, width: 220, height: M.tabsH)
        tabGlass.frame = tabs.frame.insetBy(dx: -3, dy: -3)
        tabGlass.layer.cornerRadius = tabGlass.bounds.height / 2
        let hideBars = headerHidden || searchingGifs
        let up = hideBars ? strip.frame.maxY : 0
        let down = hideBars ? h - tabGlass.frame.minY : 0
        for v in [editButton, strip] as [UIView] { v.transform = CGAffineTransform(translationX: 0, y: -up) }
        for v in [tabs, tabGlass] as [UIView] { v.transform = CGAffineTransform(translationX: 0, y: down) }
        for v in [tabs, tabGlass, editButton, strip] as [UIView] { v.alpha = hideBars ? 0 : 1 }
        if editing { tabs.alpha = 0; tabGlass.alpha = 0 }   // the Delete bar takes the foot while editing
        let gridTop = headerHidden ? 0 : strip.frame.maxY
        grid.frame = CGRect(x: 0, y: gridTop, width: w, height: max(0, h - gridTop))
        gifGrid.frame = CGRect(x: 0, y: M.top, width: w, height: max(0, h - M.top))
        gifGrid.bottomRoom = searchingGifs ? (StickerPanelHeight.current + 8) : (M.tabsH + 16)
        // Room under the last row for the floating switch (and the Delete bar while editing).
        grid.contentInset.bottom = bottomInset + M.tabsH + 16 + (editing ? 44 : 0)
        let barH = 44 + safeAreaInsets.bottom
        deleteBar.frame = CGRect(x: 0, y: h - barH, width: w, height: barH)
        deleteButton.frame = CGRect(x: 0, y: 0, width: w, height: 44)
        if lastGridWidth != w { lastGridWidth = w; grid.collectionViewLayout.invalidateLayout() }
    }
    private var lastGridWidth: CGFloat = 0

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Back on screen: pick up what changed while away (a sticker just sent, one just made).
        if window != nil, !editing { reload() }
    }

    // MARK: Expand / Collapse GIF search in place

    private func expandForGifSearch() {
        guard !searchingGifs else {
            gifGrid.focusSearchField()
            return
        }
        guard let hostWin = hostWindow() ?? window else { return }
        transitionGen += 1
        let gen = transitionGen
        searchingGifs = true
        headerHidden = false

        let startFrame: CGRect
        if let cw = collapseWindow, cardView.superview === cw {
            startFrame = cardView.layer.presentation()?.frame ?? cardView.frame
            cw.isHidden = true
            collapseWindow = nil
        } else if cardView.window != nil {
            startFrame = hostWin.convert(cardView.bounds, from: cardView)
        } else {
            let panelH = bounds.height > 0 ? bounds.height : height
            startFrame = CGRect(x: 0, y: hostWin.bounds.height - panelH, width: hostWin.bounds.width, height: panelH)
        }

        let ov = PassthroughOverlayView(frame: hostWin.bounds)
        ov.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        ov.targetView = cardView
        ov.onTouch = { [weak self] in self?.onTouch() }
        hostWin.addSubview(ov)
        searchOverlay?.removeFromSuperview()
        searchOverlay = ov

        backdrop.isHidden = false
        UIView.performWithoutAnimation {
            ov.addSubview(cardView)
            cardView.frame = startFrame
            layoutCardSubviews()
            cardView.layoutIfNeeded()
        }

        gifGrid.setSearching(true)
        onBeginGifSearch()
        gifGrid.focusSearchField()

        let topInset = max(hostWin.safeAreaInsets.top, 12)
        let expandedFrame = CGRect(x: 0, y: topInset, width: hostWin.bounds.width, height: hostWin.bounds.height - topInset)
        UIView.animate(withDuration: 0.38, delay: 0, usingSpringWithDamping: 0.92, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.cardView.frame = expandedFrame
            self.layoutCardSubviews()
            self.cardView.layoutIfNeeded()
        } completion: { [weak self] _ in
            guard let self, self.transitionGen == gen else { return }
        }
    }

    func collapseGifSearch() {
        guard searchingGifs else { return }
        transitionGen += 1
        let gen = transitionGen
        searchingGifs = false
        headerHidden = false

        let hostWin = hostWindow() ?? searchOverlay?.window ?? window
        let currentFrame = cardView.layer.presentation()?.frame ?? cardView.frame

        gifGrid.setSearching(false)
        onWillCollapseGifSearch()

        if let scene = hostWin?.windowScene {
            let maxLevel = scene.windows.map(\.windowLevel.rawValue).max() ?? 10_000_001
            let cw = PassthroughWindow(windowScene: scene)
            cw.frame = hostWin?.bounds ?? UIScreen.main.bounds
            cw.windowLevel = UIWindow.Level(rawValue: maxLevel + 1)
            cw.backgroundColor = .clear
            cw.overrideUserInterfaceStyle = hostWin?.overrideUserInterfaceStyle ?? .unspecified
            cw.targetView = cardView
            cw.onTouch = { [weak self] in self?.onTouch() }
            cw.isHidden = false
            collapseWindow?.isHidden = true
            collapseWindow = cw

            UIView.performWithoutAnimation {
                cw.addSubview(cardView)
                cardView.frame = currentFrame
                cardView.layoutIfNeeded()
                searchOverlay?.removeFromSuperview()
                searchOverlay = nil
            }
        }

        onRestorePanelFocus()

        let winBounds = hostWin?.bounds ?? UIScreen.main.bounds
        let targetH = bounds.height > 0 ? bounds.height : height
        let collapsedFrame = CGRect(x: 0, y: winBounds.height - targetH, width: winBounds.width, height: targetH)

        UIView.animate(withDuration: 0.36, delay: 0, usingSpringWithDamping: 0.92, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.cardView.frame = collapsedFrame
            self.layoutCardSubviews()
            self.cardView.layoutIfNeeded()
        } completion: { [weak self] _ in
            guard let self, self.transitionGen == gen, !self.searchingGifs else { return }
            UIView.performWithoutAnimation {
                self.backdrop.isHidden = true
                self.addSubview(self.cardView)
                self.cardView.frame = self.bounds
                self.layoutCardSubviews()
                self.cardView.layoutIfNeeded()
                self.searchOverlay?.removeFromSuperview()
                self.searchOverlay = nil
                self.collapseWindow?.isHidden = true
                self.collapseWindow = nil
            }
            self.onDidCollapseGifSearch()
        }
    }

    func tearDownSearchOverlay() {
        transitionGen += 1
        searchingGifs = false
        gifGrid.setSearching(false)
        if gifGrid.searchField.isFirstResponder {
            _ = gifGrid.searchField.resignFirstResponder()
        }
        backdrop.isHidden = true
        if cardView.superview !== self {
            addSubview(cardView)
            cardView.frame = bounds
            layoutCardSubviews()
        }
        searchOverlay?.removeFromSuperview()
        searchOverlay = nil
        collapseWindow?.isHidden = true
        collapseWindow = nil
    }

    // MARK: Data

    @MainActor func reload() {
        let store = StickerStore.shared
        var s: [Section] = [Section(shelf: .recents, stickers: store.recents)]
        if !store.favorites.isEmpty { s.append(Section(shelf: .favorites, stickers: store.favorites)) }
        for p in store.packs { s.append(Section(shelf: .pack(p), stickers: p.stickers)) }
        sections = s
        let anyMine = !store.recents.isEmpty || !store.favorites.isEmpty
        editButton.isHidden = !anyMine || tabs.selectedSegmentIndex == 0
        if editing && !anyMine { endEditing() }
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
        markedStrip = -1
        markStrip(0)
    }

    private func layoutStrip() {
        var x = M.side
        let y = (M.stripH - M.stripCell) / 2
        for b in stripButtons {
            b.frame = CGRect(x: x, y: y, width: M.stripCell, height: M.stripCell)
            x += M.stripCell + M.stripSpacing
        }
        if stripButtons.indices.contains(markedStrip) {
            stripHighlight.frame = stripButtons[markedStrip].frame.insetBy(dx: 4, dy: 4)
        }
        strip.contentSize = CGSize(width: x + M.side - M.stripSpacing, height: M.stripH)
    }

    private var markedStrip = -1
    /// One small highlight that slides between packs (owner 2026-10-17: the full-cell one looked big).
    private let stripHighlight: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.label.withAlphaComponent(0.1)
        v.layer.cornerRadius = 9
        v.layer.cornerCurve = .continuous
        v.isUserInteractionEnabled = false
        return v
    }()
    private func markStrip(_ i: Int) {
        guard i != markedStrip else { return }
        let first = markedStrip < 0
        markedStrip = i
        if stripHighlight.superview !== strip { strip.insertSubview(stripHighlight, at: 0) }
        if stripButtons.indices.contains(i) {
            let to = stripButtons[i].frame.insetBy(dx: 4, dy: 4)
            if first { stripHighlight.frame = to }
            else { UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState]) { self.stripHighlight.frame = to } }
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
        // ⛔ THE TABS AND THE PACK STRIP GET OUT OF THE WAY — owner 2026-10-17: scrolling into the
        // stickers hides them, scrolling back shows them. Only a drag moves them, so a layout pass or
        // the strip's own jump never flickers them.
        guard sv.isTracking || sv.isDecelerating else { lastY = sv.contentOffset.y; return }
        let y = sv.contentOffset.y, dy = y - lastY
        lastY = y
        if y <= 0 { setHeaderHidden(false) }
        else if dy > 6 { setHeaderHidden(true) }
        else if dy < -6 { setHeaderHidden(false) }
    }

    private var lastY: CGFloat = 0
    private var headerHidden = false

    private func setHeaderHidden(_ hide: Bool) {
        guard hide != headerHidden else { return }
        headerHidden = hide
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.layoutCardSubviews()
        }
    }

    // MARK: Tabs

    /// GIFs show in the panel itself now (owner 2026-10-17).
    @objc private func tabChanged() {
        UISelectionFeedbackGenerator().selectionChanged()
        let gifsOn = tabs.selectedSegmentIndex == 0
        if gifsOn { if editing { endEditing() }; gifGrid.loadIfNeeded() }
        UIView.transition(with: cardView, duration: 0.18, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.gifGrid.isHidden = !gifsOn
            self.grid.isHidden = gifsOn
            self.strip.isHidden = gifsOn
            self.editButton.isHidden = gifsOn || (StickerStore.shared.recents.isEmpty && StickerStore.shared.favorites.isEmpty)
        }
        setNeedsLayout()
    }

    // MARK: Editing

    @objc private func editTapped() {
        if editing { endEditing() } else { beginEditing() }
    }

    private func setPen() {
        let name = editing ? "checkmark" : "pencil"
        editButton.setImage(UIImage(systemName: name,
                                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)), for: .normal)
        editButton.tintColor = editing ? .systemBlue : .secondaryLabel
        editButton.accessibilityLabel = editing ? "Done" : "Edit stickers"
    }

    private func beginEditing() {
        editing = true
        picked = []
        deleteBar.isHidden = false
        setPen()
        updateDeleteButton()
        setNeedsLayout()
        grid.reloadData()
    }

    private func endEditing() {
        editing = false
        picked = []
        deleteBar.isHidden = true
        setPen()
        setNeedsLayout()
        grid.reloadData()
    }

    private func updateDeleteButton() {
        deleteButton.setTitle(picked.isEmpty ? "Delete" : "Delete (\(picked.count))", for: .normal)
        deleteButton.isEnabled = !picked.isEmpty
    }

    /// Recents lose the sticker from Recents only; Favorites lose it (and its file, for one I made).
    @objc @MainActor private func deleteTapped() {
        guard editing, !picked.isEmpty else { return }
        let ids = { (k: String) in Set(self.picked.filter { $0.hasPrefix(k + "|") }.map { String($0.dropFirst(2)) }) }
        let recents = ids(Shelf.recents.key), favorites = ids(Shelf.favorites.key)
        if !recents.isEmpty { StickerStore.shared.removeFromRecents(recents) }
        if !favorites.isEmpty { StickerStore.shared.removeFavorites(favorites) }
        endEditing()
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
        h.edit.isHidden = true   // the one pen beside the tabs edits every shelf (2026-10-17)
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
        c.setChecking(editing && shelf.editable, on: picked.contains("\(shelf.key)|\(s.id)"))
        c.accessibilityLabel = "Sticker \(s.emoji)"
        return c
    }

    /// Long press (owner 2026-10-17): Add to / Remove from Favorites on every sticker; Delete only on one
    /// I made — the packs are everyone's and cannot be deleted.
    func collectionView(_ cv: UICollectionView, contextMenuConfigurationForItemsAt ips: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard !editing, let ip = ips.first, !isCreate(ip), let s = sticker(at: ip) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            MainActor.assumeIsolated {
                let store = StickerStore.shared
                var items: [UIMenuElement] = []
                if store.isFavorite(s) {
                    items.append(UIAction(title: "Remove from Favorites", image: UIImage(systemName: "star.slash")) { [weak self] _ in
                        store.removeFavorites([s.id]); self?.reload()
                    })
                } else {
                    items.append(UIAction(title: "Add to Favorites", image: UIImage(systemName: "star")) { [weak self] _ in
                        store.addFavorite(s); self?.reload()
                    })
                }
                if s.source == .mine {
                    items.append(UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                        store.removeFavorites([s.id]); store.removeFromRecents([s.id]); self?.reload()
                    })
                }
                return UIMenu(children: items)
            }
        }
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
            if !editing { onCreate() }
            return
        }
        guard let s = sticker(at: ip) else { return }
        if editing {
            let shelf = sections[ip.section].shelf
            guard shelf.editable else { return }
            let k = "\(shelf.key)|\(s.id)"
            if picked.contains(k) { picked.remove(k) } else { picked.insert(k) }
            (cv.cellForItem(at: ip) as? StickerCell)?.setChecking(true, on: picked.contains(k))
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

private final class PassthroughOverlayView: UIView {
    weak var targetView: UIView?
    var onTouch: () -> Void = {}
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let target = targetView else { return nil }
        let p = convert(point, to: target)
        guard target.bounds.contains(p) else { return nil }
        onTouch()
        return super.hitTest(point, with: event)
    }
}

private final class PassthroughWindow: UIWindow {
    weak var targetView: UIView?
    var onTouch: () -> Void = {}
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let target = targetView else { return nil }
        let p = convert(point, to: target)
        guard target.bounds.contains(p) else { return nil }
        onTouch()
        return super.hitTest(point, with: event)
    }
}

