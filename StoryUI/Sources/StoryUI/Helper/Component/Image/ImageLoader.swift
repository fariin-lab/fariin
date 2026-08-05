//
//  ImageLoader.swift
//  StoryUI
//
//  Created by Tolga İskender on 28.03.2022.
//

import Combine
import UIKit
import CryptoKit

// Persistent disk cache for story images — survives app relaunches (unlike URLCache, which evicts).
// Keyed by a STABLE hash of the URL path (String.hashValue is randomized per process, so unusable;
// we ignore the volatile Firebase ?token query so the same file always maps to the same file on disk).
enum StoryDiskCache {
    static let dir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("StoryImageCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private static func key(_ url: URL) -> String {
        let base = (url.scheme ?? "") + (url.host ?? "") + url.path
        let digest = Insecure.MD5.hash(data: Data(base.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    static func path(_ url: URL) -> URL { dir.appendingPathComponent(key(url)) }
    static func image(_ url: URL) -> UIImage? {
        guard let data = try? Data(contentsOf: path(url)) else { return nil }
        return UIImage(data: data)
    }
    static func store(_ data: Data, for url: URL) {
        try? data.write(to: path(url), options: .atomic)
    }
}

// `StoryCompositeCache` and `StorySnapshotFactory` lived here, and between them they photographed
// every story's full-screen render — offscreen, on the MAIN THREAD, one `drawHierarchy` per story —
// so the viewers-sheet cards could be built from native pixels instead of a blur re-rendered at card
// size.
//
// Every reader of that cache is gone. `21f3209` removed the last one (`SnapshotCardContent`) without
// removing the machinery, so from then until now it was a screen render per story per pull feeding
// nobody. The card behind the sheet is the live story itself now (see StoryCardMorph), so there is
// nothing left to photograph and nothing left to keep in step with the real thing.

// Shimmering skeleton placeholder (instead of a spinner) while an image is fetched — feels faster.
final class ShimmerView: UIView {
    private let gradient = CAGradientLayer()
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.14, alpha: 1)
        let dark = UIColor(white: 0.14, alpha: 1).cgColor
        let light = UIColor(white: 0.26, alpha: 1).cgColor
        gradient.colors = [dark, light, dark]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.locations = [0, 0.5, 1]
        layer.addSublayer(gradient)
        let anim = CABasicAnimation(keyPath: "locations")
        anim.fromValue = [-1.0, -0.5, 0.0]
        anim.toValue = [1.0, 1.5, 2.0]
        anim.duration = 1.15
        anim.repeatCount = .infinity
        gradient.add(anim, forKey: "shimmer")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); gradient.frame = bounds }
}

final class ImageLoader: UIView {

    // MARK: Public Properties
    var imageURL: URL?
    // Round ONLY the bottom two corners of the whole card (photo + blur backdrop) in UIKit. A SwiftUI
    // .clipShape doesn't clip the UIVisualEffectView blur (it composites separately and spills past the
    // mask), so the friend reply-bar card stayed square; a UIKit corner mask clips the blur reliably.
    var bottomCornerRadius: CGFloat = 0 { didSet { applyCornerMask() } }
    // Foreground: the photo at its TRUE aspect ratio — never stretched/cropped.
    var imageView = UIImageView()
    // Background: a zoomed + blurred copy of the same photo that fills the empty top/bottom.
    private let backgroundImageView = UIImageView()
    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterialDark))
    private let shimmer = ShimmerView()
    // The story's own poster behind glass, shown while the full-size media downloads (see
    // showPreviewBlur). Built lazily: a story that is already cached never needs one.
    private var previewBlur: UIImageView?
    private var previewBlurEffect: UIVisualEffectView?
    // The frozen fill+blur composite while the viewers sheet scales the story (see freezeBlur).
    private var frozenBlur: UIImageView?

    // MARK: - Initializers
    init() {
        super.init(frame: .zero)
        setupImageView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        backgroundImageView.frame = bounds
        blurView.frame = bounds
        imageView.frame = bounds
        shimmer.frame = bounds
        previewBlur?.frame = bounds
        previewBlurEffect?.frame = bounds
        frozenBlur?.frame = bounds
        applyCornerMask()
        // NB: the fit/fill decision is NOT recomputed here — it's fixed once per image in apply(),
        // so a swipe-down's transient bounds changes can never flip it (that flip was the "shaking").
    }

    // Round the bottom two corners of THIS view (which clips every subview, blur included).
    private func applyCornerMask() {
        layer.cornerRadius = bottomCornerRadius
        layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        layer.masksToBounds = bottomCornerRadius > 0
    }

    // Fill edge-to-edge (no blur) vs aspect-FIT + blurred backdrop, decided ONCE per image against
    // the STABLE screen aspect (NOT the live view bounds). The bounds jitter as the card scales/offsets
    // during a swipe-down, and keying off them made the photo flip fit<->fill every frame = the
    // "shaking". The screen aspect never changes, so the decision is rock-stable through any drag.
    private func decideContentMode() {
        guard let img = imageView.image, img.size.width > 0 else { return }
        let imgAspect = img.size.height / img.size.width
        let screen = UIScreen.main.bounds
        let screenAspect = screen.height / screen.width
        // Fill when the image is at least as TALL as the screen. Text/colour statuses are rendered
        // taller than any phone (2.5:1), so they always fill full-bleed on every device; real photos
        // are shorter than the screen → aspect-FIT + blurred backdrop (the look the user prefers).
        imageView.contentMode = imgAspect >= screenAspect - 0.02 ? .scaleAspectFill : .scaleAspectFit
    }

    private func apply(_ image: UIImage?) {
        imageView.image = image
        backgroundImageView.image = image
        decideContentMode()        // fixed for this image; never recomputed on layout/drag
        if image != nil {
            installFreezeIfReady()   // sheet engaged + fresh image (carousel jump) → frozen backdrop now
        }
    }

    private func showShimmer(_ show: Bool) {
        shimmer.isHidden = !show
        if show { bringSubviewToFront(shimmer) }
        if !show { hidePreviewBlur() }
    }

    /// THE LOADING STATE IS THE PICTURE, BLURRED, not a grey block.
    ///
    /// Owner: "Whatsapp and Telegram and Other apps story never use grey skeleton loading, they use
    /// image blur or video blur." He is right about all three, and the reason is that a grey block
    /// says nothing while a blurred frame says "this is what is coming, it is nearly here". Ours is
    /// the story's own poster, which is a few KB and is normally already on disk because the story
    /// row drew it, so it lands at once and the full-size download happens behind it.
    ///
    /// The shimmer stays as the last resort, for a story whose poster we have not got either.
    /// Something moving beats a dead grey rectangle when there is genuinely nothing to show yet.
    private func showPreviewBlur(_ image: UIImage) {
        let view: UIImageView
        if let previewBlur { view = previewBlur } else {
            let v = UIImageView()
            v.contentMode = .scaleAspectFill
            v.clipsToBounds = true
            previewBlur = v
            addSubview(v)
            let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterialDark))
            v.addSubview(blur)
            previewBlurEffect = blur
            view = v
        }
        view.image = image
        view.frame = bounds
        previewBlurEffect?.frame = view.bounds
        view.isHidden = false
        bringSubviewToFront(view)
        // The shimmer is redundant once there is a real picture behind the glass, and running both
        // gives a moving grey band over a still photo, which reads as a glitch rather than as loading.
        shimmer.isHidden = true
    }

    private func hidePreviewBlur() {
        previewBlur?.isHidden = true
    }

    /// Draw the blurred poster NOW if we already hold one, so the story never opens on grey. Called
    /// before the network request goes out.
    private func seedPreviewBlur(_ previewURL: String?) -> Bool {
        guard let previewURL, let url = URL(string: previewURL) else { return false }
        if let cached = URLCache.shared.cachedResponse(for: .init(url: url)),
           let img = UIImage(data: cached.data) {
            showPreviewBlur(img); return true
        }
        if let disk = StoryDiskCache.image(url) {
            showPreviewBlur(disk); return true
        }
        // Not held yet: fetch it on its own. It is small, so it usually beats the full media home by
        // a wide margin, and if it does not the shimmer is already up and nothing changes.
        let forStory = imageURL   // this view is reused between stories; a late poster must not paint over the next one
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data, let img = UIImage(data: data) else { return }
            StoryDiskCache.store(data, for: url)
            DispatchQueue.main.async {
                // Still the same story, and the real thing has still not landed. Without the second
                // check this would drop a blurred poster on top of the sharp photo that beat it home.
                guard self.imageURL == forStory, self.imageView.image == nil else { return }
                self.showPreviewBlur(img)
            }
        }.resume()
        return false
    }

    func loadImageWithUrl(_ url: String?, previewURL: String? = nil, imageIsLoaded: @escaping () -> Void) {

        guard let validatedUrl = url else {
            print("url error")
            imageIsLoaded()   // still mark ready → the story auto-advances instead of freezing forever
            return
        }

        if imageURL == URL(string: validatedUrl) {
            return
        }

        imageURL = URL(string: validatedUrl)

        // Reused for a different story (carousel jump mid-sheet): the previous story's FROZEN
        // blur overlay must never survive under the new photo (audit C1 — story A's bars were
        // showing beneath story B). Drop the stale overlay ONLY — the sheet is still engaged,
        // so freezeWanted stays set and apply() re-freezes the new image the moment it lands.
        frozenBlur?.removeFromSuperview()
        frozenBlur = nil
        blurView.isHidden = false
        // Same reasoning for the loading poster: story A's blurred cover must never be the first
        // thing you see of story B.
        hidePreviewBlur()

        guard let imageURL else { imageIsLoaded(); return }   // malformed URL → don't freeze the progress bar

        // stop video if it's playing before image request
        NotificationCenter.default.post(name: .stopVideo, object: nil)

        // 1) Memory (URLCache) — instant.
        if let cachedResponse = URLCache.shared.cachedResponse(for: .init(url: imageURL)),
           let img = UIImage(data: cachedResponse.data) {
            DispatchQueue.main.async { [weak self] in
                self?.showShimmer(false)
                self?.apply(img)
                imageIsLoaded()
            }
            return
        }

        // 2) Disk — instant on revisit / relaunch (persistent, the big-apps behaviour).
        if let disk = StoryDiskCache.image(imageURL) {
            DispatchQueue.main.async { [weak self] in
                self?.showShimmer(false)
                self?.apply(disk)
                imageIsLoaded()
            }
            return
        }

        // 3) Network — the blurred poster while it downloads, and the shimmer only if we have not
        //    even got that yet.
        apply(nil)
        if !seedPreviewBlur(previewURL) { showShimmer(true) }

        let requestedURL = imageURL   // capture: if the view is reused mid-download, drop this stale result
        URLSession.shared.dataTask(
            with: imageURL,
            completionHandler: { [weak self] (data, response, error) in
            guard let self else { return }
            if error != nil {
                print(error as Any)
                DispatchQueue.main.async { self.showShimmer(false); imageIsLoaded() }
                return
            }

            guard let data,
                  let response,
                  let image = UIImage(data: data)
            else {
                DispatchQueue.main.async { self.showShimmer(false); imageIsLoaded() }
                return
            }

            URLCache.shared.storeCachedResponse(.init(response: response, data: data), for: .init(url: imageURL))
            StoryDiskCache.store(data, for: imageURL)   // persist to disk → instant next time

            DispatchQueue.main.async {
                self.showShimmer(false)
                guard self.imageURL == requestedURL else { imageIsLoaded(); return }   // reused → don't show stale photo
                self.apply(image)
                imageIsLoaded()
            }
        }).resume()
    }

}
// MARK: - Private Funcs
private extension ImageLoader {
   func setupImageView() {
       backgroundColor = .black
       // For non-9:16 photos: a zoomed + heavily-blurred copy of the SAME image fills the
       // whole screen behind, so the empty top/bottom become a blurred color-matched backdrop (no black bars).
       backgroundImageView.contentMode = .scaleAspectFill
       backgroundImageView.clipsToBounds = true
       addSubview(backgroundImageView)
       addSubview(blurView)   // heavy Gaussian blur over the fill copy

       // Foreground: the photo at its TRUE aspect ratio — aspect-FIT so a square/landscape is never
       // cropped/zoomed. The empty top/bottom become the zoomed + blurred backdrop above (user prefers
       // this resize+blur look over a center-crop fill).
       imageView.contentMode = .scaleAspectFit
       imageView.clipsToBounds = true
       addSubview(imageView)

       shimmer.isHidden = true
       addSubview(shimmer)

       // Viewers-sheet pull-up: freeze/unfreeze the blurred backdrop (posted by the host app).
       NotificationCenter.default.addObserver(self, selector: #selector(freezeBlur),
                                              name: Notification.Name("storyFreezeBlur"), object: nil)
       NotificationCenter.default.addObserver(self, selector: #selector(unfreezeBlur),
                                              name: Notification.Name("storyUnfreezeBlur"), object: nil)
   }
}

// MARK: - Blur freeze (viewers-sheet pull-up)
extension ImageLoader {
    // A LIVE material re-computes itself as the story scales down, rendering the fit-image bars far
    // darker/flatter than they looked full screen (user spec: "keep the exact blur from before the
    // pull-up — never generate a new one"). Freezing rasterizes the CURRENT on-screen appearance
    // (fill + material composite) into plain pixels and hides the live blur: frozen pixels scale
    // like a photograph, identical at every size. Unfreeze restores the live material at full screen.
    // The sheet is engaged and every current/future image should carry a frozen backdrop.
    // Set by storyFreezeBlur, cleared by storyUnfreezeBlur; apply() re-freezes on image load
    // (a one-shot timer missed slow-loading carousel jumps — audit finding 3).
    static var freezeWanted = false

    @objc private func freezeBlur() {
        Self.freezeWanted = true
        installFreezeIfReady()
    }

    func installFreezeIfReady() {
        guard Self.freezeWanted, frozenBlur == nil,
              imageView.image != nil, imageView.contentMode == .scaleAspectFit,
              bounds.width > 0, window != nil else { return }
        // BLUR-ONLY FREEZE (user's red-border test PROVED the cause): the freeze must hold ONLY
        // the blurred backdrop, never the sharp photo. It used to photograph the WHOLE story, so
        // the photo got baked into the freeze AND the live imageView still sat on top — TWO copies
        // of the photo. On the sheet morph they drifted apart (the two red rectangles the user saw)
        // and snapped to one at the hand-off (the "jump to fit", up AND back). Freezing the blur
        // alone leaves exactly ONE photo — the live one — so nothing can drift or snap.
        // This also keeps the earlier fix: a FRESH live capture (never the offscreen cache, where
        // Apple's UIVisualEffectView blur fails to render) keeps the blur from looking broken.
        guard let img = rasterizeBlurBackdrop() else { return }
        let iv = UIImageView(image: img)
        iv.frame = bounds
        iv.contentMode = .scaleToFill          // img is captured at `bounds` → no distortion
        insertSubview(iv, aboveSubview: blurView)   // BEHIND the live photo (imageView stays on top)
        blurView.isHidden = true
        frozenBlur = iv
    }

    // The blurred backdrop ALONE (background fill + material), captured with the sharp photo
    // HIDDEN — so the frozen overlay can never contain a second copy of the photo. The live
    // imageView stays on top and remains the single visible photo. afterScreenUpdates: true is
    // required so the "hide the photo" change is committed before the snapshot (otherwise the
    // capture would still include it); the photo is restored synchronously, before any refresh,
    // so it never visibly disappears.
    private func rasterizeBlurBackdrop() -> UIImage? {
        guard bounds.width > 0, window != nil, imageView.image != nil,
              imageView.contentMode == .scaleAspectFit else { return nil }
        let photoWasHidden = imageView.isHidden
        let shimmerWasHidden = shimmer.isHidden
        imageView.isHidden = true
        shimmer.isHidden = true
        let img = UIGraphicsImageRenderer(bounds: bounds).image { _ in
            drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        imageView.isHidden = photoWasHidden
        shimmer.isHidden = shimmerWasHidden
        return img
    }

    // `rasterizeComposite` and `scheduleCompositeCapture` lived here. Every fit story that appeared
    // scheduled a full-screen `drawHierarchy` 0.15s later to fill `StoryCompositeCache`. Nothing has
    // read that cache since `21f3209`, and the cards it fed are gone, so the render went with them.
    // `rasterizeBlurBackdrop` (the pull-up FREEZE, blur only) is a different function and is
    // untouched.

    @objc private func unfreezeBlur() {
        Self.freezeWanted = false
        frozenBlur?.removeFromSuperview()
        frozenBlur = nil
        blurView.isHidden = false
    }
}
