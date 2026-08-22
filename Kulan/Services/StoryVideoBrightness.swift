import Foundation
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal

/// ⛔ THE TRIM PAGE'S BRIGHTNESS, IN ONE PLACE (owner, 2026-08-20).
///
/// ⚠️ ONE MAPPING, TWO BUILDERS, AND THAT IS THE ENTIRE REASON THIS IS NOT WRITTEN INLINE. The
/// editor's preview reads `exposureEV` per frame in its own renderer; the export hangs `composition`
/// on its session. If either ever composed its own filter the screen would start promising a clip the
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

    // `LiveExposure` and `liveComposition` lived here: a composition built once per editing session
    // whose handler read a lock-guarded float. Both are gone with the preview's composition itself —
    // the trim page renders its own frames now and the exposure is a plain property on that view.
    // See `StoryVideoPreviewView`. Nothing in the app builds a composition for a PREVIEW any more;
    // the one below is the export's, and an export is the case a composition is actually right for.

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
