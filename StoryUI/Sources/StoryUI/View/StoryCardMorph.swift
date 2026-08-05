//
// The live story card, addressable from the host app so the viewers sheet can shrink the REAL
// story instead of drawing a picture of it.
//

import UIKit

/// One handle on the story card that is actually on screen.
///
/// WHY THIS EXISTS. The card behind the viewers sheet used to be a photograph of the story:
/// `StoryImage(url: previewUrl)`, and for a video that url is the cover generated when it was
/// posted, which is second zero. Watch a 30 second story to 21 seconds, swipe up, and you were
/// looking at second zero. There is no picture any more. The real story view is scaled down into
/// the card slot and scaled back out, with the player paused where it stands, so the frame you were
/// on stays on screen because it is still the same layer drawing it. It cannot flash, jump or reset
/// to the beginning, because nothing is ever swapped for anything.
///
/// This is what Telegram does. `StoryItemSetContainerComponent` scales its live items container
/// with `CATransform3DMakeScale` and pauses playback while the view list is open; it has no
/// snapshot of any kind. Their frozen-frame behaviour is not a feature they built, it is a bug they
/// cannot have.
///
/// WHY IT IS UIKIT, which is the part that matters. Scaling the live story was tried twice before
/// and reverted twice: `c938ad8` ported Telegram's centre-anchored scale, then `da0bc72` tore it
/// out again with the note "every version scaled the LIVE story with scaleEffect ... = the top
/// break-out". Both attempts used a SwiftUI `.scaleEffect` on the hosted representable, which
/// re-lays-out the view it wraps and re-insets it against the safe area, and that is where the top
/// edge escaped. A `UIView.transform` is a render-time transform: bounds do not change, no layout
/// pass runs, nothing is re-inset. The swipe-DOWN dismiss in `StoryPager.handleDismiss` has
/// transformed this exact view this exact way since it was written, and that gesture is the one the
/// owner has always called smooth.
///
/// The two never overlap: the dismiss is a downward pan and the sheet is an upward one, both
/// direction-locked, and `apply` stands down entirely while a dismiss is running.
public final class StoryCardMorph {
    public static let shared = StoryCardMorph()
    private init() {}

    /// The pager's own horizontal scroll view, which is the moving card. Registered by StoryPager
    /// when it installs its pans, cleared when SwiftUI dismantles the pager.
    private weak var card: UIView?
    private var maskLayer: CAShapeLayer?

    /// True once a pager has registered a card. The host degrades to "no zoom" rather than to a
    /// crash if one was never registered.
    public var isAvailable: Bool { card != nil }

    public func attach(_ view: UIView?) {
        card = view
    }

    public func detach() {
        reset()
        card = nil
    }

    /// Move the card `fraction` of the way from full screen to the card slot.
    ///
    /// The host passes the rectangle it wants to SEE at the far end, not a scale factor, because the
    /// host owns the slot geometry and the design numbers that produce it. Everything is
    /// interpolated FROM the card's own resting size and centre rather than from numbers the host
    /// also computes, which is what makes `fraction: 0` exactly the identity by construction. Two
    /// copies of the same geometry that have to agree to the pixel is precisely the mistake that
    /// produced the picture-jumping-inside-its-frame bug in `402ec4d`.
    public func apply(fraction: CGFloat, targetSize: CGSize, targetCenter: CGPoint, cornerRadius: CGFloat) {
        // A dismiss owns the same transform. It cannot be running at the same time as the sheet
        // (both pans are direction-locked and the sheet is shut before a dismiss can start), but if
        // it ever were, the dismiss wins: it is the gesture that removes the screen.
        guard !StoryPager.dismissActive, let card, let superview = card.superview else { return }
        let f = max(0, min(1, fraction))
        guard f > 0.001 else { reset(); return }
        let restW = card.bounds.width, restH = card.bounds.height
        guard restW > 1, restH > 1 else { return }

        // The card scales uniformly by WIDTH. The slot is deliberately shorter than the story's own
        // aspect (the owner signed off a card 12% shorter than aspect-true, twice), so a uniform
        // scale cannot satisfy both dimensions and the extra height is cropped rather than squashed.
        // Cropping is also what the neighbouring cards do, so the row stays consistent.
        let visibleW = restW + (targetSize.width - restW) * f
        let visibleH = restH + (targetSize.height - restH) * f
        let scale = max(0.0001, visibleW / restW)

        // `transform` translates the centre within the SUPERVIEW's space, and `center` IS that
        // resting position — it is not affected by `transform`, so it can be read fresh every frame
        // and is always the truth even if a layout pass lands mid-drag. Only the target has to be
        // converted in. Caching the resting point instead would let the two drift apart the one time
        // it mattered, and a stored copy of a number you can just ask for is how this file's
        // predecessors went wrong.
        let targetLocal = superview.convert(targetCenter, from: nil)
        let dx = (targetLocal.x - card.center.x) * f
        let dy = (targetLocal.y - card.center.y) * f

        // CATransaction: a CAShapeLayer path change is an implicitly ANIMATED property, so without
        // this the mask chases the transform by a quarter second and the crop visibly lags the card
        // under the finger. A UIView transform is not implicitly animated; the mask is, which is why
        // both live inside the same disabled-actions block.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The crop, in the card's own untransformed coordinates: full width always, and whatever
        // height renders as `visibleH` once the scale is applied.
        applyMask(height: min(restH, visibleH / scale),
                  cornerRadius: cornerRadius * f / scale, cardW: restW, cardH: restH)
        card.transform = CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: scale)
        CATransaction.commit()
    }

    /// Step the live card aside while the carousel row is being swiped.
    ///
    /// The story cannot follow a card that is mid-flight: it sits at the slot centre while the row
    /// slides past it, so for the length of the swipe the carousel draws its own centre card and the
    /// real one hides underneath. Both are the same size in the same place at the moment of the
    /// exchange, so it is not visible. `jumpToStoryItem` has already moved the story to whichever
    /// card the row settles on by the time it comes back.
    public func setHidden(_ hidden: Bool) {
        guard let card else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.alpha = hidden ? 0 : 1
        CATransaction.commit()
    }

    /// Back to full screen, square, unmasked. Called when the sheet is fully shut.
    public func reset() {
        guard let card else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.transform = .identity
        // Restored unconditionally: a carousel swipe that is cancelled by the sheet closing under it
        // would otherwise leave the story invisible with no gesture left to bring it back.
        card.alpha = 1
        // A mask is an offscreen pass on every frame the story renders, including video playback, so
        // it comes off entirely at rest rather than being left covering the whole card.
        card.layer.mask = nil
        maskLayer = nil
        CATransaction.commit()
    }

    private func applyMask(height: CGFloat, cornerRadius: CGFloat, cardW: CGFloat, cardH: CGFloat) {
        guard let card else { return }
        let layer: CAShapeLayer
        if let maskLayer, card.layer.mask === maskLayer {
            layer = maskLayer
        } else {
            layer = CAShapeLayer()
            maskLayer = layer
            card.layer.mask = layer
        }
        // Centred vertically: the crop takes equal bites off the top and the bottom, which keeps the
        // subject of the photo where the eye left it. A top-anchored crop is the same mistake the
        // reverted scaleEffect versions made in a different form.
        let rect = CGRect(x: 0, y: (cardH - height) / 2, width: cardW, height: height)
        layer.path = UIBezierPath(roundedRect: rect, cornerRadius: max(0, cornerRadius)).cgPath
    }
}
