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
    func setPlaying(_ playing: Bool) {
        guard isPlaying != playing else { return }
        isPlaying = playing
        playing ? startLink() : stopLink()
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
        item.add(out)
        output = out
        observedItem = item
        requestRedraw()
    }

    private func startLink() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick() { setNeedsDisplay() }

    /// One redraw, now. Used by the dial while paused — their own throttle is 30fps for the same job;
    /// ours is bounded by the fact that a touch cannot arrive faster than the screen refreshes.
    func requestRedraw() { setNeedsDisplay() }

    // MARK: - Frames

    /// The newest frame for the player's current time, or the last one we were given.
    private func currentBuffer() -> CVPixelBuffer? {
        guard let output, let item = observedItem else { return lastBuffer }
        let time = item.currentTime()
        if output.hasNewPixelBuffer(forItemTime: time),
           let buf = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            lastBuffer = buf
            return buf
        }
        return lastBuffer
    }
}

extension StoryVideoPreviewView: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { requestRedraw() }

    func draw(in view: MTKView) {
        guard let drawable = currentDrawable,
              let queue = commandQueue,
              let buffer = queue.makeCommandBuffer(),
              let pixels = currentBuffer() else { return }

        var image = CIImage(cvPixelBuffer: pixels)

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
        ciContext.render(CIImage(color: .clear).cropped(to: bounds),
                         to: drawable.texture, commandBuffer: buffer,
                         bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
        ciContext.render(image, to: drawable.texture, commandBuffer: buffer,
                         bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
        buffer.present(drawable)
        buffer.commit()
    }
}
