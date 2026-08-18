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

    /// ⚠️ THE MAIN THREAD PAYS THE DECODE HERE, AND THAT IS THE POINT — the reference app's
    /// `attemptSynchronous`.
    ///
    /// Its story item view takes exactly this branch for the item that has just become the current
    /// one: if the file is on disk it does `UIImage(contentsOfFile:)?.preparingForDisplay()` inline,
    /// inside the same update pass, and puts the picture up in that turn. It is not an oversight
    /// that this blocks — they measured it (their own timing print sits beside the call) and decided
    /// that a decode the eye reads as one heavier frame beats a hop the eye reads as a hole.
    ///
    /// Ours had only the async door: `decoded(for:)` hops to a detached task, and everything on the
    /// screen in the meantime had already been taken down. That gap IS the black frame, and no
    /// placeholder fixes it because the honest answer — the real picture — was on disk the whole time.
    ///
    /// ⚠️ ONLY EVER FOR THE ITEM BEING SHOWN RIGHT NOW. Called speculatively (a lookahead, a card in
    /// a row) this would put a full-size decode on the main thread for a story nobody is looking at,
    /// which is the opposite trade. The warm path below is what speculation uses.
    static func decodedNow(for url: URL) -> UIImage? {
        if let hit = image(for: url) { return hit }
        var raw: UIImage?
        if let cached = URLCache.shared.cachedResponse(for: .init(url: url)) {
            raw = UIImage(data: cached.data)
        }
        if raw == nil { raw = StoryDiskCache.image(url) }
        guard let raw else { return nil }
        let ready = raw.preparingForDisplay() ?? raw
        store(ready, for: url)
        return ready
    }

    /// PIXELS, NOT BYTES, FOR A STORY NOBODY HAS REACHED YET.
    ///
    /// The lookahead used to stop at bytes: it filled `URLCache` and the disk cache and left the
    /// decode to be paid at the moment of arrival, which is the one moment that cannot afford it.
    /// The reference app's preloader does not stop there either — for a video it goes as far as
    /// generating and caching the clip's FIRST FRAME as a picture before the story is reached.
    ///
    /// Everything expensive is off the main thread; a hit afterwards is a dictionary lookup, which
    /// is what makes the arrival happen inside one turn with nothing to hide.
    static func warm(_ url: URL) async {
        _ = await decoded(for: url)
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
    // Round the whole card (photo + canvas) in UIKit. This was forced by the old backdrop — a
    // SwiftUI `.clipShape` does not clip a `UIVisualEffectView`, which composites separately and
    // spilled past the mask, leaving the friend reply-bar card square. The canvas is an ordinary
    // layer and would clip either way; the UIKit mask stays because it is what the callers ask for
    // and it is one less thing to re-verify.
    //
    // ⚠️ IT NO LONGER SETS A RADIUS, ONLY WHETHER THIS VIEW CLIPS AT ALL. It used to round the bottom
    // two corners at a 24 of its own under a page clipping at 12 — his "image top corners and bottom
    // corners are different" — then all four at the page's own number, which cut the same arc twice.
    // The page owns the curve now and this owns the containment. See `applyCornerMask` for what two
    // masks on one arc actually look like, and `Constant.cardCornerRadius` for the measurement.
    var cardCornerRadius: CGFloat = 0 { didSet { applyCornerMask() } }
    // Foreground: the photo at its TRUE aspect ratio — never stretched/cropped.
    var imageView = UIImageView()
    /// THE REFERENCE APP'S CANVAS behind a photo that does not fill the card. See `StoryCanvas` for what this
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

    /// ⛔ THE AUTHOR ASKED FOR THIS STORY NOT TO BE COPIED. Read `CaptureShield` before touching it —
    /// in particular what iOS does and does not promise, which is most of the file.
    private lazy var shield = CaptureShield(host: self)

    /// Set from the story on every update, so the protection survives a pause, a swipe either way and
    /// an automatic advance rather than only being right on the first frame.
    var isCaptureProtected: Bool = false {
        didSet {
            guard isCaptureProtected != oldValue else { return }
            shield.onCaptureStateChanged = { [weak self] capturing in
                self?.applyCaptureBlank(capturing)
            }
            shield.setProtected(isCaptureProtected)
            applyCaptureBlank(shield.isCapturing)
        }
    }

    /// ⚠️ OPACITY, NOT A LAYOUT CHANGE AND NOT A TEARDOWN. A recording starting must not resize
    /// anything, reload anything or leave a hole the next layout pass has to fill — the picture is
    /// simply not drawn while the screen is being recorded or mirrored, and comes straight back.
    private func applyCaptureBlank(_ capturing: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shield.content.layer.opacity = capturing ? 0 : 1
        CATransaction.commit()
    }

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
        // FIRST, because everything below is positioned inside it. The shield holds the picture at
        // this view's own bounds whether it is shielded or not, so the four lines after this one are
        // the same lines they always were.
        shield.layout(in: bounds)
        shield.retryIfNeeded()
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

    // Round all four corners of THIS view (which clips every subview, blur included).
    //
    // ⚠️ `maskedCorners` IS BACK TO ALL FOUR AND `cornerCurve` IS SAID OUT LOUD. The card has had a
    // visible top edge since it started below the status bar, and a circle is the curve his
    // reference draws — measured, see `Constant.cardCornerRadius`. `.circular` is already the
    // default; naming it stops a future edit from reaching for `.continuous` and quietly making
    // this corner a different shape from the page clip drawn over it.
    private func applyCornerMask() {
        // ⛔ SQUARE ON PURPOSE, AND THE CURVE IS STILL THERE — the page's own `.clipShape` draws it.
        //
        // His 2026-08-18 comparison, his card beside theirs: "corners is not looks smooth". Half of
        // that was the radius (measured, and 15 → 16 in `Constant`). The other half was here: this
        // view rounded itself at exactly the radius the page was ALSO clipping at, so one arc was cut
        // twice. Antialiasing is coverage, and two coverages multiply — a boundary pixel at half
        // cover in each mask survives at a quarter, so the curve came out darker and harder-edged
        // than a single mask draws it. That is what "not smooth" looks like at 3x.
        //
        // ⚠️ `masksToBounds` STAYS. The reason this view clips at all is the backdrop spill the note
        // on `cardCornerRadius` describes; what it must not do is round. It clips to its own square
        // rect, the page rounds the result, and there is exactly one antialiased curve on screen.
        layer.cornerRadius = 0
        layer.masksToBounds = cardCornerRadius > 0
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
    /// Owner: "the standard messengers and other apps never use grey skeleton loading, they use
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
            // Inside the shield: it is a picture of the story, blurred, and a blurred copy of a
            // protected story is still a copy of it.
            shield.content.addSubview(v)
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
    private func seedPreviewBlur(_ previewURL: String?, blurThumb: String) -> Bool {
        // ⚠️ THE COVER THAT TRAVELS WITH THE STORY GOES FIRST WHEN NOTHING ELSE IS HELD, AND ITS
        // ABSENCE FROM THIS FILE WAS HALF THE BUG.
        //
        // The story document carries a ~30px JPEG as base64 (`blurThumb`, and the app's own note on
        // it says "this is the cover that cannot be missing"). It needs no network, no disk and no
        // cache — it arrived with the story. The video item view has used it as its floor since it
        // was built; this path never received it at all, so a photo whose bytes were not yet held
        // fell through to the shimmer, which is `white: 0.14` and on an OLED screen reads as black.
        //
        // This is the reference app's rule and it does not split the two media kinds either: its
        // story item view decodes `immediateThumbnailData` and puts it up blurred for an image and
        // for a video alike, before any fetch is started, in the same update pass.
        //
        // ⚠️ TRIED ONLY AFTER THE THREE CACHES BELOW HAVE MISSED. Thirty pixels blurred is the
        // FLOOR, not the preference: a poster already in hand is a real photograph and a better
        // picture than this will ever be. Ordered last for that reason, and reached in practice
        // only when this story has genuinely never been on this phone before.
        func seedFromBlurThumb() -> Bool {
            guard !blurThumb.isEmpty,
                  let data = Data(base64Encoded: blurThumb),
                  let img = UIImage(data: data) else { return false }
            showPreviewBlur(img)
            return true
        }
        guard let previewURL, let url = URL(string: previewURL) else { return seedFromBlurThumb() }
        // ⚠️ THE APP'S OWN CACHE IS ASKED FIRST, AND ITS ABSENCE HERE WAS HIS "the thumbnail turns
        // black for a fraction of a second".
        //
        // The two caches below are the LIBRARY'S. The app draws the stories row and the viewers
        // carousel through `DiskImageCache`, a different store in a different folder — so the poster
        // that is on screen in the row at this very moment is invisible to both of them. They miss,
        // the poster becomes a network fetch, and the loading state falls through to the shimmer.
        //
        // `StoryPosterSource` is the seam that was built for exactly this, and its own note names
        // this symptom: "there is nothing to hold the frame — which is the black." It was wired into
        // the VIDEO poster path and never into this one, so the photo path kept the hole the seam
        // exists to close. Synchronous and memory-only, so it costs a dictionary lookup and can only
        // ever make a poster arrive sooner.
        //
        // ⚠️ AND IT MATTERS NOW IN A WAY IT DID NOT BEFORE. Until the take-down above was moved ahead
        // of the first await, this branch was reached with the PREVIOUS story still on screen, so a
        // missing poster was invisible — you saw the wrong picture rather than no picture. Correcting
        // that is what put this path in front of him. The shimmer it falls back to is pinned to
        // `systemGray5`, which is ~44 in dark mode: on a black screen that reads as a black card,
        // which is what he photographed.
        if let warm = StoryPosterSource.provider?(previewURL) {
            showPreviewBlur(warm)
            return true
        }
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
        return seedFromBlurThumb()
    }

    func loadImageWithUrl(_ url: String?, previewURL: String? = nil, blurThumb: String = "",
                          imageIsLoaded: @escaping () -> Void) {

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
        // Nothing is lost by removing it, and less than ever now that a story ITEM owns its player.
        // A page showing a photo has no video view mounted at all, and a page switching from a video
        // item to a photo item dismantles the video item's own view, which releases that view's own
        // player. Nothing has to be told and there is nobody else's player to reach.

        // 1) ALREADY DECODED AND READY. A dictionary lookup and a pointer — no file read, no decode,
        //    and crucially no dispatch: the picture is on screen in this same turn, which is what
        //    makes a re-opened story appear with no frame of anything else.
        if let ready = StoryMemoryCache.image(for: imageURL) {
            showShimmer(false)
            apply(ready)
            imageIsLoaded()
            return
        }

        // ⚠️ THE APP IS USUALLY DRAWING THIS EXACT PICTURE ALREADY, AND NOT ASKING IT FOR THE REAL
        // THING — ONLY FOR A VEIL — WAS HIS "the centre thumbnail turns dark for a moment on every
        // swipe".
        //
        // For a photo story `previewUrl` IS `mediaUrl` (see `Story.previewUrl` in the app), so the
        // poster the app's own cache holds is not a stand-in for this story's media, it is this
        // story's media: the same url, the same bytes, decoded once when the row's card drew it. The
        // moment the viewers-sheet hand-over reveals this page, that card is ON SCREEN showing the
        // full picture — and this view, asked for the identical url, would put up
        // `loadingVeil` (the picture at 1/8 size under 45% black) while it went off to download and
        // decode the same bytes a second time into its own caches. A sharp card replaced by a
        // darkened smear of itself for the length of a decode is exactly the flash he photographed,
        // and it is why the flash was on EVERY arrival: the lookahead warms `URLCache` (bytes), never
        // `StoryMemoryCache` (pixels), so the synchronous branch above misses for every story not
        // already visited this session.
        //
        // The video path has followed this rule since the cover ranks were built ("a real frame of
        // this clip goes up AS IT IS, so the hand-over to the live layer is invisible" — its own
        // words): only the ~30px embedded thumbnail is ever blurred. This is that rule for photos.
        //
        // ⚠️ KEYED BY THE RAW STRING, not `imageURL.absoluteString`: the app stores under the string
        // it was handed (`DiskImageCache` is a `String`-keyed store), and a round trip through
        // `URL(string:)` is allowed to re-encode. The raw string is the one key both sides share.
        //
        // Stored into `StoryMemoryCache` so the next arrival of this story takes the branch above,
        // and marked loaded because it IS the media, not a placeholder for it — the progress bar
        // should run.
        if let warm = StoryPosterSource.provider?(validatedUrl) {
            showShimmer(false)
            StoryMemoryCache.store(warm, for: imageURL)
            apply(warm)
            imageIsLoaded()
            return
        }

        // ⚠️ THE STORY WE JUST LEFT IS STILL ON SCREEN AT THIS LINE, AND TAKING IT DOWN HERE — BEFORE
        // THE FIRST AWAIT — IS HIS "the previous story's image flashes inside the new centre
        // thumbnail".
        //
        // This view is reused between stories, and nothing above ever cleared the picture in it. The
        // url was replaced, the blurred poster was hidden, the download was cancelled — and
        // `imageView.image`, the one thing the eye can actually see, was left holding story A while
        // story B's lookup went away and came back. The only line that took it down, `apply(nil)`,
        // lived in `loadFromNetwork`, which is TWO awaits further on: past the async memory lookup and
        // past the disk read. So every arrival that was not already decoded in memory drew story A,
        // sharp and full size, for as long as story B took to find itself.
        //
        // ⚠️ IT IS WORST ON EXACTLY THE GESTURE HE REPORTED IT ON. The lookahead only ever warms the
        // NEXT story, so a flick that skips one lands on a story with nothing decoded — the slow path,
        // every time — while a story stepped through one at a time is usually already in memory and
        // takes the synchronous branch above, where the swap happens inside this turn and there is no
        // gap to see. That is why it reads as a fast-swipe bug and not as a bug in every open.
        //
        // The loading state moves up with it, unsplit: the take-down and what replaces it are one
        // decision and were never two. Below this line the view shows this story's own blurred poster
        // (or the shimmer, if we do not even hold that yet) and nothing else — which is what it shows
        // at the end of a real download too, so the arrival looks the same however the picture got
        // here.
        // 2b) ⚠️ ON DISK COUNTS AS HELD, AND ASKING SYNCHRONOUSLY IS THE WHOLE FIX FOR THE BLACK
        //     FRAME BETWEEN ONE STORY AND THE NEXT.
        //
        //     Everything above is a memory lookup, so before this line the ONLY way to arrive
        //     without a flash was to have already watched this story in this session. The bytes
        //     being on disk — which after one lookahead pass they almost always are — still went
        //     the long way round: take the picture down, put a placeholder up, hop to a detached
        //     task, read, decode, come back. Forty to ninety milliseconds of not-the-story, on
        //     every first visit to every item, which is exactly the report: worst straight after
        //     launch, and gone once you tap back through the same stories a second time.
        //
        //     The reference app's story item view has this branch and takes it for the item that
        //     has just become current: file on disk → `preparingForDisplay()` inline → picture up
        //     in this turn. It blocks the main thread for the length of one decode and they kept
        //     it deliberately. A heavier frame is a thing nobody sees; a hole is the thing he
        //     photographed.
        //
        //     ⚠️ IT SITS BELOW THE TWO MEMORY DOORS AND ABOVE EVERYTHING ELSE, so a story already
        //     decoded never pays it twice, and `decodedNow` stores what it builds, so neither does
        //     the second visit to this one.
        if let ready = StoryMemoryCache.decodedNow(for: imageURL) {
            showShimmer(false)
            apply(ready)
            imageIsLoaded()
            return
        }

        // ⚠️ THE FLOOR GOES UP BEFORE THE OLD PICTURE COMES DOWN, AND THE ORDER IS THE RULE.
        //
        // The take-down had to move above the first await (story A was being left on screen while
        // story B looked itself up), and that was right. What it did not have was a guarantee that
        // anything was replacing it — `seedPreviewBlur` was allowed to answer "nothing", and the
        // shimmer it fell back to is `white: 0.14`. So the fix for one hole opened a smaller one.
        //
        // The reference app never reaches this state because it never clears at all: its update is
        // wrapped in `if isMediaUpdated` and there is no `image = nil` anywhere in the file. It can
        // afford that because each story owns its OWN view — the one being left slides away with
        // its picture still in it. Ours is one view reused between stories, so leaving the picture
        // up genuinely shows the wrong story. Replace, then, rather than clear: work out what is
        // going up first, and only take the old picture down once something is standing in its
        // place. With `blurThumb` in the chain there is always something, because it arrived on the
        // story document itself.
        let floorIsUp = seedPreviewBlur(previewURL, blurThumb: blurThumb)
        apply(nil)
        if !floorIsUp { showShimmer(true) }

        // 3) NOTHING IS HELD ANYWHERE, so this is the download. The re-check in front of it is not
        //    redundant with `decodedNow` above: the lookahead runs on its own queue and can land
        //    this story's bytes in the gap between that line and this one, and finding them here
        //    saves a second fetch of something already on the disk.
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
            self.loadFromNetwork(wanted, imageIsLoaded: imageIsLoaded)
        }
    }

    /// Nothing is held for this url, so it has to come down. Split out of `loadImageWithUrl` because
    /// the cache lookup above it is asynchronous now and this is what happens when it misses.
    private func loadFromNetwork(_ imageURL: URL, imageIsLoaded: @escaping () -> Void) {
        // 3) Network. ⚠️ THE BLURRED POSTER IS ALREADY UP AND THE OLD PICTURE IS ALREADY DOWN — both
        //    happened in `loadImageWithUrl`, before its first await, because a view still wearing the
        //    last story is not something to fix after two hops. Seeding the poster a second time here
        //    would start a second fetch for it; putting `apply(nil)` here again would clear a photo
        //    the disk branch may have just landed.
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
       // THE REFERENCE APP'S CANVAS, at the very back: for media that does not fill the card, a vertical
       // gradient between the colours at the top and bottom of the picture itself. A layer, not a
       // view, and deliberately so — it is the one backdrop primitive that survives being scaled by
       // a gesture, which is the entire history of this file.
       // ⚠️ INTO THE SHIELD'S CONTENT, NOT ONTO THIS VIEW. Everything that is the PICTURE goes in
       // there so one `addSublayer` can move the whole lot inside the system's secure canvas for a
       // protected story — see `CaptureShield`. The shield's content is laid out to these exact
       // bounds every pass, so this is the same coordinate space it always was.
       shield.content.layer.addSublayer(canvasLayer)

       // Foreground: the photo at its TRUE aspect ratio — aspect-FIT so a square/landscape is never
       // cropped/zoomed. The empty top/bottom are the canvas above.
       imageView.contentMode = .scaleAspectFit
       imageView.clipsToBounds = true
       shield.content.addSubview(imageView)

       // ⚠️ THE SKELETON STAYS OUTSIDE THE SHIELD. It is not the picture, it carries nothing, and a
       // shimmer that vanishes from a screenshot only tells the person the shield is there.
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
