import Foundation
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// ⛔ THE TRIM PAGE'S BRIGHTNESS, IN ONE PLACE (owner, 2026-08-20).
///
/// ⚠️ ONE BUILDER, TWO CONSUMERS, AND THAT IS THE ENTIRE REASON THIS IS NOT WRITTEN INLINE. The
/// editor's preview attaches this composition to its player item; the export attaches the same one
/// to its session. If either ever composed its own filter the screen would start promising a clip
/// the post does not have — the WYSIWYG break this editor has already been reported for on the crop
/// and on the trim range.
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

    /// One composition for a whole editing session, reading `LiveExposure` on every frame.
    ///
    /// Neutral is a pass-through rather than a filter with nothing to do — the dial spends most of
    /// its life at zero and an exposure of 0 EV is a full Core Image pass to return what it was
    /// given.
    static func liveComposition(for asset: AVAsset) async -> (AVVideoComposition, LiveExposure)? {
        let live = LiveExposure()
        let comp = try? await AVMutableVideoComposition.videoComposition(with: asset) { request in
            let ev = live.ev
            guard abs(ev) > 0.001 else { request.finish(with: request.sourceImage, context: nil); return }
            let f = CIFilter.exposureAdjust()
            f.inputImage = request.sourceImage
            f.ev = ev
            let out = (f.outputImage ?? request.sourceImage).cropped(to: request.sourceImage.extent)
            request.finish(with: out, context: nil)
        }
        guard let comp else { return nil }
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
            request.finish(with: out, context: nil)
        }
    }
}
