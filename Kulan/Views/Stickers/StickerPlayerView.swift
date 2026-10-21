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
    private static let animKey = "sticker.frames"
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
        self.url = url
        frames = nil
        art.removeAnimation(forKey: Self.animKey)
        art.contents = nil
        tgs = nil
        if let v = lottie {
            v.stop()
            v.animation = nil
            v.isHidden = true
        }
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
        let v: LottieAnimationView
        if let have = lottie {
            v = have
            v.animation = anim
        } else {
            v = TGSSticker.makeView(anim)
            insertSubview(v, belowSubview: skeleton)
            lottie = v
        }
        v.frame = bounds
        v.isHidden = false
        v.currentProgress = 0
        skeleton.fadeOut()
        apply()
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
        if let v = lottie, tgs != nil {
            let should = wantsPlay && window != nil && !ProcessInfo.processInfo.isLowPowerModeEnabled
            if should {
                if !v.isAnimationPlaying { v.play() }
            } else if v.isAnimationPlaying {
                v.pause()
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
