import UIKit

/// One card above the field, inside the pill: "Reply to …" with the quoted content, "Edit Message"
/// with the old text, or the link preview (thumb · title · description · host). Full pill width so
/// the X sits at the far right, a hairline divider underneath. Same paddings as before:
/// 14 leading, 12 trailing, 8 vertical.
final class ComposerBannerView: UIView {
    private enum M {
        static let leading: CGFloat = 14, trailing: CGFloat = 12, vertical: CGFloat = 8
        static let spacing: CGFloat = 10
        static let barW: CGFloat = 3, barH: CGFloat = 34
        static let thumb: CGFloat = 36, linkThumb: CGFloat = 44
        static let close: CGFloat = 24
        static let dividerInset: CGFloat = 12
        static let title = UIFont.systemFont(ofSize: 12, weight: .semibold)   // .caption.weight(.semibold)
        static let caption = UIFont.systemFont(ofSize: 12)
        static let caption2 = UIFont.systemFont(ofSize: 11)
    }

    var onClose: () -> Void = {}
    private var banner: ChatComposerBanner?

    private let bar = UIView()
    private let pencil = UIImageView(image: UIImage(systemName: "pencil",
                                                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)))
    private let thumb = ThumbImageView(frame: .zero)
    private let title = UILabel()
    private let detailIcon = UIImageView()
    private let bars = MiniBarsView()
    private let detail = UILabel()
    private let foot = UILabel()
    private let close = IconButton(image: UIImage(systemName: "xmark.circle.fill",
                                                  withConfiguration: UIImage.SymbolConfiguration(pointSize: 20)),
                                   size: CGSize(width: 24, height: 24))
    private let divider = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        bar.layer.cornerRadius = 1.5
        pencil.contentMode = .center
        addSubview(bar)
        addSubview(pencil)
        addSubview(thumb)
        title.font = M.title
        title.lineBreakMode = .byTruncatingTail
        addSubview(title)
        detailIcon.contentMode = .center
        detailIcon.tintColor = .secondaryLabel
        addSubview(detailIcon)
        addSubview(bars)
        detail.textColor = .secondaryLabel
        detail.lineBreakMode = .byTruncatingTail
        addSubview(detail)
        foot.font = M.caption2
        foot.textColor = .tertiaryLabel
        foot.lineBreakMode = .byTruncatingTail
        addSubview(foot)
        close.icon.tintColor = .secondaryLabel
        close.addAction(UIAction { [weak self] _ in self?.onClose() }, for: .touchUpInside)
        addSubview(close)
        divider.backgroundColor = .separator
        addSubview(divider)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Size

    private static func contentHeight(for b: ChatComposerBanner) -> CGFloat {
        switch b.style {
        case .reply: return b.thumb != nil ? M.thumb : M.barH
        case .edit:  return M.barH
        case .link:
            var text = ceil(M.title.lineHeight)
            if case .text(let d) = b.detail, !d.isEmpty { text += 2 + ceil(M.caption2.lineHeight) }
            if b.footnote != nil { text += 2 + ceil(M.caption2.lineHeight) }
            return max(b.thumb != nil ? M.linkThumb : 0, text)
        }
    }

    /// The card's full height: content, the two 8s, and the divider.
    static func height(for b: ChatComposerBanner) -> CGFloat {
        contentHeight(for: b) + 2 * M.vertical + Theme.hairline
    }

    // MARK: - Content

    func configure(_ b: ChatComposerBanner, accent: UIColor) {
        banner = b
        bar.isHidden = b.style == .link
        bar.backgroundColor = accent
        pencil.isHidden = b.style != .edit
        pencil.tintColor = accent
        thumb.isHidden = b.thumb == nil
        thumb.load(b.thumb)
        title.text = b.title
        title.textColor = b.style == .link ? .label : accent
        switch b.detail {
        case .text(let t):
            detailIcon.isHidden = true
            bars.isHidden = true
            detail.text = t
            detail.font = b.style == .link ? M.caption2 : M.caption
            detail.isHidden = t.isEmpty
        case .labelled(let symbol, let t):
            detailIcon.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 11))
            detailIcon.isHidden = false
            bars.isHidden = true
            detail.text = t
            detail.font = M.caption
            detail.isHidden = false
        case .voice(let stored, let duration):
            detailIcon.image = UIImage(systemName: "mic.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11))
            detailIcon.isHidden = false
            bars.bars = stored
            bars.isHidden = false
            detail.text = duration
            detail.font = M.caption2
            detail.isHidden = false
        }
        foot.text = b.footnote
        foot.isHidden = b.footnote == nil
        setNeedsLayout()
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let b = banner else { return }
        let W = bounds.width
        let content = Self.contentHeight(for: b)
        let mid = M.vertical + content / 2
        var x = M.leading
        if !bar.isHidden {
            bar.frame = CGRect(x: x, y: mid - M.barH / 2, width: M.barW, height: M.barH)
            x += M.barW + M.spacing
        }
        if !pencil.isHidden {
            pencil.frame = CGRect(x: x, y: mid - 10, width: 18, height: 20)
            x += 18 + M.spacing
        }
        if !thumb.isHidden {
            let s = b.style == .link ? M.linkThumb : M.thumb
            thumb.frame = CGRect(x: x, y: mid - s / 2, width: s, height: s)
            x += s + M.spacing
        }
        close.frame = CGRect(x: W - M.trailing - M.close, y: mid - M.close / 2, width: M.close, height: M.close)
        let right = close.frame.minX - 8
        let colW = max(0, right - x)

        // The text column: title, then the detail row, then the host — centred against the bar/thumb.
        let titleH = ceil(M.title.lineHeight)
        let detailH = detail.isHidden ? 0 : ceil(max(detail.font.lineHeight, bars.isHidden ? 0 : 14))
        let footH = foot.isHidden ? 0 : ceil(M.caption2.lineHeight)
        var colH = titleH
        if detailH > 0 { colH += 2 + detailH }
        if footH > 0 { colH += 2 + footH }
        var y = mid - colH / 2
        title.frame = CGRect(x: x, y: y, width: colW, height: titleH)
        y += titleH
        if detailH > 0 {
            y += 2
            var dx = x
            if !detailIcon.isHidden {
                detailIcon.frame = CGRect(x: dx, y: y, width: 14, height: detailH)
                dx += 14 + (bars.isHidden ? 4 : 6)
            }
            if !bars.isHidden {
                bars.frame = CGRect(x: dx, y: y + (detailH - 14) / 2, width: 72, height: 14)
                dx += 72 + 6
            }
            detail.frame = CGRect(x: dx, y: y, width: max(0, right - dx), height: detailH)
            y += detailH
        }
        if footH > 0 {
            y += 2
            foot.frame = CGRect(x: x, y: y, width: colW, height: footH)
        }
        divider.frame = CGRect(x: M.dividerInset, y: bounds.height - Theme.hairline,
                               width: max(0, W - 2 * M.dividerInset), height: Theme.hairline)
    }
}

/// The 36pt (44 for a link) rounded thumbnail. A chat photo comes from `DiskImageCache`, where the
/// bubble put it; a GIF from `GifBytesCache`; a link image arrives decoded.
final class ThumbImageView: UIImageView {
    private var key = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .scaleAspectFill
        clipsToBounds = true
        layer.cornerRadius = 7
        layer.cornerCurve = .continuous
        backgroundColor = .secondarySystemFill
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func load(_ t: ChatComposerBanner.Thumb?) {
        guard let t else { key = ""; image = nil; return }
        switch t {
        case .image(let img):
            key = "image"
            image = img
        case .cached(let url):
            guard key != url else { return }
            key = url
            if let m = DiskImageCache.shared.memoryImage(url) { image = m; return }
            image = nil
            Task { [weak self] in
                let img = await DiskImageCache.shared.image(for: url)
                await MainActor.run {
                    guard let self, self.key == url else { return }
                    self.image = img
                }
            }
        case .gif(let url):
            guard key != url else { return }
            key = url
            image = GifBytesCache.data(url).flatMap { UIImage.animatedGif(data: $0) }
        }
    }
}

/// The quoted voice note's bars in the reply card: `WaveformBars` at progress 0, 72×14. The first
/// bar is "played" (full secondary), the rest at half, which is what progress 0 drew.
final class MiniBarsView: UIView {
    var bars: [Int] = [] { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        let size = bounds.size
        guard size.width > 0, !bars.isEmpty else { return }
        let maxBars = max(8, Int(size.width / 4))
        let step = max(1, Int((Double(bars.count) / Double(maxBars)).rounded(.up)))
        var drawn: [Int] = []
        var b = 0
        while b < bars.count {
            drawn.append(bars[b..<min(b + step, bars.count)].max() ?? 0)
            b += step
        }
        let count = max(drawn.count, 1)
        let slot = size.width / CGFloat(count)
        let barW = max(2, slot * 0.5)
        for (i, v) in drawn.enumerated() {
            let h = max(2, WaveformBars.display(v) * size.height)
            let x = CGFloat(i) * slot + (slot - barW) / 2
            (i == 0 ? UIColor.secondaryLabel : UIColor.secondaryLabel.withAlphaComponent(0.5)).setFill()
            UIBezierPath(roundedRect: CGRect(x: x, y: (size.height - h) / 2, width: barW, height: h),
                         cornerRadius: barW / 2).fill()
        }
    }
}
