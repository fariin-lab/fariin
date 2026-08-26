import SwiftUI   // AvatarPalette hands back SwiftUI Colors
import UIKit

// ===== The UIKit half of the app's existing image pipeline =====
//
// `SecureImageView` and `AvatarView` are SwiftUI views that own their own async load. The UIKit rows
// need the same bytes with the same caching and the same decryption, so these two views call the
// same `DiskImageCache` / `MediaSession` / `Crypto` the SwiftUI ones do rather than introducing a
// second pipeline. Nothing here downloads anything the SwiftUI path would not have downloaded.
//
// ⚠️ EVERY LOAD IS TOKENED. Cells recycle, and an async load that lands after the view has been
// handed a different url would paint the WRONG photo into someone else's row — the class of bug the
// story code hit repeatedly. `token` is bumped on every `configure`, and a completion whose token is
// stale drops its result on the floor.

/// A small image inside a row: the reply quote's thumbnail, an album tile's placeholder, a link
/// preview's picture. Encrypted urls are decrypted with the conversation's key.
final class RowImageView: UIImageView {
    private var token = 0
    private var currentUrl: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .scaleAspectFill
        clipsToBounds = true
        backgroundColor = UIColor.systemGray5.withAlphaComponent(0.5)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(url: String?, enc: EncMeta?, cid: String, cornerRadius: CGFloat = 0) {
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
        token += 1
        let mine = token
        guard let url, !url.isEmpty else { currentUrl = nil; image = nil; return }
        guard url != currentUrl || image == nil else { return }   // same photo, already drawn
        currentUrl = url

        // Synchronous memory hit → the first frame already has the picture, no skeleton flash.
        if let mem = DiskImageCache.shared.memoryImage(url) { image = mem; return }
        // Small images opt into the synchronous DISK read: memory is empty on every launch, so a
        // thumbnail that IS on disk would otherwise appear a beat late.
        if let warm = DiskImageCache.shared.smallImageSync(url) { image = warm; return }
        image = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            if let cached = await DiskImageCache.shared.image(for: url) {
                guard self.token == mine else { return }
                self.image = cached
                return
            }
            guard let u = URL(string: url),
                  let (data, _) = try? await MediaSession.shared.data(from: u) else { return }
            var ui: UIImage?
            var clear: Data?
            if let enc {
                if let bytes = await Crypto.shared.decryptBytes(cid, cipher: data, meta: enc) {
                    ui = UIImage(data: bytes); clear = bytes
                }
            } else {
                ui = UIImage(data: data); clear = data
            }
            guard let ui, self.token == mine else { return }
            let bounded = ui.boundedForDisplay()
            // owned: a chat photo is the only copy left once the server's is deleted, so it must
            // survive the cache trim exactly as the SwiftUI path stores it.
            DiskImageCache.shared.store(bounded, data: clear, for: url, owned: true)
            self.image = bounded
        }
    }

    func reset() {
        token += 1
        currentUrl = nil
        image = nil
    }
}

/// A circular avatar with the same coloured-letter fallback the SwiftUI `AvatarView` draws, so a
/// group cluster's face does not change appearance when its row changes render path.
final class RowAvatarView: UIView {
    private let imageView = UIImageView()
    private let gradient = CAGradientLayer()
    private let letter = UILabel()
    private var token = 0
    private var currentUrl: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        layer.addSublayer(gradient)
        letter.textAlignment = .center
        letter.textColor = .white
        addSubview(letter)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        addSubview(imageView)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(name: String, photoUrl: String?) {
        let initial = name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
        letter.text = initial
        gradient.colors = AvatarPalette.gradient(for: name).map { UIColor($0).cgColor }

        token += 1
        let mine = token
        guard let photoUrl, !photoUrl.isEmpty else {
            currentUrl = nil
            imageView.image = nil
            imageView.isHidden = true
            return
        }
        guard photoUrl != currentUrl || imageView.image == nil else { return }
        currentUrl = photoUrl

        // The synchronous disk seed, for the same reason the SwiftUI avatar takes it: memory starts
        // empty on every launch, so without it every avatar in the chat flashes its letter first.
        if let warm = DiskImageCache.shared.smallImageSync(photoUrl) {
            imageView.image = warm
            imageView.isHidden = false
            return
        }
        imageView.image = nil
        imageView.isHidden = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            var found: UIImage?
            if let cached = await DiskImageCache.shared.image(for: photoUrl) {
                found = cached
            } else if let u = URL(string: photoUrl),
                      let (data, _) = try? await MediaSession.shared.data(from: u),
                      let ui = UIImage(data: data) {
                DiskImageCache.shared.store(ui, data: data, for: photoUrl)
                found = ui
            }
            ProfilePhotoIndex.noteLoad(photoUrl, ok: found != nil)
            guard let found, self.token == mine else { return }
            self.imageView.image = found
            self.imageView.isHidden = false
            self.imageView.alpha = 0
            UIView.animate(withDuration: 0.25) { self.imageView.alpha = 1 }   // the same no-blink fade
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
        letter.frame = bounds
        letter.font = .systemFont(ofSize: bounds.height * 0.42, weight: .bold)
        imageView.frame = bounds
    }
}
