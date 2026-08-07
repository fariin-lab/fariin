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
    // Application Support, NOT Caches — see `StoryStorage`. It was under Caches, which iOS reclaims
    // whenever the device is short of space and which is not carried across an app update, so every
    // story he had already downloaded went back to needing the network. His report, and the same bug
    // `DiskImageCache` was moved off Caches for long ago.
    static let dir: URL = StoryStorage.directory("StoryImageCache")
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

/// DECODED IMAGES, IN MEMORY, ABOVE THE DISK.
///
/// The "instant" disk path was not instant. `StoryDiskCache.image` does `Data(contentsOf:)` and then
/// builds a UIImage, and `loadImageWithUrl` runs from `updateUIView` — so opening a story you had
/// already seen meant reading a full-screen JPEG off the file system AND decoding it, on the main
/// thread, while the story was appearing. It was called the fast path because it skipped the
/// network, which is a different thing from being fast.
///
/// Worse, `UIImage(data:)` does not decode anything: it defers that until the image is first drawn,
/// which lands on the main thread in the middle of the transition. So even the URLCache hit paid a
/// decode at exactly the wrong moment.
///
/// This holds images that are already decoded and already display-ready (`preparingForDisplay`), so
/// a hit is a dictionary lookup and a pointer. Everything below it — the file read, the decode, the
/// preparation — happens off the main thread, once, and never again for that story this session.
enum StoryMemoryCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        // ~14 full-screen decoded frames on a 3x phone. Decoded is roughly w*h*4, which is far
        // bigger than the JPEG on disk, so this is counted in real bytes rather than in items.
        c.totalCostLimit = 160 * 1024 * 1024
        return c
    }()

    static func image(for url: URL) -> UIImage? { cache.object(forKey: url.absoluteString as NSString) }

    static func store(_ img: UIImage, for url: URL) {
        let cost = Int(img.size.width * img.size.height * img.scale * img.scale * 4)
        cache.setObject(img, forKey: url.absoluteString as NSString, cost: cost)
    }

    /// A display-ready image for this url, from memory if we have one and from disk otherwise, with
    /// every expensive part off the main thread. Returns nil when the bytes are not held anywhere.
    static func decoded(for url: URL) async -> UIImage? {
        if let hit = image(for: url) { return hit }
        return await Task.detached(priority: .userInitiated) { () -> UIImage? in
            var raw: UIImage?
            if let cached = URLCache.shared.cachedResponse(for: .init(url: url)) {
                raw = UIImage(data: cached.data)
            }
            if raw == nil { raw = StoryDiskCache.image(url) }
            guard let raw else { return nil }
            let ready = raw.preparingForDisplay() ?? raw
            await MainActor.run { store(ready, for: url) }
            return ready
        }.value
    }

    /// Decode bytes we have just downloaded, off the main thread, and remember the result.
    static func prepare(_ data: Data, for url: URL) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let raw = UIImage(data: data) else { return nil }
            let ready = raw.preparingForDisplay() ?? raw
            await MainActor.run { store(ready, for: url) }
            return ready
        }.value
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
    /// The download in flight for the story on screen, held so that moving on can cancel it.
    private var loadTask: URLSessionDataTask?

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
        // The fit/fill decision is re-taken here because it is measured against the CARD, and the
        // card's size is only known once there has been a layout pass. It cannot bring the old
        // "shaking" back: `decideContentMode` returns the moment the answer is unchanged, and the
        // two gestures that move this view (the viewers-sheet morph and the swipe-down dismiss) are
        // both `UIView.transform`, which does not touch bounds and does not run layout at all.
        decideContentMode()
    }

    // Round the bottom two corners of THIS view (which clips every subview, blur included).
    private func applyCornerMask() {
        layer.cornerRadius = bottomCornerRadius
        layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        layer.masksToBounds = bottomCornerRadius > 0
    }

    // Fill edge-to-edge (no blur) vs aspect-FIT + blurred backdrop, decided against the CARD the
    // photo actually lives in.
    //
    // IT WAS DECIDED AGAINST `UIScreen`, and the card has not been the screen since `8e224d9` made
    // it 9:16. A phone is 2.17 tall and the card is 1.78, so every photo between those two numbers
    // — which is every photo a story is framed to — was called "shorter than the screen" and
    // demoted to letterbox inside a card it very nearly fills. Measured on his own post: a
    // 2638x4800 picture (1.82) in a 1.78 card, aspect-fit, leaves a 1.3% blurred band down each
    // side. That is the pair of lines he drew.
    //
    // This is the same bug `VideoLoader.applyGravity` was fixed for, in the same words, and the
    // photo half was left behind. The two now answer the same question against the same rectangle.
    //
    // Deliberately kept: the 0.02 tolerance, and FIT for anything genuinely wider than the card —
    // a landscape photo hard-cropped to a 9:16 card loses most of its frame, and the blurred
    // backdrop behind it is the look he chose.
    private func decideContentMode() {
        guard let img = imageView.image, img.size.width > 0,
              bounds.width > 1, bounds.height > 1 else { return }
        let imgAspect = img.size.height / img.size.width
        let cardAspect = bounds.height / bounds.width
        let want: UIView.ContentMode = imgAspect >= cardAspect - 0.02 ? .scaleAspectFill : .scaleAspectFit
        // The early return is what makes calling this from `layoutSubviews` free, and it is what
        // guarantees a settled card can never flip the photo mid-gesture.
        guard imageView.contentMode != want else { return }
        imageView.contentMode = want
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

        // THE PREVIOUS STORY'S DOWNLOAD IS NO LONGER WANTED. It was left running: move through four
        // stories quickly and four full-size downloads competed for the connection, with the three
        // you had already left ahead of the one you were waiting on. On a weak network that is the
        // difference between a story appearing and a story spinning.
        loadTask?.cancel()
        loadTask = nil

        // stop video if it's playing before image request
        NotificationCenter.default.post(name: .stopVideo, object: nil)

        // 1) ALREADY DECODED AND READY. A dictionary lookup and a pointer — no file read, no decode,
        //    and crucially no dispatch: the picture is on screen in this same turn, which is what
        //    makes a re-opened story appear with no frame of anything else.
        if let ready = StoryMemoryCache.image(for: imageURL) {
            showShimmer(false)
            apply(ready)
            imageIsLoaded()
            return
        }

        // 2) URLCache or disk, with the read AND the decode off the main thread. This used to be two
        //    synchronous branches right here, which is why "cached" still cost a stutter.
        let wanted = imageURL
        Task { [weak self] in
            if let ready = await StoryMemoryCache.decoded(for: wanted) {
                guard let self, self.imageURL == wanted else { return }
                self.showShimmer(false)
                self.apply(ready)
                imageIsLoaded()
                return
            }
            guard let self, self.imageURL == wanted else { return }
            self.loadFromNetwork(wanted, previewURL: previewURL, imageIsLoaded: imageIsLoaded)
        }
    }

    /// Nothing is held for this url, so it has to come down. Split out of `loadImageWithUrl` because
    /// the cache lookup above it is asynchronous now and this is what happens when it misses.
    private func loadFromNetwork(_ imageURL: URL, previewURL: String?, imageIsLoaded: @escaping () -> Void) {
        // 3) Network — the blurred poster while it downloads, and the shimmer only if we have not
        //    even got that yet.
        apply(nil)
        if !seedPreviewBlur(previewURL) { showShimmer(true) }

        let requestedURL = imageURL   // capture: if the view is reused mid-download, drop this stale result
        // HELD, so moving on can cancel it. See the note at the top of `loadImageWithUrl`.
        loadTask = URLSession.shared.dataTask(
            with: imageURL,
            completionHandler: { [weak self] (data, response, error) in
            guard let self else { return }
            if error != nil {
                // A cancel arrives here too, and it is not a failure — the story simply moved on, and
                // calling `imageIsLoaded` would advance a progress bar that no longer owns the screen.
                if (error as? URLError)?.code == .cancelled { return }
                print(error as Any)
                DispatchQueue.main.async { self.showShimmer(false); imageIsLoaded() }
                return
            }

            guard let data, let response else {
                DispatchQueue.main.async { self.showShimmer(false); imageIsLoaded() }
                return
            }

            URLCache.shared.storeCachedResponse(.init(response: response, data: data), for: .init(url: imageURL))
            StoryDiskCache.store(data, for: imageURL)   // persist to disk → instant next time

            // DECODED OFF THE MAIN THREAD, and kept decoded. `UIImage(data:)` on its own defers the
            // real work to the first draw, which lands on the main thread in the middle of the story
            // appearing — the cost was simply moved to the worst possible moment rather than paid.
            Task {
                guard let ready = await StoryMemoryCache.prepare(data, for: imageURL) else {
                    await MainActor.run { self.showShimmer(false); imageIsLoaded() }
                    return
                }
                await MainActor.run {
                    self.showShimmer(false)
                    guard self.imageURL == requestedURL else { imageIsLoaded(); return }   // reused → don't show stale photo
                    self.apply(ready)
                    imageIsLoaded()
                }
            }
        })
        loadTask?.resume()
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

    /// ⚠️ NEVER SYNCHRONOUSLY. THIS IS THE CRASH.
    ///
    /// `rasterizeBlurBackdrop` needs `afterScreenUpdates: true`, and that flag does not just take a
    /// picture: it forces a CoreAnimation commit first, which runs a full layout and render pass
    /// there and then. `apply(_:)` is reached from `loadImageWithUrl`, which runs from
    /// `updateUIView` — so on a memory-cache hit the picture was taken from INSIDE SwiftUI's own
    /// update, and the commit re-entered the view graph while it was still building it. SwiftUI then
    /// tore down and rebuilt a display list underneath itself.
    ///
    /// Build 495, `Kulan-2026-08-07-222010.ips`, EXC_BREAKPOINT in `__CFCheckCFInfoPACSignature`
    /// under `_CFRelease` — an object released whose header no longer passes its integrity check —
    /// at the bottom of a recursive `swift_arrayDestroy` chain out of
    /// `DisplayList.ViewUpdater.render`. The stack reads the whole path in order:
    /// `PlatformViewRepresentableAdaptor.updateViewProvider` → us → `UIGraphicsImageRenderer` → us →
    /// `drawViewHierarchyInRect` → `_UIRenderViewImageAfterCommit` → `CA::Transaction::commit` →
    /// `_UIHostingView.layoutSubviews` → the render that died.
    ///
    /// It is very likely the same root cause as the OTHER signature we have seen three times
    /// (EXC_BAD_ACCESS in `StackLayout.makeChildren`, also on the AttributeGraph flush): the same
    /// re-entrancy, blowing up one phase earlier. Intermittent because it needs the sheet engaged
    /// AND an image that lands synchronously from memory.
    ///
    /// One hop off the current pass is the whole fix. Every guard below is re-checked when it lands,
    /// so arriving a frame late is safe and a state that moved on simply declines.
    func installFreezeIfReady() {
        DispatchQueue.main.async { [weak self] in self?.installFreezeNow() }
    }

    private func installFreezeNow() {
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
