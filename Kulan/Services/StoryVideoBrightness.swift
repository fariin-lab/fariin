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
    /// -1…1 from the dial, 0 untouched. Core Image's `brightness` is an additive offset where ±1 is
    /// pure white and pure black, so the dial's full travel is scaled to a range that is a visible
    /// change and still a picture: a story is watched for five seconds, not graded.
    static func exposure(for value: Double) -> Float { Float(min(1, max(-1, value)) * 0.28) }

    static func isNeutral(_ value: Double) -> Bool { abs(value) < 0.001 }

    /// The composition to hang on a player item or an export session. Nil when there is nothing to
    /// do, so a clip nobody adjusted keeps whatever path it had — for a plain video that is a
    /// passthrough, and paying for a Core Image pass to add zero would be a straight loss.
    static func composition(for asset: AVAsset, value: Double) async -> AVVideoComposition? {
        guard !isNeutral(value) else { return nil }
        let amount = exposure(for: value)
        return try? await AVMutableVideoComposition.videoComposition(with: asset) { request in
            let f = CIFilter.colorControls()
            f.inputImage = request.sourceImage
            f.brightness = amount
            f.contrast = 1
            f.saturation = 1
            // ⚠️ CROPPED BACK TO THE SOURCE EXTENT. A colour filter can hand back an image with a
            // different or infinite extent, and a composition given one of those renders a frame
            // that does not line up with the one before it.
            let out = (f.outputImage ?? request.sourceImage).cropped(to: request.sourceImage.extent)
            request.finish(with: out, context: nil)
        }
    }
}
