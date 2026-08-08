//
//  StoryCanvas.swift
//  StoryUI
//
//  THE ONE ANSWER TO "WHAT IS BEHIND A STORY THAT DOES NOT FILL THE FRAME".
//
//  It is Telegram's answer, read from their source (`MediaEditorComposer.swift`,
//  `VideoFinishPass.swift`) on the owner's order, 2026-08-08:
//
//      public func mediaEditorGetGradientColors(from image: UIImage) -> GradientColors {
//          ... draw the image into a 5x5 context ...
//          return GradientColors(top:    context.colorAt(CGPoint(x: 2, y: 0)),
//                                bottom: context.colorAt(CGPoint(x: 2, y: 4)))
//      }
//
//  Two colours taken off the media itself, a vertical gradient between them, the media laid on top.
//  There is NO BLUR anywhere in Telegram's story pipeline — not in the editor, not in the export, not
//  in the viewer. `VideoFinishPass` draws the gradient with a two-colour fragment shader as the
//  bottom layer and encodes the result into the exported file, so by the time a story is watched the
//  canvas is part of the picture and the viewer computes nothing at all.
//
//  ⚠️ THAT IS THE WHOLE REASON THIS FILE EXISTS, and it is worth stating plainly because the code it
//  replaced was correct-looking and still failed for four months. What we had was a live
//  `UIVisualEffectView(.systemThickMaterialDark)` over an aspect-filled copy of the media. A visual
//  effect view re-samples what is behind it every frame and composites OUTSIDE its own view's
//  transform, so the moment anything scaled the card — the viewers-sheet pull-up, the story flight,
//  the carousel — the blur detached from the picture it belonged to and tore, shimmered, or dropped
//  out entirely. Every fix for that was a fix for one symptom: a pre-baked imitation for the
//  crossfade (`StoryBlurBake`), a `drawHierarchy` freeze for the pull-up (`rasterizeBlurBackdrop`,
//  which then caused its own re-entrancy crash), a downscaled veil for the video (`frozenVeil`), a
//  hidden-when-undecided guard for the black bars. Six mechanisms, one cause.
//
//  A `CAGradientLayer` has none of that surface. It is two colours interpolated by the GPU inside
//  its own layer: it transforms with its parent, it holds still under any scale, it cannot re-sample
//  the wrong thing because it never samples anything, and there is no state to freeze because
//  nothing about it is recomputed. Which is why Telegram's stories do not do this and ours did.
//
//  BOTH HALVES OF THE APP READ THEIR COLOURS THROUGH `colours(of:)` — the export that bakes the
//  canvas into a posted file, and the viewer that draws it live behind a file posted before the bake
//  existed. That is deliberate and it is load-bearing: the two must agree on the same media, or a
//  story would change colour the moment it finished uploading. Two implementations would agree today
//  and drift the first time either was touched.
//

import UIKit

public enum StoryCanvas {

    /// A story frame is 9:16, the same number the composer card and the viewer card are both built
    /// from, and the same shape Telegram exports every story at.
    public static let aspect: CGFloat = 9.0 / 16.0

    /// Does media of this pixel size fill a card of this size, or does it need a canvas behind it?
    ///
    /// ONE FUNCTION FOR A QUESTION THAT USED TO BE ASKED IN FOUR PLACES, in four slightly different
    /// ways, against three different rectangles. `ImageLoader` measured the screen (his left/right
    /// bands), `VideoLoader` measured a derived `videoGravity` that had not been written yet (his
    /// black bars, three reports), `StoryImage` measured the screen unless a caller remembered to
    /// pass an aspect. The tolerance is the old 0.02 from all of them: a photo framed to fill a card
    /// arrives a fraction off after JPEG rounding, and 2% is the difference between "fills" and a
    /// 1%-a-side band nobody wants.
    public static func fills(media: CGSize, in box: CGSize) -> Bool {
        guard media.width > 0, media.height > 0, box.width > 0, box.height > 0 else { return false }
        return media.height / media.width >= box.height / box.width - 0.02
    }

    // MARK: - The two colours

    /// The top and bottom colours of the canvas, read off the media itself.
    ///
    /// Telegram samples a 5x5 reduction and takes the single pixel at (2,0) and (2,4). This averages
    /// the top eighth and the bottom eighth of the frame instead, which is the same idea — the
    /// colour the picture ends on, at each end — with two differences that were paid for in bugs
    /// already and are kept on purpose:
    ///
    ///  • A BAND, NOT A PIXEL. One pixel can land on a caption, a letterbox edge, or a speck of
    ///    glare, and the whole canvas is then keyed to it.
    ///  • AVERAGED IN CODE, from an 8x8 grid, rather than by asking CoreGraphics to scale a band
    ///    straight down to 1x1. At extreme reductions the interpolator is free to point sample, so a
    ///    "mean" that is really one arbitrary pixel is the same bug wearing a different hat.
    ///
    /// TOTAL BY CONSTRUCTION: it always returns a usable pair. Media that will not decode gets the
    /// neutral dark pair, which still reads as a deliberate backdrop rather than as the black bars
    /// that produced four reports. Nothing in the canvas path may quietly produce nothing.
    public static func colours(of cg: CGImage) -> (top: UIColor, bottom: UIColor) {
        let fallback = (top: UIColor(red: 0.13, green: 0.13, blue: 0.15, alpha: 1),
                        bottom: UIColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1))
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        guard w >= 1, h >= 1 else { return fallback }
        let band = max(1, (h / 8).rounded())
        // ⚠️ `CGImage.cropping(to:)` takes its rectangle in the IMAGE's own space, whose origin is
        // the TOP left. That is not a CGContext's convention, and getting it backwards puts the sky
        // at the bottom — the kind of mistake nobody sees until it ships.
        guard let top = average(of: cg, in: CGRect(x: 0, y: 0, width: w, height: band)),
              let bottom = average(of: cg, in: CGRect(x: 0, y: h - band, width: w, height: band))
        else { return fallback }
        return (top, bottom)
    }

    /// Convenience for callers holding a `UIImage`. An image with no `cgImage` (a pure CIImage-backed
    /// one) falls back rather than failing, for the same reason as above.
    public static func colours(of image: UIImage) -> (top: UIColor, bottom: UIColor) {
        guard let cg = image.cgImage else {
            return (UIColor(red: 0.13, green: 0.13, blue: 0.15, alpha: 1),
                    UIColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1))
        }
        return colours(of: cg)
    }

    private static func average(of image: CGImage, in rect: CGRect) -> UIColor? {
        guard let crop = image.cropping(to: rect.integral), crop.width > 0, crop.height > 0
        else { return nil }
        let side = 8
        var px = [UInt8](repeating: 0, count: side * side * 4)
        let ok: Bool = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)))
            return true
        }
        guard ok else { return nil }
        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        for i in stride(from: 0, to: px.count, by: 4) {
            // Premultiplied: undo the alpha before averaging, and skip anything transparent, so
            // media with an alpha channel cannot drag the mean towards black.
            let a = Double(px[i + 3]) / 255
            guard a > 0.01 else { continue }
            r += Double(px[i]) / 255 / a
            g += Double(px[i + 1]) / 255 / a
            b += Double(px[i + 2]) / 255 / a
            n += 1
        }
        guard n > 0 else { return nil }
        return UIColor(red: CGFloat(min(1, r / n)), green: CGFloat(min(1, g / n)),
                       blue: CGFloat(min(1, b / n)), alpha: 1)
    }

    // MARK: - Drawing it

    /// The canvas as a layer. THIS IS THE DISPLAY PRIMITIVE and there is no other one.
    ///
    /// `.axial` from the top edge to the bottom edge, which is Telegram's `drawLinearGradient` from
    /// (0,0) to (0,height) and their shader's single vertical interpolation. Actions are disabled
    /// because a colour change inside a layout pass would otherwise animate over the default 0.25s,
    /// and a canvas that fades between two greys while a card is moving is the flicker this file
    /// exists to remove.
    public static func makeLayer() -> CAGradientLayer {
        let l = CAGradientLayer()
        l.startPoint = CGPoint(x: 0.5, y: 0)
        l.endPoint = CGPoint(x: 0.5, y: 1)
        l.locations = [0, 1]
        l.needsDisplayOnBoundsChange = false
        l.colors = [UIColor.black.cgColor, UIColor.black.cgColor]
        return l
    }

    /// Point a layer at a piece of media. Safe to call every layout pass: it returns without touching
    /// anything when the answer has not moved, so the layer is never handed a new colour pair for the
    /// same picture (which is what an implicit animation needs to start).
    public static func apply(_ colours: (top: UIColor, bottom: UIColor), to layer: CAGradientLayer) {
        let want = [colours.top.cgColor, colours.bottom.cgColor]
        if let have = layer.colors as? [CGColor], have.count == 2,
           have[0] == want[0], have[1] == want[1] { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.colors = want
        CATransaction.commit()
    }

    /// Frame a layer without animating it. `CALayer` sublayers do not autoresize and a plain
    /// `frame =` inside an animation block inherits that animation, so the canvas would lag the card
    /// it belongs to by one spring — visible as the backdrop sliding under a still photo.
    public static func frame(_ layer: CAGradientLayer, to rect: CGRect) {
        guard layer.frame != rect else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = rect
        CATransaction.commit()
    }

    /// The canvas as flat pixels, for the two places that need an image rather than a layer: the
    /// export that bakes it into a posted file, and the uploading placeholder.
    ///
    /// A gradient has no detail, so it is rendered small and stretched — nothing about it is sharper
    /// at full size, and one of its callers runs during a layout pass. `opaque` because this is the
    /// bottom of the picture; anything it fails to cover composites as black, which is the bug the
    /// whole canvas exists to end.
    public static func image(size: CGSize, top: UIColor, bottom: UIColor) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            draw(in: ctx.cgContext, size: size, top: top, bottom: bottom)
        }
    }

    // MARK: - The loading placeholder

    /// THE ONE PLACE A STORY IS STILL ALLOWED TO BLUR, and it is not the canvas — it is the LOADING
    /// STATE, which is a different thing and is Telegram's too: they show the story's thumbnail
    /// blurred while the full-size file comes down. The owner asked for this directly ("Whatsapp and
    /// Telegram and Other apps story never use grey skeleton loading, they use image blur or video
    /// blur") and it stays.
    ///
    /// STATIC PIXELS, NEVER A `UIVisualEffectView`. The poster is drawn into a canvas an eighth of
    /// the size and handed back at that size — a downscale IS a blur, the interpolation on the way
    /// back up does the work — with the dark veil already in it. One draw, at load time, never
    /// re-sampled, so it transforms like any other image and cannot shimmer against the card the way
    /// the effect view it replaced did (owner 2026-08-05: "scroll up video blur... is shaking").
    ///
    /// The small canvas carries the aspect of the RECT IT WILL COVER, not the screen's: getting that
    /// wrong paints the poster at a different zoom from the media that replaces it, which is a jump
    /// at first frame.
    public static func loadingVeil(of poster: UIImage, covering: CGSize) -> UIImage {
        let small = CGSize(width: max(8, covering.width / 8), height: max(8, covering.height / 8))
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: small, format: fmt).image { ctx in
            let s = max(small.width / max(poster.size.width, 1), small.height / max(poster.size.height, 1))
            let w = poster.size.width * s, h = poster.size.height * s
            poster.draw(in: CGRect(x: (small.width - w) / 2, y: (small.height - h) / 2, width: w, height: h))
            UIColor.black.withAlphaComponent(0.45).setFill()
            ctx.fill(CGRect(origin: .zero, size: small))
        }
    }

    /// The gradient stroke itself, shared by every raster caller.
    ///
    /// The flat fill goes down FIRST, so even if `CGGradient` cannot be built the result is a full
    /// opaque canvas rather than a transparent one.
    ///
    /// ⚠️ `UIGraphicsImageRenderer` hands out a FLIPPED context (origin top-left, y downwards), so
    /// y = 0 is the TOP and the top colour starts there. Drawing it the other way up is the classic
    /// way a gradient ships upside down, and on media whose two colours are similar nobody would
    /// notice until it shipped.
    public static func draw(in cg: CGContext, size: CGSize, top: UIColor, bottom: UIColor) {
        top.setFill()
        cg.fill(CGRect(origin: .zero, size: size))
        guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                    colors: [top.cgColor, bottom.cgColor] as CFArray,
                                    locations: [0, 1]) else { return }
        cg.drawLinearGradient(grad,
                              start: CGPoint(x: size.width / 2, y: 0),
                              end: CGPoint(x: size.width / 2, y: size.height),
                              options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
}
