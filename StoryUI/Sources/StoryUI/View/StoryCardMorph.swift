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
    /// ⚠️ WHICH CLIP THAT FRAME BELONGS TO, and it is the reason a cover can no longer be filed
    /// under the wrong story.
    ///
    /// `frameSource` is one global slot written by whichever player set up last, and the viewer keeps
    /// three pages alive. So "give me the frame on screen" was a question with no subject: the answer
    /// could be about a story the user is not looking at, and the caller had no way to tell. Every
    /// wrong-cover report in this area traces back to that.
    var currentVideoURL: String? { get }
    /// ⚠️ AND WHERE IN THE CLIP IT IS, which is the difference between a frame worth keeping and a
    /// frame that will overwrite one. See `bankCurrentFrame`. NaN or a negative is a normal answer
    /// from a player that has no item yet, and it fails the caller's test like any other.
    var currentVideoSeconds: Double { get }
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

    /// The corner the flight is asking for at this fraction. Two things need this number and they
    /// need the same one: the mask (the one visible curve on the card — see the ownership note in
    /// `applyCore`) and the cover (whose square corners are baked-in photograph, so it must carry
    /// its own copy of the same curve).
    private func wantedRadius(f: CGFloat, rowRadius: CGFloat) -> CGFloat {
        cardCornerRadius + (rowRadius - cardCornerRadius) * min(1, f / 0.12)
    }

    /// TRUE while a flight mask is cutting the card, posted as `storyFlightMask` (object: Bool).
    ///
    /// The contract behind the uncapped `flightRadius` in `applyCore`: while this is raised,
    /// `StoryDetailView` sets its own corner clip to ZERO, so the flight mask is the only curve on
    /// the card and cuts real pixels at any radius. Raised on the first frame of every flight —
    /// where the mask's radius equals the clip it replaces, so the swap cannot show — and lowered
    /// by `resetFlight`, in the same main-thread turn that restores the clip.
    private var flightMaskOwnsCorner = false
    private func setFlightMaskOwnsCorner(_ on: Bool) {
        guard flightMaskOwnsCorner != on else { return }
        flightMaskOwnsCorner = on
        if !on { cardClipIsDown = false }
        NotificationCenter.default.post(name: .init("storyFlightMask"), object: on)
    }

    /// ⚠️ HAS THE CARD ACTUALLY STOOD DOWN YET, as opposed to having been ASKED to.
    ///
    /// `storyFlightMask` is a notification into SwiftUI, where it lands on `@State flightMaskOn` and
    /// takes effect on the NEXT render pass. Until that pass commits, the card is still clipping
    /// itself at `cardCornerRadius` while this mask has already started opening — and the note in
    /// `applyCore` that says the swap cannot show is only true at exactly f = 0 with scale = 1.
    ///
    /// THE FIRST FRAME OF A DRAG IS NEVER AT f = 0. A pan begins after its slop threshold, so the
    /// first `applyCore` already carries a few points of movement, and from there the mask's radius
    /// in the card's own space is `wanted / scale` — climbing from both ends at once as `wanted`
    /// ramps 12 → 24 and `scale` shrinks — against a clip still sitting at 12. The difference is a
    /// crescent at each corner where the mask has cut real pixels away and the card's own black no
    /// longer reaches, so the dim wall behind shows through: his 2026-08-08 report, "a small black
    /// artifact around the corners" for the first 5-20% of the pull, gone by 30%, and ONLY on the
    /// first pull — because the first time that subtree re-renders with a new clip shape is the slow
    /// one, and every drag after it lands within a frame.
    ///
    /// ⚠️ THIS DOES NOT WALK BACK `8150fbd`. That fix is that the mask owns the corner, uncapped,
    /// with the card's own clip out of the way — and it still does, from the moment the card
    /// confirms. All this adds is that "the card has stood down" is now something the card SAYS
    /// rather than something we assume it did in time. Once the acknowledgement is in, every number
    /// below is exactly what it was; the clamp can only ever affect frames in which the old code was
    /// drawing two different curves over one corner.
    private var cardClipIsDown = false
    private var ackObserver: NSObjectProtocol?
    private func startListeningForCardClipAck() {
        guard ackObserver == nil else { return }
        // `queue: nil`, so this runs synchronously on the thread that posted — which is main, from
        // inside the card's own post-commit hop. An `OperationQueue.main` observer would add a
        // second hop and hold the cap one frame longer than it needs to be held.
        ackObserver = NotificationCenter.default.addObserver(
            forName: .init("storyFlightMaskAck"), object: nil, queue: nil
        ) { [weak self] _ in
            guard let self, self.flightMaskOwnsCorner else { return }
            self.cardClipIsDown = true
        }
    }

    /// WHERE A CIRCULAR OPEN STOPS BEING A CIRCLE AND STARTS BECOMING THE CARD, and where it has
    /// finished. Both measured in `f`, so they read backwards: the flight runs 1 → 0 on the way in.
    ///
    /// The window ENDS at 0.18 on purpose. That is `heroChromeSpan`, the point where the host starts
    /// fading the viewer's surround back in, and a mask that is still cutting when the furniture
    /// arrives is his 2026-08-08 screenshot: a header and a reply bar drawn in a rectangle around a
    /// round hole. Finishing the shape first means the surround only ever fills in around a mask
    /// that is already the card. `applyCore` also multiplies the surround by the shape's progress,
    /// so the two cannot disagree even if these numbers are edited apart.
    static let circleOpenStart: CGFloat = 0.35
    static let circleOpenEnd: CGFloat = 0.18

    /// How much of a LEAVING circular flight is spent becoming the circle, measured from full
    /// screen. Past it the mask is a true circle for every remaining frame.
    ///
    /// ⚠️ 0.06, DOWN FROM 0.15, AND THE OLD NUMBER WAS NOT WRONG SO MUCH AS MEASURED AGAINST THE
    /// WRONG THING. His original spec was "a 100% circle within the first 10-15% of the drag", and
    /// 0.15 reads like exactly that — but this is a fraction of `f`, and `f` does not run to 1 on a
    /// drag. `heroDragCeiling` caps it so the card stops shrinking at `heroDragMinScale` (0.46), and
    /// for a 49pt chat ring in a ~393pt card the ratio is about 0.125, so the ceiling is
    /// (1 - 0.46) / (1 - 0.125) = about 0.62.
    ///
    /// So 0.15 of `f` was 0.15 / 0.62 = about 24% OF THE TRAVEL HIS FINGER ACTUALLY MAKES — half as
    /// long again as the number promised, which is exactly the "too late, feels slow" he reported.
    /// 0.06 / 0.62 is about 9.7%, which is the spec he gave the first time, measured against the
    /// thing he is actually moving.
    ///
    /// ⚠️ DO NOT READ THIS AS A PERCENTAGE OF THE DRAG. Divide it by `heroDragCeiling` for the door
    /// in question, and re-derive it if `heroDragMinScale` ever moves.
    ///
    /// The open no longer has a window of its own to be confused with this one — a circular door
    /// opens as a card now (see `circleMorph`), which is the whole of his second report.
    /// ⚠️ 0.03 SINCE 2026-08-09, down from 0.06, and the reason is his WhatsApp reference shot.
    ///
    /// The shape journey was already right — at `circleMorph = 0` the crop is a SQUARE at the
    /// card's width, i.e. a centre-crop, which is exactly WhatsApp's filled circle rather than a
    /// whole story shrunk to fit. What he photographed and disliked ("I don't like how the circle
    /// starts") is the INTERMEDIATE: a big rounded rectangle for the first tenth of the travel,
    /// which reads as a blob because it is neither the card nor the circle.
    ///
    /// 0.03 of `f` over a ~0.62 ceiling is about 5% of the travel his finger makes, so the circle
    /// is there almost from the first movement and the whole rest of the drag is a circle flying
    /// home — his image 2. A NUMBER, deliberately: the geometry is not in question, only how long
    /// it is allowed to be in between, so this is the one thing to move if he wants it different
    /// again. Divide by the door's `heroDragCeiling` before reading it as a percentage.
    static let circleRushSpan: CGFloat = 0.03

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
    ///
    /// ⚠️ THE METRICS ARE A SHARED SINGLETON AND THEY OUTLIVE THE VIEWER THAT PUBLISHED THEM, which
    /// is where his 2026-08-08 "uploading story… sometimes have black top and bottom" comes from.
    /// `StoryDetailView` publishes on its own `onAppear`, so between a screen going up and its first
    /// layout the numbers still describe the LAST viewer — and a strip taller than the card it is
    /// cropping to shows what lies past the card, which is the page's own black.
    ///
    /// So the height is clamped to what a card in THIS view could possibly be. `cardHeight` is
    /// `min(9:16 of the width, the room available)`, so a strip taller than 9:16 of the view's own
    /// width is not a card at any size — it can only be a stale number, and clamping it costs
    /// nothing when the metrics are fresh because then the two agree exactly. The strip is pinned
    /// inside the view's bottom edge for the same reason.
    private func contentRect(in view: UIView) -> CGRect {
        guard cardHeight > 1, cardTop + 1 < view.bounds.height else { return view.bounds }
        let w = view.bounds.width
        let ceilingH = ceil(w * 1.77778)
        let h = max(1, min(min(cardHeight, ceilingH), view.bounds.height - cardTop))
        return CGRect(x: view.bounds.minX, y: view.bounds.minY + cardTop, width: w, height: h)
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
    ///   - exiting: this flight is LEAVING (a pull and the landing that follows it), as opposed to
    ///     an open. Only a circular door reads it, and only to pick which way its circle is timed —
    ///     see `circleRushSpan`.
    public func applyFlight(fraction: CGFloat, targetSize: CGSize, targetCenter: CGPoint, cornerRadius: CGFloat,
                            centerOverride: CGPoint? = nil, alpha: CGFloat = 1, dim: CGFloat? = nil,
                            chrome: CGFloat = 0, crop: CGFloat = 1, exiting: Bool = false) {
        guard let flightCard else { return }
        applyCore(on: flightCard, sheet: false, fraction: fraction, targetSize: targetSize,
                  targetCenter: targetCenter, cornerRadius: cornerRadius,
                  centerOverride: centerOverride, alpha: alpha, dim: dim, chrome: chrome, crop: crop,
                  exiting: exiting)
    }

    /// Flight over: container back to identity, unmasked — and the wall behind it opaque again. The
    /// dim writes onto the container's superview (the presenter's wall), and at rest that wall must
    /// be solid black, or a friend's full-bleed story would show the chat list through its own
    /// letterbox.
    public func resetFlight() {
        // The card's own clip comes back in the same main-thread turn the mask leaves in, so both
        // land in one render commit and there is no bare-cornered frame between them. (And even if
        // SwiftUI ever slipped a frame, at rest the two curves are the same 12pt — see the
        // ownership note in `applyCore`.) BEFORE the guard: the flag must never outlive a flight,
        // even one whose card has already gone, or the next viewer would render bare-cornered.
        setFlightMaskOwnsCorner(false)
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
        sheetFraction = max(0, min(1, fraction))
        applyCore(on: card, sheet: true, fraction: fraction, targetSize: targetSize,
                  targetCenter: targetCenter, cornerRadius: cornerRadius,
                  centerOverride: centerOverride, alpha: alpha, dim: dim, chrome: 0, crop: 1,
                  exiting: false)
    }

    /// HOW FAR THE STORY IS INTO THE VIEWERS SLOT: 0 full screen, 1 fully shrunk. Written here, on
    /// the one call that shrinks it, so it is a description of what is ON SCREEN rather than a
    /// message about what was requested.
    ///
    /// ⚠️ THIS IS TELEGRAM'S ANSWER TO "WHY IS THE CAPTION STILL THERE", and he has now asked four
    /// times. `StoryItemSetContainerComponent` sets its caption's alpha like this, in the same
    /// layout pass that scales the card:
    ///
    ///     var captionAlpha: CGFloat = (component.hideUI || ...) ? 0.0 : 1.0
    ///     captionAlpha *= (1.0 - itemLayout.contentScaleFraction)
    ///
    /// `contentScaleFraction` is the SAME number that shrinks their card. That multiplication is the
    /// whole mechanism: there is no notification, no timer, no snapshot, and no way for the caption
    /// to disagree with the card, because it is a pure function of the card's own state computed in
    /// the same pass.
    ///
    /// Ours was three separate signals (`storySheetProgress`, `storyChromeHidden`,
    /// `storyFlightActive`), and the doc on `SheetCaptionFade` admits the failure mode in as many
    /// words: "a fade driven by a continuous value is only ever as correct as the last value it was
    /// told". A cancelled drag, a killed spring, or a sheet that arrives open by a path that never
    /// walked the fade window all leave it holding a stale number, and a stale number is his
    /// screenshot. Reading THIS instead cannot be stale: if the card is in the slot, this is 1.
    public private(set) var sheetFraction: CGFloat = 0

    /// The one copy of the interpolation, serving both targets. `sheet` picks the mask slot and the
    /// reset that runs on the early-out, nothing else differs.
    private func applyCore(on card: UIView, sheet: Bool,
                           fraction: CGFloat, targetSize: CGSize, targetCenter: CGPoint,
                           cornerRadius: CGFloat, centerOverride: CGPoint?, alpha: CGFloat, dim: CGFloat?,
                           chrome: CGFloat, crop: CGFloat, exiting: Bool) {
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

        // The card's own corner clip stands down for the flight — see `setFlightMaskOwnsCorner`.
        // The listener is armed here rather than in `init` so the singleton owns no observer until
        // something actually flies.
        if !sheet { startListeningForCardClipAck(); setFlightMaskOwnsCorner(true) }

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
        // ⚠️ A CIRCULAR DOOR NEVER OUTGROWS THE CARD; IT BECOMES THE CARD.
        //
        // A ringed avatar is not a smaller card, and treating it as one is a mistake this file has
        // now made twice. The first version simply interpolated the corner radius and produced a
        // rounded rectangle growing out of a circle. The second grew a SQUARE from the card's width
        // out to its DIAGONAL, so that near full screen the circle circumscribed the card and cut
        // nothing — the arithmetic is right and the SHAPE is wrong, and his 2026-08-08 screenshot is
        // the proof: a circle whose diameter is between the card's width and its height is clipped
        // by the card's own edges, so what is really on screen has flat left and right sides and
        // curved top and bottom. "when it will circle left and Right feeling cut" — that is that
        // shape, and growing faster cannot fix it, because every intermediate size passes through it.
        //
        // So the crop is ALWAYS exactly the card's width, which nothing can clip sideways, and only
        // its HEIGHT and its RADIUS travel: a square with a half-width radius is a true circle at
        // one end, the full card with the card's own 12pt corner at the other, and every frame
        // between is a rounded rectangle on its way somewhere. At the card end the mask IS the card,
        // so handing over to the card's own clip changes nothing.
        //
        // `circleMorph` is that journey: 0 = a circle, 1 = the card.
        let circular = !sheet && cornerRadius >= min(targetSize.width, targetSize.height) / 2 - 0.5
        let cropRect: CGRect
        var circleMorph: CGFloat = 1
        if circular, exiting {
            // LEAVING: a circle inside the first 15%, held for the whole flight home. His spec,
            // "reach a 100% full circle mask within the first 10-15% of the drag".
            circleMorph = 1 - min(1, f / Self.circleRushSpan)
            // ⚠️ A TRUE CIRCLE THE WHOLE WAY, AND ITS DIAMETER IS FREE TO EXCEED THE CARD.
            //
            // The width-locked journey below (width pinned to `restW`, only the height and radius
            // travelling) was the THIRD shape this door has worn, built so nothing could clip the
            // mask sideways — and its intermediate frames are a flat-sided pill taller than it is
            // wide, which is his 2026-08-10 screenshot next to Snapchat's. The requirement, in his
            // words: width == height, cornerRadius = width / 2, at every moment, with the diameter
            // allowed to pass the screen width and the excess simply running off the edges.
            //
            // So the crop is a SQUARE whose side travels from the card's DIAGONAL — the circle that
            // CONTAINS the whole card, so the first frame cuts nothing — down to the card's width,
            // the circle the flight home already holds. While the side exceeds `restW` the circle
            // bulges past the card's own bounds; a mask hole beyond the layer's pixels cuts nothing
            // there, so what shows is the middle band of an oversized circle: curved top and bottom
            // on screen, the sides running off it. The old flat-sides bug cannot return, because the
            // shape never lingers between the card's width and height — it is wider than BOTH until
            // the moment it is a circle of the card's width.
            //
            // ⚠️ ACCEPTED COST, on purpose: at the very start of a drag the containing circle does
            // not reach the card's 12pt corners, so they render square for the first frames of the
            // rush. Snapchat's card is edge-to-edge square at rest, so this is exactly their look;
            // capping the circle to preserve a 12pt curve is how the pill got built.
            let diagonal = (restW * restW + restH * restH).squareRoot()
            let side = restW + (diagonal - restW) * circleMorph
            cropRect = CGRect(x: content.midX - side / 2, y: content.midY - side / 2,
                              width: side, height: side)
        } else if circular {
            // OPENING: NOT A CIRCLE AT ALL ANY MORE. His 2026-08-08 order in as many words —
            // "when opening the story it should open normally like the other stories, not as a
            // circle. Only when I close should it transition back into the circular avatar."
            // That is Snapchat's and WhatsApp's asymmetry: out as a card, home as a circle.
            //
            // `circleMorph = 1` IS the card, so an opening circular door now takes exactly the
            // same shape journey as a story-row card: a small rounded rectangle at the ring's
            // rect, growing to the full 9:16. The host drops the cover for these doors in the
            // same breath (`stageHeroOpen`), because a round cover in a card-shaped seat would
            // show its own empty corners.
            //
            // `circleOpenStart` / `circleOpenEnd` are kept rather than deleted: they are the
            // only record of why the open's window had to END before the surround arrived, and
            // that constraint comes straight back the day anyone re-introduces a shaped open.
            circleMorph = 1
            cropRect = CGRect(x: content.minX, y: content.midY - restH / 2, width: restW, height: restH)
        } else {
            let tightH = min(restH, visibleH / scale)
            let cropH = restH + (tightH - restH) * max(0, min(1, crop))
            cropRect = CGRect(x: content.minX, y: content.midY - cropH / 2, width: restW, height: cropH)
        }

        // A circular door's radius travels with its SHAPE, not with the fraction: half the card's
        // width while it is a circle, the card's own corner once it has become the card. Worked out
        // in the view's own coordinates, because the crop is — the non-circular radius below is a
        // screen-space number and the two must never be mixed.
        //
        // On the way OUT the crop is a true square (see the diagonal journey above), so half its
        // side IS the circle's radius at every frame — width == height == 2r, his rule verbatim.
        // The opening door still blends toward the card's own corner, because its `circleMorph`
        // is pinned to 1 and its shape is the card.
        let circleRadiusInView = (circular && exiting)
            ? cropRect.width / 2
            : (restW / 2) + (cardCornerRadius / max(scale, 0.05) - restW / 2) * circleMorph

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
        // ⚠️ THE COVER ROUNDS ITSELF, because the container's mask deliberately will not round it
        // enough. This is the white corner rind, third time, and this time it is WHITE rather than
        // black because the chat list was in LIGHT MODE.
        //
        // MEASURED off his 14:51 screenshot rather than taken from the report, which supplied a cause
        // ("white parent background, set it to clear") that the numbers do not support:
        //
        //     crescent at the top corners   (247, 244, 245)
        //     chat list under the card      (226, 226, 226)     <- dimmed, because a flight is running
        //     nav bar background            (247, 247, 247)     <- UNDIMMED chrome
        //
        // Brighter than the list it sits on, and an exact match for undimmed chrome. So it is not a
        // parent's backgroundColor (that would be a flat 255 and would not track the system
        // background), and it is not the list showing through a hole. It is the COVER's own pixels.
        //
        // The cover is a rectangular crop of the WINDOW at the row card's rect, taken at tap time.
        // The row card is rounded, so the corners of that rectangle contain the chat list BEHIND it,
        // photographed before the dim existed. Those pixels are part of the image.
        //
        // The container mask DOES cut them now (`flightRadius` runs uncapped at the wanted radius —
        // see the ownership note below), but the cover still clips itself at the same curve: its
        // corner pixels are photograph, not content, and a cover that relied on somebody else's
        // mask has been this area's mistake twice. Divided by `scale` for the same reason the
        // mask's is: the transform multiplies it back.
        if !sheet, let cover = flightCover {
            // A circle is a CIRCULAR curve, not a squircle. `.continuous` at exactly half the width
            // degenerates into something that is neither, and against a real avatar ring underneath it
            // that mismatch is a visible seam at the hand-over.
            cover.layer.cornerCurve = circular ? .circular : .continuous
            cover.layer.cornerRadius = circular
                ? circleRadiusInView
                : max(0, wantedRadius(f: f, rowRadius: cornerRadius)) / scale
            cover.layer.masksToBounds = true
        }
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
        // ⚠️ THE MASK OWNS THE CORNER, AND THE CARD'S OWN CLIP STANDS DOWN FOR THE FLIGHT.
        //
        // The story card used to clip ITSELF at `cardCornerRadius` (StoryDetailView's 12), and that
        // clip shrinks with the card: at the landing scale of 0.218 it renders as 2.6pt. A mask
        // rounder than the content's own clip cuts a crescent at the card's corners with nothing of
        // the card in it — the near-black wall early in a drag, measured in `6bf4418` as a wedge of
        // (0,9,23) against a photo of (91,177,202) — so the mask was capped at the card's rendered
        // corner, and only an opaque cover could release it (`3a5bcc7`, the square landing).
        //
        // Which left the DRAG. His spec pins the cover at 0 while the finger is down, so the cap
        // never stood down there, and a scroll-down close travelled with corners a couple of points
        // round and the grey wall sitting square against every one of them — his 2026-08-08 report,
        // four screenshots with the missing curve drawn on in red. The caption's scrim, overlaid
        // OUTSIDE the card's clip with square corners of its own, was the dark pair at the bottom.
        //
        // The cap was treating the symptom. The disease was two curves fighting over one corner:
        // the content's own clip (shrinking with the card) and this mask (the radius the design
        // actually wants). So while a flight mask is on, the card does not clip itself at all
        // (`storyFlightMask` → StoryDetailView): the hole cuts REAL pixels right up to its curve,
        // no crescent can exist at ANY radius, and the mask runs at the full wanted radius from the
        // first frame of a drag to the landing — including the caption scrim, which the same hole
        // now rounds. At f = 0 the wanted radius IS `cardCornerRadius`, so the swap with the card's
        // own clip at either end of a flight exchanges two identical corners and cannot show.
        // `* scale` so the `/ scale` in the call below hands it back unchanged: the circular radius
        // is already in the view's own coordinates (see where it is worked out), the other one is a
        // screen-space number that has to be converted.
        let wanted = circular ? circleRadiusInView : wantedRadius(f: f, rowRadius: cornerRadius)
        // HOLD THE HOLE AT THE CARD'S OWN CURVE UNTIL THE CARD SAYS ITS CLIP IS OFF. See
        // `cardClipIsDown` for the whole of why. In the card's own space this mask is
        // `flightRadius / scale`, and the clip it is replacing is a flat `cardCornerRadius`, so
        // matching them means capping the SCREEN-space number at `cardCornerRadius * scale`. While
        // the two agree there is no crescent to show anything through, at any fraction.
        //
        // Only the card path is held. A CIRCULAR door is a different shape by design — capping it
        // to a 12pt rounded rectangle for a frame would be a visible square, which is worse than
        // what it is guarding against, and the circle is not what he is reporting.
        let unconfirmed = !circular && !sheet && !cardClipIsDown
        let capped = unconfirmed ? min(wanted, cardCornerRadius * scale) : wanted
        let flightRadius = capped * (circular ? scale : 1)
        applyMask(on: card, sheet: sheet, rect: cropRect,
                  cornerRadius: (sheet ? cornerRadius * f : flightRadius) / scale,
                  // The exiting circle is a CIRCULAR curve, not a squircle — the same rule the
                  // cover already obeys (see its `cornerCurve` above): `.continuous` at exactly
                  // half the width degenerates into something that is neither, and against the
                  // avatar ring underneath the mismatch is a visible seam at the hand-over.
                  circularHole: circular && exiting,
                  // ⚠️ NOTHING OUTSIDE A CIRCLE, EVER — the first half of his 2026-08-08 report:
                  // "plz dont show transition images or mirror, just make like snapchat".
                  //
                  // `chrome` lets the viewer's surround — the header's own strip, the reply bar, the
                  // page's black — show through beyond the mask as the card arrives home. On a card
                  // door that is right: the mask is a rounded rectangle by then and the surround
                  // simply fills in around it. On a CIRCLE it is what he photographed: the story's
                  // furniture drawn in a rectangle around a round hole, with the chat list behind it,
                  // which reads as two pictures of the same screen at once.
                  //
                  // Multiplied by the shape's own progress, so the surround can only appear to the
                  // extent the mask has already become the card. At a true circle it is 0.
                  outside: sheet ? 0 : chrome * (circular ? circleMorph : 1),
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

    // ⚠️ `snapshotCard` IS DELETED, AND ITS WHOLE REASON FOR EXISTING WENT WITH IT.
    //
    // It answered "what is the live card showing right now", so the host could file that picture
    // under a story id and the row could draw it. That is a question with a subject that changes
    // under you: one global `frameSource`, three pages alive, and one instant to ask. Every
    // wrong-cover report in this area traced back to it, and moving the instant three times never
    // fixed it.
    //
    // Cards fetch their own picture from the frame bank now, keyed by their own clip
    // (`StoryPlaybackResume.cardFrame`), and `bankCurrentFrame` below fills that bank at the pause.
    // Nobody has to ask at the right moment, so nobody can ask at the wrong one.

    /// ⚠️ THE FRAME IS BANKED WHEN THE STORY IS FROZEN, NOT WHEN A CARD HAPPENS TO ASK FOR IT.
    ///
    /// `StoryPlaybackResume` already keeps one picture per clip, and its own note argues that asking
    /// BY STORY is what removes the timing window `snapshotCard` has never quite closed. But it was
    /// only ever written on a clip CHANGE or a `stopVideo` (`rememberPlaybackPosition`), and the
    /// viewers sheet does neither — it PAUSES. So at the one moment the carousel needs a real frame
    /// for the story it is coming up over, the bank was empty, every card fell back to `previewUrl`,
    /// and for a video that url is the poster made at post time: second zero. **That gap is the whole
    /// reason the capture-at-an-instant system exists**, and filling it here is what lets that system
    /// be deleted rather than re-timed a fourth time.
    ///
    /// Called from the host pause and BEFORE the player is actually paused, because a paused item's
    /// video output hands its buffer over exactly once — see `currentVideoFrame`.
    ///
    /// Cheap to call and safe to call often: a clip with no decoded frame answers nil and writes
    /// nothing, and the bank is an `NSCache` keyed by the clip's own url, so re-banking the same
    /// story just replaces one entry.
    /// ⚠️ AND IT REFUSES TO BANK SECOND ZERO OVER SOMETHING BETTER.
    ///
    /// His 2026-08-10 report: a video paused at 20s, pull the sheet up and the mini card correctly
    /// shows the 20s frame; swipe the carousel away and back and it is second zero again.
    ///
    /// The bank has TWO writers and they did not agree. `rememberPlaybackPosition` has always been
    /// fenced at `t > 1` — a position under a second is not worth resuming to, and it banks the
    /// picture "in the same breath and under the same guard". This one had no fence at all. So the
    /// sequence is: the sheet pauses, 20s is banked, the card is right. Swiping away moves the
    /// player to another clip; swiping BACK builds a fresh player for this one, and the sheet is
    /// still up so the story is paused again the moment it arrives — with `.pauseStory` calling
    /// straight into here while that fresh player is still at the beginning and has not finished
    /// seeking to the position it remembered. A frame of second zero went into the bank, and
    /// `rememberFrame` also drops the card-sized copies, so the good 20s picture was gone twice
    /// over.
    ///
    /// Same fence as the other writer now, from the same number. A clip genuinely near its start has
    /// nothing to lose: the bank keeps whatever it had, and an empty bank still falls through to the
    /// poster, which is second zero anyway. There is no case where refusing this write is worse.
    @MainActor
    public func bankCurrentFrame() {
        guard let source = frameSource,
              let mediaURL = source.currentVideoURL,
              let url = URL(string: mediaURL) else { return }
        let t = source.currentVideoSeconds
        guard t.isFinite, t > 1 else { return }
        guard let frame = source.currentVideoFrame() else { return }
        StoryPlaybackResume.rememberFrame(url, image: frame)
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
        // BEFORE the guard: the card is back at full size whether or not there is still a card to
        // put back, and a `sheetFraction` left at 1 would hold the caption invisible for the next
        // story. This is the one number the caption trusts, so it must never outlive the shrink.
        sheetFraction = 0
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
                           circularHole: Bool = false,
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
        // ⚠️ THE SURROUND IS FENCED OUT OF THE CARD'S RECTANGLE, and that is what makes the hole a
        // TRUE CROP. The surround used to be the container's own backgroundColor, which paints
        // EVERYWHERE outside the hole — including the four corner notches between the hole's curve
        // and the card's square content (the card does not clip itself while a flight mask is on).
        // In those notches the card's own square corner rendered at the surround's alpha: his
        // 2026-08-09 screenshots, the square edge showing dimmed through the rounded corner for the
        // first ~40% of a close and the tail of an open. Trading that alpha away instead was build
        // 512's regression (`ac2c26e4`, reverted): the paint was the only thing DARKENING the notch,
        // so removing it showed the notch in full.
        //
        // The mask cannot tell card pixels from page furniture — they are one masked tree — so the
        // distinction is drawn in GEOMETRY instead: the surround is its own layer whose even-odd
        // cutout excludes the card's rect entirely. Outside the rect it is the same fading page
        // furniture as ever; inside the rect only the hole speaks, and beyond the hole's curve the
        // notch is alpha 0 — cropped, showing the presenter's backdrop like every other cut edge.
        // Both cutout rects are PLAIN RECTANGLES, so the squircle-vs-arc crescent war (the white
        // corners) has nothing to fight over here.
        let layer: CALayer
        let hole: CALayer
        let surround: CALayer
        let existing = sheet ? maskLayer : flightMask
        if let existing, card.layer.mask === existing, existing.sublayers?.count == 2,
           let s = existing.sublayers?.first, let h = existing.sublayers?.last {
            layer = existing
            surround = s
            hole = h
        } else {
            existing?.removeFromSuperlayer()   // an old single-sublayer mask cannot be reused
            layer = CALayer()
            let s = CALayer()
            // Opaque: only the alpha channel reaches the mask, the colour is arbitrary. The fade
            // rides on `opacity`, not on the colour's alpha, so the cutout mask below composes.
            s.backgroundColor = UIColor.black.cgColor
            s.cornerCurve = .continuous
            let cut = CAShapeLayer()
            cut.fillRule = .evenOdd
            cut.fillColor = UIColor.black.cgColor
            s.mask = cut
            let h = CALayer()
            // Opaque: only the alpha channel reaches the mask, the colour is arbitrary.
            h.backgroundColor = UIColor.black.cgColor
            h.cornerCurve = .continuous
            layer.addSublayer(s)
            layer.addSublayer(h)
            surround = s
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
        let holeRadius = max(0, min(cornerRadius, min(local.width, local.height) / 2))
        hole.cornerRadius = holeRadius
        // A true circle asks for the CIRCULAR curve; everything card-shaped stays on the squircle
        // so the hand-over to SwiftUI's `.continuous` clips cannot grow a crescent (the white
        // corners — see the note at the top of this function).
        hole.cornerCurve = circularHole ? .circular : .continuous
        // The surround — the page furniture beyond the card's rect, at the flight's fade. Its
        // cutout keeps it out of the card's rect entirely (see the note at the top): the notches
        // between the hole's curve and the card's square content belong to nobody, which IS the crop.
        let o = max(0, min(1, outside))
        surround.opacity = Float(o)
        if o > 0.001 {
            surround.frame = CGRect(origin: .zero, size: card.bounds.size)
            if let cut = surround.mask as? CAShapeLayer {
                cut.frame = surround.bounds
                let path = CGMutablePath()
                path.addRect(surround.bounds)
                // ⚠️ A CIRCULAR HOLE IS CUT OUT AS A CIRCLE, NOT AS ITS BOUNDING BOX — and his
                // 2026-08-10 black-corners screenshot is what a rectangle costs here.
                //
                // MEASURED off that screenshot rather than reasoned (1183x2560, luminance mapped on a
                // 24x60 grid): a bright circle running off both edges, four HARD BLACK wedges hugging
                // it, and above and below them a faint dimmed picture at luminance 25-70. Three
                // regions where the design has two.
                //
                // The rectangle above is the cause. For a CARD-shaped hole the gap between the hole's
                // curve and its bounding box is four corner notches a few points across — invisible,
                // and cutting them square is what keeps the squircle-vs-arc crescent war (the white
                // corners) off this layer. For a CIRCLE the same gap is the whole of a square minus
                // its inscribed disc: about a fifth of the crop, in four wedges the size of a thumb.
                // Excluded from the surround, they are alpha 0 — cropped down to the presenter's
                // wall, which early in a pull is near-solid black. The page furniture outside the
                // crop meanwhile draws at `outside`, so the two meet along the square's edge and that
                // seam is the artifact he circled.
                //
                // Cut as a circle they are simply outside the hole, like everything else outside the
                // hole, and they fade on the same number as the rest of the page. Nothing else moves:
                // the exact same arc the hole is drawn with (`addRoundedRect` draws CIRCULAR corners,
                // which is the curve `circularHole` already puts on the hole, at the same radius), so
                // the two shapes coincide and no crescent can open between them. The card path keeps
                // its plain rectangle untouched.
                if circularHole {
                    path.addRoundedRect(in: local, cornerWidth: holeRadius, cornerHeight: holeRadius)
                } else {
                    path.addRect(local)
                }
                cut.path = path
            }
        }
        // AND THE SURROUND IS A CARD TOO, not a square sheet of screen.
        //
        // His 2026-08-07 screenshot of a friend's story opening, bottom-left corner circled: the card
        // had its rounded corner and the black strip under it carrying the reply bar was square, so
        // the moment the reply bar faded in the page grew square shoulders under a rounded card. This
        // layer IS that strip — it is the whole page, and its alpha is what lets the surround
        // through — so it needs the same corner the card has. Same continuous curve, same radius,
        // which means the thing that grows out of the row reads as one card end to end.
        surround.cornerRadius = max(0, min(outsideRadius, min(card.bounds.width, card.bounds.height) / 2))
    }
}
