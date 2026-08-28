import UIKit
import Combine

// ===== The photo / video / gif bubble, drawn =====
//
// The picture wears the bubble's own corners and sits flush against them; the caption, when there
// is one, is flush below it under the SAME background and the same clip. One bubble, never two.
//
// Every rect comes from `MediaPlan`. Nothing here measures anything.

/// An animated GIF, on the app's existing gif pipeline — the same memory cache, the same
/// `GifBytesCache` bytes on disk, the same decode. A second pipeline would re-download every gif
/// the SwiftUI path had already stored.
final class RowGifView: UIImageView {
    private static let cache = NSCache<NSString, UIImage>()
    private var loadedURL: String?
    /// The url whose bytes are actually on screen. `loadedURL` is only what was last REQUESTED, and
    /// a request that fails must not look like a finished picture. See `configure`.
    private var displayedURL: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .scaleAspectFill
        clipsToBounds = true
        backgroundColor = .secondarySystemFill
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(url: String?) {
        guard let url, !url.isEmpty else { loadedURL = nil; displayedURL = nil; image = nil; return }
        // ⛔ THE SENTINEL IS THE REQUEST, THE RETRY GATE IS THE RESULT. `loadedURL` is set BEFORE the
        // fetch so a re-configure mid-flight cannot start a second download — that part is right and
        // stays. But it was also the only thing the guard above consulted, and the network callback
        // has no failure path, so a gif whose fetch failed was a permanently grey box for the life of
        // the view. The comment's stated intent, "a re-configure cannot re-download", is exactly what
        // made it unrecoverable.
        //
        // `displayedURL` records what actually arrived, so a failure is retried on the next
        // configure while an in-flight request is still not duplicated.
        guard url != displayedURL else { return }
        guard url != loadedURL || image == nil else { return }
        loadedURL = url                      // marked BEFORE loading, so a re-configure cannot re-download
        if let hit = Self.cache.object(forKey: url as NSString) { image = hit; displayedURL = url; return }
        if let bytes = GifBytesCache.data(url), let img = UIImage.animatedGif(data: bytes) {
            Self.cache.setObject(img, forKey: url as NSString)
            image = img
            displayedURL = url
            return
        }
        image = nil
        guard let u = URL(string: url) else { return }
        URLSession.shared.dataTask(with: u) { [weak self] data, _, _ in
            guard let data, let img = UIImage.animatedGif(data: data) else { return }
            GifBytesCache.store(data, url)
            Self.cache.setObject(img, forKey: url as NSString)
            DispatchQueue.main.async {
                // The view may have been REUSED for a different gif while this was in flight — only
                // assign if it still wants THIS url, or the old gif overwrites the new one.
                guard let self, self.loadedURL == url else { return }
                self.displayedURL = url
                self.image = img
            }
        }.resume()
    }

    func reset() { loadedURL = nil; displayedURL = nil; image = nil }
}

final class MediaBubbleView: UIView {
    private let picture = RowImageView(frame: .zero)
    private var gif: RowGifView?
    private let playBadge = UIImageView()
    private let durationPill = UIView()
    private let durationLabel = UILabel()
    private let metaCapsule = UIView()
    private let captionLabel = UILabel()
    private var ring: UploadRingView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false     // the cell hit-tests the plan and routes every tap
        addSubview(picture)
        playBadge.contentMode = .scaleAspectFit
        playBadge.tintColor = UIColor.white.withAlphaComponent(0.95)
        playBadge.layer.shadowColor = UIColor.black.cgColor
        playBadge.layer.shadowOpacity = 0.4
        playBadge.layer.shadowRadius = 3
        playBadge.layer.shadowOffset = .zero
        addSubview(playBadge)
        durationPill.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        durationPill.isUserInteractionEnabled = false
        addSubview(durationPill)
        durationLabel.textColor = .white
        durationLabel.textAlignment = .center
        addSubview(durationLabel)
        metaCapsule.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        metaCapsule.isUserInteractionEnabled = false
        addSubview(metaCapsule)
        captionLabel.numberOfLines = 0
        captionLabel.lineBreakMode = .byWordWrapping
        addSubview(captionLabel)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ m: BubbleBody.MediaBody, plan: MediaPlan, cid: String) {
        // The picture. A gif is its own view because it animates; everything else is one image.
        switch m.kind {
        case .gif:
            picture.isHidden = true
            picture.reset()
            let v = gif ?? {
                let v = RowGifView(frame: .zero)
                insertSubview(v, at: 0)
                gif = v
                return v
            }()
            v.isHidden = false
            v.frame = plan.media
            v.configure(url: m.url)
        case .photo, .video:
            gif?.isHidden = true
            gif?.reset()
            picture.isHidden = false
            picture.frame = plan.media
            if let data = m.localData, let ui = UIImage(data: data) {
                // The optimistic local copy, shown before the upload lands. It is the real bytes, so
                // it must beat anything the url would fetch.
                picture.reset()
                picture.image = ui
            } else {
                // A video shows its POSTER, not its file.
                let url = m.kind == .video ? m.posterUrl : m.url
                let enc = m.kind == .video ? m.posterEnc : m.enc
                picture.configure(url: url, enc: enc, cid: cid,
                                  placeholder: InlineThumbCache.image(id: m.thumbCacheId,
                                                                      base64: m.inlineThumbBase64)
                                      ?? m.blurhash.flatMap { BlurHash.decode($0) })
            }
        }

        if let badge = plan.playBadge {
            playBadge.isHidden = false
            playBadge.frame = badge
            playBadge.image = UIImage(systemName: "play.circle.fill",
                                      withConfiguration: UIImage.SymbolConfiguration(pointSize: badge.height))
        } else {
            playBadge.isHidden = true
        }

        if let d = plan.duration, let text = m.durationText {
            durationPill.isHidden = false
            durationLabel.isHidden = false
            durationPill.frame = d
            durationPill.layer.cornerRadius = d.height / 2
            durationLabel.frame = d
            durationLabel.attributedText = NSAttributedString(string: text, attributes: [
                .font: UIFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: UIColor.white])
        } else {
            durationPill.isHidden = true
            durationLabel.isHidden = true
        }

        if let capsule = plan.metaCapsule {
            metaCapsule.isHidden = false
            metaCapsule.frame = capsule
            metaCapsule.layer.cornerRadius = capsule.height / 2
        } else {
            metaCapsule.isHidden = true
        }

        if let rect = plan.captionText, let attr = plan.captionAttr {
            captionLabel.isHidden = false
            captionLabel.frame = rect
            captionLabel.attributedText = attr
        } else {
            captionLabel.isHidden = true
        }

        if let r = plan.uploadRing {
            let v = ring ?? {
                let v = UploadRingView(frame: .zero)
                addSubview(v)
                ring = v
                return v
            }()
            v.isHidden = false
            v.frame = r
            v.clientId = m.clientId
            v.showsCancel = m.cancellable
            v.start()
        } else {
            ring?.stop()
            ring?.isHidden = true
        }
    }

    func prepareForReuse() {
        picture.reset()
        gif?.reset()
        ring?.stop()
    }
}

// ── The album mosaic ──

final class AlbumBubbleView: UIView {
    private var tiles: [AlbumTileView] = []
    private let metaCapsule = UIView()
    private let captionLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        metaCapsule.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        addSubview(metaCapsule)
        captionLabel.numberOfLines = 0
        captionLabel.lineBreakMode = .byWordWrapping
        addSubview(captionLabel)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ a: BubbleBody.AlbumBody, plan: AlbumPlan, cid: String) {
        while tiles.count < plan.tiles.count {
            let v = AlbumTileView()
            insertSubview(v, at: 0)
            tiles.append(v)
        }
        for (i, v) in tiles.enumerated() {
            guard i < plan.tiles.count else { v.isHidden = true; v.reset(); continue }
            v.isHidden = false
            let t = plan.tiles[i]
            v.frame = t.rect.offsetBy(dx: plan.grid.minX, dy: plan.grid.minY)
            v.configure(a.tiles.indices.contains(i) ? a.tiles[i] : nil, tile: t,
                        // The blurhash and the inline thumbnail belong to the FIRST tile only —
                        // they were sealed into the message for the album as a whole.
                        placeholder: i == 0 ? (InlineThumbCache.image(id: a.thumbCacheId,
                                                                      base64: a.inlineThumbBase64)
                                               ?? a.blurhash.flatMap { BlurHash.decode($0) }) : nil,
                        cid: cid, cancellable: a.cancellable)
        }

        if let capsule = plan.metaCapsule {
            metaCapsule.isHidden = false
            metaCapsule.frame = capsule
            metaCapsule.layer.cornerRadius = capsule.height / 2
        } else {
            metaCapsule.isHidden = true
        }
        if let rect = plan.captionText, let attr = plan.captionAttr {
            captionLabel.isHidden = false
            captionLabel.frame = rect
            captionLabel.attributedText = attr
        } else {
            captionLabel.isHidden = true
        }
    }

    /// Which tile is at this point, in this view's coordinates? The album opens the tile you hit,
    /// not the message.
    func tileIndex(at point: CGPoint, plan: AlbumPlan) -> Int? {
        for (i, t) in plan.tiles.enumerated()
        where t.rect.offsetBy(dx: plan.grid.minX, dy: plan.grid.minY).contains(point) {
            return i
        }
        return nil
    }

    func prepareForReuse() { tiles.forEach { $0.reset() } }
}

final class AlbumTileView: UIView {
    private let picture = RowImageView(frame: .zero)
    private let playBadge = UIImageView()
    private let durationPill = UIView()
    private let durationLabel = UILabel()
    private let extraScrim = UIView()
    private let extraLabel = UILabel()
    private var ring: UploadRingView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        addSubview(picture)
        playBadge.contentMode = .scaleAspectFit
        playBadge.tintColor = UIColor.white.withAlphaComponent(0.95)
        addSubview(playBadge)
        durationPill.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        addSubview(durationPill)
        durationLabel.textAlignment = .center
        addSubview(durationLabel)
        extraScrim.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        addSubview(extraScrim)
        extraLabel.textAlignment = .center
        addSubview(extraLabel)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ model: BubbleBody.AlbumBody.Tile?, tile: AlbumPlan.Tile,
                   placeholder: UIImage?, cid: String, cancellable: Bool) {
        let local = CGRect(origin: .zero, size: tile.rect.size)
        picture.frame = local
        if let data = model?.localData, let ui = UIImage(data: data) {
            picture.reset()
            picture.image = ui
        } else {
            picture.configure(url: model?.url, enc: model?.enc, cid: cid, placeholder: placeholder)
        }

        if let b = tile.playBadge {
            playBadge.isHidden = false
            playBadge.frame = b.offsetBy(dx: -tile.rect.minX, dy: -tile.rect.minY)
            playBadge.image = UIImage(systemName: "play.circle.fill",
                                      withConfiguration: UIImage.SymbolConfiguration(pointSize: b.height))
        } else {
            playBadge.isHidden = true
        }

        if let d = tile.duration, let attr = tile.durationAttr {
            let r = d.offsetBy(dx: -tile.rect.minX, dy: -tile.rect.minY)
            durationPill.isHidden = false; durationLabel.isHidden = false
            durationPill.frame = r
            durationPill.layer.cornerRadius = r.height / 2
            durationLabel.frame = r
            durationLabel.attributedText = attr
        } else {
            durationPill.isHidden = true; durationLabel.isHidden = true
        }

        if let attr = tile.extraAttr {
            extraScrim.isHidden = false; extraLabel.isHidden = false
            extraScrim.frame = local
            extraLabel.frame = local
            extraLabel.attributedText = attr
        } else {
            extraScrim.isHidden = true; extraLabel.isHidden = true
        }

        if let r = tile.ring {
            let v = ring ?? {
                let v = UploadRingView(frame: .zero); addSubview(v); ring = v; return v
            }()
            v.isHidden = false
            v.frame = r.offsetBy(dx: -tile.rect.minX, dy: -tile.rect.minY)
            v.clientId = model?.uploadKey
            v.showsCancel = cancellable
            // The X drops THIS item and the album ships without it — so the tile has to say so.
            v.onCancelled = { [weak self] c in self?.picture.alpha = c ? 0.4 : 1 }
            v.start()
        } else {
            picture.alpha = 1
            ring?.stop(); ring?.isHidden = true
        }
    }

    func reset() {
        picture.reset()
        picture.alpha = 1
        ring?.stop()
    }
}

// ── A document ──

final class FileBubbleView: UIView {
    private let preview = RowImageView(frame: .zero)
    private let glyph = UIImageView()
    private let nameLabel = UILabel()
    private let sizeLabel = UILabel()
    private var spinner: UIActivityIndicatorView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        preview.layer.cornerRadius = 7
        preview.layer.cornerCurve = .continuous
        preview.layer.borderWidth = 0.5
        preview.layer.borderColor = UIColor.black.withAlphaComponent(0.12).cgColor
        preview.backgroundColor = .white
        addSubview(preview)
        glyph.contentMode = .center
        addSubview(glyph)
        nameLabel.lineBreakMode = .byTruncatingTail
        sizeLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)
        addSubview(sizeLabel)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ f: BubbleBody.FileBody, plan: FilePlan, tint: UIColor, cid: String) {
        if plan.slotIsPreview {
            preview.isHidden = false
            glyph.isHidden = true
            preview.frame = plan.slot
            if let data = f.localPreview, let ui = UIImage(data: data) {
                preview.reset()
                preview.image = ui
            } else {
                preview.configure(url: f.previewUrl, enc: f.previewEnc, cid: cid, cornerRadius: 7)
            }
        } else {
            preview.isHidden = true
            preview.reset()
            glyph.isHidden = false
            glyph.frame = plan.slot
            glyph.image = UIImage(systemName: "doc.fill",
                                  withConfiguration: UIImage.SymbolConfiguration(pointSize: 26))
            glyph.tintColor = tint
        }

        nameLabel.frame = plan.name
        nameLabel.attributedText = plan.nameAttr
        sizeLabel.frame = plan.size
        sizeLabel.attributedText = plan.sizeAttr

        if let rect = plan.spinner {
            let v = spinner ?? {
                let v = UIActivityIndicatorView(style: .medium); addSubview(v); spinner = v; return v
            }()
            v.isHidden = false
            v.frame = rect
            v.color = plan.slotIsPreview ? .white : tint
            v.startAnimating()
        } else {
            spinner?.stopAnimating()
            spinner?.isHidden = true
        }
    }

    func prepareForReuse() {
        preview.reset()
        spinner?.stopAnimating()
    }
}

/// The upload indicator: a soft dark disc, a white ring that FILLS with the real bytes, and a bold
/// X in its centre that cancels this transfer.
///
/// Owner 2026-08-27, off his side-by-side against another messenger: ours was a 20pt thread on a
/// 36pt disc and read as a speck on a full-width photo. Theirs is 52 across with a 3pt ring, and
/// the cancel lives IN the indicator rather than behind a long press.
///
/// ⚠️ THE FILL IS REAL, AND THE NOTE THAT USED TO SIT HERE SAID IT COULD NOT BE. It claimed
/// Firebase reports no byte progress so the ring had to be indeterminate. It reports them:
/// `ChatService` observes `.progress` on the upload task and writes every event into
/// `UploadProgress` — which is exactly what the SwiftUI bubble this view replaced read. The port
/// dropped the fill and kept the spinner, so every upload looked identical from first byte to last.
///
/// The spinner is only what runs BEFORE the first byte lands ("not started" is not "zero"), and its
/// two phases are still the reference's: the stroke opens from nothing to a half circle over the
/// first second while turning, then that half circle spins at one turn a second.
final class UploadRingView: UIView {
    private let disc = UIView()
    private let arc = CAShapeLayer()
    private let cross = UIImageView()
    private var bag = Set<AnyCancellable>()
    private var spinning = false

    /// Where this ring's bytes are filed: a single photo's `clientId`, an album tile's
    /// "clientId#index". The cell reads it back to know what the X cancels.
    var clientId: String?

    /// False on a photo somebody ELSE is still uploading: same ring, no X. See
    /// `MediaBody.cancellable`.
    var showsCancel = true {
        didSet { cross.isHidden = !showsCancel }
    }

    /// Told when THIS item is cancelled, so an album tile can dim the picture it just dropped. A
    /// cancel with no visible answer reads as a dead button.
    var onCancelled: ((Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false     // the cell hit-tests the plan and routes every tap
        disc.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        addSubview(disc)
        arc.fillColor = UIColor.clear.cgColor
        arc.strokeColor = UIColor.white.cgColor
        arc.lineCap = .round
        arc.strokeStart = 0
        arc.strokeEnd = 0
        layer.addSublayer(arc)
        // Added AFTER the arc layer on purpose: a bare CAShapeLayer sits under every subview added
        // after it, which is where the X belongs.
        cross.contentMode = .center
        cross.tintColor = .white
        addSubview(cross)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Called on every configure. `clientId` must already be set.
    func start() {
        subscribe()
        paint()
    }

    func stop() {
        bag.removeAll()
        spinning = false
        arc.removeAllAnimations()
        arc.strokeEnd = 0
        alpha = 1                            // a recycled cell must not inherit a hidden ring
        onCancelled = nil
    }

    /// One subscription, rebuilt on every configure so a recycled cell never keeps the previous
    /// upload's.
    ///
    /// ⚠️ `receive(on:)` IS LOAD-BEARING, the same reason `VoiceBubbleView` states it:
    /// `objectWillChange` fires BEFORE the value changes, so painting synchronously would read the
    /// state we are being told is about to be replaced.
    private func subscribe() {
        bag.removeAll()
        Publishers.Merge(UploadProgress.shared.objectWillChange,
                         MediaSend.shared.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.paint() }
            .store(in: &bag)
    }

    /// Bytes → the ring. No geometry: the plan owns every rect, and this runs many times a second.
    private func paint() {
        // No key: a photo somebody else is still uploading, whose sender's id never reached us.
        // There is nothing to fill and nothing to cancel, so it spins — which is exactly what this
        // view did for every case before it learned to read the bytes.
        guard let key = clientId else { startSpinning(); return }
        // This transfer has landed or been X'd. The MESSAGE may still be committing — `sendState`
        // is per-message and an album tile finishes long before its siblings — so the per-ITEM
        // truth is the only one that can take an indicator off a finished photo.
        let cancelled = MediaSend.shared.isItemCancelled(key)
        onCancelled?(cancelled)
        let settled = cancelled || MediaSend.shared.isItemDone(key)
        alpha = settled ? 0 : 1
        guard !settled else { stopSpinning(); return }

        guard let fraction = UploadProgress.shared.fraction(key) else { startSpinning(); return }
        stopSpinning()
        // A hair of ring at zero, so the first determinate frame is still an indicator and not an
        // empty circle.
        let end = max(0.03, CGFloat(fraction))
        guard abs(arc.strokeEnd - end) > 0.001 else { return }
        let fill = CABasicAnimation(keyPath: "strokeEnd")
        fill.fromValue = arc.strokeEnd
        fill.toValue = end
        fill.duration = 0.2                  // the reference's determinate step
        fill.timingFunction = CAMediaTimingFunction(name: .easeOut)
        arc.strokeEnd = end
        arc.add(fill, forKey: "fill")
    }

    private func startSpinning() {
        guard !spinning else { return }
        spinning = true
        let open = CABasicAnimation(keyPath: "strokeEnd")
        open.fromValue = 0
        open.toValue = 0.5
        open.duration = 1
        open.timingFunction = CAMediaTimingFunction(name: .easeIn)
        open.fillMode = .forwards
        open.isRemovedOnCompletion = false
        arc.add(open, forKey: "open")

        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = Double.pi * 2
        spin.duration = 1
        spin.repeatCount = .infinity
        arc.add(spin, forKey: "spin")
    }

    /// ⚠️ The opening animation is `isRemovedOnCompletion = false`, so the arc DRAWS half a circle
    /// while the model still says zero. Removing it is what lets the real fraction take over
    /// instead of being masked by a presentation value that outlived its animation.
    private func stopSpinning() {
        guard spinning else { return }
        spinning = false
        arc.removeAnimation(forKey: "open")
        arc.removeAnimation(forKey: "spin")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = min(bounds.width, bounds.height)
        disc.frame = bounds
        disc.layer.cornerRadius = bounds.height / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.frame = bounds
        arc.lineWidth = max(2, round(side * 0.058))       // 3 at the standard 52
        // ⚠️ THE PATH STARTS AT TWELVE O'CLOCK so `strokeEnd` fills clockwise from the top with no
        // rotation on the layer. A rotation would be fighting the spin animation, which drives that
        // same property.
        arc.path = UIBezierPath(arcCenter: CGPoint(x: bounds.midX, y: bounds.midY),
                                radius: side * 0.4225,    // a 44 ring inside a 52 disc
                                startAngle: -.pi / 2, endAngle: .pi * 1.5,
                                clockwise: true).cgPath
        CATransaction.commit()
        cross.frame = bounds
        cross.image = UIImage(systemName: "xmark", withConfiguration:
            UIImage.SymbolConfiguration(pointSize: round(side * 0.34), weight: .semibold))
    }
}
