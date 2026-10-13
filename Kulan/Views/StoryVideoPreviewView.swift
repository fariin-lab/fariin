import UIKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import MetalKit

/// ⛔ THE TRIM PAGE'S VIDEO, DRAWN BY US INSTEAD OF BY AN `AVPlayerLayer`.
///
/// THIS EXISTS BECAUSE THE BRIGHTNESS DIAL FROZE PLAYBACK, AND BECAUSE THREE FIXES FOR THAT WERE
/// AIMED AT THE WRONG LAYER (owner, four reports, 2026-08-22).
///
/// What the previous attempts did: hang an `AVMutableVideoComposition(asset:applyingCIFiltersWithHandler:)`
/// on the `AVPlayerItem`, then try to make it cheap — a shared Metal `CIContext`, a 1280 cap, the
/// filter moved before the downscale, the seeks coalesced. Every one of those was a real improvement
/// and none of them was the problem. Attaching ANY composition takes playback off AVFoundation's
/// direct path and puts a per-frame render in front of every frame, and installing or re-priming one
/// tears the pipeline down and builds it again — which is the multi-second silence-with-sound he kept
/// reporting, and why it only ever showed at the ends of the dial where the filter actually ran.
///
/// The reference app was read on his instruction. It has **zero** occurrences of `videoComposition`
/// or `applyingCIFiltersWithHandler` anywhere in its media editor, export included. It owns the loop:
///
///     AVPlayer                → decoder and clock, nothing else
///     AVPlayerItemVideoOutput → suppressesPlayerRendering = true
///     CADisplayLink           → pulls copyPixelBuffer once per screen refresh
///     GPU                     → the adjustment is one uniform read per frame
///     MTKView                 → presents
///
/// Nothing is rebuilt when the value changes, so changing it costs nothing. This is that, with a
/// `CIContext` where they use a hand-written shader — we need exactly one effect, and Core Image
/// rendering straight into the drawable's texture is the same GPU work without a `.metal` file to
/// keep in step with the export's filter.
///
/// ⚠️ THE PLAYER IS UNTOUCHED. It still decodes, still keeps time, still seeks. Only the thing that
/// DISPLAYS the frames changed, which is why trim, the playhead and the scrubber need no changes at
/// all — they were always talking to the player, never to the layer.
final class StoryVideoPreviewView: MTKView {

    /// ⛔ READ PER FRAME, WRITTEN WHENEVER. This is the whole point of the exercise: the dial writes a
    /// float and the next frame picks it up. No composition to install, no pipeline to re-prime, and
    /// nothing that can stall because the value moved.
    var exposureEV: Float = 0 {
        didSet {
            guard exposureEV != oldValue else { return }
            // Paused: the display link is not running, so ask for the one redraw. Playing: the next
            // frame is already on its way and will read the new value — asking for an extra one is
            // the wasted work their own `updateRenderChain` has an empty branch to avoid.
            if !isPlaying { requestRedraw() }
        }
    }

    private let ciContext: CIContext
    private let commandQueue: MTLCommandQueue?
    private var output: AVPlayerItemVideoOutput?
    private var link: CADisplayLink?
    private weak var observedItem: AVPlayerItem?
    /// The last frame pulled, kept so a paused redraw has something to draw. `copyPixelBuffer` only
    /// answers for a time it has not already handed over, so without this a paused dial move would
    /// ask for a frame and be given nothing.
    private var lastBuffer: CVPixelBuffer?
    private var isPlaying = false
    /// ⛔ THE CLIP'S OWN ROTATION, nil until read. Owner 2026-10-13, a long-standing report: a tall
    /// video in the editor showed as three bands, a sideways copy of the clip in the middle with the
    /// upright poster above and below it. A phone camera stores its frames sideways and says "turn
    /// me 90°" in the track's `preferredTransform`; `AVPlayerLayer` obeyed that, and
    /// `AVPlayerItemVideoOutput` hands over the raw sideways buffer. This renderer aspect-fitted the
    /// sideways frame into the card and the clear letterbox let the poster show through. The export
    /// rotates (`StoryVideoEncoder`), so only the preview was wrong. Nothing is drawn until it is
    /// known, so a frame never shows sideways for a moment.
    private var orientation: CGImagePropertyOrientation?
    /// Screen refreshes in a row that found no new frame while the clip was meant to be moving.
    /// See `currentBuffer`.

    private(set) var player: AVPlayer? {
        didSet { attachOutput() }
    }

    init(device: MTLDevice?) {
        let dev = device ?? MTLCreateSystemDefaultDevice()
        // ⚠️ Intermediates deliberately NOT cached: every frame is a new image, so a cache of
        // intermediates is memory that can never be hit again. Same reasoning as the export's context.
        let options: [CIContextOption: Any] = [.cacheIntermediates: false]
        if let dev {
            ciContext = CIContext(mtlDevice: dev, options: options)
            commandQueue = dev.makeCommandQueue()
        } else {
            ciContext = CIContext(options: options)
            commandQueue = nil
        }
        super.init(frame: .zero, device: dev)
        // ⚠️ `framebufferOnly = false` OR NOTHING DRAWS. Core Image renders INTO the drawable's
        // texture, which counts as reading it back — a framebuffer-only drawable refuses that, and
        // the symptom is a black view with no error anywhere.
        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        // Draw on demand, never free-running: the display link asks while playing and the dial asks
        // while paused. An MTKView left to its own 60fps would redraw a still frame all day.
        isPaused = true
        enableSetNeedsDisplay = true
        backgroundColor = .clear
        isOpaque = false
        layer.isOpaque = false
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        link?.invalidate()
        if let output, let item = observedItem { item.remove(output) }
    }

    // MARK: - Wiring

    func setPlayer(_ p: AVPlayer?) {
        guard player !== p else { return }
        player = p
    }

    /// Told whether the clip is running, so the display link only exists while there is motion to
    /// follow. A paused editor costs nothing.
    /// ⛔ THE FRAME CLOCK NO LONGER FOLLOWS THIS FLAG (owner, 2026-10-12: "the repost video plays
    /// sound but the picture does not move"; the reference app's editor, `UniversalTextureSource`).
    /// The link used to run only while SwiftUI said "playing", so a late or missed update left a
    /// playing player that nobody read, and an unread output stops vending: sound on, picture still.
    /// The reference keeps its link for as long as there is a video and reads every tick. So does
    /// this now (`startLinkIfNeeded`); the flag only decides whether a stop lands on its frame.
    func setPlaying(_ playing: Bool) {
        guard isPlaying != playing else { return }
        isPlaying = playing
        if !playing { requestRedraw() }   // land on the frame it stopped at
    }

    /// One frame, now, for a change the view cannot see coming.
    ///
    /// ⚠️ A SEEK THAT LANDS WHILE PAUSED IS THE CASE THIS EXISTS FOR. The player moves to a new time
    /// and the output has a new frame ready, but nothing is running to come and take it — the link
    /// only exists while there is motion. The editor calls this on every pass where the clip is not
    /// playing, which costs one render of a still frame and catches a landed seek, a new item, and a
    /// resized card alike.
    func redrawIfIdle() {
        guard !isPlaying else { return }   // the link is already producing frames
        requestRedraw()
    }

    private func attachOutput() {
        if let output, let item = observedItem { item.remove(output) }
        output = nil
        observedItem = nil
        lastBuffer = nil
        // ⛔ THE CLIP YOU JUST LEFT IS WIPED OFF THIS LAYER HERE, SYNCHRONOUSLY — owner, 2026-08-23:
        // "when I press Play on Video B, the cover of Video A briefly flashes before Video B starts",
        // and the same flash when Trim is opened on a clip he has not played.
        //
        // ⚠️ A METAL LAYER GOES ON SHOWING THE LAST DRAWABLE THAT WAS PRESENTED TO IT. Swapping the
        // player does not touch that, and neither does hiding the view: clip A's final frame stayed
        // in this layer for as long as the editor was on a photo or on a clip with no player, and the
        // moment a player existed again — Play, or Trim asking for one — the view came back wearing
        // that frame until clip B's first buffer had been decoded. One mechanism, both reports: each
        // is just "a player exists now", and neither had anything to do with posters, caches or
        // thumbnails.
        //
        // `draw()` is MTKView's own immediate draw, and with no buffer to hand it `draw(in:)` now
        // presents a TRANSPARENT drawable rather than leaving what was there. It runs on the pass
        // where the player goes away, which is the tap that changed clip — so the wipe is a whole
        // gesture ahead of the next Play, and it happens while the view is still on screen. What
        // shows through is the item's own poster, sitting under this view in the same container,
        // which is the picture that should be there.
        stopLink()   // restarted below once there is a new output to read
        draw()
        guard let item = player?.currentItem else { return }
        // Their settings, and the pixel format matters: a Metal-compatible buffer is what lets the
        // frame reach the GPU without a copy through the CPU.
        let out = AVPlayerItemVideoOutput(outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        // ⛔ THE PLAYER STOPS DRAWING FOR ITSELF. Without this it goes on decoding for a layer that
        // is not there, which is the cost we came here to remove.
        out.suppressesPlayerRendering = true
        // ⛔ READ EVERY TICK, NOT WOKEN (owner, 2026-10-12, a video repost: "the audio is running
        // but the video is not", still on 877 with the delegate wake that used to be here). The
        // reference app's editor never asks the output to resume: it simply reads it on every
        // refresh for as long as there is a video (`startLinkIfNeeded`, `tick`), so it is never
        // left unread long enough to stop vending.
        item.add(out)
        output = out
        observedItem = item
        orientation = nil
        let asset = item.asset
        Task { @MainActor [weak self, weak item] in
            let t = (try? await asset.loadTracks(withMediaType: .video).first?.load(.preferredTransform)) ?? nil
            guard let self, let item, self.observedItem === item else { return }
            self.orientation = Self.orientation(of: t ?? .identity)
            self.requestRedraw()
        }
        // An output added to an item that is ALREADY playing (the repost starts its clip the same
        // turn the player is made; this view only hears about it on the next update) may never get
        // a first frame. An exact seek to where it is makes the item deliver one to the new output.
        if let p = player, p.rate != 0 {
            p.seek(to: p.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        startLinkIfNeeded()
        requestRedraw()
    }

    /// The link lives while there is a video and the view is on screen (the reference's lifetime),
    /// not while a flag says "playing". Weakly proxied: a display link retains its target.
    private func startLinkIfNeeded() {
        guard link == nil, output != nil, window != nil else { return }
        let l = CADisplayLink(target: LinkProxy(self), selector: #selector(LinkProxy.fire))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopLink() } else { startLinkIfNeeded() }
    }

    /// Every tick: take the newest frame for NOW on the host clock, and draw only if one came.
    /// Paused, nothing new arrives and nothing is drawn; a seek while paused delivers one and it
    /// lands on screen by itself.
    fileprivate func tick() {
        if pullFrame() { setNeedsDisplay() }
    }

    /// The reference app's pull: `itemTime(forHostTime:)`, then `copyPixelBuffer`; nil keeps the
    /// last frame. Returns whether a new one was taken.
    @discardableResult
    private func pullFrame() -> Bool {
        guard let output else { return false }
        let t = output.itemTime(forHostTime: CACurrentMediaTime())
        guard t.isValid, t.seconds >= 0,
              let buf = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) else { return false }
        lastBuffer = buf
        return true
    }

    /// One redraw, now. Used by the dial while paused — their own throttle is 30fps for the same job;
    /// ours is bounded by the fact that a touch cannot arrive faster than the screen refreshes.
    func requestRedraw() { setNeedsDisplay() }

    // MARK: - Frames

    /// What `draw` paints: the last frame taken by `tick`, or one taken now (a redraw asked for
    /// before the first tick, e.g. the brightness dial on a fresh item).
    private func currentBuffer() -> CVPixelBuffer? {
        if lastBuffer == nil { pullFrame() }
        return lastBuffer
    }
}

/// Breaks the display link's strong hold on its target, so the view can go away while linked.
@MainActor private final class LinkProxy: NSObject {
    weak var view: StoryVideoPreviewView?
    init(_ view: StoryVideoPreviewView) { self.view = view }
    @objc func fire() { view?.tick() }
}

extension StoryVideoPreviewView: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { requestRedraw() }

    func draw(in view: MTKView) {
        guard let drawable = currentDrawable,
              let queue = commandQueue,
              let buffer = queue.makeCommandBuffer() else { return }

        // ⛔ NO FRAME MEANS AN EMPTY VIEW, NEVER THE LAST FRAME. Returning here left the previously
        // presented drawable on the layer, and after a clip change that drawable belongs to the clip
        // you just left — this is the other half of the flash `attachOutput` describes, and the one
        // that catches the case where the wipe there could not get a drawable.
        guard let pixels = currentBuffer(), let orientation else {
            clear(drawable, with: buffer)
            buffer.present(drawable)
            buffer.commit()
            return
        }

        // Upright first, so the fit below measures the clip as it is meant to be seen.
        var image = CIImage(cvPixelBuffer: pixels).oriented(orientation)

        // ⛔ THE FILTER RUNS WHATEVER THE VALUE IS, AND THAT IS DELIBERATE. The reference has the
        // neutral early-out COMMENTED OUT in its own source, so the per-frame cost is constant. A
        // cheap path and an expensive path with a threshold between them is precisely what produces
        // a hitch the first time the dial leaves the middle — which is the shape of his report, four
        // times over. One cost, always paid, never noticed.
        let f = CIFilter.exposureAdjust()
        f.inputImage = image
        f.ev = exposureEV
        image = (f.outputImage ?? image).cropped(to: image.extent)

        // Aspect-fit into the drawable, centred — what `videoGravity = .resizeAspect` did for the
        // layer this replaces. Done as a transform on the image rather than by resizing anything, so
        // there is no second buffer and nothing to allocate per frame.
        let target = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        let src = image.extent.size
        if src.width > 1, src.height > 1, target.width > 1, target.height > 1 {
            let scale = min(target.width / src.width, target.height / src.height)
            let dx = (target.width - src.width * scale) / 2
            let dy = (target.height - src.height * scale) / 2
            image = image
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: dx - image.extent.minX * scale,
                                                   y: dy - image.extent.minY * scale))
        }

        let bounds = CGRect(origin: .zero, size: target)
        // Cleared first, or the letterbox bands keep whatever the last frame left in them.
        clear(drawable, with: buffer)
        ciContext.render(image, to: drawable.texture, commandBuffer: buffer,
                         bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
        buffer.present(drawable)
        buffer.commit()
    }

    /// A track's `preferredTransform` as the orientation that turns its raw frames upright. The
    /// rotation is read off the matrix; a mirrored track (front camera) carries the flip in the sign
    /// of the determinant.
    static func orientation(of t: CGAffineTransform) -> CGImagePropertyOrientation {
        let angle = atan2(t.b, t.a)
        let mirrored = t.a * t.d - t.b * t.c < 0
        let quarter = Int((angle / (.pi / 2)).rounded()) & 3   // 0, 90, 180, 270 degrees
        switch (quarter, mirrored) {
        case (1, false): return .right
        case (2, false): return .down
        case (3, false): return .left
        case (0, true):  return .upMirrored
        case (1, true):  return .rightMirrored
        case (2, true):  return .downMirrored
        case (3, true):  return .leftMirrored
        default:         return .up
        }
    }

    /// Transparent, edge to edge. Used for the letterbox bands under a frame, and on its own when
    /// there is no frame to show — see the two notes above.
    private func clear(_ drawable: CAMetalDrawable, with buffer: MTLCommandBuffer) {
        let bounds = CGRect(x: 0, y: 0, width: drawable.texture.width, height: drawable.texture.height)
        ciContext.render(CIImage(color: .clear).cropped(to: bounds),
                         to: drawable.texture, commandBuffer: buffer,
                         bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
    }
}
