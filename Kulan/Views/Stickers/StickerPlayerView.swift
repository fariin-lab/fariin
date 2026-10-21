import UIKit
import ImageIO
import Lottie

// ⛔ ONE STICKER, STILL OR MOVING — 2026-10-17, the sticker keyboard. A plain UIKit view: frames are
// decoded OFF the main thread, DOWNSAMPLED to the pixel size the tile is drawn at (ImageIO thumbnail
// per frame; never the full 512px art, which is what `AnimatedGifView` does and why it is not used
// here), cached by url + pixel size, and played by a Core Animation keyframe animation on a layer's
// `contents`. No display link, no timer, and ⛔ never SwiftUI repeatForever (the iOS 26 deadlock).
// Plays only when told to (visible cells), and never in Low Power Mode.
//
// ⛔ A .TGS PLAYS AS VECTORS — owner 2026-10-21: an animated .tgs (gzipped Lottie) is decoded off the
// main thread by `TGSSticker` and drawn by a `LottieAnimationView` over the same tile, under the same
// rules: plays only while told to and in a window, paused in Low Power Mode. Never turned into frames.

final class StickerFrames {
    let images: [CGImage]
    let delays: [Double]
    var duration: Double { delays.reduce(0, +) }
    init(images: [CGImage], delays: [Double]) { self.images = images; self.delays = delays }
    var cost: Int { images.reduce(0) { $0 + $1.bytesPerRow * $1.height } }
}

enum StickerFrameCache {
    static let cache: NSCache<NSString, StickerFrames> = {
        let c = NSCache<NSString, StickerFrames>()
        c.totalCostLimit = 64 * 1024 * 1024
        return c
    }()

    /// Decodes at most two stickers at once so a fast scroll does not start forty decodes.
    static let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated
        return q
    }()

    /// A tile does not need every frame of a 60fps animation; past this many, frames are merged.
    static let maxFrames = 30

    static func key(_ url: URL, _ px: Int) -> NSString { "\(url.path)#\(px)" as NSString }

    /// Runs on `queue`. Downsampled frames and their delays.
    static func decode(_ url: URL, maxPixel px: Int) -> StickerFrames? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, px),
        ]
        let step = max(1, Int((Double(count) / Double(maxFrames)).rounded(.up)))
        var images: [CGImage] = []
        var delays: [Double] = []
        var i = 0
        while i < count {
            guard let img = CGImageSourceCreateThumbnailAtIndex(src, i, opts as CFDictionary) else { i += step; continue }
            var d = 0.0
            for j in i..<min(i + step, count) { d += frameDelay(src, j) }
            images.append(img)
            delays.append(d)
            i += step
        }
        guard !images.isEmpty else { return nil }
        return StickerFrames(images: images, delays: delays)
    }

    private static func frameDelay(_ src: CGImageSource, _ i: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any] else { return 1.0 / 30 }
        var d: Double?
        if let w = props[kCGImagePropertyWebPDictionary] as? [CFString: Any] {
            d = (w[kCGImagePropertyWebPUnclampedDelayTime] as? Double) ?? (w[kCGImagePropertyWebPDelayTime] as? Double)
        } else if let g = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            d = (g[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (g[kCGImagePropertyGIFDelayTime] as? Double)
        } else if let p = props[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
            d = (p[kCGImagePropertyAPNGUnclampedDelayTime] as? Double) ?? (p[kCGImagePropertyAPNGDelayTime] as? Double)
        }
        guard let v = d, v >= 0.02 else { return 1.0 / 30 }
        return v
    }
}

final class StickerPlayerView: UIView {
    private let art = CALayer()
    private var frames: StickerFrames?
    /// A .tgs sticker (owner 2026-10-21): the decoded animation and the view that draws it.
    private var tgs: LottieAnimation?
    private var lottie: LottieAnimationView?
    private var token = 0
    private(set) var url: URL?
    /// What the owner asked for; Low Power Mode and a missing window can still hold it back.
    private var wantsPlay = false
    /// The tile's side in points, for a .tgs still drawn at the size it shows.
    private var tilePoints: CGFloat = 80
    private static let animKey = "sticker.frames"

    // ⛔ NO LIVE .tgs WHILE THE PANEL SCROLLS — owner 2026-10-21: "the sticker keyboard lags when I
    // scroll". Every tile built a whole Lottie layer tree on the main thread as it came on screen.
    // Now a moving panel shows each animated sticker's saved still (`TGSSticker.stillAsync`); live
    // animations start once the grid stops, one tile per run-loop turn, and a tile that leaves the
    // screen lets its animation go.
    static let scrollChanged = Notification.Name("StickerPanel.scrollChanged")
    @MainActor static private(set) var panelScrolling = false
    @MainActor static func setPanelScrolling(_ on: Bool) {
        guard on != panelScrolling else { return }
        panelScrolling = on
        NotificationCenter.default.post(name: scrollChanged, object: nil)
    }
    @MainActor private static var startJobs: [() -> Void] = []
    @MainActor private static var starting = false
    @MainActor private static func enqueueStart(_ job: @escaping () -> Void) {
        startJobs.append(job)
        drainStarts()
    }
    @MainActor private static func drainStarts() {
        guard !starting, !startJobs.isEmpty else { return }
        starting = true
        let job = startJobs.removeFirst()
        DispatchQueue.main.async { job(); starting = false; drainStarts() }
    }
    private var startPending = false
    /// At most this many live animations at once (owner 2026-10-21, panel lag): a stopped grid with
    /// thirty animated tiles started thirty Lottie trees; past the cap a tile keeps its still.
    @MainActor private static var liveCount = 0
    private static let liveCap = 12
    /// Owner 2026-10-18: a tile still decoding showed nothing. The shimmer stands in until its
    /// first frame is up; a cache hit never shows it.
    private let skeleton = SkeletonShimmerView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        art.contentsGravity = .resizeAspect
        layer.addSublayer(art)
        addSubview(skeleton)
        NotificationCenter.default.addObserver(self, selector: #selector(powerChanged),
                                               name: .NSProcessInfoPowerStateDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(powerChanged),
                                               name: Self.scrollChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        art.frame = bounds
        art.contentsScale = window?.screen.scale ?? UIScreen.main.scale
        CATransaction.commit()
        lottie?.frame = bounds
        skeleton.frame = bounds.insetBy(dx: 2, dy: 2)
        skeleton.layer.cornerRadius = min(16, skeleton.bounds.width * 0.18)
    }

    /// Shows a sticker. `pixelSize` is the longest side the tile is drawn at, in pixels.
    func setSticker(url: URL?, pixelSize: Int) {
        guard url != self.url || (frames == nil && tgs == nil) else { return }
        token += 1
        tilePoints = CGFloat(pixelSize) / max(1, UIScreen.main.scale)
        self.url = url
        frames = nil
        art.removeAnimation(forKey: Self.animKey)
        art.contents = nil
        tgs = nil
        dropLottie()
        guard let url else { skeleton.setActive(false); return }
        if TGSSticker.isTGS(url) { loadTGS(url); return }
        let key = StickerFrameCache.key(url, pixelSize)
        if let hit = StickerFrameCache.cache.object(forKey: key) {
            skeleton.setActive(false)
            show(hit)
            return
        }
        skeleton.setActive(true)
        let mine = token
        StickerFrameCache.queue.addOperation {
            guard let f = StickerFrameCache.decode(url, maxPixel: pixelSize) else {
                // A file that will not decode: no shimmer forever over nothing.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.token == mine else { return }
                    self.skeleton.setActive(false)
                }
                return
            }
            StickerFrameCache.cache.setObject(f, forKey: key, cost: f.cost)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.token == mine else { return }
                self.show(f)
            }
        }
    }

    private func show(_ f: StickerFrames) {
        frames = f
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        art.contents = f.images.first
        CATransaction.commit()
        skeleton.fadeOut()
        apply()
    }

    /// The .tgs path: a cache hit shows at once; otherwise decoded on the sticker queue.
    private func loadTGS(_ url: URL) {
        if let hit = TGSSticker.cached(url.path) {
            skeleton.setActive(false)
            showTGS(hit)
            return
        }
        skeleton.setActive(true)
        let mine = token
        StickerFrameCache.queue.addOperation {
            let anim = TGSSticker.animation(url: url)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.token == mine else { return }
                guard let anim else { self.skeleton.setActive(false); return }
                self.showTGS(anim)
            }
        }
    }

    private func showTGS(_ anim: LottieAnimation) {
        tgs = anim
        guard let url else { return }
        let mine = token
        TGSSticker.stillAsync(url: url, side: tilePoints) { [weak self] img in
            guard let self, self.token == mine else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.art.contents = img?.cgImage
            CATransaction.commit()
            self.skeleton.fadeOut()
            self.apply()
        }
    }

    /// The live view goes entirely when not playing, so a scrolled-past tile holds no layer tree.
    private func dropLottie() {
        startPending = false
        guard let v = lottie else { return }
        v.stop()
        v.removeFromSuperview()
        lottie = nil
        Self.liveCount = max(0, Self.liveCount - 1)
        art.isHidden = false
    }

    func play() { wantsPlay = true; apply() }
    func stop() { wantsPlay = false; apply() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        apply()
    }

    @objc private func powerChanged() {
        DispatchQueue.main.async { [weak self] in self?.apply() }
    }

    private func apply() {
        if let anim = tgs {
            let should = wantsPlay && window != nil && !ProcessInfo.processInfo.isLowPowerModeEnabled
                && !Self.panelScrolling
            guard should else { dropLottie(); return }
            if let v = lottie {
                if !v.isAnimationPlaying { v.play() }
                return
            }
            guard !startPending else { return }
            startPending = true
            let mine = token
            Self.enqueueStart { [weak self] in
                guard let self, self.token == mine, self.startPending, self.tgs === anim,
                      self.wantsPlay, self.window != nil, !Self.panelScrolling,
                      Self.liveCount < Self.liveCap else {
                    self?.startPending = false
                    return
                }
                Self.liveCount += 1
                self.startPending = false
                let v = TGSSticker.makeView(anim)
                v.frame = self.bounds
                self.insertSubview(v, belowSubview: self.skeleton)
                self.lottie = v
                v.currentProgress = 0
                self.art.isHidden = true
                v.play()
            }
            return
        }
        let running = art.animation(forKey: Self.animKey) != nil
        let should = wantsPlay && window != nil && !ProcessInfo.processInfo.isLowPowerModeEnabled
            && (frames?.images.count ?? 0) > 1
        if should == running { return }
        guard should, let f = frames else {
            art.removeAnimation(forKey: Self.animKey)
            return
        }
        let total = max(f.duration, 0.05)
        var times: [NSNumber] = []
        var t = 0.0
        for d in f.delays { times.append(NSNumber(value: t / total)); t += d }
        times.append(1)   // discrete mode wants one more key time than values, ending at 1
        let a = CAKeyframeAnimation(keyPath: "contents")
        a.values = f.images
        a.keyTimes = times
        a.calculationMode = .discrete
        a.duration = total
        a.repeatCount = .infinity
        a.isRemovedOnCompletion = false
        art.add(a, forKey: Self.animKey)
    }
}
