import UIKit
import Lottie

// ⛔ A .TGS PLAYS AS PICTURES DRAWN OFF THE MAIN THREAD — owner 2026-10-21: "the reference app's
// animated stickers have no lag, mine do". Ours gave every playing sticker its own LottieAnimationView:
// a whole layer tree built on the main thread as it came on screen (the hitch), and either the render
// server interpolating every vector shape of every sticker each frame, or, for an animation the Core
// Animation engine cannot take, the main-thread engine running per frame on OUR thread (the lag).
//
// The reference app never puts a vector tree on screen. A background thread draws each frame into a
// bitmap at the size the sticker shows, the bitmaps are kept, and the screen only swaps one finished
// picture for the next. This does the same:
//   • one LottieAnimationLayer per player, main-thread engine, used ONLY on the render queue and
//     never in a window. Its per-frame update (`forceDisplayUpdate`) has no main-thread
//     check, so it draws anywhere; `render(in:)` copies it into a bitmap sized to the tile in pixels.
//   • finished frames go into one shared cache (by file, pixel size, frame rate and index), so a
//     second loop, or the same sticker in the chat and in the panel, is not drawn again.
//   • one display link for every player; on each tick a player puts up its next frame only if it is
//     already drawn, then asks for the one after. A late frame is skipped, never waited for.
//
// ⛔ ONE RENDER QUEUE, NEVER A POOL — build 1006 crashed twice (2026-10-21, SIGTRAP in CFEqual under
// -[CAShapeLayer setFillColor:] on a "TGSFrames.player" thread): players drew on a concurrent pool,
// eight at once, while stills drew the same decoded animations on the main thread. The engine is not
// made for that. Every .tgs drawing, frames and stills, now goes through `renderQueue`, one at a
// time; the threads were all waiting on Core Animation's one lock anyway, so nothing was gained.
// The .tgs file itself is never converted (owner: stickers stay .tgs); only what is shown is pixels.
final class TGSFramePlayer {
    let key: String
    let pixel: Int
    let fps: Double
    let count: Int
    private let anim: LottieAnimation
    private weak var target: CALayer?

    // Main thread.
    private(set) var playing = false
    private var shown = -1
    private var wanted = 0
    private var ready: (Int, CGImage)?
    private var inFlight = false
    private var due: CFTimeInterval = 0
    private var primeOnly = false

    // `renderQueue` only.
    private var drawer: LottieAnimationLayer?

    /// Every .tgs drawing in the app runs here, one at a time (see the note above).
    static let renderQueue = DispatchQueue(label: "TGSFrames.render", qos: .userInitiated)
    private static let frames: NSCache<NSString, CGImage> = {
        let c = NSCache<NSString, CGImage>()
        c.totalCostLimit = 80 * 1024 * 1024
        return c
    }()

    /// `pixel` is the longest side the sticker shows at, in pixels; `fps` the rate it is drawn at
    /// (capped by the file's own).
    init(anim: LottieAnimation, key: String, pixel: Int, fps: Double, target: CALayer) {
        self.anim = anim
        self.key = key
        self.pixel = max(16, pixel)
        let rate = min(fps, max(1, anim.framerate))
        self.fps = rate
        let seconds = Double(anim.endFrame - anim.startFrame) / max(1, anim.framerate)
        self.count = max(1, Int((seconds * rate).rounded()))
        self.target = target
    }

    /// Where it is in the loop, 0...1 (a live copy starts from here).
    var progress: Double { Double(max(0, shown)) / Double(count) }

    /// Puts frame 0 up without playing (a sticker that is loaded but not yet on screen).
    func prime() {
        guard shown < 0, !playing else { return }
        primeOnly = true
        request(0)
    }

    func start(at progress: Double = 0) {
        guard !playing else { return }
        playing = true
        primeOnly = false
        due = 0
        let i = progress > 0 ? Int(progress * Double(count)) % count : max(0, shown + 1) % count
        if ready?.0 != i { ready = nil }
        request(i)
        TGSClock.shared.add(self)
    }

    func stop() {
        guard playing else { return }
        playing = false
        TGSClock.shared.remove(self)
    }

    fileprivate func tick(_ now: CFTimeInterval) {
        guard playing else { return }
        guard let target else { stop(); return }
        if due > 0, now < due - 0.002 { return }
        guard let next = ready else { return }   // not drawn yet: skip this tick, never wait
        let (i, img) = next
        ready = nil
        put(img, on: target)
        shown = i
        let step = 1 / fps
        // A frame that came late does not slow the sticker down: the frames it missed are skipped,
        // so it keeps its real speed. Then the clock restarts from now instead of racing to catch up.
        let missed = due > 0 ? max(0, Int((now - due) / step)) : 0
        due = (due == 0 || now - due > step) ? now + step : due + step
        request((i + 1 + missed) % count)
    }

    private func put(_ img: CGImage, on layer: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = img
        CATransaction.commit()
    }

    private func cacheKey(_ i: Int) -> NSString { "\(key)#\(pixel)#\(Int(fps))#\(i)" as NSString }

    private func request(_ i: Int) {
        wanted = i
        if let hit = Self.frames.object(forKey: cacheKey(i)) { arrived(i, hit); return }
        guard !inFlight else { return }
        inFlight = true
        Self.renderQueue.async { [self] in
            let img = draw(i)
            DispatchQueue.main.async { [self] in
                inFlight = false
                if let img {
                    Self.frames.setObject(img, forKey: cacheKey(i), cost: img.bytesPerRow * img.height)
                }
                if wanted != i { request(wanted); return }   // moved on while this one was drawing
                if let img { arrived(i, img) }
            }
        }
    }

    private func arrived(_ i: Int, _ img: CGImage) {
        if primeOnly && !playing {
            primeOnly = false
            if let target, shown < 0 { put(img, on: target); shown = i }
            return
        }
        guard playing else { return }
        ready = (i, img)
    }

    /// On `renderQueue`. Frame `i` at this player's rate, as a bitmap `pixel` wide on its longest side.
    private func draw(_ i: Int) -> CGImage? {
        let frame = anim.startFrame + CGFloat(Double(i) * anim.framerate / fps)
        return Self.render(anim, frame: frame, pixel: pixel, drawer: &drawer)
    }

    /// One frame (0...1 through the loop) as a bitmap, for a still. Drawn on `renderQueue`; the
    /// caller waits for it.
    static func stillFrame(_ anim: LottieAnimation, progress: CGFloat, pixel: Int) -> CGImage? {
        renderQueue.sync {
            var drawer: LottieAnimationLayer?
            let frame = anim.startFrame + (anim.endFrame - anim.startFrame) * min(1, max(0, progress))
            return render(anim, frame: frame, pixel: max(16, pixel), drawer: &drawer)
        }
    }

    /// On `renderQueue`. `drawer` is made on first use and kept by the caller.
    private static func render(_ anim: LottieAnimation, frame: CGFloat, pixel: Int,
                               drawer: inout LottieAnimationLayer?) -> CGImage? {
        let b = anim.bounds
        guard b.width > 0, b.height > 0 else { return nil }
        // An explicit transaction: this thread has no run loop to flush implicit ones, and Lottie's
        // own nested transactions finish (and run their completion) when this one commits, here.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let layer: LottieAnimationLayer
        if let have = drawer {
            layer = have
        } else {
            layer = LottieAnimationLayer(animation: anim,
                                         configuration: LottieConfiguration(renderingEngine: .mainThread))
            layer.frame = b
            drawer = layer
        }
        layer.currentFrame = min(frame, anim.endFrame)
        layer.forceDisplayUpdate()
        let scale = CGFloat(pixel) / max(b.width, b.height)
        let w = max(1, Int((b.width * scale).rounded())), h = max(1, Int((b.height * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        // Top-left origin, as a UIKit image context has, which is what layer drawing expects.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        layer.render(in: ctx)
        return ctx.makeImage()
    }
}

/// One display link for every playing sticker, running only while one plays.
private final class TGSClock: NSObject {
    static let shared = TGSClock()
    private let players = NSHashTable<TGSFramePlayer>.weakObjects()
    private var link: CADisplayLink?

    func add(_ p: TGSFramePlayer) {
        players.add(p)
        retune()
    }

    func remove(_ p: TGSFramePlayer) {
        players.remove(p)
        retune()
    }

    private func retune() {
        let all = players.allObjects
        guard let top = all.map(\.fps).max() else {
            link?.invalidate()
            link = nil
            return
        }
        let l: CADisplayLink
        if let have = link {
            l = have
        } else {
            l = CADisplayLink(target: self, selector: #selector(step(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
        let want = Float(min(60, max(30, top.rounded())))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: want, preferred: want)
    }

    @objc private func step(_ l: CADisplayLink) {
        let now = l.targetTimestamp
        for p in players.allObjects { p.tick(now) }
        if players.count == 0 { retune() }
    }
}

/// A standalone moving copy of a .tgs (the long-press menu lays it over the bubble's still snapshot).
/// Plays while it exists; letting it go stops it.
final class TGSFrameView: UIView {
    private let art = CALayer()
    private var player: TGSFramePlayer?

    init(frame: CGRect, anim: LottieAnimation, key: String, fps: Double, progress: Double, still: Any?) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        let scale = UIScreen.main.scale
        art.frame = bounds
        art.contentsGravity = .resizeAspect
        art.contentsScale = scale
        art.contents = still
        layer.addSublayer(art)
        let px = Int(max(frame.width, frame.height) * scale)
        let p = TGSFramePlayer(anim: anim, key: key, pixel: px, fps: fps, target: art)
        player = p
        p.start(at: progress)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        art.frame = bounds
        CATransaction.commit()
    }

    deinit { player?.stop() }
}
