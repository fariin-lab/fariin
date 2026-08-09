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
    // Round ONLY the bottom two corners of the whole card (photo + canvas) in UIKit. This was
    // forced by the old backdrop — a SwiftUI `.clipShape` does not clip a `UIVisualEffectView`,
    // which composites separately and spilled past the mask, leaving the friend reply-bar card
    // square. The canvas is an ordinary layer and would clip either way; the UIKit mask stays
    // because it is what the callers ask for and it is one less thing to re-verify.
    var bottomCornerRadius: CGFloat = 0 { didSet { applyCornerMask() } }
    // Foreground: the photo at its TRUE aspect ratio — never stretched/cropped.
    var imageView = UIImageView()
    /// TELEGRAM'S CANVAS behind a photo that does not fill the card. See `StoryCanvas` for what this
    /// replaced and why: a live `UIVisualEffectView` over an aspect-filled copy of the photo, which
    /// re-sampled every frame and composited outside this view's transform, so every gesture that
    /// scaled the card tore it away from the picture it belonged to.
    private let canvasLayer = StoryCanvas.makeLayer()
    private let shimmer = ShimmerView()
    // The story's own poster, blurred, shown while the full-size media downloads (see
    // showPreviewBlur). Built lazily: a story that is already cached never needs one.
    private var previewBlur: UIImageView?
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
        // The canvas is framed through `StoryCanvas` rather than assigned directly: a CALayer
        // sublayer does not autoresize, and a bare `frame =` inside an animation block inherits that
        // animation, so the backdrop would lag the card it belongs to by one spring.
        StoryCanvas.frame(canvasLayer, to: bounds)
        imageView.frame = bounds
        shimmer.frame = bounds
        previewBlur?.frame = bounds
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
        let fills = StoryCanvas.fills(media: img.size, in: bounds.size)
        let want: UIView.ContentMode = fills ? .scaleAspectFill : .scaleAspectFit
        // A photo that fills has no bars, so there is nothing for the canvas to do and it is hidden
        // rather than left to composite under an opaque picture nobody can see through.
        canvasLayer.isHidden = fills
        // The early return is what makes calling this from `layoutSubviews` free, and it is what
        // guarantees a settled card can never flip the photo mid-gesture.
        guard imageView.contentMode != want else { return }
        imageView.contentMode = want
    }

    private func apply(_ image: UIImage?) {
        imageView.image = image
        // The canvas is coloured from the photo the moment the photo arrives, and never again for
        // it. There is no per-frame work behind a story any more, and nothing to freeze or thaw
        // while the viewers sheet scales the card: two colours in a layer scale like the pixels they
        // sit behind. (`StoryCanvas.apply` returns without touching the layer when the pair has not
        // moved, so a re-layout cannot restart an implicit colour animation.)
        if let image {
            StoryCanvas.apply(StoryCanvas.colours(of: image), to: canvasLayer)
        }
        decideContentMode()
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
            view = v
        }
        // BAKED, not a live material. This was the poster with a `UIVisualEffectView` laid over it,
        // and an effect view composites outside its own view's transform — so the loading state
        // sheared away from the card during the very gesture (the story flight) that it is most
        // often on screen for. `loadingVeil` is the same look as ordinary pixels.
        let box = bounds.width > 1 ? bounds.size : UIScreen.main.bounds.size
        view.image = StoryCanvas.loadingVeil(of: image, covering: box)
        view.frame = bounds
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

        // Reused for a different story (carousel jump mid-sheet): story A's loading cover must never
        // be the first thing you see of story B.
        //
        // The stale FROZEN BLUR this used to also have to clear here is gone with the blur itself.
        // Audit C1 was exactly that overlay outliving its story — a class of bug the canvas cannot
        // have, because it holds no picture of story A to leak, only two colours that are rewritten
        // the moment story B's photo lands.
        hidePreviewBlur()

        guard let imageURL else { imageIsLoaded(); return }   // malformed URL → don't freeze the progress bar

        // THE PREVIOUS STORY'S DOWNLOAD IS NO LONGER WANTED. It was left running: move through four
        // stories quickly and four full-size downloads competed for the connection, with the three
        // you had already left ahead of the one you were waiting on. On a weak network that is the
        // difference between a story appearing and a story spinning.
        loadTask?.cancel()
        loadTask = nil

        // ⚠️ THE `.stopVideo` BROADCAST THAT USED TO BE HERE IS GONE, AND IT HAD NO LEGITIMATE TARGET.
        //
        // It read "stop video if it's playing before image request", which sounds local and is not:
        // the notification carries no page identity, so EVERY mounted `PlayerView` obeyed it. The
        // pager pre-builds the neighbouring person's page, so loading a photo on a page nobody is
        // looking at reached across and stopped the video the user WAS watching — it froze on its
        // frame with the audio gone while the progress bar kept counting and the story advanced on
        // schedule.
        //
        // Nothing is lost by removing it. A page that shows a photo has no `VideoView` mounted at
        // all, and the one case where a page switches from a video item to a photo item is already
        // handled locally by `resetAVPlayer()` in the image branch of `getStoryView`. This post
        // could only ever hit somebody else's player.

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
       // TELEGRAM'S CANVAS, at the very back: for media that does not fill the card, a vertical
       // gradient between the colours at the top and bottom of the picture itself. A layer, not a
       // view, and deliberately so — it is the one backdrop primitive that survives being scaled by
       // a gesture, which is the entire history of this file.
       layer.addSublayer(canvasLayer)

       // Foreground: the photo at its TRUE aspect ratio — aspect-FIT so a square/landscape is never
       // cropped/zoomed. The empty top/bottom are the canvas above.
       imageView.contentMode = .scaleAspectFit
       imageView.clipsToBounds = true
       addSubview(imageView)

       shimmer.isHidden = true
       addSubview(shimmer)

       // `storyFreezeBlur` / `storyUnfreezeBlur` were observed here. Both are gone: they existed to
       // rasterize a live material before the viewers sheet scaled it, and there is no live material
       // left to rasterize. The `drawHierarchy(afterScreenUpdates: true)` that freeze needed is also
       // gone, and with it the re-entrancy it caused (build 495, `Kulan-2026-08-07-222010.ips`).
   }
}

// `freezeBlur` / `unfreezeBlur` / `installFreezeNow` / `rasterizeBlurBackdrop` lived here, and so
// did `rasterizeComposite` before them. Every one of them existed to photograph a live
// `UIVisualEffectView` before something scaled it, because a material cannot be scaled and cannot
// be composited at fractional opacity without falling apart. The material is gone, so the whole
// apparatus goes with it: no static `freezeWanted`, no notifications, no snapshot, and in
// particular no `drawHierarchy(afterScreenUpdates: true)` — which forced a CoreAnimation commit
// from inside SwiftUI's own update pass and crashed build 495 (`Kulan-2026-08-07-222010.ips`).
//
// What replaced all of it is `StoryCanvas`: two colours in a `CAGradientLayer`. There is nothing to
// freeze because there is nothing that recomputes itself.
