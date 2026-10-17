import UIKit
import ImageIO

// ⛔ GIFs INSIDE THE PANEL — owner 2026-10-17: "when I tap the GIFs tab don't open a sheet, show me the
// GIFs". Trending GIFs in the keyboard's own space; a GIF animates only while its cell is on screen,
// through Core Animation (CGAnimateImageDataWithBlock), never a SwiftUI repeat. Searching needs real
// keys, so the Search pill hands over to the existing GIF picker.

final class PanelGifGrid: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    var onSend: (GiphyService.Gif) -> Void = { _ in }
    var onSearch: () -> Void = {}

    private var gifs: [GiphyService.Gif] = []
    private var loaded = false
    private let search = UIButton(type: .system)
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
        grid.backgroundColor = .clear
        grid.dataSource = self
        grid.delegate = self
        grid.register(GifCell.self, forCellWithReuseIdentifier: GifCell.id)
        addSubview(grid)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        search.frame = CGRect(x: 10, y: 4, width: bounds.width - 20, height: 36)
        grid.frame = CGRect(x: 0, y: 46, width: bounds.width, height: max(0, bounds.height - 46))
        grid.contentInset.bottom = safeAreaInsets.bottom
        grid.collectionViewLayout.invalidateLayout()
    }

    /// First showing: fetch trending once.
    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        Task { @MainActor [weak self] in
            let list = await GiphyService.shared.search("")
            guard let self else { return }
            self.gifs = list
            self.grid.reloadData()
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
        onSend(gifs[ip.item])
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
