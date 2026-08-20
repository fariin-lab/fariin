import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// ⛔ THE TRIM PAGE'S SECOND TAB: colour adjustments on a story clip (owner, 2026-08-20, with his two
/// screenshots — Enhance, Brightness, Contrast, Highlights, Shadows, Vignette).
///
/// ⚠️ ONE CHAIN, TWO CONSUMERS, AND THAT IS THE WHOLE POINT OF THIS FILE. The live preview builds it
/// through `AVVideoComposition(asset:applyingCIFiltersWithHandler:)` and the export builds it inside
/// the transcoder's own per-frame handler. If those two ever compose their own filters the editor
/// starts showing something the posted clip does not have — the exact WYSIWYG break this screen has
/// been reported for before, on the crop and on the trim range.
///
/// Every value is -1…1 with 0 meaning untouched, so "has the user changed anything" is a comparison
/// against zero rather than six remembered defaults, and a reset is a new instance.
struct StoryVideoAdjustments: Equatable, Codable {
    var enhance: Double = 0
    var brightness: Double = 0
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var vignette: Double = 0

    static let neutral = StoryVideoAdjustments()

    /// Nothing to apply → the caller can keep the untouched export path, which for a plain clip is a
    /// passthrough and costs nothing.
    var isNeutral: Bool { self == Self.neutral }

    /// The six, in the order the row draws them.
    enum Knob: String, CaseIterable, Identifiable {
        case enhance, brightness, contrast, highlights, shadows, vignette
        var id: String { rawValue }

        var title: String {
            switch self {
            case .enhance:    return "Enhance"
            case .brightness: return "Brightness"
            case .contrast:   return "Contrast"
            case .highlights: return "Highlights"
            case .shadows:    return "Shadows"
            case .vignette:   return "Vignette"
            }
        }

        /// SF Symbols, chosen to read at 20pt in a dark circle rather than for literal accuracy.
        var icon: String {
            switch self {
            case .enhance:    return "wand.and.stars"
            case .brightness: return "sun.max"
            case .contrast:   return "circle.righthalf.filled"
            case .highlights: return "circle.tophalf.filled"
            case .shadows:    return "circle.bottomhalf.filled"
            case .vignette:   return "circle.dotted"
            }
        }
    }

    subscript(_ k: Knob) -> Double {
        get {
            switch k {
            case .enhance:    return enhance
            case .brightness: return brightness
            case .contrast:   return contrast
            case .highlights: return highlights
            case .shadows:    return shadows
            case .vignette:   return vignette
            }
        }
        set {
            let v = min(1, max(-1, newValue))
            switch k {
            case .enhance:    enhance = v
            case .brightness: brightness = v
            case .contrast:   contrast = v
            case .highlights: highlights = v
            case .shadows:    shadows = v
            case .vignette:   vignette = v
            }
        }
    }

    /// ⛔ THE CHAIN. Order matters and is the ordinary photographic one: exposure and tone first,
    /// then the shadow/highlight recovery that reads those tones, and the vignette last because it
    /// darkens the frame's edge and everything above it should already be final.
    ///
    /// The multipliers are deliberately gentle. A slider at its end is a visible change, not a
    /// destroyed frame: this is a story someone will watch for five seconds, not a grading suite.
    func apply(to input: CIImage) -> CIImage {
        guard !isNeutral else { return input }
        var image = input

        // ENHANCE is one control standing for the small lift people actually want: a touch of
        // exposure, a touch of contrast, a touch of colour. Doing it as a preset here rather than as
        // Apple's `autoAdjustmentFilters` keeps it deterministic — an auto pass analyses each FRAME
        // and would breathe across a moving clip.
        if enhance != 0 {
            let e = CIFilter.colorControls()
            e.inputImage = image
            e.brightness = Float(enhance * 0.06)
            e.contrast = Float(1 + enhance * 0.12)
            e.saturation = Float(1 + enhance * 0.18)
            image = e.outputImage ?? image
        }
        if brightness != 0 || contrast != 0 {
            let c = CIFilter.colorControls()
            c.inputImage = image
            c.brightness = Float(brightness * 0.25)
            c.contrast = Float(1 + contrast * 0.35)
            c.saturation = 1
            image = c.outputImage ?? image
        }
        if highlights != 0 || shadows != 0 {
            let h = CIFilter.highlightShadowAdjust()
            h.inputImage = image
            // Apple's ranges: highlights 0…1 where 1 is untouched, shadows -1…1 where 0 is untouched.
            h.highlightAmount = Float(1 - max(0, -highlights) * 0.7 - max(0, highlights) * 0.0)
            h.shadowAmount = Float(shadows * 0.7)
            image = h.outputImage ?? image
        }
        if vignette != 0 {
            let v = CIFilter.vignette()
            v.inputImage = image
            v.intensity = Float(vignette * 2.0)
            v.radius = 1.6
            image = v.outputImage ?? image
        }
        // ⚠️ CROPPED BACK TO THE INPUT'S EXTENT. Several of these filters (the vignette especially)
        // return an image with a larger or infinite extent, and a video composition handed one of
        // those renders a frame that does not line up with the one before it.
        return image.cropped(to: input.extent)
    }
}
