import UIKit
import ImageIO

// ⛔ ONE STICKER, STILL OR MOVING — 2026-10-17, the sticker keyboard. A plain UIKit view: frames are
// decoded OFF the main thread, DOWNSAMPLED to the pixel size the tile is drawn at (ImageIO thumbnail
// per frame; never the full 512px art, which is what `AnimatedGifView` does and why it is not used
// here), cached by url + pixel size, and played by a Core Animation keyframe animation on a layer's
// `contents`. No display link, no timer, and ⛔ never SwiftUI repeatForever (the iOS 26 deadlock).
// Plays only when told to (visible cells), and never in Low Power Mode.
//
// ⛔ A .TGS — owner 2026-10-21 (played natively), 2026-10-23 (lag): drawn by `TGSEngine` (rlottie, off
// the main thread) into a `TGSPlayer` layer at 2x the tile at most and half the file's frame rate,
// the reference app's panel. Plays while told to and in a window, scrolling included.

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
    private var isTGS = false
    private let player = TGSPlayer()
    private var token = 0
    private(set) var url: URL?
    private var wantsPlay = false
    private var tilePoints: CGFloat = 80
    private static let animKey = "sticker.frames"

    /// The panel says when it scrolls. .tgs tiles no longer stop for it (the reference app's keep
    /// playing); kept because the panel still posts it.
    static let scrollChanged = Notification.Name("StickerPanel.scrollChanged")
    @MainActor static private(set) var panelScrolling = false
    @MainActor static func setPanelScrolling(_ on: Bool) {
        guard on != panelScrolling else { return }
        panelScrolling = on
        NotificationCenter.default.post(name: scrollChanged, object: nil)
    }
    private let skeleton = SkeletonShimmerView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        art.contentsGravity = .resizeAspect
        layer.addSublayer(art)
        layer.addSublayer(player)
        addSubview(skeleton)
        // The engine's first frame replaces both the still and the shimmer (owner 2026-10-23: the
        // shimmer could stay over a playing sticker when no still arrived first).
        player.onFirstFrame = { [weak self] in self?.art.isHidden = true; self?.skeleton.fadeOut() }
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
        player.frame = bounds
        CATransaction.commit()
        // ⛔ SHARP AT THE SIZE IT IS SHOWN (owner 2026-10-23, the pack sheet "losing quality"): the
        // box was worked out before layout, when bounds were still zero. Grown here to the real
        // tile: 2x for the panel's small tiles (the reference app's cap), the screen's own scale for
        // anything bigger (the pack and info sheets).
        if isTGS, bounds.width > 1 {
            let scale = window?.screen.scale ?? UIScreen.main.scale
            let want = Int((bounds.width * (bounds.width > 72 ? scale : min(scale, 2))).rounded(.up))
            if want > player.pixelBox, let url {
                player.set(key: url.path, source: .file(url), pixelBox: want, step: 2)
            }
        }
        skeleton.frame = bounds.insetBy(dx: 2, dy: 2)
        skeleton.layer.cornerRadius = min(16, skeleton.bounds.width * 0.18)
    }

    func setSticker(url: URL?, pixelSize: Int) {
        guard url != self.url || (frames == nil && !isTGS) else { return }
        token += 1
        tilePoints = CGFloat(pixelSize) / max(1, UIScreen.main.scale)
        self.url = url
        frames = nil
        art.removeAnimation(forKey: Self.animKey)
        art.contents = nil
        art.isHidden = false
        isTGS = false
        player.clear()
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

    /// The still first (shipped `_still.png`, off main), then the engine takes over on play.
    /// Drawn at 2x the tile at most and every other frame, as the reference app's panel does.
    private func loadTGS(_ url: URL) {
        isTGS = true
        let scale = min(UIScreen.main.scale, 2)
        player.set(key: url.path, source: .file(url),
                   pixelBox: Int((max(tilePoints, bounds.width) * scale).rounded(.up)), step: 2)
        skeleton.setActive(true)
        let mine = token
        TGSSticker.stillAsync(url: url, side: tilePoints) { [weak self] img in
            guard let self, self.token == mine else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if !self.player.hasFrame { self.art.contents = img?.cgImage }
            CATransaction.commit()
            self.skeleton.fadeOut()
        }
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
        if isTGS {
            // Low Power Mode halves the rate inside the engine rather than freezing the tile.
            if wantsPlay && window != nil { player.play() } else { player.pause() }
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
