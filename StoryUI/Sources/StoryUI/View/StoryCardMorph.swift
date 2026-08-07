//
// The live story card, addressable from the host app so the viewers sheet can shrink the REAL
// story instead of drawing a picture of it.
//

import UIKit

/// Where a hero drag has got to. The pan lives in the library, because it has to be arranged
/// against the pager's own scroll view with `require(toFail:)`; every decision it leads to lives in
/// the host, because the host is the only thing that knows what the story was opened from.
public enum StoryHeroPhase { case began, changed, ended, cancelled }

/// Something that can hand over the video frame it is showing RIGHT NOW.
///
/// Implemented by the story's player. It exists because the alternative — photographing the screen
/// with `drawHierarchy` — cannot see a video layer reliably: it returns the frame sometimes and a
/// black rectangle other times, with no error and nothing for the caller to check.
public protocol StoryVideoFrameSource: AnyObject {
    /// Nil is a normal answer, not a failure to hide. Callers fall back.
    func currentVideoFrame() -> UIImage?
}

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
    private var maskLayer: CALayer?

    /// THE FLIGHT CARD — the second transform target, and the reason there are two.
    ///
    /// The hero open/close used to fly the SAME view the sheet shrinks, and for a friend's story
    /// that view is UIPageViewController's internal scroll view. Build 481's crash is what that
    /// costs (`queuingScrollView:didEndManualScroll:` asserting while UIKit cleaned up a transition
    /// we had a transform on): a private view UIKit animates itself is not ours to move, and no
    /// geometry fix was going to make it safe. The flight therefore moves THIS view instead — the
    /// full-screen container the app's own presenter (`StoryZoomPresenter`) wraps around the whole
    /// viewer. Created by us, laid out by nobody, never written to by UIKit: the property the solo
    /// host's `cardContainer` has always had, now true for BOTH hosts, because the container sits
    /// above whichever of them is mounted.
    ///
    /// The sheet keeps `card` (the inner view): it shrinks the story INSIDE the full-screen viewer
    /// while the carousel and panel stay put around it. The flight shrinks the WHOLE presented
    /// screen and crops it to the card strip with its mask — which is also what retires the old
    /// begging-layers-to-step-aside choreography: anything outside the strip is simply cropped,
    /// black backings included.
    private weak var flightCard: UIView?
    private var flightMask: CALayer?

    /// THE COVER THE OPEN WEARS. His frame-grab of the open showed the problem exactly: the flying
    /// card faded in as a half-transparent ghost of the full-screen layout over a row card that
    /// never moved — where Snapchat's growing thing is the cover picture itself, opaque from the
    /// first pixel, dissolving into the live story mid-flight. So the presenter hangs a snapshot of
    /// the tapped row card here (inside the flight container, above the content), the open seats
    /// the card OPAQUE wearing it — pixel-matched to the row card it covers, so nothing can pop —
    /// and dissolves it away while the card grows. Framed to the card strip on every apply, because
    /// the strip's metrics arrive with layout. Alpha is driven by the OPEN's own tick alone; it
    /// stays 0 for the close, whose landing crossfade into the real row card is untouched.
    public weak var flightCover: UIView?

    public func setFlightCoverAlpha(_ a: CGFloat) {
        guard let flightCover else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        flightCover.alpha = max(0, min(1, a))
        CATransaction.commit()
    }

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

    /// The full-screen story card's OWN corner radius, published by `StoryDetailView`. The flight's
    /// mask interpolates to this at the full-screen end rather than to a square corner — see
    /// `applyCore`.
    private var cardCornerRadius: CGFloat = 0

    public func setCardMetrics(top: CGFloat, height: CGFloat, radius: CGFloat = 0) {
        // Ignore a card that has not been laid out yet rather than storing a degenerate one and
        // dividing by it on the next frame of a drag.
        guard height > 1 else { return }
        cardTop = max(0, top)
        cardHeight = height
        cardCornerRadius = max(0, radius)
    }

    /// TRUE while the host's own hero open/close owns this card.
    ///
    /// It is not the same flag as `StoryPager.dismissActive`, and the difference matters. That one
    /// means "somebody else is writing `card.transform` directly, so `apply` must stand down". The
    /// hero transition drives the card THROUGH `apply`, so it must not raise that flag or it would
    /// switch itself off. What it does need is the other half of what that flag buys: the cube must
    /// not fold while the card is moving, because `getAngle` derives its angle from the page's
    /// global position and this transition moves the page.
    public static var heroDismissActive = false

    /// Undo the see-through a hero drag turned on. Registered by whichever pager installed the hero
    /// pan (it owns that page's background), called by the host when a close springs back.
    ///
    /// NOT called when a close commits: the card is on its way out, and repainting the page black
    /// behind it puts a black rectangle where the chat list should already be showing through.
    public var restoreAfterHero: (() -> Void)?

    /// The story's current player, while there is one. Weak: a player that has gone away must not be
    /// asked for frames, and must not be kept alive by having been asked once.
    public weak var frameSource: StoryVideoFrameSource?

    /// Make the page see-through for a hero flight: what pulls away has to be the story, over the
    /// chat list, not a black page with a story in it. Registered by whichever pager installed the
    /// hero pan, because the page's background belongs to the pager.
    ///
    /// Called from the drag's `.began` AND from a button close, so both exits look the same. That
    /// they must is not a detail: the chat media viewer shipped with an arrow that used a different
    /// exit from its drag, and it was reported.
    public var prepareForHero: (() -> Void)?

    /// Show a page that was born invisible for a hero OPEN.
    ///
    /// THE ONE-FRAME FLASH THIS EXISTS TO PREVENT. A hero open has to seat the card on the row card
    /// BEFORE anybody sees it, and the card is neither attached, in a window, nor laid out at the
    /// moment the cover goes up. So the first painted frame would be the story at full size, and the
    /// open would begin with a pop.
    ///
    /// The pager therefore gives birth to the page INVISIBLE when a hero open is expected, and the
    /// host reveals it through here once it has placed the card. If nothing ever does, the pager
    /// reveals the page by itself shortly afterwards: a missed animation is a disappointment, an
    /// invisible story is a broken screen.
    public var revealAfterHeroOpen: (() -> Void)?

    /// The story card's rectangle in WINDOW coordinates, at rest.
    ///
    /// The one honest source for where the card is. The host needs it to open FROM the row card
    /// rather than to a rectangle it worked out for itself with a second copy of `cardHeight`'s
    /// rule — and two copies of the same geometry that have to agree to the pixel is what produced
    /// the picture-jumping-inside-its-frame bug in `402ec4d`.
    ///
    /// Read it before a transform is applied, or `convert` will fold that transform into the answer.
    public var cardWindowRect: CGRect? {
        // `cardHeight` is published by StoryDetailView once it has laid out. Without it `contentRect`
        // honestly falls back to the whole page, which is a rectangle taller than the card and NOT
        // what a hero should fly to — better to answer "not yet" and let the caller wait a frame.
        guard let card, card.window != nil, card.bounds.width > 1, cardHeight > 1 else { return nil }
        let r = contentRect(in: card)
        guard r.width > 1, r.height > 1 else { return nil }
        return card.convert(r, to: nil)
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

    // MARK: The flight target

    public var isFlightAvailable: Bool { flightCard != nil }

    public func attachFlight(_ view: UIView?) {
        flightCard = view
    }

    /// Identity-checked for the same reason `detach` is: a teardown must never clear a successor's
    /// registration.
    public func detachFlight(_ view: UIView?) {
        guard let view, flightCard === view else { return }
        resetFlight()
        flightCard = nil
    }

    /// The card strip inside the flight container, in WINDOW coordinates, at rest. Resolved from
    /// the same metrics `cardWindowRect` uses, against a view whose `bounds.origin` is structurally
    /// zero — the double-counted-offset trap in `applyMask` cannot arise here. Read it before a
    /// transform is applied, or `convert` folds that transform into the answer.
    public var flightRestRect: CGRect? {
        guard let flightCard, flightCard.window != nil, flightCard.bounds.width > 1, cardHeight > 1 else { return nil }
        let r = contentRect(in: flightCard)
        guard r.width > 1, r.height > 1 else { return nil }
        return flightCard.convert(r, to: nil)
    }

    /// `apply`, on the flight container. Same interpolation, same mask discipline, shared core —
    /// two copies of geometry that must agree to the pixel is the mistake this file keeps warning
    /// about, so there is exactly one. No `dismissActive` guard: the library's own dismiss pan is
    /// never installed on a hero presentation, so the two cannot contest this view.
    /// - Parameter chrome: how much of what lies OUTSIDE the card strip may show through, 0…1.
    ///   The crop is not a switch any more. Everything the viewer draws around the card — the reply
    ///   bar and its black footer, my own story's Views/trash footer, the page's own black — was
    ///   cropped away for the WHOLE flight and then arrived in one frame when `resetFlight` took the
    ///   mask off. That is his "the top and bottom sections pop into place" and his "the reply bar
    ///   comes late": there was no state between hidden and there. Now the mask's outside region is
    ///   drawn at this alpha, so the surround fades in with the card's last stretch home and out
    ///   again with the first of a drag — one continuous arrival, driven by the same fraction as
    ///   everything else. 0 is the old hard crop, which is what the viewers sheet still wants.
    ///   - crop: how much of the story's height is shaved to reach the row slot's shorter shape,
    ///     0…1. **The drag passes 0 and a flight drives it** — see the note in `applyCore`. Defaulted
    ///     to 1 so any caller that does not care keeps the original geometry exactly.
    public func applyFlight(fraction: CGFloat, targetSize: CGSize, targetCenter: CGPoint, cornerRadius: CGFloat,
                            centerOverride: CGPoint? = nil, alpha: CGFloat = 1, dim: CGFloat? = nil,
                            chrome: CGFloat = 0, crop: CGFloat = 1) {
        guard let flightCard else { return }
        applyCore(on: flightCard, sheet: false, fraction: fraction, targetSize: targetSize,
                  targetCenter: targetCenter, cornerRadius: cornerRadius,
                  centerOverride: centerOverride, alpha: alpha, dim: dim, chrome: chrome, crop: crop)
    }

    /// Flight over: container back to identity, unmasked — and the wall behind it opaque again. The
    /// dim writes onto the container's superview (the presenter's wall), and at rest that wall must
    /// be solid black, or a friend's full-bleed story would show the chat list through its own
    /// letterbox.
    public func resetFlight() {
        guard let flightCard else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        flightCard.transform = .identity
        flightCard.alpha = 1
        flightCard.layer.mask = nil
        flightMask = nil
        flightCover?.alpha = 0   // the cover belongs to flights; at rest the live story is the screen
        flightCard.superview?.backgroundColor = .black
        CATransaction.commit()
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
    /// - Parameters:
    ///   - centerOverride: put the card's centre EXACTLY here (window coords) instead of
    ///     interpolating rest → `targetCenter` by `fraction`. The hero close needs this: while the
    ///     finger is down the card must sit under the finger, 1:1, and `fraction` must still be free
    ///     to describe how far the SHRINK has got. Those are two different journeys and the sheet's
    ///     single-fraction lerp cannot express both. Nil keeps the original behaviour exactly, which
    ///     is what the viewers sheet still uses.
    ///   - alpha: the card's own opacity. 1 for the sheet; the hero close softens it slightly as it
    ///     is pulled away.
    ///   - dim: how dark the surface BEHIND the card should be, 0…1. Snapchat darkens the list while
    ///     the story is pulled away from it, and that darkening is most of why theirs reads as the
    ///     story lifting off rather than a card sliding about on a bright white page. It is written
    ///     onto the card's superview rather than a new view because that view is already the thing
    ///     `prepareForHero` makes see-through, so there is exactly one answer to "what is behind the
    ///     card". Nil leaves it alone, which is what the viewers sheet wants: it has its own canvas.
    public func apply(fraction: CGFloat, targetSize: CGSize, targetCenter: CGPoint, cornerRadius: CGFloat,
                      centerOverride: CGPoint? = nil, alpha: CGFloat = 1, dim: CGFloat? = nil) {
        // A dismiss owns the same transform. It cannot be running at the same time as the sheet
        // (both pans are direction-locked and the sheet is shut before a dismiss can start), but if
        // it ever were, the dismiss wins: it is the gesture that removes the screen.
        guard !StoryPager.dismissActive, let card else { return }
        // `crop: 1` — the sheet's geometry is unchanged and must stay so. It shrinks the story into
        // the viewers panel's slot, where the shave IS the effect: it is what hides the black above
        // and below the card. Only the flight defers it.
        applyCore(on: card, sheet: true, fraction: fraction, targetSize: targetSize,
                  targetCenter: targetCenter, cornerRadius: cornerRadius,
                  centerOverride: centerOverride, alpha: alpha, dim: dim, chrome: 0, crop: 1)
    }

    /// The one copy of the interpolation, serving both targets. `sheet` picks the mask slot and the
    /// reset that runs on the early-out, nothing else differs.
    private func applyCore(on card: UIView, sheet: Bool,
                           fraction: CGFloat, targetSize: CGSize, targetCenter: CGPoint,
                           cornerRadius: CGFloat, centerOverride: CGPoint?, alpha: CGFloat, dim: CGFloat?,
                           chrome: CGFloat, crop: CGFloat) {
        guard let superview = card.superview else { return }
        let f = max(0, min(1, fraction))
        // The dim is written before the early-out: a drag that has begun but not yet moved is still a
        // drag, and the surface behind should already be answering to it.
        if let dim { superview.backgroundColor = UIColor.black.withAlphaComponent(max(0, min(1, dim))) }
        // A hero drag begins at fraction 0 and moves the card by translation alone for the first
        // few points, so "nothing to do" cannot be decided from the fraction on its own any more.
        guard f > 0.001 || centerOverride != nil else {
            if sheet { reset() } else { resetFlight() }
            return
        }
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
        let wantX: CGFloat, wantY: CGFloat
        if let centerOverride {
            let p = superview.convert(centerOverride, from: nil)
            wantX = p.x; wantY = p.y
        } else {
            wantX = restCenter.x + (targetLocal.x - restCenter.x) * f
            wantY = restCenter.y + (targetLocal.y - restCenter.y) * f
        }
        // ...minus where the scale alone will already have put it. At f = 0 this is exactly zero.
        let dx = wantX - card.center.x - offset.x * scale
        let dy = wantY - card.center.y - offset.y * scale

        // The crop, in the view's own untransformed coordinates: the card's width, and whatever
        // height renders as `visibleH` once the scale is applied, centred on the CARD. This is also
        // what hides the black above and below the card once the sheet is open.
        //
        // ⚠️ `crop` IS HOW MUCH OF THAT RECONCILIATION IS APPLIED, AND THE DRAG PASSES 0.
        //
        // The row slot is deliberately ~12% shorter than the story's own 9:16 (the owner signed that
        // off twice), so a uniform scale cannot satisfy width AND height and the difference has to
        // come out of the story's height somewhere. Taking it out on the FRACTION meant the picture
        // was being shaved from the top and bottom while his finger was still on it, which is his
        // 2026-08-07 report: "as the view moves downward its content bounds clip and crop… the media
        // is distorted". So the shave is a value the flight owns, exactly like the cover: the finger
        // gets `crop: 0`, a pure uniform scale-down of the whole 9:16 picture with nothing removed
        // (Snapchat's zoom-out), and the snap that follows the release converges it to 1 over the
        // same window the cover fades in on. At the landing it is 1, so the card is the slot's shape
        // and the pixel identity the hand-over depends on is untouched.
        let tightH = min(restH, visibleH / scale)
        let cropH = restH + (tightH - restH) * max(0, min(1, crop))
        let cropRect = CGRect(x: content.minX, y: content.midY - cropH / 2, width: restW, height: cropH)

        // CATransaction: the mask's geometry is implicitly ANIMATED, so without this it chases the
        // transform by a quarter second and the crop visibly lags the card under the finger. A
        // UIView transform is not implicitly animated; a bare CALayer's frame, cornerRadius and
        // backgroundColor all are, which is why they live inside the same disabled-actions block.
        // (Was a CAShapeLayer path, same hazard, same reason — see `applyMask`.)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // ⚠️ THE COVER IS FRAMED TO THE CROP, NOT TO THE WHOLE STRIP, and that is a pixel identity
        // rather than a preference. The strip is 9:16; the row card is not (the slot is deliberately
        // shorter, and the crop above is what takes the difference out of the story). A cover framed
        // to the STRIP was therefore aspect-filled into 9:16 and then cropped AGAIN by that same
        // mask — the row card's own picture, zoomed by about a fifth, landing on top of the row card
        // it was supposed to be identical to. Framed to the crop, the rectangle it fills has exactly
        // the row card's aspect (restW / (targetH/scale) == targetW/targetH), so at fraction 1 the
        // cover IS the row card, pixel for pixel, and the hand-over at either end cannot pop.
        // Alpha is not touched here — the flight's own fraction owns it.
        if !sheet { flightCover?.frame = cropRect }
        // THE RADIUS RUNS BETWEEN TWO REAL CARDS AND NEVER REACHES ZERO.
        //
        // It used to be `cornerRadius * f`, which means square corners whenever the card is anywhere
        // near full screen — his 2026-08-07 screenshot of an opening story with all four corners
        // circled, "when i click story to open, plz give small rounded corners". It also read as a
        // rectangle of screen rather than a card for the first inch of a drag, which is the other
        // half of the same number.
        //
        // Both ends are now the radius of the thing actually being matched: `cornerRadius` at the row
        // (the row card's 24) and `cardCornerRadius` at full screen (StoryDetailView's own 12, which
        // it publishes). So the corner is rounded at every moment of the journey, and at BOTH ends
        // the hand-over is exact — at the row the mask agrees with the row card, and at full screen
        // it agrees with the card's own `.clipShape`, so `resetFlight` taking the mask away changes
        // nothing. Ramped over the first twelfth so the drag reaches the full 24 almost at once,
        // which is the "fixed 20-24pt as soon as the drag starts" his earlier spec asked for.
        // Divided by `scale` because the transform will multiply it back.
        // The SHEET keeps its own `cornerRadius * f` exactly as it was: it is a different journey
        // (full screen into the viewers panel) and nobody has reported anything about it.
        let flightRadius = cardCornerRadius + (cornerRadius - cardCornerRadius) * min(1, f / 0.12)
        applyMask(on: card, sheet: sheet, rect: cropRect,
                  cornerRadius: (sheet ? cornerRadius * f : flightRadius) / scale,
                  outside: sheet ? 0 : chrome,
                  // The sheet has no surround to round: its `outside` is 0, a hard crop.
                  //
                  // ⚠️ CAPPED, and the cap is what keeps a CIRCULAR landing from deforming the page.
                  // The surround follows the card's radius so the two read as one card — but a door
                  // that lands in a circle reports a radius of half its own width, and once that is
                  // divided by a small scale it is large enough to bend the whole full-screen
                  // container into a stadium. The card is allowed to become a circle; the page it
                  // sits in is always a page.
                  outsideRadius: sheet ? 0 : min(flightRadius / scale, 44))
        card.transform = CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: scale)
        if abs(card.alpha - alpha) > 0.001 { card.alpha = alpha }
        CATransaction.commit()
    }

    /// The card exactly as it looks right now, cropped to the story and no bigger than it needs to be.
    ///
    /// WHY THE CAROUSEL NEEDS THIS. The row draws its cards from `previewUrl`, and for a video that
    /// url is the poster generated at post time — second zero. That is fine until the live card
    /// steps aside for a swipe (`setHidden`), because at that instant the slot stops showing the
    /// frame you were watching and starts showing the first frame of the clip. Same complaint this
    /// whole file was written for, in the one place the transform does not reach: "swiping between
    /// stories must not replace the background video cover."
    ///
    /// `drawHierarchy` rather than `layer.render(in:)`, because an AVPlayerLayer's frames are not in
    /// the layer tree and `render(in:)` comes back with a hole where the video was. StoryPager's
    /// dismiss backdrop has taken this same picture of this same view since it was written.
    ///
    /// The view's own `transform` is NOT baked in — it belongs to the card's place in its superview,
    /// not to its contents — so this is the story at full size however far the morph has shrunk it.
    public func snapshotCard(width targetW: CGFloat) -> UIImage? {
        guard let card, card.bounds.width > 1, card.bounds.height > 1 else { return nil }
        let rect = contentRect(in: card)
        guard rect.width > 1, rect.height > 1 else { return nil }
        // ASK THE PLAYER FIRST. For a video this is the only answer that cannot come back black, and
        // the black-picture rejection below exists precisely because the fallback sometimes does.
        // A photo has no frame source, so it goes straight past this to the screen capture, which is
        // reliable for everything that is not a video layer.
        if let frame = frameSource?.currentVideoFrame() { return frame }
        // Rendered at the size it will be DRAWN at, not the size it is on screen. These are kept for
        // the length of a viewing session and a full-screen bitmap is several megabytes each.
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = UIScreen.main.scale * max(0.1, min(1, targetW / rect.width))
        fmt.opaque = true
        let shot = UIGraphicsImageRenderer(size: rect.size, format: fmt).image { _ in
            // Shifted so `rect` lands at the origin: the card is a page-wide strip and only the
            // story part of it is wanted.
            card.drawHierarchy(in: CGRect(x: -rect.minX, y: -rect.minY,
                                          width: card.bounds.width, height: card.bounds.height),
                               afterScreenUpdates: false)
        }
        // ⚠️ A BLACK PICTURE IS A FAILED PICTURE, AND IT MUST NOT BE KEPT.
        //
        // `drawHierarchy` does not reliably capture an AVPlayerLayer. Sometimes it does and
        // sometimes it hands back a black rectangle, and the caller had no way to tell — so a
        // failed capture was cached as though it were the frame he had been watching, and every
        // carousel card for that video went black for the rest of the session. His report, and only
        // ever on videos, because videos are the only thing this is taken for.
        //
        // Rejecting it costs nothing: the caller falls back to the poster, which is the behaviour
        // that existed before any of this and is merely second-zero rather than broken.
        return isBlank(shot) ? nil : shot
    }

    /// Nine points across the image; if every one of them is essentially black, the capture failed.
    /// A real story frame that is uniformly black at all nine is possible and would simply keep its
    /// poster, which is the safe way round to be wrong.
    private func isBlank(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return true }
        let w = cg.width, h = cg.height
        guard w > 2, h > 2 else { return true }
        var pixel = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpaceCreateDeviceRGB()
        for fx in [0.15, 0.5, 0.85] {
            for fy in [0.15, 0.5, 0.85] {
                guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                                          bytesPerRow: 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return true }
                ctx.translateBy(x: -CGFloat(w) * fx, y: -CGFloat(h) * (1 - fy))
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
                if Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2]) > 24 { return false }
            }
        }
        return true
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
        applyMask(on: card, sheet: true, rect: contentRect(in: card), cornerRadius: cornerRadius / max(scale, 0.05))
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
    ///
    /// `outside` is the alpha everything BEYOND `rect` renders at — a mask layer is composited by its
    /// own alpha channel, so a background colour under the path is a real, per-frame fade of the
    /// surround with no second view, no SwiftUI write and no animation of its own. 0 is the hard crop
    /// this has always done.
    private func applyMask(on card: UIView, sheet: Bool, rect: CGRect, cornerRadius: CGFloat,
                           outside: CGFloat = 0, outsideRadius: CGFloat = 0) {
        // ⚠️ A LAYER WITH A CORNER RADIUS, NOT A BEZIER PATH, AND THE REASON IS HIS WHITE CORNERS.
        //
        // This was a CAShapeLayer whose path came from `UIBezierPath(roundedRect:cornerRadius:)`,
        // which draws a CIRCULAR corner. Every card this thing has to agree with — the row card, the
        // story card — is a SwiftUI `RoundedRectangle(style: .continuous)`, an Apple squircle. Two
        // different curves at the same radius do not enclose the same area, and the crescent between
        // them is a few points wide at r = 24. What fills that crescent is the cover snapshot's own
        // corner pixels, which are the chat list photographed BEFORE the dim went on — so it reads as
        // a bright white rind hugging each corner, against a list that is by then dimmed.
        //
        // MEASURED, not reasoned: in his screenshot the rind samples (239,246,244) while the list two
        // pixels further out samples (190,188,189). Undimmed background sitting inside the mask. And
        // it is corner-only — a horizontal cut across the middle of the same edge shows the picture
        // meeting the list with nothing between them, which is what rules out a white parent view.
        //
        // `cornerCurve = .continuous` on a plain CALayer is the same curve SwiftUI draws, so the two
        // shapes now coincide and there is no crescent to fill. The surround still needs the layer
        // BEHIND the hole to carry `outside`'s alpha, hence a container plus one sublayer rather than
        // a single shape.
        let layer: CALayer
        let hole: CALayer
        let existing = sheet ? maskLayer : flightMask
        if let existing, card.layer.mask === existing, let h = existing.sublayers?.first {
            layer = existing
            hole = h
        } else {
            layer = CALayer()
            let h = CALayer()
            // Opaque: only the alpha channel reaches the mask, the colour is arbitrary.
            h.backgroundColor = UIColor.black.cgColor
            h.cornerCurve = .continuous
            layer.addSublayer(h)
            hole = h
            if sheet { maskLayer = layer } else { flightMask = layer }
            card.layer.mask = layer
        }
        // THE MASK'S OWN GEOMETRY, stated rather than left at CoreAnimation's default.
        //
        // A fresh CAShapeLayer has frame .zero. Its path is then resolved against a coordinate
        // origin that is NOT the masked layer's bounds origin — and the masked layer here is the
        // pager's internal scroll view, whose `bounds.origin` IS the content offset and moves by a
        // full page width every time you swipe to another person. So the path was drawn relative to
        // one origin while the card it was meant to cut sat at another, and the reveal landed
        // somewhere other than the story. Which page you were on decided where.
        //
        // That is the picture-in-the-wrong-place-with-black-around-it in his screenshots, and it is
        // also why the same code looked fine on the first person and broke on the next.
        layer.frame = card.bounds
        // ⚠️ AND THE PATH IS IN THE MASK'S OWN COORDINATES, WHICH IS THE OTHER HALF OF THE SAME BUG.
        //
        // Setting `frame` above puts the mask's origin AT `bounds.origin`, and a layer's path is then
        // drawn relative to that origin. `rect` comes from `contentRect(in:)`, which is built from
        // `bounds.minX` — so the content offset was counted twice and the reveal hole landed a whole
        // page to the RIGHT of the story it was meant to cut.
        //
        // Measured, not reasoned: his screen recordings show my own story (a plain container, origin
        // zero, so the two are equal and nothing goes wrong) flying correctly, while a friend's story
        // — the pager's scroll view, origin one page wide — is invisible for the whole open and leaves
        // a sliver of itself parked against the right edge on the close. One host works and the other
        // does not, and this is the only line that can tell them apart.
        let local = rect.offsetBy(dx: -card.bounds.origin.x, dy: -card.bounds.origin.y)
        hole.frame = local
        // Capped at half the short side: a continuous curve asked for more than that degenerates,
        // and the crop gets very short at the end of a close.
        hole.cornerRadius = max(0, min(cornerRadius, min(local.width, local.height) / 2))
        // The surround. Black is arbitrary — only the alpha reaches the mask.
        let o = max(0, min(1, outside))
        layer.backgroundColor = o > 0.001 ? UIColor.black.withAlphaComponent(o).cgColor : nil
        // AND THE SURROUND IS A CARD TOO, not a square sheet of screen.
        //
        // His 2026-08-07 screenshot of a friend's story opening, bottom-left corner circled: the card
        // had its rounded corner and the black strip under it carrying the reply bar was square, so
        // the moment the reply bar faded in the page grew square shoulders under a rounded card. This
        // container IS that strip — it is the whole page, and its alpha is what lets the surround
        // through — so it needs the same corner the card has. Same continuous curve, same radius,
        // which means the thing that grows out of the row reads as one card end to end.
        layer.cornerCurve = .continuous
        layer.cornerRadius = max(0, min(outsideRadius, min(layer.bounds.width, layer.bounds.height) / 2))
    }
}
