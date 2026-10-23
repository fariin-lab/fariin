import UIKit
import librlottie

// THE STICKER ENGINE (owner 2026-10-23, "make it like the reference app"). See the note at the top
// of TGSSticker.swift for why it exists. Three pieces:
//
//   TGSDoc     one parsed .tgs (an rlottie handle). Lives on ONE render queue for its whole life.
//   TGSEngine  one CADisplayLink on main; each tick asks the render queues for every playing
//              sticker's next frame, then sets all the results in one main-thread pass.
//   TGSPlayer  a CALayer that shows one sticker. Views host it; they say play, pause and size.

/// One parsed sticker. rlottie draws premultiplied ARGB32 (0xAARRGGBB in a native word), which on
/// these little-endian phones is BGRA in memory: `byteOrder32Little | premultipliedFirst`.
final class TGSDoc {
    private let handle: OpaquePointer
    let frameCount: Int
    let frameRate: Double
    /// The canvas, for the aspect of the box frames are drawn into (512x512 for real .tgs files).
    let canvas: CGSize

    init?(_ raw: Data) {
        guard let json = TGSSticker.isTGS(raw) ? TGSSticker.gunzip(raw) : raw, !json.isEmpty else { return nil }
        // rlottie takes a C string. An empty key means rlottie keeps no cache of its own: ours is
        // `TGSDocCache`, which is bounded.
        var text = [CChar](repeating: 0, count: json.count + 1)
        json.withUnsafeBytes { src in
            text.withUnsafeMutableBytes { dst in dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[0..<json.count])) }
        }
        guard let h = text.withUnsafeBufferPointer({ lottie_animation_from_data($0.baseAddress, "", "") }) else { return nil }
        let frames = Int(lottie_animation_get_totalframe(h))
        guard frames > 0 else { lottie_animation_destroy(h); return nil }
        handle = h
        frameCount = frames
        let fps = lottie_animation_get_framerate(h)
        frameRate = fps > 0 && fps <= 120 ? fps : 30
        var w = 0, hgt = 0
        lottie_animation_get_size(h, &w, &hgt)
        canvas = w > 0 && hgt > 0 ? CGSize(width: w, height: hgt) : CGSize(width: 512, height: 512)
    }

    deinit { lottie_animation_destroy(handle) }

    /// The pixel box a frame is drawn into: the canvas fitted inside `px` x `px`.
    func box(_ px: Int) -> (Int, Int) {
        let s = CGFloat(px) / max(canvas.width, canvas.height)
        return (max(1, Int((canvas.width * s).rounded())), max(1, Int((canvas.height * s).rounded())))
    }

    func render(_ frame: Int, px: Int) -> CGImage? {
        let (w, h) = box(px)
        let bpr = w * 4
        let bytes = bpr * h
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
        buf.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
        lottie_animation_render(handle, max(0, frame) % frameCount, buf.assumingMemoryBound(to: UInt32.self), w, h, bpr)
        guard let provider = CGDataProvider(dataInfo: nil, data: buf, size: bytes, releaseData: { _, data, _ in
            UnsafeMutableRawPointer(mutating: data).deallocate()
        }) else { buf.deallocate(); return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr,
                       space: Self.space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                                | CGImageAlphaInfo.premultipliedFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Frame 0, or the middle frame when frame 0 is nearly empty (stickers that start blank).
    func still(_ px: Int) -> CGImage? {
        guard let first = render(0, px: px) else { return nil }
        return Self.mostlyEmpty(first) ? (render(frameCount / 2, px: px) ?? first) : first
    }

    private static let space = CGColorSpaceCreateDeviceRGB()

    private static func mostlyEmpty(_ cg: CGImage) -> Bool {
        let side = 16
        var px = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &px, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        var inked = 0
        for i in stride(from: 3, to: px.count, by: 4) where px[i] > 20 { inked += 1 }
        return inked < (side * side * 3) / 100
    }
}

/// Where a sticker's bytes come from: a file (the panel, bundled packs) or bytes already loaded
/// (the chat, which may have decrypted or downloaded them).
enum TGSSource {
    case file(URL)
    case bytes(Data)
    func load() -> Data? {
        switch self {
        case .file(let u): return try? Data(contentsOf: u, options: .mappedIfSafe)
        case .bytes(let d): return d
        }
    }
}

/// Parsed documents of ONE render queue, touched only on that queue. Bounded, oldest out first.
private final class TGSDocCache {
    private var docs: [String: TGSDoc] = [:]
    private var order: [String] = []
    private let limit = 24
    func doc(_ key: String, _ source: TGSSource) -> TGSDoc? {
        if let d = docs[key] {
            if let i = order.firstIndex(of: key) { order.remove(at: i); order.append(key) }
            return d
        }
        guard let raw = source.load(), let d = TGSDoc(raw) else { return nil }
        docs[key] = d
        order.append(key)
        while order.count > limit { docs[order.removeFirst()] = nil }
        return d
    }
}

/// Main thread only (it is driven by a display link and touched by views), not marked @MainActor
/// so CALayer subclasses can call it.
final class TGSEngine {
    static let shared = TGSEngine()

    /// Two serial queues, as the reference app's panel renderer uses. A sticker always goes to the
    /// same one (by key), so its document is never touched by two threads.
    private let queues = (0..<2).map { DispatchQueue(label: "TGSRender\($0)", qos: .userInitiated) }
    private let caches = [TGSDocCache(), TGSDocCache()]
    private let players = NSHashTable<TGSPlayer>.weakObjects()
    private var link: CADisplayLink?

    func add(_ p: TGSPlayer) {
        players.add(p)
        wake()
    }

    func remove(_ p: TGSPlayer) { players.remove(p) }

    /// Starts the clock when a sticker wants frames; the tick stops it when none do.
    func wake() {
        guard link == nil else { return }
        let l = CADisplayLink(target: TGSLinkTarget.shared, selector: #selector(TGSLinkTarget.tick))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        // `.common`, so stickers keep playing while a list scrolls, as the reference app's do.
        l.add(to: .main, forMode: .common)
        link = l
    }

    fileprivate func tick() {
        let now = CACurrentMediaTime()
        var jobs: [(TGSPlayer, Int)] = []
        var anyWanting = false
        for p in players.allObjects where p.wantsFrames {
            anyWanting = true
            guard !p.inFlight, let f = p.frameDue(now), f != p.shownFrame else { continue }
            jobs.append((p, f))
        }
        guard anyWanting else { link?.invalidate(); link = nil; return }
        guard !jobs.isEmpty else { return }

        let group = DispatchGroup()
        let lock = NSLock()
        var done: [(TGSPlayer, Int, Int, CGImage?, Int, Double)] = []
        for (p, f) in jobs {
            p.inFlight = true
            let key = p.key, source = p.source, px = p.pixelBox, gen = p.generation
            let lane = p.lane
            let cache = caches[lane]
            group.enter()
            queues[lane].async {
                var image: CGImage?
                var count = 0, fps = 0.0
                if let source, let doc = cache.doc(key, source) {
                    count = doc.frameCount
                    fps = doc.frameRate
                    image = doc.render(f, px: px)
                }
                lock.lock(); done.append((p, gen, f, image, count, fps)); lock.unlock()
                group.leave()
            }
        }
        // One main-thread pass for every sticker this tick, not one per sticker.
        group.notify(queue: .main) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (p, gen, f, image, count, fps) in done {
                p.receive(gen, f, image, frameCount: count, frameRate: fps)
            }
            CATransaction.commit()
        }
    }
}

/// CADisplayLink retains its target; this keeps the engine itself out of that.
private final class TGSLinkTarget: NSObject {
    static let shared = TGSLinkTarget()
    @objc func tick() { TGSEngine.shared.tick() }
}

/// One sticker on screen. The host view sets `frame`, calls `set`, `play` and `pause`.
/// Until the first frame arrives it shows whatever `contents` the host put there (a still).
final class TGSPlayer: CALayer {
    fileprivate(set) var key = ""
    fileprivate(set) var source: TGSSource?
    /// The longest side, in pixels, frames are drawn at.
    fileprivate(set) var pixelBox = 256
    /// 1 = every frame of the file (the chat); 2 = every other frame (the panel: half rate, as the
    /// reference app stores panel stickers). Low Power Mode doubles it.
    private var step = 1
    fileprivate var inFlight = false
    /// Bumped on every new sticker, so a frame drawn for the previous one is thrown away.
    fileprivate var generation = 0
    fileprivate var shownFrame = -1
    private var frameCount = 0
    private var frameRate = 30.0
    private var playing = false
    private var startedAt: CFTimeInterval = 0
    private var pausedAt: CFTimeInterval = 0
    /// Which render queue (and so which document cache) this sticker uses: by key, so every player
    /// of one sticker shares one parsed document.
    fileprivate var lane = 0
    /// Called once, when the first real frame is on screen (the host fades its still out).
    var onFirstFrame: (() -> Void)?
    var hasFrame: Bool { shownFrame >= 0 }

    override init() {
        super.init()
        contentsGravity = .resizeAspect
        actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(key: String, source: TGSSource, pixelBox: Int, step: Int) {
        guard key != self.key || self.source == nil else {
            self.pixelBox = pixelBox; self.step = max(1, step)
            return
        }
        generation += 1
        self.key = key
        lane = Int(UInt(bitPattern: key.hashValue) % 2)
        self.source = source
        self.pixelBox = max(16, pixelBox)
        self.step = max(1, step)
        shownFrame = -1
        frameCount = 0
        inFlight = false
        startedAt = CACurrentMediaTime()
        pausedAt = startedAt
        if playing { TGSEngine.shared.add(self) }
    }

    func clear() {
        generation += 1
        inFlight = false
        source = nil
        key = ""
        shownFrame = -1
        pause()
        contents = nil
    }

    func play() {
        guard !playing else { return }
        playing = true
        // Resume where it stopped rather than jumping.
        startedAt += CACurrentMediaTime() - pausedAt
        TGSEngine.shared.add(self)
    }

    func pause() {
        guard playing else { return }
        playing = false
        pausedAt = CACurrentMediaTime()
        TGSEngine.shared.remove(self)
    }

    fileprivate var wantsFrames: Bool { playing && source != nil }

    fileprivate func frameDue(_ now: CFTimeInterval) -> Int? {
        guard frameCount > 0 else { return 0 }   // not parsed yet: ask for frame 0
        let s = ProcessInfo.processInfo.isLowPowerModeEnabled ? step * 2 : step
        let tick = Int((now - startedAt) * frameRate / Double(s))
        return (tick * s) % frameCount
    }

    fileprivate func receive(_ gen: Int, _ frame: Int, _ image: CGImage?, frameCount: Int, frameRate: Double) {
        guard gen == generation else { return }
        inFlight = false
        guard source != nil else { return }
        // A file that would not parse is not asked again every tick: it keeps its still.
        guard frameCount > 0 else { source = nil; TGSEngine.shared.remove(self); return }
        self.frameCount = frameCount; self.frameRate = frameRate
        guard let image else { return }
        let first = shownFrame < 0
        contents = image
        shownFrame = frame
        if first { onFirstFrame?() }
    }
}
