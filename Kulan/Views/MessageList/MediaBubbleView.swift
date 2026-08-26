import UIKit

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

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .scaleAspectFill
        clipsToBounds = true
        backgroundColor = .secondarySystemFill
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(url: String?) {
        guard let url, !url.isEmpty else { loadedURL = nil; image = nil; return }
        guard url != loadedURL else { return }
        loadedURL = url                      // marked BEFORE loading, so a re-configure cannot re-download
        if let hit = Self.cache.object(forKey: url as NSString) { image = hit; return }
        if let bytes = GifBytesCache.data(url), let img = UIImage.animatedGif(data: bytes) {
            Self.cache.setObject(img, forKey: url as NSString)
            image = img
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
                self.image = img
            }
        }.resume()
    }

    func reset() { loadedURL = nil; image = nil }
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

/// The upload indicator: a thin white arc on a dark disc.
///
/// ⚠️ INDETERMINATE ON PURPOSE. Firebase's `putFileAsync` reports no byte progress, so a filling
/// ring would be a lie about something that cannot be measured. Two phases, as the reference draws
/// it: the stroke opens from nothing to a half circle over the first second while turning, then
/// that half circle spins at one turn a second. The opening is the part that says "this has just
/// started" rather than "something is busy".
final class UploadRingView: UIView {
    private let disc = UIView()
    private let arc = CAShapeLayer()
    var clientId: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        disc.backgroundColor = UIColor.black.withAlphaComponent(0.28)
        addSubview(disc)
        arc.fillColor = UIColor.clear.cgColor
        arc.strokeColor = UIColor.white.cgColor
        arc.lineWidth = 2
        arc.lineCap = .round
        arc.strokeStart = 0
        arc.strokeEnd = 0
        layer.addSublayer(arc)
    }
    required init?(coder: NSCoder) { fatalError() }

    func start() {
        guard arc.animation(forKey: "spin") == nil else { return }
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

    func stop() {
        arc.removeAllAnimations()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        disc.frame = bounds
        disc.layer.cornerRadius = bounds.height / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.frame = bounds
        let inset: CGFloat = 8
        arc.path = UIBezierPath(ovalIn: bounds.insetBy(dx: inset, dy: inset)).cgPath
        CATransaction.commit()
    }
}
