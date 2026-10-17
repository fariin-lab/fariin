import UIKit
import ImageIO

// ⛔ GIFs INSIDE THE PANEL — owner 2026-10-17: "when I tap the GIFs tab don't open a sheet, show me the
// GIFs". Trending GIFs in the keyboard's own space; a GIF animates only while its cell is on screen,
// through Core Animation (CGAnimateImageDataWithBlock), never a SwiftUI repeat.
// ⛔ 2026-10-17 GIF SEARCH IN PLACE: tapping "Search GIFs" expands the same GIF/Sticker keyboard sheet
// to full screen without dismissing the keyboard or opening a separate sheet; tapping X smoothly
// collapses the sheet back to its original keyboard height.

final class PanelGifGrid: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UITextFieldDelegate {
    var onSend: (GiphyService.Gif) -> Void = { _ in }
    var onSearch: () -> Void = {}
    var onCancelSearch: () -> Void = {}
    var onSearchFieldEnded: () -> Void = {}
    /// Room under the last row for the panel's floating GIFs | Stickers switch (or the keyboard while searching).
    var bottomRoom: CGFloat = 0 { didSet { if oldValue != bottomRoom { setNeedsLayout() } } }

    private var gifs: [GiphyService.Gif] = []
    private var trendingGifs: [GiphyService.Gif] = []
    private var loaded = false
    private(set) var searching = false
    private var searchTask: Task<Void, Never>?

    private let search = UIButton(type: .system)
    private let searchPill = UIView()
    private let searchIcon = UIImageView(image: UIImage(systemName: "magnifyingglass"))
    let searchField = UITextField()
    private let cancelButton = OutsetHitButton(type: .system)
    private let grid: UICollectionView

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

        grid.backgroundColor = .clear
        grid.dataSource = self
        grid.delegate = self
        grid.alwaysBounceVertical = true
        grid.register(GifCell.self, forCellWithReuseIdentifier: GifCell.id)
        addSubview(grid)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var lastGridWidth: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        if searching {
            let barY: CGFloat = 8
            let xSize: CGFloat = 36
            let gap: CGFloat = 8
            let pillW = max(0, w - 20 - xSize - gap)
            search.frame = CGRect(x: 10, y: barY, width: pillW, height: 36)
            search.alpha = 0
            searchPill.frame = CGRect(x: 10, y: barY, width: pillW, height: 36)
            searchPill.alpha = 1
            cancelButton.bounds = CGRect(x: 0, y: 0, width: xSize, height: xSize)
            cancelButton.center = CGPoint(x: w - 10 - xSize / 2, y: barY + 18)
            cancelButton.alpha = 1
            cancelButton.transform = .identity
            let top = barY + 36 + 8
            grid.frame = CGRect(x: 0, y: top, width: w, height: max(0, bounds.height - top))
        } else {
            search.frame = CGRect(x: 10, y: 4, width: w - 20, height: 36)
            search.alpha = 1
            searchPill.frame = search.frame
            searchPill.alpha = 0
            cancelButton.bounds = CGRect(x: 0, y: 0, width: 36, height: 36)
            cancelButton.center = CGPoint(x: w - 10 + 18, y: 4 + 18)
            cancelButton.alpha = 0
            cancelButton.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
            grid.frame = CGRect(x: 0, y: 46, width: w, height: max(0, bounds.height - 46))
        }
        searchIcon.frame = CGRect(x: 12, y: 9, width: 18, height: 18)
        searchField.frame = CGRect(x: 36, y: 0, width: max(0, searchPill.bounds.width - 42), height: 36)
        grid.contentInset.bottom = max(safeAreaInsets.bottom, 8) + bottomRoom
        if lastGridWidth != w {
            lastGridWidth = w
            grid.collectionViewLayout.invalidateLayout()
        }
    }

    func setSearching(_ on: Bool) {
        guard searching != on else { return }
        searching = on
        searchPill.isUserInteractionEnabled = on
        search.isUserInteractionEnabled = !on
        if !on {
            searchTask?.cancel()
            searchTask = nil
            if !(searchField.text ?? "").isEmpty {
                searchField.text = ""
                if !trendingGifs.isEmpty {
                    gifs = trendingGifs
                    grid.reloadData()
                }
            }
        }
        setNeedsLayout()
    }

    func focusSearchField() {
        _ = searchField.becomeFirstResponder()
    }

    @objc private func searchTextChanged() {
        searchTask?.cancel()
        let q = (searchField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            gifs = trendingGifs
            grid.reloadData()
            return
        }
        searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            let cur = (self.searchField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard cur == q else { return }
            let list = await GiphyService.shared.search(q)
            guard !Task.isCancelled else { return }
            let after = (self.searchField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard after == q else { return }
            self.gifs = list
            self.grid.reloadData()
            self.grid.setContentOffset(.zero, animated: false)
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        searchTask?.cancel()
        let q = (textField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        searchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let list = await GiphyService.shared.search(q)
            guard !Task.isCancelled else { return }
            self.gifs = list
            self.grid.reloadData()
            self.grid.setContentOffset(.zero, animated: false)
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
        if gifs.isEmpty, !GifPickerView.trendingCache.isEmpty {
            trendingGifs = GifPickerView.trendingCache
            gifs = trendingGifs
            grid.reloadData()
        }
        Task { @MainActor [weak self] in
            let list = await GiphyService.shared.search("")
            guard let self, !list.isEmpty else { return }
            self.trendingGifs = list
            GifPickerView.trendingCache = list
            let q = (self.searchField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if q.isEmpty {
                self.gifs = list
                self.grid.reloadData()
            }
        }
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
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let gif = gifs[ip.item]
        GifRecents.note(gif)
        onSend(gif)
        if searching { onCancelSearch() }
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
