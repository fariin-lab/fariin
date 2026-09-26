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

        Task { @MainActor [weak self] in
            guard let self else { return }
            if let cached = await DiskImageCache.shared.image(for: url) {
                guard self.token == mine else { return }
                self.image = cached
                self.loadedUrl = url
                if self.inFlight == url { self.inFlight = nil }
                return
            }
            guard self.token == mine else { return }
            // ⛔ THE SHARED JOB, WATCHED — 2026-09-26 media pass (see MediaDownloads). This view used
            // to download the photo itself and, if the cell had been reused by the time the bytes
            // came, threw them away uncached: scrolling past a loading photo and back started it
            // again from zero. The job's finisher decrypts and stores whether anyone is still
            // looking, off the main thread (the decode note that lived here is in `photoFinisher`),
            // and this view just picks the picture up from the cache when the job says done.
            self.watch(url, token: mine)
            MediaFetch.requestPhoto(url: url, enc: enc, cid: cid, gated: self.gated)
        }
    }

    /// Chat photo bubbles set this: Settings › Storage and Data and the automatic size ceiling may
    /// hold the download until a tap. Reply thumbnails, album placeholders and link previews leave
    /// it off — they are small and part of reading the message.
    var gated = false
    private var watching: (url: String, id: UUID)?

    private func watch(_ url: String, token mine: Int) {
        unwatch()
        let id = MediaDownloads.shared.observe(url) { [weak self] state in
            guard let self, self.token == mine else { return }
            switch state {
            case .downloading:
                self.inFlight = url
                self.setLoading(true)
            case .none:
                break   // the first callback, before the request below has made the job
            case .done:
                self.setLoading(false)
                self.unwatch()
                Task { @MainActor [weak self] in
                    guard let self, let img = await DiskImageCache.shared.image(for: url),
                          self.token == mine else { return }
                    self.image = img
                    self.loadedUrl = url
                    if self.inFlight == url { self.inFlight = nil }
                }
            case .waitingTap, .failed:
                // Not in flight any more: a later configure (or the bubble's tap) may ask again.
                self.setLoading(false)
                if self.inFlight == url { self.inFlight = nil }
            }
        }
        watching = (url, id)
    }

    private func unwatch() {
        if let w = watching { MediaDownloads.shared.stopObserving(w.url, w.id) }
        watching = nil
    }

    func reset() {
        token += 1
        unwatch()
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

/// A circular avatar with the same silhouette fallback the SwiftUI `AvatarView` draws, so a group
/// cluster's face does not change appearance when its row changes render path.
///
/// ⛔ THE COLOURED LETTER IS GONE — owner, 2026-09-16, "make one type". The gradient layer and its
/// label went with it; the fill and the glyph both come from `AvatarPalette` so this view cannot
/// drift from the other eight places that draw the same fallback.
final class RowAvatarView: UIView {
    private let imageView = UIImageView()
    private let glyph = UIImageView()
    private var glyphSize: CGFloat = 0
    private var token = 0
    private var currentUrl: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = AvatarPalette.placeholderFillUI
        glyph.contentMode = .center
        addSubview(glyph)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        addSubview(imageView)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(name: String, photoUrl: String?) {
        // `name` is still taken so the call sites and the accessibility label do not change; it no
        // longer decides anything about how the fallback looks, which is the whole point of the rule.
        accessibilityLabel = name

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

        // The synchronous seed, for the same reason the SwiftUI avatar takes it: memory starts empty
        // on every launch. Through `ProfilePhotoLoader` (2026-09-25), the one avatar pipeline: its own
        // memory, one shared download per url, and a network failure is no longer recorded as "no
        // photo" (this path used to note every failed load as missing, which then hid a real photo
        // on the profile header after a single dropped request).
        if let warm = ProfilePhotoLoader.shared.cachedAvatar(photoUrl) {
            imageView.image = warm
            imageView.isHidden = false
            return
        }
        imageView.image = nil
        imageView.isHidden = true
        Task { @MainActor [weak self] in
            let found = await ProfilePhotoLoader.shared.avatar(photoUrl)
            guard let self, let found, self.token == mine else { return }
            self.imageView.image = found
            self.imageView.isHidden = false
            self.imageView.alpha = 0
            UIView.animate(withDuration: 0.25) { self.imageView.alpha = 1 }   // the same no-blink fade
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        glyph.frame = bounds
        // ⚠️ RE-RENDERED ONLY WHEN THE SIZE ACTUALLY CHANGES, and tracked with its own number rather
        // than read back off the image: a symbol's rendered height is its GLYPH's, not the view's, so
        // comparing the two would re-render on every layout pass of every cell in the chat.
        if glyphSize != bounds.height {
            glyphSize = bounds.height
            glyph.image = AvatarPalette.placeholderCanvas(size: bounds.height)
        }
        imageView.frame = bounds
    }
}
