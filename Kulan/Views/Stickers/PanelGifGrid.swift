import UIKit
import ImageIO

// ⛔ GIFs INSIDE THE PANEL — owner 2026-10-17: "when I tap the GIFs tab don't open a sheet, show me the
// GIFs". Trending GIFs in the keyboard's own space; a GIF animates only while its cell is on screen,
// through Core Animation (CGAnimateImageDataWithBlock), never a SwiftUI repeat.
// ⛔ GIF SEARCH IN PLACE — owner 2026-10-18 (first built 2026-10-17 in 5775aae8, reverted, asked for
// again): tapping "Search GIFs" grows this same GIF/Sticker sheet to full screen without dropping the
// keyboard or opening another sheet; X shrinks it back to the panel's own height. The search field
// lives here; `StickerKeyboardView` moves the sheet, see `expandForGifSearch`.
// ⛔ RECENT AND FAVORITES — owner 2026-10-18: a small strip under the search bar like the sticker
// side's (his clock and star icons), then Trending. Recent = GIFs I sent (`GifRecents`), Favorites =
// held a GIF and picked Add to Favorites (`GifFavorites`). Both local to this phone and account.

final class PanelGifGrid: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UITextFieldDelegate {
    var onSend: (GiphyService.Gif) -> Void = { _ in }
    var onSearch: () -> Void = {}
    var onCancelSearch: () -> Void = {}
    var onSearchFieldEnded: () -> Void = {}
    /// Room under the last row for the panel's floating GIFs | Stickers switch (or the keyboard while searching).
    var bottomRoom: CGFloat = 0 { didSet { if oldValue != bottomRoom { setNeedsLayout() } } }

    private enum Shelf: Int { case recent, favorites, trending }
    private var shelf: Shelf = .trending

    private var gifs: [GiphyService.Gif] = []
    private var trendingGifs: [GiphyService.Gif] = []
    private var loaded = false
    private(set) var searching = false
    private var searchTask: Task<Void, Never>?
    /// True once a typed search has come back, so an empty grid reads "nothing found", not "loading".
    private var searchAnswered = false

    private let search = UIButton(type: .system)
    private let searchPill = UIView()
    private let searchIcon = UIImageView(image: UIImage(systemName: "magnifyingglass"))
    let searchField = UITextField()
    private let cancelButton = OutsetHitButton(type: .system)
    private let strip = UIView()
    private var stripButtons: [UIButton] = []
    private let stripHighlight = UIView()
    private let emptyLabel = UILabel()
    private let grid: UICollectionView

    // The sticker strip's numbers (StickerKeyboardView.M): 40 pt cells, 4 apart, a 44 pt row.
    private enum M {
        static let barY: CGFloat = 4, barH: CGFloat = 36
        static let stripH: CGFloat = 44, stripCell: CGFloat = 40, stripSpacing: CGFloat = 4, side: CGFloat = 10
    }

    override init(frame: CGRect) {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 4
        layout.minimumLineSpacing = 4
        grid = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        var cfg = UIButton.Configuration.gray()
        cfg.title = "Search GIFs"
        cfg.image = UIImage(systemName: "magnifyingglass")
        cfg.imagePadding = 6
        cfg.cornerStyle = .capsule
        cfg.baseForegroundColor = .secondaryLabel
        search.configuration = cfg
        search.addAction(UIAction { [weak self] _ in self?.onSearch() }, for: .touchUpInside)
        addSubview(search)

        // Active search capsule: same 36pt gray capsule look as the resting button, with X beside it.
        searchPill.backgroundColor = .tertiarySystemFill
        searchPill.layer.cornerRadius = 18
        searchPill.layer.cornerCurve = .continuous
        searchPill.alpha = 0
        searchPill.isUserInteractionEnabled = false
        searchIcon.tintColor = .secondaryLabel
        searchIcon.contentMode = .scaleAspectFit
        searchPill.addSubview(searchIcon)

        searchField.font = .systemFont(ofSize: 16)
        searchField.textColor = .label
        searchField.tintColor = .label
        searchField.attributedPlaceholder = NSAttributedString(
            string: "Search GIFs",
            attributes: [.foregroundColor: UIColor.secondaryLabel]
        )
        searchField.returnKeyType = .search
        searchField.clearButtonMode = .whileEditing
        searchField.autocorrectionType = .no
        searchField.autocapitalizationType = .none
        searchField.delegate = self
        searchField.addTarget(self, action: #selector(searchTextChanged), for: .editingChanged)
        searchPill.addSubview(searchField)
        addSubview(searchPill)

        var xCfg = UIButton.Configuration.gray()
        xCfg.cornerStyle = .capsule
        xCfg.contentInsets = .zero
        xCfg.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        xCfg.baseForegroundColor = .secondaryLabel
        cancelButton.configuration = xCfg
        cancelButton.hitOutset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 10)
        cancelButton.accessibilityLabel = "Cancel search"
        cancelButton.alpha = 0
        cancelButton.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
        cancelButton.addAction(UIAction { [weak self] _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            self?.onCancelSearch()
        }, for: .touchUpInside)
        addSubview(cancelButton)

        buildStrip()
        addSubview(strip)

        grid.backgroundColor = .clear
        grid.dataSource = self
        grid.delegate = self
        grid.alwaysBounceVertical = true
        grid.register(GifCell.self, forCellWithReuseIdentifier: GifCell.id)
        addSubview(grid)

        emptyLabel.font = .systemFont(ofSize: 15)
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.isHidden = true
        emptyLabel.isUserInteractionEnabled = false
        addSubview(emptyLabel)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var lastGridWidth: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        let gridTop: CGFloat
        if searching {
            let barY: CGFloat = 8
            let xSize: CGFloat = 36
            let gap: CGFloat = 8
            let pillW = max(0, w - 20 - xSize - gap)
            search.frame = CGRect(x: 10, y: barY, width: pillW, height: M.barH)
            search.alpha = 0
            searchPill.frame = CGRect(x: 10, y: barY, width: pillW, height: M.barH)
            searchPill.alpha = 1
            cancelButton.bounds = CGRect(x: 0, y: 0, width: xSize, height: xSize)
            cancelButton.center = CGPoint(x: w - 10 - xSize / 2, y: barY + 18)
            cancelButton.alpha = 1
            cancelButton.transform = .identity
            // The strip steps aside while searching: the results are the whole page.
            strip.frame = CGRect(x: 0, y: barY + M.barH + 4, width: w, height: M.stripH)
            strip.alpha = 0
            gridTop = barY + M.barH + 8
        } else {
            search.frame = CGRect(x: 10, y: M.barY, width: w - 20, height: M.barH)
            search.alpha = 1
            searchPill.frame = search.frame
            searchPill.alpha = 0
            cancelButton.bounds = CGRect(x: 0, y: 0, width: 36, height: 36)
            cancelButton.center = CGPoint(x: w - 10 + 18, y: M.barY + 18)
            cancelButton.alpha = 0
            cancelButton.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
            strip.frame = CGRect(x: 0, y: M.barY + M.barH + 2, width: w, height: M.stripH)
            strip.alpha = 1
            gridTop = strip.frame.maxY + 2
        }
        strip.isUserInteractionEnabled = !searching
        layoutStrip()
        searchIcon.frame = CGRect(x: 12, y: 9, width: 18, height: 18)
        searchField.frame = CGRect(x: 36, y: 0, width: max(0, searchPill.bounds.width - 42), height: 36)
        grid.frame = CGRect(x: 0, y: gridTop, width: w, height: max(0, bounds.height - gridTop))
        grid.contentInset.bottom = max(safeAreaInsets.bottom, 8) + bottomRoom
        emptyLabel.frame = CGRect(x: 32, y: gridTop + 28, width: max(0, w - 64), height: 60)
        if lastGridWidth != w {
            lastGridWidth = w
            grid.collectionViewLayout.invalidateLayout()
        }
    }

    // MARK: Recent / Favorites / Trending strip

    private func buildStrip() {
        stripHighlight.backgroundColor = UIColor.label.withAlphaComponent(0.1)
        stripHighlight.layer.cornerRadius = 9
        stripHighlight.layer.cornerCurve = .continuous
        stripHighlight.isUserInteractionEnabled = false
        strip.addSubview(stripHighlight)
        let items: [(Shelf, UIImage?, String)] = [
            // His icons (owner 2026-10-18), the same two the sticker strip uses.
            (.recent, UIImage(named: "ic_clock_outline")?.withRenderingMode(.alwaysTemplate), "Recent GIFs"),
            (.favorites, UIImage(named: "ic_star_outline")?.withRenderingMode(.alwaysTemplate), "Favorite GIFs"),
            // No asset of his for this one; the flame is what the GIF picker's Trending row already uses.
            (.trending, UIImage(systemName: "flame", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)), "Trending GIFs"),
        ]
        for (s, img, label) in items {
            let b = UIButton(type: .system)
            b.tag = s.rawValue
            b.tintColor = .secondaryLabel
            b.setImage(img, for: .normal)
            b.accessibilityLabel = label
            b.layer.cornerRadius = 10
            b.addTarget(self, action: #selector(stripTapped(_:)), for: .touchUpInside)
            strip.addSubview(b)
            stripButtons.append(b)
        }
    }

    private func layoutStrip() {
        var x = M.side
        let y = (M.stripH - M.stripCell) / 2
        for b in stripButtons {
            b.frame = CGRect(x: x, y: y, width: M.stripCell, height: M.stripCell)
            x += M.stripCell + M.stripSpacing
        }
        if stripButtons.indices.contains(shelf.rawValue) {
            stripHighlight.frame = stripButtons[shelf.rawValue].frame.insetBy(dx: 4, dy: 4)
        }
        for b in stripButtons { b.tintColor = b.tag == shelf.rawValue ? .label : .secondaryLabel }
    }

    @objc private func stripTapped(_ b: UIButton) {
        guard let s = Shelf(rawValue: b.tag), s != shelf else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        shelf = s
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.layoutStrip()
        }
        showShelf()
        grid.setContentOffset(CGPoint(x: 0, y: -grid.adjustedContentInset.top), animated: false)
    }

    /// The chosen shelf's GIFs into the grid. Not while a typed search is on screen.
    private func showShelf() {
        guard !hasQuery else { return }
        switch shelf {
        case .recent: gifs = GifRecents.all()
        case .favorites: gifs = GifFavorites.all()
        case .trending: gifs = trendingGifs
        }
        grid.reloadData()
        updateEmpty()
    }

    /// The panel came back on screen: a GIF sent or favorited elsewhere since shows now.
    func refreshLocalShelf() {
        guard shelf != .trending, !searching else { return }
        showShelf()
    }

    private var hasQuery: Bool {
        !(searchField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func updateEmpty() {
        let text: String?
        if !gifs.isEmpty { text = nil }
        else if hasQuery { text = searchAnswered ? "Nothing found. Try another word." : nil }
        else if searching { text = nil }   // trending still on its way
        else {
            switch shelf {
            case .recent: text = "GIFs you send will show up here."
            case .favorites: text = "Hold a GIF and tap Add to Favorites to keep it here."
            case .trending: text = nil
            }
        }
        emptyLabel.text = text
        emptyLabel.isHidden = text == nil
    }

    // MARK: Search

    func setSearching(_ on: Bool) {
        guard searching != on else { return }
        searching = on
        searchPill.isUserInteractionEnabled = on
        search.isUserInteractionEnabled = !on
        if on {
            // The search page opens on Trending, whatever shelf the panel showed.
            if !hasQuery { gifs = trendingGifs; grid.reloadData() }
        } else {
            searchTask?.cancel()
            searchTask = nil
            searchAnswered = false
            searchField.text = ""
            showShelf()
        }
        updateEmpty()
        setNeedsLayout()
    }

    func focusSearchField() {
        _ = searchField.becomeFirstResponder()
    }

    @objc private func searchTextChanged() {
        searchTask?.cancel()
        searchAnswered = false
        let q = (searchField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            gifs = trendingGifs
            grid.reloadData()
            updateEmpty()
            return
        }
        updateEmpty()
        searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            let cur = (self.searchField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard cur == q else { return }
            let list = await GiphyService.shared.search(q)
            guard !Task.isCancelled else { return }
            let after = (self.searchField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard after == q else { return }
            self.showResults(list)
        }
    }

    private func showResults(_ list: [GiphyService.Gif]) {
        searchAnswered = true
        gifs = list
        grid.reloadData()
        grid.setContentOffset(CGPoint(x: 0, y: -grid.adjustedContentInset.top), animated: false)
        updateEmpty()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        searchTask?.cancel()
        let q = (textField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        searchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let list = await GiphyService.shared.search(q)
            guard !Task.isCancelled else { return }
            self.showResults(list)
        }
        return true
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        if searching { onSearchFieldEnded() }
    }

    /// First showing: fetch trending once.
    @MainActor func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if trendingGifs.isEmpty, !GifPickerView.trendingCache.isEmpty {
            trendingGifs = GifPickerView.trendingCache
            if shelf == .trending || searching { showTrendingIfIdle() }
        }
        Task { @MainActor [weak self] in
            let list = await GiphyService.shared.search("")
            guard let self, !list.isEmpty else { return }
            self.trendingGifs = list
            GifPickerView.trendingCache = list
            self.showTrendingIfIdle()
        }
    }

    private func showTrendingIfIdle() {
        guard !hasQuery, shelf == .trending || searching else { return }
        gifs = trendingGifs
        grid.reloadData()
        updateEmpty()
    }

    func collectionView(_ cv: UICollectionView, numberOfItemsInSection s: Int) -> Int { gifs.count }

    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout, sizeForItemAt ip: IndexPath) -> CGSize {
        let w = floor((cv.bounds.width - 10 * 2 - 4 * 2) / 3)
        return CGSize(width: w, height: w)
    }

    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout, insetForSectionAt s: Int) -> UIEdgeInsets {
        UIEdgeInsets(top: 0, left: 10, bottom: 8, right: 10)
    }

    func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
        let c = cv.dequeueReusableCell(withReuseIdentifier: GifCell.id, for: ip) as! GifCell
        c.load(gifs[ip.item].url)
        return c
    }

    func collectionView(_ cv: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt ip: IndexPath) {
        (cell as? GifCell)?.setPlaying(true)
    }

    func collectionView(_ cv: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt ip: IndexPath) {
        (cell as? GifCell)?.setPlaying(false)
    }

    func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) {
        guard gifs.indices.contains(ip.item) else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let gif = gifs[ip.item]
        GifRecents.note(gif)
        onSend(gif)
        if searching { onCancelSearch() }
    }

    /// Long press: Add to / Remove from Favorites on any GIF; Remove from Recent on the Recent shelf.
    func collectionView(_ cv: UICollectionView, contextMenuConfigurationForItemsAt ips: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard let ip = ips.first, gifs.indices.contains(ip.item) else { return nil }
        let g = gifs[ip.item]
        let onRecent = shelf == .recent && !hasQuery && !searching
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            MainActor.assumeIsolated {
                var items: [UIMenuElement] = []
                if GifFavorites.contains(g.url) {
                    items.append(UIAction(title: "Remove from Favorites", image: UIImage(systemName: "star.slash")) { [weak self] _ in
                        GifFavorites.remove(g.url); self?.refreshAfterEdit()
                    })
                } else {
                    items.append(UIAction(title: "Add to Favorites", image: UIImage(systemName: "star")) { [weak self] _ in
                        GifFavorites.add(g); self?.refreshAfterEdit()
                    })
                }
                if onRecent {
                    items.append(UIAction(title: "Remove from Recent", image: UIImage(systemName: "clock.badge.xmark"),
                                          attributes: .destructive) { [weak self] _ in
                        GifRecents.forget(g.url); self?.refreshAfterEdit()
                    })
                }
                return UIMenu(children: items)
            }
        }
    }

    /// Redraw only when the list just edited is the one on screen; Trending and results stay put.
    private func refreshAfterEdit() {
        guard !hasQuery, !searching, shelf != .trending else { return }
        showShelf()
    }
}

private final class GifCell: UICollectionViewCell {
    static let id = "PanelGifCell"
    private let art = CALayer()
    private var url: String?
    private var data: Data?
    private var playing = false
    private var generation = 0     // playback
    private var loadToken = 0      // which url a finished download belongs to

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = UIColor.secondarySystemFill
        contentView.layer.cornerRadius = 8
        contentView.layer.masksToBounds = true
        art.contentsGravity = .resizeAspectFill
        contentView.layer.addSublayer(art)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        art.frame = contentView.bounds
        CATransaction.commit()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        generation += 1
        loadToken += 1
        playing = false
        url = nil; data = nil
        art.contents = nil
    }

    func load(_ u: String) {
        url = u
        let token = loadToken
        guard let link = URL(string: u) else { return }
        Task { @MainActor [weak self] in
            // URLCache (1 GB disk, set at launch) keeps these between openings.
            guard let (d, _) = try? await URLSession.shared.data(from: link) else { return }
            guard let self, self.loadToken == token else { return }
            self.data = d
            if let src = CGImageSourceCreateWithData(d as CFData, nil),
               let first = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                self.art.contents = first
            }
            if self.playing { self.playing = false; self.setPlaying(true) }
        }
    }

    func setPlaying(_ on: Bool) {
        guard on != playing else { return }
        playing = on
        if !on { generation += 1; return }
        guard let d = data else { return }
        let gen = generation
        CGAnimateImageDataWithBlock(d as CFData, nil) { [weak self] _, image, stop in
            guard let self, self.generation == gen, self.playing else { stop.pointee = true; return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self.art.contents = image
            CATransaction.commit()
        }
    }
}
