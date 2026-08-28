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
    /// Where a downloaded photo is decoded and resized. Off the main thread, because both of those
    /// are real work and doing them on main is what kept the blur up after the bytes had landed.
    private static let decodeQueue = DispatchQueue(label: "fariin.rowimage.decode",
                                                   qos: .userInitiated, attributes: .concurrent)
    private var token = 0
    private var currentUrl: String?
    /// ⛔ A DOWNLOAD THAT IS HAPPENING SHOULD LOOK LIKE ONE — his report, 2026-08-28: an album
    /// somebody sends has "no download loading".
    ///
    /// A single photo at least has a blurhash to sit behind, so something is on screen while the
    /// bytes come. An album tile often has neither an inline thumb nor a hash, so it was a flat grey
    /// square with nothing to say whether it was loading, stuck, or broken — and the ring that DOES
    /// exist on a tile is the UPLOAD ring, which only ever appears on your own outgoing album.
    ///
    /// Opt-in, because the same view draws 34pt reply-quote thumbnails, where a spinner would be
    /// bigger than the picture.
    var showsLoadingIndicator = false
    private var spinner: UIActivityIndicatorView?
    /// The url whose REAL bytes are on screen — as opposed to `currentUrl`, which is only what was
    /// last asked for. A fetch that fails leaves the placeholder showing and this nil, so the next
    /// configure tries again instead of treating the blur as a finished picture.
    private var loadedUrl: String?
    /// The url currently being fetched. Without it a reconfigure mid-download looks identical to a
    /// fresh one. See `configure`.
    private var inFlight: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .scaleAspectFill
        clipsToBounds = true
        backgroundColor = UIColor.systemGray5.withAlphaComponent(0.5)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// `placeholder` is what to draw while the real bytes are still coming: the inline thumbnail
    /// that travelled inside the message, or the blurhash behind it. Either beats a grey box, and
    /// the inline thumb beats the hash because it is an actual (tiny) photo rather than a sketch of
    /// one — and it is already in hand, before anything has been asked of the network.
    func configure(url: String?, enc: EncMeta?, cid: String,
                   cornerRadius: CGFloat = 0, placeholder: UIImage? = nil) {
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
        token += 1
        let mine = token
        guard let url, !url.isEmpty else { currentUrl = nil; image = placeholder; return }
        // ⛔ "ALREADY DRAWN" MUST MEAN THE REAL BYTES, NOT ANY IMAGE. The placeholder — an inline
        // thumb or a decoded blurhash — is not nil, so a fetch that failed once left `image` holding
        // the blur, and every later configure with the same url returned here immediately. The photo
        // stayed blurred for good: reopening the chat did not help, because the url had not changed,
        // and only a cell recycling through `prepareForReuse` ever cleared it.
        //
        // `loadedUrl` records what actually LANDED, so a failure is retried the next time the row is
        // configured, and a success still costs nothing.
        // ⛔ THREE STATES, NOT TWO — the same fault as the gif view next door, and I introduced both
        // in the same change. `loadedUrl` alone means a reconfigure DURING a download does not match
        // it, so every one of them (a tick landing, a reaction, a scroll — this row reconfigures
        // constantly) reset the picture to the placeholder and started ANOTHER fetch.
        //
        // `inFlight` is the missing state: a reconfigure while the bytes are coming does nothing, a
        // reconfigure after a failure retries, and a reconfigure after success returns above.
        guard url != loadedUrl, inFlight != url else { return }
        currentUrl = url

        // Synchronous memory hit → the first frame already has the picture, no skeleton flash.
        if let mem = DiskImageCache.shared.memoryImage(url) { image = mem; return }
        // Small images opt into the synchronous DISK read: memory is empty on every launch, so a
        // thumbnail that IS on disk would otherwise appear a beat late.
        if let warm = DiskImageCache.shared.smallImageSync(url) { image = warm; return }
        image = placeholder
        inFlight = url
        setLoading(true)

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.token == mine {
                    // Cleared whatever happened, so a failure is retryable and a success is not
                    // re-fetched — `loadedUrl` is what says which of the two it was.
                    if self.inFlight == url { self.inFlight = nil }
                    self.setLoading(false)
                }
            }
            if let cached = await DiskImageCache.shared.image(for: url) {
                guard self.token == mine else { return }
                self.image = cached
                self.loadedUrl = url
                return
            }
            guard let u = URL(string: url),
                  let (data, _) = try? await MediaSession.shared.data(from: u) else { return }
            // Bytes only here. The decode used to happen on this line as well, on the main actor,
            // which is half of what kept the blur up — see the note below.
            let clear: Data?
            if let enc {
                clear = await Crypto.shared.decryptBytes(cid, cipher: data, meta: enc)
            } else {
                clear = data
            }
            guard let bytes = clear, self.token == mine else { return }
            // ⛔ THE PICTURE IS PREPARED OFF THE MAIN THREAD — his report: the blur stays for a
            // moment AFTER the download has finished.
            //
            // This whole task is `@MainActor`, so everything between the bytes arriving and the
            // assignment was running on main while the blurhash sat on screen: `UIImage(data:)`,
            // then `boundedForDisplay()`, which is a synchronous decode-and-resize
            // (`preparingThumbnail`) and is the expensive one — tens of milliseconds for a photo
            // off a modern camera, longer on an older phone. The download had finished; the main
            // thread was simply too busy to draw the result yet.
            //
            // ⚠️ THE DISK PATH ALREADY DOES THIS CORRECTLY, and the asymmetry is the whole bug:
            // `DiskImageCache.image(for:)` decodes on its own queue, bounds, and force-prepares the
            // bitmap before handing it back, with a comment saying exactly why. A photo read from
            // the cache appeared instantly and the same photo arriving from the network did not.
            //
            // ⚠️ AND THE DECODE IS FORCED, not just the resize. `UIImage(data:)` is lazy: assigning
            // it hands the work to the render server and the bitmap is decoded on the main thread at
            // DRAW time, which puts the stall back one frame later. Mirrors the disk path's rule —
            // if `boundedForDisplay` actually resized, the result is already decoded; if it returned
            // the original untouched, prepare it.
            //
            // ⚠️ A QUEUE AND A CONTINUATION, NOT `Task.detached`: `Task`'s success type must be
            // `Sendable` and `UIImage` is not. This is the same shape `DiskImageCache.image(for:)`
            // uses two files over, for the same reason.
            let prepared: UIImage? = await withCheckedContinuation { cont in
                Self.decodeQueue.async {
                    guard let raw = UIImage(data: bytes) else { cont.resume(returning: nil); return }
                    let bounded = raw.boundedForDisplay()
                    cont.resume(returning: (bounded === raw ? raw.preparingForDisplay() : bounded) ?? raw)
                }
            }
            guard let prepared, self.token == mine else { return }
            // THE PICTURE FIRST, THE BOOKKEEPING AFTER. Storing before the assignment put a memory
            // insert, a file removal and a disk-write dispatch between the finished image and the
            // frame that shows it, for no reason — nothing about the cache is owed to this frame.
            self.image = prepared
            self.loadedUrl = url
            // owned: a chat photo is the only copy left once the server's is deleted, so it must
            // survive the cache trim exactly as the SwiftUI path stores it.
            DiskImageCache.shared.store(prepared, data: bytes, for: url, owned: true)
        }
    }

    func reset() {
        token += 1
        currentUrl = nil
        loadedUrl = nil
        inFlight = nil
        image = nil
        setLoading(false)
    }

    /// Shown only while the bytes are actually in flight, and never for a picture that is already
    /// on screen — a memory or synchronous-disk hit returns before this is ever switched on.
    private func setLoading(_ on: Bool) {
        guard showsLoadingIndicator else { return }
        guard on else { spinner?.stopAnimating(); spinner?.isHidden = true; return }
        let v = spinner ?? {
            let v = UIActivityIndicatorView(style: .medium)
            v.hidesWhenStopped = true
            v.color = .white
            // Legible on a pale photo as well as a dark one, without a scrim over the picture.
            v.layer.shadowColor = UIColor.black.cgColor
            v.layer.shadowOpacity = 0.45
            v.layer.shadowRadius = 3
            v.layer.shadowOffset = .zero
            addSubview(v)
            spinner = v
            return v
        }()
        v.isHidden = false
        v.startAnimating()
        bringSubviewToFront(v)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        spinner?.center = CGPoint(x: bounds.midX, y: bounds.midY)
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
