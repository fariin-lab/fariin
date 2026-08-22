import Foundation
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal

/// ⛔ THE TRIM PAGE'S BRIGHTNESS, IN ONE PLACE (owner, 2026-08-20).
///
/// ⚠️ ONE MAPPING, TWO BUILDERS, AND THAT IS THE ENTIRE REASON THIS IS NOT WRITTEN INLINE. The
/// editor's preview hangs `liveComposition` on its player item; the export hangs `composition` on
/// its session. If either ever composed its own filter the screen would start promising a clip the
/// post does not have — the WYSIWYG break this editor has already been reported for on the crop and
/// on the trim range.
///
/// ⚠️ THE TWO ARE NOT INTERCHANGEABLE AND THE DIFFERENCE IS DELIBERATE: they apply the SAME exposure
/// through the same filter, so they agree about how the clip LOOKS, but the preview renders at a
/// capped size and the export at the clip's own. Colour is the promise; pixel count is not.
enum StoryVideoBrightness {
    /// ⛔ EXPOSURE, NOT AN ADDITIVE OFFSET — read from the reference app's own source (2026-08-20).
    ///
    /// Theirs maps the brightness slider onto EXPOSURE and passes the value through unscaled:
    /// `self.adjustmentsPass.adjustments.exposure = value`, in a Metal pass where exposure multiplies
    /// the colour. Ours used `CIFilter.colorControls().brightness`, which ADDS a constant to every
    /// channel — so darkening lifted the blacks toward grey and flattened the picture instead of
    /// deepening it, and brightening washed rather than opened up. Same dial, visibly worse ends.
    ///
    /// `exposureAdjust` is Core Image's multiplicative equivalent and takes stops, so the dial's
    /// -1…1 IS the value in EV: one stop down at the left, one up at the right, and their
    /// pass-through mapping rather than a scale factor of ours invented on top of it.
    static func exposureEV(for value: Double) -> Float { Float(min(1, max(-1, value))) }

    static func isNeutral(_ value: Double) -> Bool { abs(value) < 0.001 }

    /// ⛔ THE EXPOSURE A PREVIEW IS APPLYING RIGHT NOW, CHANGEABLE WITHOUT REBUILDING ANYTHING.
    ///
    /// A composition bakes its filter in at build time, so following the dial by building a new one
    /// per touch meant an asynchronous build between every move of his thumb and the picture. This
    /// is the value the handler READS on each frame instead, so the whole drag is one composition
    /// and each move is a float.
    ///
    /// ⚠️ Locked because the two ends are on different threads: the dial writes on the main actor
    /// and the composition's handler runs on AVFoundation's own render queue.
    final class LiveExposure: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Float = 0
        var ev: Float {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    /// ⛔ ONE CONTEXT FOR EVERY FRAME OF EVERY CLIP, AND `nil` WAS THE BUG (owner 2026-08-22, second
    /// report: "why is the video lag or frozen when I am using brightness").
    ///
    /// `request.finish(with:context:)` takes a `CIContext` because it is meant to be GIVEN one.
    /// Handing it nil makes AVFoundation fall back to its own, which cannot keep this filter's
    /// compiled kernel, its texture cache or its working buffers between frames — so every frame of
    /// playback pays a setup cost that belongs to the session, not to the frame.
    ///
    /// Metal-backed, and intermediates deliberately NOT cached: a video pass is a new image every
    /// frame, so a cache of intermediates is memory that can never be hit again.
    private static let ciContext: CIContext = {
        let options: [CIContextOption: Any] = [.cacheIntermediates: false]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }()

    /// ⛔ WHAT A PREVIEW IS ALLOWED TO COST, ON ITS LONG EDGE.
    ///
    /// The composition builder hands back a composition that renders at the asset's own size. A clip
    /// off a modern iPhone is 3840 across, so the dial was running an exposure pass over 8.3 million
    /// pixels a frame to fill a card about 1200 pixels wide — nine tenths of that work is thrown away
    /// by the scaler on its way to the screen, and it is the reason the picture could not keep up
    /// while the sound could.
    ///
    /// ⚠️ THE PREVIEW ONLY. `composition(for:value:)` below is the EXPORT and is deliberately left at
    /// full size: what is posted must not be capped by a number chosen for a phone screen.
    private static let previewLongEdge: CGFloat = 1280

    /// One composition for a whole editing session, reading `LiveExposure` on every frame.
    ///
    /// Neutral is a pass-through rather than a filter with nothing to do — the dial spends most of
    /// its life at zero and an exposure of 0 EV is a full Core Image pass to return what it was
    /// given.
    static func liveComposition(for asset: AVAsset) async -> (AVVideoComposition, LiveExposure)? {
        let live = LiveExposure()
        let comp = try? await AVMutableVideoComposition.videoComposition(with: asset) { request in
            var img = request.sourceImage

            // ⛔ SHRINK FIRST, FILTER SECOND, AND THE ORDER IS THE WHOLE POINT (owner 2026-08-22,
            // THIRD report on this freeze — my last fix had these the wrong way round).
            //
            // The cap was already here, but it was applied AFTER the exposure. So the filter still
            // ran over every pixel of a 3840-wide frame and only the finished result was shrunk —
            // the expensive part was never actually capped. Core Image is lazy and MAY fold a
            // trailing scale back into the graph, but "may" is not a guarantee to hang a stall on,
            // and written this way there is nothing left to hope for: the exposure sees about one
            // million pixels instead of eight.
            //
            // ⚠️ THE SCALE CANNOT BE LEFT TO `renderSize` ALONE. Shrinking the render size only
            // shrinks the BUFFER the frame is drawn into; the source keeps its own size and is drawn
            // at the origin, so the cap on its own would post a crop of the top-left corner. Read off
            // the request rather than captured, so it is an identity transform whenever the cap below
            // did not apply and cannot fall out of step with it.
            let target = request.renderSize
            let w = max(1, img.extent.width), h = max(1, img.extent.height)
            let s = min(target.width / w, target.height / h)
            if s < 0.999 { img = img.transformed(by: CGAffineTransform(scaleX: s, y: s)) }

            let ev = live.ev
            if abs(ev) > 0.001 {
                let f = CIFilter.exposureAdjust()
                f.inputImage = img
                f.ev = ev
                // ⚠️ CROPPED BACK TO THE EXTENT IT WAS GIVEN. A colour filter can hand back an image
                // with a different or infinite extent, and a composition given one of those renders a
                // frame that does not line up with the one before it.
                img = (f.outputImage ?? img).cropped(to: img.extent)
            }
            request.finish(with: img, context: ciContext)
        }
        guard let comp else { return nil }
        let native = comp.renderSize
        let longEdge = max(native.width, native.height)
        if longEdge > previewLongEdge, longEdge > 0 {
            let k = previewLongEdge / longEdge
            // Rounded to even numbers: an odd dimension is a size a video pipeline has to pad, and
            // the padding is drawn.
            func even(_ v: CGFloat) -> CGFloat { max(2, (v * k / 2).rounded() * 2) }
            comp.renderSize = CGSize(width: even(native.width), height: even(native.height))
        }
        return (comp, live)
    }

    /// The composition to hang on a player item or an export session. Nil when there is nothing to
    /// do, so a clip nobody adjusted keeps whatever path it had — for a plain video that is a
    /// passthrough, and paying for a Core Image pass to add zero would be a straight loss.
    static func composition(for asset: AVAsset, value: Double) async -> AVVideoComposition? {
        guard !isNeutral(value) else { return nil }
        let ev = exposureEV(for: value)
        return try? await AVMutableVideoComposition.videoComposition(with: asset) { request in
            let f = CIFilter.exposureAdjust()
            f.inputImage = request.sourceImage
            f.ev = ev
            // ⚠️ CROPPED BACK TO THE SOURCE EXTENT. A colour filter can hand back an image with a
            // different or infinite extent, and a composition given one of those renders a frame
            // that does not line up with the one before it.
            let out = (f.outputImage ?? request.sourceImage).cropped(to: request.sourceImage.extent)
            // The same shared context the preview uses, and for the same reason — an export is
            // thousands of frames through one filter, which is exactly the case a reused context is
            // for. No size cap here: what is posted keeps the clip's own resolution.
            request.finish(with: out, context: ciContext)
        }
    }
}
