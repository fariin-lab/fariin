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

    /// Where the STORY CARD sits inside the registered view: how far down it starts, and how tall it
    /// is. The view is a page-wide strip; the card is 9:16 and pinned to the safe-area top inside it
    /// (Telegram's rule, see `StoryDetailView.cardHeight`). Shrinking the whole VIEW would carry the
    /// black above and below the card into the slot and centre on the wrong point.
    ///
    /// TOP AND HEIGHT, NOT A RECTANGLE, because the view is the pager's own scroll view: its
    /// `bounds` origin is the content offset and moves as you swipe between people. An absolute rect
    /// would be right on the first page and wrong on every other one. These are resolved against
    /// `bounds` at the moment they are used.
    private var cardTop: CGFloat = 0
    private var cardHeight: CGFloat = 0

    public func setCardMetrics(top: CGFloat, height: CGFloat) {
        // Ignore a card that has not been laid out yet rather than storing a degenerate one and
        // dividing by it on the next frame of a drag.
        guard height > 1 else { return }
        cardTop = max(0, top)
        cardHeight = height
    }

    /// The card in the registered view's CURRENT coordinates, or the whole view if nobody has
    /// published metrics yet.
    private func contentRect(in view: UIView) -> CGRect {
        guard cardHeight > 1, cardTop + cardHeight <= view.bounds.height + 1 else { return view.bounds }
        return CGRect(x: view.bounds.minX, y: view.bounds.minY + cardTop,
                      width: view.bounds.width, height: cardHeight)
    }

    /// True once a pager has registered a card. The host degrades to "no zoom" rather than to a
    /// crash if one was never registered.
    public var isAvailable: Bool { card != nil }

    public func attach(_ view: UIView?) {
        card = view
    }

    /// ONLY IF IT IS STILL THE CARD THIS CALLER ATTACHED.
    ///
    /// SwiftUI builds a replacement representable BEFORE it dismantles the one it is replacing, so a
    /// teardown routinely runs after the next viewer has already attached its own card. An
    /// unconditional `card = nil` here therefore wiped a LIVE viewer's card, and every later `apply`
    /// returned at its `guard let card` — the story simply never moved while the sheet came up over
    /// it, with nothing logged and nothing visibly broken until you pulled the sheet.
    ///
    /// Passing the view that is going away turns that into a no-op, which is what it always should
    /// have been: a dead pager has no business clearing a live one's binding.
    public func detach(_ view: UIView?) {
        guard let view else { return }
        guard card === view else { return }
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
        let content = contentRect(in: card)
        let restW = content.width, restH = content.height
        guard restW > 1, restH > 1, card.bounds.width > 1 else { return }

        // The card scales uniformly by WIDTH. The slot is deliberately shorter than the story's own
        // aspect (the owner signed off a card 12% shorter than aspect-true, twice), so a uniform
        // scale cannot satisfy both dimensions and the extra height is cropped rather than squashed.
        // Cropping is also what the neighbouring cards do, so the row stays consistent.
        let visibleW = restW + (targetSize.width - restW) * f
        let visibleH = restH + (targetSize.height - restH) * f
        let scale = max(0.0001, visibleW / restW)

        // The transform scales about the VIEW's centre, but what has to land in the slot is the
        // CARD's centre, and the card sits high in the view rather than in the middle of it. This
        // vector is the difference, and it scales along with everything else, so it has to come back
        // out of the translation or the story would arrive in the slot offset by it.
        let offset = CGPoint(x: content.midX - card.bounds.midX, y: content.midY - card.bounds.midY)

        // `center` is the view's resting position in its superview and is not affected by
        // `transform`, so it can be read fresh every frame and is always the truth even if a layout
        // pass lands mid-drag. A cached copy of a number you can just ask for is how this file's
        // predecessors went wrong.
        let targetLocal = superview.convert(targetCenter, from: nil)
        let restCenter = CGPoint(x: card.center.x + offset.x, y: card.center.y + offset.y)
        // Where the card's centre has to be this frame...
        let wantX = restCenter.x + (targetLocal.x - restCenter.x) * f
        let wantY = restCenter.y + (targetLocal.y - restCenter.y) * f
        // ...minus where the scale alone will already have put it. At f = 0 this is exactly zero.
        let dx = wantX - card.center.x - offset.x * scale
        let dy = wantY - card.center.y - offset.y * scale

        // CATransaction: a CAShapeLayer path change is an implicitly ANIMATED property, so without
        // this the mask chases the transform by a quarter second and the crop visibly lags the card
        // under the finger. A UIView transform is not implicitly animated; the mask is, which is why
        // both live inside the same disabled-actions block.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The crop, in the view's own untransformed coordinates: the card's width, and whatever
        // height renders as `visibleH` once the scale is applied, centred on the CARD. This is also
        // what hides the black above and below the card once the sheet is open.
        applyMask(rect: CGRect(x: content.minX,
                               y: content.midY - min(restH, visibleH / scale) / 2,
                               width: restW,
                               height: min(restH, visibleH / scale)),
                  cornerRadius: cornerRadius * f / scale)
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

    /// Clip the moving card to the STORY during a swipe-down dismiss.
    ///
    /// The page is TALLER THAN THE STORY. The card starts at the safe-area top and is 9:16, so the
    /// strip above it is the page's own black background — invisible normally, because it sits behind
    /// the status bar. The dismiss scales the whole page, which shrank that strip along with
    /// everything else and brought it into view as a black header inside the rounded card. Snapchat
    /// and Telegram have no such band because what shrinks for them is the story, not a page with a
    /// story in it.
    ///
    /// `cornerRadius` is the radius wanted ON SCREEN; it is divided by the scale here, because the
    /// mask lives in the card's own untransformed coordinates.
    public func maskToCard(cornerRadius: CGFloat, scale: CGFloat) {
        guard let card else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyMask(rect: contentRect(in: card), cornerRadius: cornerRadius / max(scale, 0.05))
        CATransaction.commit()
    }

    /// Drop the dismiss clip when the drag springs back.
    public func clearMask() {
        guard let card else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.layer.mask = nil
        maskLayer = nil
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

    /// `rect` is already centred on the card by the caller: the crop takes equal bites off its top
    /// and bottom, which keeps the subject of the photo where the eye left it. A top-anchored crop is
    /// the same mistake the reverted scaleEffect versions made in a different form.
    private func applyMask(rect: CGRect, cornerRadius: CGFloat) {
        guard let card else { return }
        let layer: CAShapeLayer
        if let maskLayer, card.layer.mask === maskLayer {
            layer = maskLayer
        } else {
            layer = CAShapeLayer()
            maskLayer = layer
            card.layer.mask = layer
        }
        layer.path = UIBezierPath(roundedRect: rect, cornerRadius: max(0, cornerRadius)).cgPath
    }
}
