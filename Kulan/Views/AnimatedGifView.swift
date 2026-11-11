import SwiftUI
import UIKit
import ImageIO
import CryptoKit

// Persistent disk store for raw GIF bytes (keyed by URL) — so a GIF downloads ONCE and replays from
// disk on every relaunch, no re-download. Application Support (permanent), excluded from backup.
enum GifBytesCache {
    private static var dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("gif-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var mutable = d; try? mutable.setResourceValues(values)
        return d
    }()
    private static func file(_ url: String) -> URL {
        let key = SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(key).appendingPathExtension("gif")
    }
    static func data(_ url: String) -> Data? { try? Data(contentsOf: file(url)) }
    static func store(_ data: Data, _ url: String) {
        try? data.write(to: file(url), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

// Plays an animated GIF from a URL with zero third-party deps. The bytes go through `GifStore`
// (one shared cache, bounded in bytes) and play in a `GifPlayerImageView`. Used in the GIF picker,
// the gallery, story stickers and the SwiftUI chat paths.
struct AnimatedGifView: UIViewRepresentable {
    let url: String
    /// ⚠️ A STICKER IS NOT A GIF IN A BOX, and these two parameters are the whole difference.
    ///
    /// A GIF in a chat is a rectangle: it fills its cell and wears a grey placeholder while it
    /// downloads. A sticker is drawn on transparency and has to arrive with NOTHING behind it — a
    /// placeholder fill would be a grey square around it, and `scaleAspectFill` would crop the very
    /// edges the artwork was cut out to have. Defaults are exactly what every existing caller had.
    var fill: Bool = true
    var placeholder: UIColor = .secondarySystemFill

    func makeUIView(context: Context) -> GifPlayerImageView {
        let v = GifPlayerImageView()
        v.contentMode = fill ? .scaleAspectFill : .scaleAspectFit
        v.clipsToBounds = true
        v.backgroundColor = placeholder
        // ⚠️ IT MUST ACCEPT THE SIZE IT IS OFFERED, AND THIS IS HIS "stickers are overlapping each
        // other". A `UIImageView` has an INTRINSIC content size — its image's own pixel size — and a
        // representable that insists on one is a representable that grows past the cell SwiftUI laid
        // out for it. A 480px sticker in a 90pt grid square therefore drew five times its square,
        // straight over its neighbours. Dropping both priorities makes the offered size win.
        for axis in [NSLayoutConstraint.Axis.horizontal, .vertical] {
            v.setContentHuggingPriority(.defaultLow, for: axis)
            v.setContentCompressionResistancePriority(.defaultLow, for: axis)
        }
        load(into: v, context.coordinator)
        return v
    }

    func updateUIView(_ v: GifPlayerImageView, context: Context) {
        if context.coordinator.loadedURL != url { load(into: v, context.coordinator) }
    }

    /// The GIF provider's media hosts and our own storage.
    static let allowedHosts = ["giphy.com", "firebasestorage.googleapis.com", "storage.googleapis.com", "fariin.com"]

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var loadedURL: String? }

    private func load(into v: GifPlayerImageView, _ coord: Coordinator) {
        coord.loadedURL = url   // mark BEFORE loading so re-renders/updates don't re-download+re-decode
        // Only hosts the app itself serves GIFs from (audit 06 F9): a crafted GIF message with any
        // https url made every reader's phone fetch it, leaking their IP and when they read.
        guard let u = URL(string: url), u.scheme == "https", let host = u.host?.lowercased(),
              Self.allowedHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else {
            v.show(nil); return
        }
        if let hit = GifStore.cached(url) { v.show(hit); return }
        v.show(nil)
        let requested = url
        Task { @MainActor in
            let movie = await GifStore.load(requested)
            // The view may have been REUSED for a different GIF while this was in flight (grid
            // reuse): only assign if it still wants THIS url, the "wrong GIF flashes" bug.
            guard coord.loadedURL == requested else { return }
            v.show(movie)
        }
    }
}

/// One GIF, ready to play (perf audit 2026-11-11 M1/L3).
///
/// ⛔ NEVER EVERY FRAME OF A BIG GIF IN MEMORY. The old path decoded every frame to a 600 px bitmap
/// up front: a 100-frame GIF was about 140 MB, and the chat cache had no limit at all. Now a GIF
/// whose frames all fit in `GifStore.wholeBudget` is still decoded whole (cheap, and UIKit animates
/// it), and anything bigger keeps only its compressed bytes and is decoded one frame at a time while
/// it plays, one frame ahead, so it costs two frames instead of all of them.
final class GifMovie {
    /// The first frame, decoded. What shows while paused, off screen, or as a still thumbnail.
    let still: UIImage
    /// Every frame decoded, for a small GIF; nil for a streamed one.
    let animated: UIImage?
    let frameCount: Int
    /// Per frame, in seconds.
    let delays: [Double]
    /// Bytes this entry holds, for the cache's limit.
    let cost: Int
    fileprivate let source: CGImageSource?
    fileprivate let options: CFDictionary
    /// Serial: one source is only ever asked for one frame at a time.
    private let queue = DispatchQueue(label: "gif.frames", qos: .userInitiated)

    var isStreamed: Bool { source != nil && frameCount > 1 }

    fileprivate init(still: UIImage, animated: UIImage?, frameCount: Int, delays: [Double], cost: Int,
                     source: CGImageSource?, options: CFDictionary) {
        self.still = still; self.animated = animated; self.frameCount = frameCount
        self.delays = delays; self.cost = cost; self.source = source; self.options = options
    }

    /// Decodes frame `i` off the main thread; `done` runs on that background queue.
    func frame(_ i: Int, _ done: @escaping (UIImage?) -> Void) {
        let source = self.source, options = self.options
        queue.async {
            let cg = source.flatMap { CGImageSourceCreateThumbnailAtIndex($0, i, options) }
            done(cg.map { UIImage(cgImage: $0) })
        }
    }
}

/// The one GIF cache for the whole app (chat bubbles, picker, gallery, reply banner), bounded in
/// BYTES, with one load job per url so two views asking for the same GIF share one download.
enum GifStore {
    /// Frames are made at most this many pixels on the long side: no GIF spot in the app is wider.
    static let maxPixel = 600
    /// A GIF whose frames, all decoded, fit under this is decoded whole; above it, it streams.
    static let wholeBudget = 6 * 1024 * 1024

    private static let cache: NSCache<NSString, GifMovie> = {
        let c = NSCache<NSString, GifMovie>()
        c.totalCostLimit = 48 * 1024 * 1024
        c.countLimit = 80
        return c
    }()

    static func cached(_ url: String) -> GifMovie? { cache.object(forKey: url as NSString) }

    @MainActor private static var jobs: [String: Task<GifMovie?, Never>] = [:]

    /// Disk bytes first, then the network; decoded off main; cached with its byte cost. Nil when
    /// the bytes are not an image at all, and then nothing is cached, so the next ask retries.
    @MainActor static func load(_ url: String) async -> GifMovie? {
        if let hit = cached(url) { return hit }
        if let running = jobs[url] { return await running.value }
        let cache = Self.cache
        let t = Task.detached(priority: .userInitiated) { () async -> GifMovie? in
            if let bytes = GifBytesCache.data(url), let m = GifStore.movie(data: bytes) {
                cache.setObject(m, forKey: url as NSString, cost: m.cost)
                return m
            }
            // The app's own session rather than `URLSession.shared`, the shared cookie jar.
            guard let u = URL(string: url),
                  let data = try? await MediaSession.shared.data(from: u).0,
                  let m = GifStore.movie(data: data) else { return nil }
            GifBytesCache.store(data, url)
            cache.setObject(m, forKey: url as NSString, cost: m.cost)
            return m
        }
        jobs[url] = t
        let m = await t.value
        if jobs[url] == t { jobs[url] = nil }
        return m
    }

    /// Builds a movie from GIF (or any still image) bytes. Call off the main thread.
    static func movie(data: Data) -> GifMovie? {
        // ⛔ DECODED OFF THE MAIN THREAD, AT A SIZE THE SCREEN CAN USE (owner's cpu report,
        // 2026-11-01: 91% for 99 s on main in ImageIO). Thumbnails made with CacheImmediately come
        // out as finished bitmaps, so nothing decodes again while it draws.
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        // The source itself keeps no decoded frames: ours are the only copies.
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0,
              let first = CGImageSourceCreateThumbnailAtIndex(src, 0, options) else { return nil }
        let count = CGImageSourceGetCount(src)
        let frameBytes = first.bytesPerRow * first.height
        let still = UIImage(cgImage: first)
        guard count > 1 else {
            return GifMovie(still: still, animated: nil, frameCount: 1, delays: [0.1], cost: frameBytes,
                            source: nil, options: options)
        }
        // Delays come from the frame properties alone: no frame is decoded to read them.
        let delays: [Double] = (0..<count).map { i in
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let d = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            return max(d, 0.02)
        }
        if frameBytes * count <= wholeBudget {
            var frames: [UIImage] = [still]
            for i in 1..<count {
                if let cg = CGImageSourceCreateThumbnailAtIndex(src, i, options) { frames.append(UIImage(cgImage: cg)) }
            }
            let whole = UIImage.animatedImage(with: frames, duration: delays.reduce(0, +))
            return GifMovie(still: still, animated: whole, frameCount: count, delays: delays,
                            cost: frameBytes * count, source: nil, options: options)
        }
        return GifMovie(still: still, animated: nil, frameCount: count, delays: delays,
                        cost: data.count + frameBytes * 2, source: src, options: options)
    }
}

/// Plays a `GifMovie` only while it can be seen: in a window, not hidden, and (for list rows) told
/// it is on screen. A whole movie is UIKit's animated image; a streamed one is stepped here on a
/// display link at its own frame times, with the next frame decoded in the background one step
/// ahead. Not visible, it rests on the first frame and the link is gone.
class GifPlayerImageView: UIImageView {
    private(set) var movie: GifMovie?
    /// Set by a list row from its cell's willDisplay / didEndDisplaying. True for views outside lists.
    var onScreen = true { didSet { if onScreen != oldValue { updatePlayback() } } }

    private var link: CADisplayLink?
    private var index = 0
    private var due: CFTimeInterval = 0
    private var pendingFrame: UIImage?
    private var nextIndex = -1
    private var decoding = false
    private var generation = 0
    private var showingWhole = false

    func show(_ m: GifMovie?) {
        if m == nil, movie == nil, image == nil { return }
        if let m, m === movie { return }
        generation += 1
        movie = m
        index = 0; pendingFrame = nil; nextIndex = -1; decoding = false; due = 0; showingWhole = false
        image = m?.still
        updatePlayback()
    }

    override func didMoveToWindow() { super.didMoveToWindow(); updatePlayback() }
    override var isHidden: Bool { didSet { if isHidden != oldValue { updatePlayback() } } }

    private var canPlay: Bool { window != nil && !isHidden && onScreen }

    private func updatePlayback() {
        guard let m = movie else { stopLink(); return }
        if let whole = m.animated {
            stopLink()
            if canPlay, !showingWhole { image = whole; showingWhole = true }
            else if !canPlay, showingWhole { image = m.still; showingWhole = false }
            return
        }
        guard m.isStreamed, canPlay else { stopLink(); return }
        guard link == nil else { return }
        let l = CADisplayLink(target: GifLinkTarget(self), selector: #selector(GifLinkTarget.tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
        l.add(to: .main, forMode: .common)
        link = l
        due = 0
        prefetch()
    }

    private func stopLink() { link?.invalidate(); link = nil }

    fileprivate func tick(_ l: CADisplayLink) {
        guard let m = movie, m.isStreamed else { stopLink(); return }
        let now = l.timestamp
        if due == 0 { due = now + m.delays[index]; return }
        guard now >= due else { return }
        let want = (index + 1) % m.frameCount
        // Not decoded yet: hold the current frame rather than skip ahead.
        guard nextIndex == want, let img = pendingFrame else { prefetch(); return }
        image = img
        index = want
        pendingFrame = nil; nextIndex = -1
        // A late tick does not build a debt of frames to catch up on.
        due = max(due + m.delays[index], now)
        prefetch()
    }

    private func prefetch() {
        guard let m = movie, m.isStreamed, !decoding, pendingFrame == nil else { return }
        let want = (index + 1) % m.frameCount
        decoding = true
        let gen = generation
        m.frame(want) { [weak self] img in
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.decoding = false
                // A frame that will not decode is stepped over.
                if let img { self.pendingFrame = img; self.nextIndex = want } else { self.index = want }
            }
        }
    }

}

/// The display link holds its target strongly; this keeps it from holding the view.
private final class GifLinkTarget: NSObject {
    weak var view: GifPlayerImageView?
    init(_ v: GifPlayerImageView) { view = v }
    @objc func tick(_ l: CADisplayLink) {
        guard let view else { l.invalidate(); return }
        view.tick(l)
    }
}
