import SwiftUI
import UIKit
// The one sink this row keeps: `StoryFrameTick`, so a generated card frame reaches ONE card instead
// of invalidating every card's SwiftUI body. See `frameToken`. (The chat-list row next door has
// imported this for its own token since it was written — a different file, which is what I misread.)
import Combine
// `StoryVideoFrames` and `StoryFrameTick` live in the story library. ⚠️ The library also declares its
// own `Story`, and the one this file means is the app's — the module-local type wins, which is the
// same resolution StoriesViews.swift has always relied on.
import StoryUI

// THE VIEWERS-SHEET ROW, LAID OUT THE WAY THE REFERENCE APP LAYS ITS OWN OUT: one view per story,
// created once, and moved by writing three properties on it per frame.
//
// WHY THIS FILE EXISTS. The row was a SwiftUI `ZStack` of cards positioned from an `@State` that the
// scroll view wrote on every frame of a drag. That is one full SwiftUI body rebuild per frame — every
// card's view tree reconstructed and diffed sixty to a hundred and twenty times a second, each one
// re-asking for its picture, re-applying a clip, a shape, an opacity and a shadow — to move some
// views sideways. The owner's report was that the swipe felt slow and jumpy, and this was the largest
// part of it.
//
// Theirs does none of that. `updateScrolling` reads the scroller's `contentOffset`, works out each
// item's position and scale from it, and writes them onto views that already exist:
//
//     let effectiveScrollingOffsetX = self.scroller.contentOffset.x * itemLayout.contentScaleFraction
//                                   + centralItemOffset * (1.0 - itemLayout.contentScaleFraction)
//     ...
//     itemTransition.setPosition(view: visibleItem.unclippedContainerView, position: ...)
//
// No view is rebuilt, nothing is allocated on a moving frame, and no state is written that anything
// else observes. This file is that function.
//
// WHAT STAYED SWIFTUI, AND WHY. The picture inside a card is still `StoryImage` — the canvas, the
// fill threshold, the disk seeding and the owner's framing rules are all in it, and rewriting them in
// UIKit would be re-deciding settled questions for no gain. It is hosted ONCE PER STORY. Its inputs
// do not change while the row moves, so a scroll costs it nothing: SwiftUI is asked to draw a card
// when the card's content changes, and never because the card moved.

/// One card's numbers. ⚠️ A STRUCT RATHER THAN THE TUPLE THIS STARTED AS, because the row compares
/// the whole set on every update to decide whether to touch the labels — and a dictionary of tuples
/// cannot be compared without building two new dictionaries to compare instead. During a sheet page
/// drag that update runs once per frame, so a tuple here was two dictionary allocations per frame in
/// the middle of a gesture.
struct StoryRowCounts: Equatable {
    let views: Int
    let likes: Int
    static let zero = StoryRowCounts(views: 0, likes: 0)
}

/// WHY THE ROW IS MOVING WITHOUT A FINGER ON IT, and therefore how long it takes.
///
/// The reference app has exactly two of these and they are not the same length. A COMMIT — a tap on
/// a side card, a sheet page that crossed its threshold — settles over
/// `.curve(duration: 0.3, curve: .spring)`. An ABANDON — a sheet page released short — springs home
/// over `.curve(duration: 0.4, curve: .spring)`, deliberately slower, because a movement that
/// undoes itself should not look as decisive as one that meant something.
///
/// Ours had 0.3 for both, and the sheet's own panels had a THIRD number (0.28, ease-out) for the
/// commit and a FOURTH (0.3, damping 0.9) for the abandon — so the viewers list and the cards it
/// belongs to arrived on different curves at different times. One enum, read by both.
enum StoryRowSettle {
    case commit
    case abandon

    var duration: TimeInterval {
        switch self {
        case .commit: return 0.3
        case .abandon: return 0.4
        }
    }

    /// ⚠️ ONE CURVE, AND EVERY PIECE OF ONE MOVEMENT READS IT FROM HERE. HIS 2026-08-14 REPORT.
    ///
    /// The length was already shared and the CURVE was not, which is a subtler version of the same
    /// bug this enum was written to end. The side cards and their tints travelled on
    /// `usingSpringWithDamping: 0.82` — an UNDERDAMPED spring, slow to leave and overshooting at the
    /// far end — while the centre story, drawn by the morph in another hierarchy, travelled on a
    /// `CAMediaTimingFunction(name: .easeOut)`, which is fastest at the start. Over 0.3s those two
    /// are nowhere near each other: at the half-way point ease-out has covered about 85% of the
    /// distance and the spring about two thirds.
    ///
    /// So on every change of the centre story — a tap on a thumbnail, a sideways page — the centre
    /// card arrived while the thumbnails were still leaving, and the dimming, which is written with
    /// the cards it covers, arrived with them. That is his "the thumbnails have a delayed
    /// animation… the incoming card appears to move over the outgoing card… the brightness briefly
    /// appears in the wrong position": three symptoms of one movement drawn on two clocks.
    ///
    /// ⚠️ THE CURVE IS THE REFERENCE APP'S OWN SPRING NOW, AND IT IS A PLAIN BEZIER — READ OFF
    /// THEIR SOURCE, 2026-08-16. Ease-out lived here because their spring looked unnameable: a
    /// private timing constant paired with `UIView.AnimationOptions(rawValue: 7 << 16)`, and a
    /// curve that can only be stated exactly on one of the two faces is how the 2026-08-14 bug
    /// happened in the first place. Their animation utilities say otherwise: that constant is a
    /// DISPATCHER, not a curve. At 0.5s it builds a real `CASpringAnimation`; at one magic
    /// OS-specific duration a system spring; and at EVERY OTHER DURATION — their 0.3 commit and
    /// their 0.4 abandon included — a plain `CABasicAnimation` on the cubic bezier
    /// (0.38, 0.70, 0.125, 1.0). Fast out of the seat, a long gentle landing. So the spring CAN be
    /// stated exactly on both faces, and `run` below is the only place it is stated: view
    /// properties ride a `UIViewPropertyAnimator` built from the same two control points, and the
    /// bare layers written inside the block (the tints, the morph's transaction) ride `timing`.
    ///
    /// ⚠️ WHOEVER ADDS A THIRD SURFACE TO THIS MOVEMENT READS BOTH OF THESE. Neither a duration nor
    /// a curve may be written anywhere else, and nobody calls `UIView.animate` with a curve option
    /// on this movement again — that is a SECOND statement of the curve, which is the bug.
    private static let cp1 = CGPoint(x: 0.38, y: 0.70)
    private static let cp2 = CGPoint(x: 0.125, y: 1.0)
    var timing: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: Float(Self.cp1.x), Float(Self.cp1.y),
                              Float(Self.cp2.x), Float(Self.cp2.y))
    }

    /// THE ONE WAY A SETTLE IS ANIMATED. A property animator rather than `UIView.animate` because
    /// only `UICubicTimingParameters` can carry the bezier above for view properties — the options
    /// mask cannot name it. What the old options bought is still here: a property animator never
    /// turns touch delivery off (`.allowUserInteraction`), and an interrupting write lands additively
    /// on the presentation value (`.beginFromCurrentState`'s job since iOS 8).
    ///
    /// The explicit `CATransaction` inside the block is for the BARE layers written alongside the
    /// views — the tints. They used to inherit the `UIView.animate` block's ambient transaction;
    /// a property animator's block makes no such promise, so the duration and curve are stated
    /// rather than inherited. Same numbers, one clock, nothing implicit.
    func run(_ animations: @escaping () -> Void, completion: ((Bool) -> Void)? = nil) {
        let animator = UIViewPropertyAnimator(
            duration: duration,
            timingParameters: UICubicTimingParameters(controlPoint1: Self.cp1,
                                                      controlPoint2: Self.cp2))
        let duration = self.duration
        let timing = self.timing
        animator.addAnimations {
            CATransaction.begin()
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(timing)
            animations()
            CATransaction.commit()
        }
        if let completion {
            animator.addCompletion { completion($0 == .end) }
        }
        animator.startAnimation()
    }
}

// MARK: - The picture on one card

/// The card's media, hosted once per story.
///
/// Lifted verbatim out of the row's old `cardMedia` + `card`, including both branches and both of
/// their notes, because the framing rules in here have been ruled on by the owner more than once and
/// this move must not quietly change any of them.
struct StoryRowCardMedia: View {
    let story: Story
    let slotW: CGFloat
    let slotH: CGFloat

    // ⚠️ `isLive` IS GONE FROM HERE, AND ITS DELETION IS PART OF THE 2026-08-13 RULING.
    //
    // It was a boolean threaded down into the hosted content so the card could draw itself at
    // opacity 0 while the real story stood in its place. That put a question the ROW answers —
    // which of my items is the live one — inside a SwiftUI view, where changing the answer meant
    // reassigning `host.rootView` and rebuilding the card mid-scroll. The row hides the picture
    // directly now (`StoryRowItemView.setLive`), which is one property on a view that already
    // exists, decided in the same loop that decides everything else about this item.

    /// THE GENERATED FRAME FOR THIS CLIP, HANDED IN. Nil for a photo, and for a video nobody has
    /// watched this session; both fall through to the poster.
    ///
    /// ⚠️ IT IS NOT ASKED FOR HERE ANY MORE, AND THE OBSERVER THAT USED TO DRIVE IT IS GONE.
    ///
    /// This view held `@ObservedObject var frameTick = StoryFrameTick.shared` and asked
    /// `StoryVideoFrames.card` inside its own body. The note above it said that observing the tick
    /// HERE rather than on the row meant "it rebuilds one" — that was not true. The tick is a
    /// singleton with one published counter, so every mounted card observed the same object and one
    /// clip's frame landing invalidated all of them. A per-frame-arrival rebuild of every card in the
    /// row is the exact cost this file was written to remove.
    ///
    /// ⚠️ AND ASKING AT DRAW TIME MEANT THE PICTURE COULD CHANGE MID-SWIPE. The lookup returns nil
    /// until the frame has been made off the main thread, so a card draws the poster and then swaps
    /// to the generated frame whenever that lands — including in the middle of a movement, which is a
    /// thumbnail changing its picture while it travels. Theirs never swaps a cover during a
    /// transition; a cover is decided when the item is laid out and holds for that layout.
    ///
    /// The row asks now, once per card per pass, and holds a new answer until the row is still. See
    /// `cardShot(for:)` and `frameArrived()`.
    let shot: UIImage?

    var body: some View {
        media
            .frame(width: slotW, height: slotH)
            .clipped()
    }

    @ViewBuilder private var media: some View {
        if let shot {
            // ⚠️ PINNED TO THE SLOT. `Color.clear` is size-NEUTRAL: it accepts whatever size it is
            // proposed, and a bare `scaledToFill` would report its own oversized layout and have the
            // stack adopt it — which is how the cards once stopped agreeing about their own width and
            // grew into each other.
            Color.clear
                .frame(width: slotW, height: slotH)
                .overlay(Image(uiImage: shot).resizable().scaledToFill())
                .clipped()
        } else {
            // His 2026-08-08 report was that non-centred cards lost their blur. That was a
            // `UIVisualEffectView` DROPPING ITS BLUR when composited at fractional opacity, which is
            // exactly what a cover-flow does to every card that is not centred. The canvas ends the
            // question rather than patching it: a gradient at 80% opacity is the same gradient, 20%
            // weaker, in every card at once.
            StoryImage(url: story.previewUrl, fitCanvas: true, cardFillThreshold: slotH / slotW)
        }
    }
}

// MARK: - The small count inside a card

/// Eye + views + heart + likes, white over a soft shadow — the row's old `countRow(big: false)`.
///
/// UIKit, because its ALPHA is written on every frame of a scroll (a card hides its count as it
/// reaches the centre, where the big count below takes over). A SwiftUI view whose opacity changes
/// per frame is a SwiftUI view rebuilt per frame, which is the thing this whole file removes.
final class StoryRowCountView: UIView {
    private let stack = UIStackView()
    private let eye = UIImageView()
    private let views = UILabel()
    private let heart = UIImageView()
    private let likes = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        // ⚠️ THE BIG ROW'S NUMBERS, because this IS the big row now — it is only ever seen at full
        // size on the centred card, and the card's transform shrinks it on the way out. These match
        // the fixed section this replaced: `.subheadline.weight(.bold)` is 15, and its symbols came
        // out at the same point size.
        let font = UIFont.systemFont(ofSize: 15, weight: .bold)
        let symbol = UIImage.SymbolConfiguration(pointSize: 15, weight: .bold)
        eye.image = UIImage(systemName: "eye.fill", withConfiguration: symbol)
        eye.tintColor = .white
        heart.image = UIImage(systemName: "heart.fill", withConfiguration: symbol)
        // ⛔ WHITE, NOT RED (owner 2026-08-22). The eye beside it is white and the two are one
        // reading — a red heart made the number look like an alert rather than a count, and it was
        // the only coloured mark on a strip that is otherwise white over a photograph.
        heart.tintColor = .white
        for l in [views, likes] {
            l.font = font
            l.textColor = .white
        }
        // ⛔ THE GLYPHS KEEP THEIR OWN WIDTH (owner 2026-08-22: "left and right eyes icons sometimes
        // change width"). A `UIStackView` squeezes whichever arranged view is cheapest to squeeze
        // when it is handed less room than it asked for, and an image view's default resistance is
        // low — so the eye, not the number, was the thing that got flattened.
        //
        // It only showed SOMETIMES because the shortage is momentary: the count's frame is set from
        // `fittedSize()` by the card's `layoutSubviews`, and a new number arriving is measured on the
        // next pass, so for one frame the stack is sized for the old text. Required resistance means
        // that frame can be wrong without the icon paying for it, and `.center` keeps the drawn
        // glyph its own size whatever box it ends up in.
        for icon in [eye, heart] {
            icon.contentMode = .center
            icon.setContentCompressionResistancePriority(.required, for: .horizontal)
            icon.setContentHuggingPriority(.required, for: .horizontal)
        }
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 7
        stack.addArrangedSubview(eye)
        stack.addArrangedSubview(views)
        stack.addArrangedSubview(heart)
        stack.addArrangedSubview(likes)
        addSubview(stack)
        // The soft shadow the SwiftUI row drew with `.shadow(color: .black.opacity(0.5), radius: 3)`.
        // On the layer rather than per glyph, which is what a SwiftUI shadow on a stack resolves to
        // anyway and costs one offscreen pass instead of four.
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.5
        layer.shadowRadius = 3
        layer.shadowOffset = .zero
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// ⛔ NOT KNOWN YET IS NOT ZERO (owner 2026-08-22: "sometimes it says 0 but I have views… first
    /// it says 0, in seconds it shows the real count").
    ///
    /// The counts arrive from the server a moment after the strip is built, and until they did the
    /// card was handed `.zero` and printed a confident "0" over somebody's story. Nothing was wrong
    /// with the number when it landed; the wrong part was answering at all before there was anything
    /// to answer with. A blank space for a fraction of a second is honest, and a wrong count is not.
    ///
    /// A story that genuinely has no views still shows its 0 — that is a real answer and it stays.
    func set(views v: Int, likes l: Int, known: Bool = true) {
        isHidden = !known
        guard known else { return }
        views.text = Self.compact(v)
        likes.text = Self.compact(l)
        // The SwiftUI original omitted the heart entirely at zero rather than showing "0".
        let showLikes = l > 0
        heart.isHidden = !showLikes
        likes.isHidden = !showLikes
        // `.padding(.leading, 4)` on the heart, which a stack expresses as custom spacing.
        stack.setCustomSpacing(showLikes ? 11 : 7, after: views)
        setNeedsLayout()
        // ⚠️ AND THE CARD, because the card is what sets this view's FRAME from `fittedSize()`.
        // Asking only ourselves to lay out re-flows the stack inside a box that is still measured for
        // the previous number — which is the one frame the icon had to be squeezed into.
        superview?.setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        stack.frame = bounds
    }

    override var intrinsicContentSize: CGSize { stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize) }

    func fittedSize() -> CGSize { stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize) }

    static func compact(_ n: Int) -> String {
        if n >= 1000 {
            return String(format: "%.1fK", Double(n) / 1000).replacingOccurrences(of: ".0K", with: "K")
        }
        return "\(n)"
    }
}

// MARK: - One card

/// A card: the hosted picture, the small count over it, and a rounded clip.
///
/// Their `VisibleItem` — an object per story that lives for as long as the story is in the window,
/// holding the views so a scroll only has to move them.
final class StoryRowItemView: UIView {
    let storyId: String
    /// The hosting controller is retained here so the card's SwiftUI content lives exactly as long as
    /// the card does. It is parented properly by the row controller; see `addItem`.
    let host: UIHostingController<StoryRowCardMedia>
    let count = StoryRowCountView()
    /// What the hosted content was last built from. ⚠️ THE ROOT VIEW IS ONLY REASSIGNED WHEN ONE OF
    /// THESE ACTUALLY CHANGES. Writing `host.rootView` is a SwiftUI update; doing it inside the
    /// layout pass would put a per-frame SwiftUI rebuild straight back into the thing this file
    /// exists to take it out of.
    ///
    /// ⚠️ `isLive` USED TO BE IN HERE AND IS NOT ANY MORE. It changes whenever the row crosses a
    /// half-card, so it was the one member of this tuple that moved at scroll speed — which made a
    /// SwiftUI rebuild of two cards part of the cost of every swipe. It is a view property now, set
    /// by `setLive`, and nothing in this tuple changes faster than the sheet's own slot.
    private var applied: (mediaUrl: String, previewUrl: String, w: CGFloat, h: CGFloat,
                          shot: ObjectIdentifier?)?
    /// The frame this card is currently DRAWING, so the row can hand it back to itself rather than
    /// let a newly generated one replace the picture mid-movement. See `cardShot(for:current:)`.
    private(set) var appliedShot: UIImage?

    /// THE ONE ITEM WHOSE PIXELS COME FROM SOMEWHERE ELSE.
    ///
    /// The live story is a real player, a progress bar, a caption and a reply bar; it cannot be a
    /// poster. So its item holds its place, its size, its corner, its tint and its tap target like
    /// every other item in the row, and hides its own picture — the live layer underneath draws
    /// through the hole, at the rectangle THIS item was placed at.
    ///
    /// ⚠️ THIS IS NOT THE OLD BLANK-CARD RULE UNDER A NEW NAME. That rule existed because two
    /// renderers were positioned by two different code paths and one had to leave a hole for the
    /// other to fly into; the hole and the card in it could and did disagree about where they were.
    /// There is one code path now — `StoryRowController.updateScrolling` places this item and the
    /// live layer from the same `StoryRowPlacement`, in the same pass — so the hole cannot be
    /// anywhere the story is not.
    /// Whether the live layer is standing in for this card right now. Asked by `updateScrolling` on
    /// the pass a tap lands, to tell "this story is arriving" from "this story is already here" —
    /// the first needs the live layer seeded at this card's position so it has somewhere to travel
    /// from, the second must not be touched. Kept as a stored answer rather than read back off
    /// `host.view.isHidden`, because a value you are about to write is not a value to ask about.
    private(set) var isLive = false

    func setLive(_ on: Bool) {
        isLive = on
        guard host.view.isHidden != on else { return }
        host.view.isHidden = on
    }

    /// Clear air between the bottom of a card and its own count. Scales with the card, because it is
    /// laid out inside the card's transform — see `layoutSubviews`.
    private static let countGap: CGFloat = 10

    init(storyId: String, media: StoryRowCardMedia) {
        self.storyId = storyId
        self.host = UIHostingController(rootView: media)
        super.init(frame: .zero)
        // ⚠️ THE CLIP IS ON THE PICTURE, NOT ON THE CARD, which is the SwiftUI order this replaces:
        // `cardMedia.clipped().opacity().clipShape(RoundedRectangle(24)).overlay(count)`. The count
        // row was applied AFTER the shape and so was never clipped by it. Clipping the whole card
        // would cut the count's shadow off at the corners.
        //
        // The radius scales with the card because the card carries the transform and the picture is
        // inside it — the same thing `.clipShape` under a `.scaleEffect` did.
        host.view.layer.cornerRadius = 24
        host.view.layer.cornerCurve = .continuous
        host.view.clipsToBounds = true
        // A hosting controller's view is opaque by default on some paths, which would paint a
        // rectangle behind a card whose picture has not loaded yet.
        host.view.backgroundColor = .clear
        // ⚠️ NO SAFE-AREA INSETTING. The card is positioned by hand at an exact size; letting the
        // hosted content inset itself against the screen's safe area would make the picture inside a
        // card a different shape from the card.
        host.safeAreaRegions = []
        addSubview(host.view)
        // ⛔ THE COUNT IS A SUBVIEW OF THE CARD, AND THAT IS THE WHOLE MECHANISM (owner 2026-08-22,
        // stated twice and confirmed: "Preview + its Views + its Likes = one unit that moves
        // together. When the card moves, its counts move with it.").
        //
        // Being a child is what makes it follow: the row moves a card by writing `center` and
        // `transform` on the card, and every subview goes with it at the same instant, in the same
        // frame, with no second value to keep in step. A count drawn outside the card — which is what
        // the fixed section under the carousel was — can only ever be told about the movement
        // afterwards, which is the "stays fixed then swaps numbers" he rejected.
        //
        // ⚠️ IT IS SIZED FOR THE CENTRE and shrinks with the card, because the card's own transform
        // scales it. At the centre the scale is 1, so it draws at its full size and IS the single
        // large section; a side card is smaller and so is its count. One view, two jobs, no
        // hand-over.
        addSubview(count)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Rebuild the hosted picture only if something it is drawn from moved.
    func updateMedia(story: Story, slotW: CGFloat, slotH: CGFloat, shot: UIImage?) {
        // Labelled to match the stored tuple exactly: `==` on tuples wants the same labels, not just
        // the same types. The frame joins it by IDENTITY — a generated card frame is a cached object,
        // so the same picture is the same pointer and a changed one is a different pointer. That is
        // what turns "a frame landed somewhere in the row" into "this one card's picture changed",
        // which is the rebuild the old shared observer could not express.
        let want = (mediaUrl: story.mediaUrl, previewUrl: story.previewUrl, w: slotW, h: slotH,
                    shot: shot.map { ObjectIdentifier($0) })
        if let applied, applied == want { return }
        applied = want
        appliedShot = shot
        host.rootView = StoryRowCardMedia(story: story, slotW: slotW, slotH: slotH, shot: shot)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        host.view.frame = bounds
        let size = count.fittedSize()
        // ⛔ BELOW THE CARD, NOT INSIDE IT (owner 2026-08-22, with the design zoomed in so there was
        // no doubt: every thumbnail carries its own count in the black underneath, the way the
        // centre one already does).
        //
        // It used to be `bounds.height - size.height - 10`, i.e. sitting ON the picture ten points up
        // from its bottom edge — over somebody's photograph, which is what he means by the numbers
        // "entering inside the image". Ten points BELOW the edge instead. Safe because this view does
        // not clip: only `host.view` does, deliberately, so that the corner radius cuts the PICTURE
        // and not the count's shadow. See the note in `init`.
        //
        // It still rides the card's own transform, so a side card's count is smaller than the centre
        // one's in the same proportion its picture is — which is what the design shows.
        count.frame = CGRect(x: (bounds.width - size.width) / 2,
                             y: bounds.height + Self.countGap,
                             width: size.width, height: size.height)
    }
}

// MARK: - The row

/// A controller rather than a view, so the cards' hosting controllers have a real parent. An
/// unparented `UIHostingController` is a known way to lose appearance callbacks and leak, and there is
/// no reason to take that on when the representable can vend a controller just as easily.
@MainActor
final class StoryRowController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {

    // MARK: Inputs, written by the representable

    private(set) var stories: [Story] = []
    private(set) var liveStoryId = ""
    private(set) var geometry = StoryRowGeometry(slotW: 1, slotH: 1, centerY: 0, fullW: 1, fraction: 0)
    /// Per-story numbers for the small count inside each card.
    private(set) var counts: [String: StoryRowCounts] = [:]

    /// The sheet's own sideways throw, in card units — their `viewListPanState.fraction`, which they
    /// add to the same `offsetFraction` the scroller feeds.
    ///
    /// It arrives from SwiftUI because that is where it is animated (the commit and the spring home
    /// are both `withAnimation`), and it arrives ALREADY INTERPOLATED — see `StoryRowPositionReporter`.
    private(set) var pageDrag: CGFloat = 0

    // MARK: Outputs

    /// The rounded index changed while the row was scrolling — their `scrollViewDidScroll` navigate.
    var onIndexChanged: (Int) -> Void = { _ in }
    /// A finger-driven movement has fully ended — the drag, its deceleration and the snap included —
    /// and this is the index the row came to rest on. Fired exactly once per movement, from every
    /// way a scroll can end.
    ///
    /// ⚠️ WHY IT EXISTS: the host defers the PAGER's jump to this moment. The crossings still report
    /// through `onIndexChanged` (the viewers list and the count row follow the card mid-drag, which
    /// is the reference app's behaviour) — but telling the full-screen pager to swap stories on
    /// every crossing of a fling meant the live layer's CONTENT changed owners while the row was
    /// moving, and the pager loads a story slower than a finger crosses a card. Everything drawn in
    /// that lag is a picture in the wrong slot at the wrong brightness: his double-brightness at the
    /// half-card and his wrong-cover flash are both that window. The reference app can navigate
    /// mid-scroll because its navigation redraws nothing in the row; ours redraws the live layer,
    /// so the honest equivalent is to move the redraw to the one moment the row is still.
    var onIndexSettled: (Int) -> Void = { _ in }
    /// The centred card was tapped: collapse the sheet.
    var onActiveTap: () -> Void = {}

    // ⚠️ `onRowPosition` IS DELETED, AND SO IS EVERYTHING THAT LISTENED TO IT.
    //
    // It published the row's position outward every frame so the HOST could place the live story
    // from it. The host does not place the live story any more — this controller does, in the same
    // loop and from the same numbers as every other card — so there is nothing on the other end of
    // that wire. What it carried (`StorySheetPageDrag.rowScroll`, `publishRowPosition`, the host's
    // `placeLiveStory`) went with it.

    // MARK: Machinery

    /// THE ENGINE. A hidden `UIScrollView` whose pan is re-homed onto the row — their `Scroller`,
    /// added to `itemsContainerView` with `itemsContainerView.addGestureRecognizer(scroller.panGestureRecognizer)`.
    /// The scroll view does the physics; nothing is ever drawn by it.
    private let scroller = UIScrollView()
    /// Their `visibleItems`: one entry per story that is inside the window, keyed by story id.
    ///
    /// ⚠️ THE LIVE STORY IS IN HERE TOO. That is the 2026-08-13 ruling in one line: there is no
    /// separate concept of "the centred one" any more, no second table and no second loop. Its item
    /// is built, culled, positioned, dimmed, layered and hit-tested by exactly the code below that
    /// does those things for a thumbnail; the only difference is that it hides its own picture and
    /// the live layer draws through the hole (`StoryRowItemView.setLive`).
    private var items: [String: StoryRowItemView] = [:]

    /// THEIR `contentTintLayer`: one black layer per item, and a SIBLING of the cards rather than
    /// something inside one.
    ///
    /// A sibling because it must be able to dim a card it knows nothing about — which is precisely
    /// how their central, playing item is dimmed by the same code path as a thumbnail.
    ///
    /// ⚠️ ONE EXCEPTION, AND IT IS WRITTEN HERE BECAUSE THE OPPOSITE CLAIM STOOD IN THIS COMMENT FOR
    /// FOUR DAYS AND COST A REPORT. This view IS above the live layer — `coreLayers` is
    /// `ZStack { storyLayer; viewersBackdrop }` and the row is inside the second — so a tint here
    /// reaches the live story perfectly well. It just must not, because that story is ALREADY
    /// wearing `StoryCardMorph.contentTint` at the same number, and two black layers compound. The
    /// live item's tint is therefore written at zero; see the note beside the write.
    private var tints: [String: CALayer] = [:]
    /// THE DIM THE MORPH IS CURRENTLY DRAWING OVER THE LIVE CARD — remembered so the card can take it
    /// back at the instant the live layer leaves.
    ///
    /// A card that stops being live has had its own tint at zero for as long as it was live, and the
    /// brightness the eye was reading came from the morph. Hand it the placement's number instead and
    /// it steps to the DESTINATION on the spot: on a tap that is the centre card going dark before it
    /// has moved anywhere, the same shape as the 2026-08-16 arriving-card report. So the pass that
    /// takes the live layer away seats the tint at what the morph was showing and lets the settle
    /// carry it the rest of the way, like every other card.
    private var lastLiveDim: CGFloat = 0
    /// The stories this pass could actually SEE, as against the ones it holds a place for. Their
    /// `trulyValidIds`: a card animating out of the window stays in `items` and is missing from this,
    /// and its own animation's completion asks this set whether it is still gone. Re-asked rather than
    /// captured, so a card that came back during the glide is not removed underneath itself.
    private var trulyValidIds: Set<String> = []
    /// The story the row last told the player store was central, so the "only the central one plays"
    /// rule can be re-asserted per pass without asking the store on every frame of a drag.
    private var lastCentralTold: String = ""
    /// A generated frame landed while the row was moving and has not been spent. See `frameArrived`.
    private var framesPending = false
    /// THE ONE OBSERVER OF THE FRAME TICK FOR THE WHOLE ROW. It used to be one per card, on a shared
    /// singleton, which meant every card rebuilt whenever any clip's frame landed.
    private var frameToken: AnyCancellable?
    /// Their `ignoreScrolling` fence. A programmatic offset must not be mistaken for a finger.
    private var ignoreScrolling = false

    /// ⚠️ THE ROW IS STILL MOVING AND `isDecelerating` HAS ALREADY GONE FALSE.
    ///
    /// `snapScrolling` finishes a drag that stopped short of a whole card with an ANIMATED
    /// `setContentOffset`, and a scroll view animating its own offset reports itself as neither
    /// dragging, tracking nor decelerating. Without this the row would be back to accepting an
    /// outside jump for the length of that animation — a smaller window than the deceleration one
    /// below it, and the same bug in it.
    ///
    /// Lowered in `scrollViewDidEndScrollingAnimation`, which is the only thing that ends it.
    private var isSnapping = false

    /// THEIR `animateNextNavigationId`: a story this row ASKED for, whose arrival it owns the
    /// animation of.
    ///
    /// Set by a tap on a side card and cleared on the pass where the live story actually becomes it
    /// — their `if animateNextNavigationId == component.slice.item.id`. While it is set, the row
    /// refuses every other reason to move, because the only move it is waiting for is this one.
    private var animateNextStoryId: String?
    /// TRUE for the window between `handleTap` recording a side-card tap and `apply` seating the
    /// row on the arrived story. The host reads it (through `StoryRowLink`) at the moment
    /// `onIndexChanged` lands, to tell a TAP'S navigation apart from a SCROLL'S: the report is the
    /// same callback, but the sheet answers them differently — a tap pages the viewers list
    /// sideways, the reference app's way, while a scroll swaps it in place, also the reference
    /// app's way. The flag is already up when `handleTap` reports (it is set the line before), and
    /// a finger on the row clears it, so a drag can never read as a tap.
    var tapNavigationPending: Bool { animateNextStoryId != nil }
    /// TRUE for the whole of a finger-driven movement: the drag, its deceleration, and our own snap
    /// animation (which reports itself as none of the three — that is what `isSnapping` exists for).
    /// One statement of the question `apply`'s outside-jump gate and the host's pager-jump deferral
    /// both ask; two copies of this list is how `isDecelerating` went missing the first time.
    var isRowMoving: Bool {
        scroller.isDragging || scroller.isTracking || scroller.isDecelerating || isSnapping
    }
    /// The last index handed out through `onIndexChanged`, so the answer coming back around as an
    /// input cannot be mistaken for somebody else asking for a jump.
    private var reportedIndex = -1

    /// Where the scroller is, in card units. Unclamped on purpose: past either end the scroll view
    /// rubber-bands, and theirs has no clamp on this path either — that stretch is the row telling
    /// you there is nothing more that way.
    private var scroll: CGFloat {
        guard geometry.fullDist > 0.5 else { return 0 }
        let v = scroller.contentOffset.x / geometry.fullDist
        return v.isFinite ? v : 0
    }

    /// The card the row considers centred.
    private var centredIndex: Int {
        // ⚠️ CLAMPED BEFORE `Int(_:)`, NOT AFTER. `Int(_:)` TRAPS on infinity, on NaN and on
        // anything outside `Int`'s range — it does not saturate — and this is fed by a division. That
        // is the shape of the crash in build 463, and the rubber band makes an out-of-range value a
        // normal state here rather than an impossible one.
        let r = scroll.rounded()
        guard r.isFinite, r > -1_000_000, r < 1_000_000 else { return 0 }
        return max(0, min(max(0, stories.count - 1), Int(r)))
    }

    /// The CENTRAL item for layout purposes: the story the live layer is holding. Their
    /// `component.slice.item.id`, and the anchor the row's resting position is derived from.
    private var centralIndex: Int {
        stories.firstIndex { $0.id == liveStoryId } ?? centredIndex
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        scroller.isHidden = true
        scroller.showsHorizontalScrollIndicator = false
        scroller.showsVerticalScrollIndicator = false
        scroller.decelerationRate = .normal          // theirs; `.fast` overshoots the snap feel
        scroller.alwaysBounceHorizontal = true
        scroller.alwaysBounceVertical = false
        scroller.contentInsetAdjustmentBehavior = .never
        scroller.delegate = self
        view.addSubview(scroller)
        // THE TRICK, AND IT IS THEIRS: the scroll view's own pan, re-homed onto the visible row. The
        // scroll view still drives it, so the physics and the deceleration curve are the system's;
        // the touches it answers are the row's.
        view.addGestureRecognizer(scroller.panGestureRecognizer)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        view.addGestureRecognizer(tap)

        // See `frameToken`. One sink, and the row decides per card whether the answer changed.
        frameToken = StoryFrameTick.shared.$n
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.frameArrived() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scroller.frame = view.bounds
        syncContentSize()
        updateScrolling()
    }

    // MARK: Input

    func apply(stories: [Story], liveStoryId: String, geometry: StoryRowGeometry,
               counts: [String: StoryRowCounts], activeIndex: Int?) {
        // ⚠️ COMPARED WITHOUT ALLOCATING. This runs once per frame of a sheet page drag, and the
        // first version of it built two arrays of ids and two dictionaries to answer two questions
        // that are almost always "no". `zip` walks the pair in place, and `StoryRowCounts` is
        // `Equatable` so the dictionary compares itself.
        let storiesChanged = self.stories.count != stories.count
            || zip(self.stories, stories).contains { $0.id != $1.id }
        let countsChanged = self.counts != counts
        let geometryChanged = self.geometry != geometry
        let liveChanged = self.liveStoryId != liveStoryId
        self.stories = stories
        self.liveStoryId = liveStoryId
        self.geometry = geometry
        if geometry.fraction > 0.0001, geometry.slotH > 1 { everRaised = true }
        self.counts = counts

        syncScrollEnabled()

        // Unconditionally: the content size depends on the story count AND on `fullDist`, and
        // `fullDist` is derived from the slot, which the pull can re-measure without the story set
        // changing at all.
        syncContentSize()
        if storiesChanged {
            // A story was added or removed under the row. Anything the window no longer covers is
            // dropped on the next pass; what is left is re-anchored on the item the viewer is on.
            for (id, item) in items where !stories.contains(where: { $0.id == id }) {
                removeItem(id, item)
            }
        }
        if countsChanged {
            for (id, item) in items {
                let c = counts[id]
                item.count.set(views: c?.views ?? 0, likes: c?.likes ?? 0, known: c != nil)
            }
        }

        // SOMEBODY ELSE MOVED THE SELECTION — the sheet paged sideways, or the row was opened on a
        // story it is not currently centred on. Their `animateNextNavigationId` path: the offset is
        // put on the new item AT ONCE and the layout is animated to catch up over 0.3s.
        //
        // ⚠️ ONLY WHILE THE ROW IS COMPLETELY STILL, AND THAT IS THE WHOLE OF THE FAST-SWIPE FIX.
        //
        // Their rule, read off `:5234-5247`: while the row is open, the ONLY programmatic write to
        // the scroll offset is the sheet-page commit — `resetScrollingOffsetWithItemTransition`,
        // set at `:2764` only when the model has ARRIVED at the id the sideways pan asked for, and
        // never from the scroller's own navigation. The scroller is the truth and the story id
        // follows it. They cannot yank a moving row because they never write a moving row.
        //
        // Ours tested `!isDragging, !isTracking` — which are both FALSE for the whole of a flick's
        // deceleration, the one window this needs to cover. What arrives in that window is our own
        // report coming back around: the row says "index 3", that goes out through `onIndexChanged`
        // → `activeId` → `sheetStoryId` → a notification → the library's pager → back as
        // `targetStoryId`. Cross three cards in two hundred milliseconds and the value returning is
        // a card or two behind where the row already is. It does not match `reportedIndex`, so it
        // reads as somebody else asking for a jump, and the row teleports BACKWARDS mid-flight and
        // springs the cards 0.3s onto a card the finger already left. That is his "the centre one
        // has not finished leaving before the next one arrives".
        //
        // Deceleration and our own snap animation are as much the row's own movement as a finger is.
        let rowIsStill = !isRowMoving
        var seatedByTap = false
        if let pending = animateNextStoryId {
            // A TAP IS WAITING FOR ITS OWN STORY TO ARRIVE. Theirs, at the top of the update pass:
            //
            //     if let animateNextNavigationId = self.animateNextNavigationId,
            //        animateNextNavigationId == component.slice.item.id {
            //         self.animateNextNavigationId = nil
            //         itemsTransition = transition.withAnimation(.curve(duration: 0.3, curve: .spring))
            //         resetScrollingOffsetWithItemTransition = true
            //     }
            //
            // and `resetScrollingOffsetWithItemTransition` is what puts the offset on the new
            // central item AT ONCE (`:5240`), unanimated, inside their `ignoreScrolling` fence —
            // after which the one layout pass springs every view from where it was to where that
            // offset puts it. The offset never travels; the VIEWS do. `navigate(to:animated:)` is
            // that pair, and it always was — what was missing is the waiting.
            //
            // ⚠️ AND NOTHING ELSE MAY MOVE THE ROW WHILE THIS IS PENDING. The tap has already told
            // the outside world, so `activeIndex` is ALREADY the tapped story; letting the branch
            // below see it would seat the row immediately and put back the exact window this
            // exists to close.
            if liveStoryId == pending, let i = stories.firstIndex(where: { $0.id == pending }) {
                animateNextStoryId = nil
                // ⚠️ THE SHEET'S PAN CONTRIBUTION IS DROPPED HERE, IN THIS BLOCK, AND THAT IS WHAT
                // MAKES A SHEET PAGE AND A TAP THE SAME MOVEMENT.
                //
                // Theirs sets `viewListPanState = nil` inside the `animateNextNavigationId` block
                // (`:2751`), one statement above `resetScrollingOffsetWithItemTransition = true`.
                // So the fraction and the offset become their new values in the SAME update, and the
                // 0.3s spring that pass installs is the only animation any of these views get.
                //
                // On the tap path this is already zero and the line changes nothing, which is the
                // point: one path, and the sheet's page stops being a special case with a spring of
                // its own. Before `navigate`, because `navigate` lays out.
                pageDrag = 0
                navigate(to: i, animated: true)
                seatedByTap = true
            } else if !stories.contains(where: { $0.id == pending }) {
                // The story went away before it could arrive — deleted under the sheet. Waiting for
                // it forever would leave the row unable to accept any jump for the rest of the
                // sitting, which is a worse failure than a missed animation. The drag goes with the
                // flag: a cleared wait with a live page-drag leaves the row parked off centre with
                // nothing left coming to move it.
                animateNextStoryId = nil
                if pageDrag != 0 {
                    pageDrag = 0
                    updateScrolling(settle: .commit)
                }
            }
            // ⚠️ AND THE THIRD CASE IS DELIBERATELY NOT HANDLED HERE: a story this row HAS that the
            // library's own bucket does not, so the jump is refused and `liveStoryId` never becomes
            // `pending`. It cannot strand the row, and that is worth writing down because the
            // eager anchor write used to hide it: `handleTap` overwrites this flag unconditionally,
            // so the next tap on any other card replaces the request and moves, and a finger on the
            // row clears it outright. What is left is that the refused card itself does nothing when
            // tapped again — which is honest, because there is no picture for the viewer to show.
        }
        // ⚠️ THE WAIT BLOCKS THE JUMP, NOT THE LAYOUT. A pending tap must not swallow an ordinary
        // relayout — a story arriving, a count landing — or the row would sit frozen for as long as
        // the navigation takes. It blocks exactly one thing: somebody else seating the row.
        if seatedByTap {
            // `navigate` has already laid out, with the animation. Nothing further.
        } else if animateNextStoryId == nil, let activeIndex, activeIndex != reportedIndex,
                  activeIndex != centredIndex,
                  stories.indices.contains(activeIndex), rowIsStill {
            navigate(to: activeIndex, animated: true)
        } else if storiesChanged || countsChanged || geometryChanged || liveChanged {
            // ⚠️ ONLY WHEN SOMETHING THIS METHOD OWNS ACTUALLY MOVED, AND THAT GUARD IS LOAD-BEARING
            // RATHER THAN THRIFT.
            //
            // The page-drag is `@Published`, so the row's SwiftUI view is re-evaluated on every frame
            // of a sheet throw and this method runs on every one of them. An unconditional
            // `updateScrolling()` here was a SECOND layout pass per frame — and worse, an UNANIMATED
            // one running immediately after `setPageDrag` had started the completion spring, writing
            // the same values hard on top of it. The drag's own path (`setPageDrag`) is what lays the
            // row out while a drag is happening; this branch is for everything else.
            //
            // ⚠️ AND IT JOINS A SETTLE RATHER THAN ENDING ONE. See `isSettling`: at a sheet-page
            // commit this branch runs one turn after the spring started, because the live story's id
            // changed, and an unanimated pass here writes the destination hard over it.
            //
            // ⚠️ BUT NEVER WHEN THE PULL ITSELF HAS MOVED, AND THAT EXCEPTION IS THE OWNER'S
            // 2026-08-13 REPORT: the sheet is half open and the row has not got there, the corners
            // arrive late, and the story is still shrinking after the sheet has finished.
            //
            // `isSettling` is a 0.3s WINDOW, not a single pass. Opening the sheet sets `sheetStoryId`,
            // which lands a `.commit` — and for the next 300ms every pass through here animated,
            // including every frame of the pull. So each frame started a fresh 0.3s spring toward
            // that frame's target while the finger had already moved on: the row chasing the sheet
            // by a third of a second, and the corner radius, which is written in the same block,
            // arriving with it.
            //
            // Theirs cannot do this. `animateNextNavigationId` upgrades the transition on the ONE
            // pass where the tapped item's model arrives (`:2750`) and is cleared in the same
            // statement; every other pass, including all of a pan's, is `.immediate`. A pass caused
            // by the finger is immediate, full stop — a settle can only ever own a pass the finger
            // did not cause.
            let pulled = geometryChanged
            updateScrolling(settle: (isSettling && !pulled) ? .commit : nil)
        }
    }

    /// HAS THIS ROW EVER BEEN OPEN? A row that has only ever been at zero has not collapsed, it has
    /// not STARTED — and only a row that started may put the live story back to full screen. See the
    /// note in `placeLiveStory`.
    private var everRaised = false

    /// Their `scroller.isScrollEnabled = itemLayout.contentScaleFraction >= 1.0 - 0.0001`: the row
    /// is only scrollable once it has finished becoming a row.
    private func syncScrollEnabled() {
        let enabled = geometry.fraction >= 1.0 - 0.0001
        guard scroller.isScrollEnabled != enabled else { return }
        // ⚠️ A ROW SHUT DOWN MID-FLIGHT STILL OWES ITS SETTLE, AND THAT DEBT WAS BEING WRITTEN OFF.
        //
        // Disabling a scroll view that is decelerating stops it dead and UIKit delivers NO
        // `didEndDecelerating` for it. So a flick followed straight away by a pull on the sheet ended
        // the row's movement through a door that reports nothing — and since the pager jump was
        // deferred to the settle, the settle is now the ONLY thing that posts it for a flick. The
        // full-screen story was left on the card the flick started from while the row showed the one
        // it landed on, for as long as the sheet stayed open. It corrected itself at the close, which
        // is why it reads as "the thumbnail is showing the wrong story" rather than as a stuck story.
        //
        // Theirs cannot have this: `scrollViewDidScroll` navigates on the rounded index as the finger
        // moves, so there is never a report owed at the end. Ours defers because our navigation
        // redraws the row, so the deferral has to be honoured on every way out — this was the fourth
        // way out, and the one nothing was watching.
        let interrupted = !enabled && isRowMoving
        scroller.isScrollEnabled = enabled
        guard interrupted, geometry.fullDist > 0.5 else { return }
        isSnapping = false
        let i = centredIndex
        guard stories.indices.contains(i) else { return }
        // The crossings that happened before the fraction dropped were reported; the rest of the
        // deceleration was not. Say where it actually stopped before saying that it stopped.
        if i != reportedIndex {
            reportedIndex = i
            onIndexChanged(i)
        }
        // ⚠️ AND SEAT IT ON THE GRID. A halted scroller keeps whatever offset it froze at, which is
        // between two cards; nothing snaps it, because every snap path hangs off a delegate callback
        // that this shutdown skipped. Let the sheet come back up and the row would sit off-centre for
        // the rest of the sitting.
        navigate(to: i, animated: false)
        // ⚠️ CALLED DIRECTLY, NOT THROUGH `reportScrollSettled`, AND DELIBERATELY. That one refuses to
        // report below full fraction — right for every other caller, and exactly wrong here, because
        // the fraction dropping is the reason this movement ended.
        onIndexSettled(i)
        flushPendingFrames()
    }

    /// HOW FAR THE SHEET IS UP, once per frame of the pull, straight off the finger.
    ///
    /// ⚠️ IT COMES IN HERE RATHER THAN GOING TO THE MORPH, and that is the shape of the 2026-08-13
    /// ruling. The sheet's pan used to call the host's `placeLiveStory(fraction:)`, which posted a
    /// transform to `StoryCardMorph` — so the pull moved the live story and the row moved the cards,
    /// two writers on one layout. The pull now tells the ROW how far it has got, and the row lays
    /// out everything it owns, the live story included, in one pass.
    ///
    /// Ignored until the row has a real slot: before that the geometry is the placeholder the
    /// controller is built with, and placing a story against a 1×1 slot is worse than placing it a
    /// frame later. The SwiftUI path (`apply`) carries the same fraction and arrives with the slot.
    func setFraction(_ f: CGFloat) {
        guard f.isFinite, geometry.slotH > 1 else { return }
        let clamped = max(0, min(1, f))
        guard clamped != geometry.fraction else { return }
        geometry = geometry.withFraction(clamped)
        if clamped > 0.0001 { everRaised = true }
        syncScrollEnabled()
        updateScrolling()
    }

    /// The page-drag, once per frame of the sheet's sideways throw.
    ///
    /// ⚠️ RETURNING TO ZERO IS A COMPLETION, NOT A FRAME, and it is animated — their
    /// `isCompletingViewListPan`. Both ends of a sheet page drop the drag in ONE step: the commit
    /// because the offset moves a whole card at the same instant, and the abandon because the panel
    /// is springing home under its own curve. Drawn straight through, a step is a jump. Theirs
    /// answers it by animating the item POSITIONS rather than the number
    /// (`transition.attachAnimation(view: self, id: "isCompletingViewListPan")`, a 0.3s spring on
    /// the commit and 0.4s on the abandon), which is what this branch does.
    /// - Parameter settle: which curve a RETURN TO ZERO travels on. A drag released short of its
    ///   threshold is an abandon and takes their slower 0.4s; anything else is a commit at 0.3s.
    ///   Ignored on the frames of a live drag, which are the finger's and are never animated.
    func setPageDrag(_ v: CGFloat, settle: StoryRowSettle = .commit) {
        // ⚠️ A PAGE COMMIT WAITING FOR ITS STORY FREEZES THE DRAG WHERE THE FINGER LEFT IT.
        //
        // Theirs never touches `viewListPanState` at the release of a committed page: it survives
        // untouched until the new item's model arrives and is dropped inside the same block that
        // clears `animateNextNavigationId` (`:2750-2764`). Ours has to refuse the zero the box sends
        // itself at the commit, or the row would move on the release and again on the arrival.
        //
        // A NON-zero here is a new finger on the sheet, which supersedes the wait for the same
        // reason `scrollViewWillBeginDragging` does: something is driving the row directly now, and
        // a navigation that never lands must not be able to lock this out for the sitting.
        if animateNextStoryId != nil {
            if v == 0 { return }
            animateNextStoryId = nil
        }
        guard v.isFinite, v != pageDrag else { return }
        let completing = v == 0 && pageDrag != 0
        pageDrag = v
        updateScrolling(settle: completing ? settle : nil)
    }

    /// THE SHEET PAGED, AND THE ROW MOVES ONCE.
    ///
    /// ⚠️ IT IS ONE CALL BECAUSE IT WAS TWO MOVEMENTS. The host used to zero the page drag — one
    /// animated pass, springing the cards back to where the OLD story sat centred — and then, on the
    /// next SwiftUI turn, let the `activeIndex` branch re-seat the scroller: a second animated pass,
    /// to where the NEW story sits. Two springs half a frame apart over the same cards, which is the
    /// double movement at every sheet page.
    ///
    /// Theirs is one pass by construction: the pan's fraction and the central item change in the
    /// same update, so their layout runs once with one transition. This is that — the drag returns
    /// to zero and the scroller is re-seated before a single layout pass runs.
    func commitPage(toStoryId id: String) {
        // ⚠️ THIS IS THE TAP'S PATH NOW, AND NOT A SECOND ONE. Read off theirs, `viewListPanGesture`
        // `:1092-1112`: the committed branch does exactly two things —
        //
        //     self.animateNextNavigationId = nextItem.id
        //     component.navigate(.id(nextItem.id))
        //
        // It does NOT drop the pan fraction and it does NOT re-seat the scroller. Both of those
        // happen later, in the single update where the new item's model ARRIVES (`:2750-2764`), and
        // that block is shared with the tap: same flag, same 0.3s spring, same
        // `resetScrollingOffsetWithItemTransition`. One page swipe, ONE animated pass.
        //
        // ⚠️ OURS WAS DOING AT THE RELEASE WHAT THEIRS DOES AT THE ARRIVAL, AND THAT IS THE WHOLE OF
        // HIS "the thumbnail coming into the centre arrives enormous, from the side, at the wrong
        // scale". `pageDrag = 0` plus `navigate(animated: true)` here sprang every card once while
        // the live layer was still the story being LEFT; the arriving story's id then reached the row
        // a turn or two later and `liveChanged` sprang the same cards a second time, with the live
        // layer seeded into the middle of the first spring. Two 0.3s property animators over one set
        // of views, and a hand-over between them — which is why the card can render at a size neither
        // end of either animation ever asked for, and why the tap, which waits, has never done it.
        //
        // The row now waits for the story exactly as it waits for a tapped one. `apply`'s pending
        // block is where the drag is dropped and the offset re-seated, in that order, before a single
        // layout pass runs.
        guard stories.contains(where: { $0.id == id }) else {
            // Not in this row at all: there is no arrival to wait for, so the drag cannot be left
            // holding the row off centre.
            pageDrag = 0
            updateScrolling(settle: .commit)
            return
        }
        animateNextStoryId = id
    }

    /// Put the row on this story. `animated` runs their 0.3s spring over the layout while the offset
    /// itself moves immediately, which is what keeps the cards and the live story on one clock.
    func navigate(to index: Int, animated: Bool) {
        guard stories.indices.contains(index), geometry.fullDist > 0.5 else { return }
        // An unanimated `setContentOffset` cancels a running snap WITHOUT delivering
        // `didEndScrollingAnimation`, so the flag has to come down here or it would never come down
        // at all — and a stuck `isSnapping` means the row ignores every outside jump for the rest of
        // the sitting. A tap can reach this while a snap is in flight.
        isSnapping = false
        ignoreScrolling = true
        scroller.setContentOffset(CGPoint(x: CGFloat(index) * geometry.fullDist, y: 0), animated: false)
        ignoreScrolling = false
        reportedIndex = index
        updateScrolling(settle: animated ? .commit : nil)
    }

    /// WITH THE SHEET DOWN, THE SCROLLER IS NOT THE TRUTH — THE CENTRAL ITEM IS. Theirs, at `:5233`:
    ///
    ///     if itemLayout.contentScaleFraction <= 0.0001 {
    ///         if abs(self.scroller.contentOffset.x - centralX) > CGFloat.ulpOfOne {
    ///             self.scroller.contentOffset = CGPoint(x: centralX, y: 0.0)
    ///         }
    ///     }
    ///
    /// ⚠️ AND IT IS ALSO HOW THE ROW SEEDS ITSELF, which is why it is not a nicety. The row is
    /// mounted at fraction 0 — the very bottom of the pull — and the scroller starts at offset zero,
    /// which means "the first story". Opening the sheet from story three and letting the scroller
    /// keep that zero is the same class of bug as the row position defaulting to 0 was: an answer
    /// about the first story, given for every story. Pinning here means the row is on the right card
    /// before the pull has moved a pixel, without anybody having to remember to seed it.
    ///
    /// The layout does not shift when this runs: at fraction 0 `rowPosition` is the central index
    /// whatever the scroller says. What it buys is that the moment the fraction rises above zero and
    /// the blend starts reading the scroller, the scroller already agrees.
    private func pinToCentralWhileCollapsed() {
        guard geometry.fraction <= 0.0001, geometry.fullDist > 0.5, !stories.isEmpty else { return }
        guard !scroller.isTracking, !scroller.isDragging, !scroller.isDecelerating else { return }
        let centralX = CGFloat(centralIndex) * geometry.fullDist
        guard abs(scroller.contentOffset.x - centralX) > .ulpOfOne else { return }
        ignoreScrolling = true
        scroller.contentOffset = CGPoint(x: centralX, y: 0)
        ignoreScrolling = false
        reportedIndex = centralIndex
    }

    private func syncContentSize() {
        guard geometry.fullDist > 0.5, view.bounds.width > 0 else { return }
        let want = CGSize(width: CGFloat(max(0, stories.count - 1)) * geometry.fullDist + view.bounds.width,
                          height: view.bounds.height)
        if abs(scroller.contentSize.width - want.width) > 0.5
            || abs(scroller.contentSize.height - want.height) > 0.5 {
            scroller.contentSize = want
        }
    }

    // MARK: THE LAYOUT — their `updateScrolling`

    /// EVERY CARD'S POSITION, SCALE AND DIM, WRITTEN ONTO VIEWS THAT ALREADY EXIST.
    ///
    /// This is their `updateScrolling`, and the shape is theirs line for line: derive where the row
    /// is sitting, walk every story, work out how far from the centre it is in card units, cull the
    /// ones outside the window, and set three properties on the rest.
    /// ⚠️ A SETTLE IS RUNNING AND A RELAYOUT ARRIVING INSIDE IT MUST JOIN IT, NOT SLAM IT.
    ///
    /// The commit of a sheet page does two things in two turns: the drag springs out at once, and
    /// then SwiftUI re-renders with the new story, which reaches `apply` as `liveChanged` and used
    /// to run an UNANIMATED `updateScrolling()` — writing the destination hard over the spring that
    /// had just started. The cards therefore jumped to their new seats while the viewers panel slid,
    /// which is "the incoming card appears before the outgoing one has left". The file already
    /// warned about this shape for the page-drag frames; the id changing was the case it missed.
    ///
    /// `.beginFromCurrentState` is already on the animation, so re-animating mid-flight resumes from
    /// what is on screen rather than restarting.
    private var isSettling = false
    private var settleCycle = 0

    private func beginSettle(_ settle: StoryRowSettle) {
        settleCycle &+= 1
        let cycle = settleCycle
        isSettling = true
        // Cleared by the clock rather than by an animation completion: the animation is per ITEM and
        // per pass, so there is no single completion to hang this on, and a completion that fires
        // for an interrupted animation would clear it early.
        DispatchQueue.main.asyncAfter(deadline: .now() + settle.duration) { [weak self] in
            guard let self, self.settleCycle == cycle else { return }
            self.isSettling = false
        }
    }

    private func updateScrolling(settle: StoryRowSettle? = nil) {
        if let settle { beginSettle(settle) }
        // ⚠️ THE EARLY RETURN STILL HAS TO PLACE THE LIVE STORY, AND MISSING THAT WOULD HAVE PUT
        // BACK A SCREENSHOT THIS FILE HAS SEEN TWICE.
        //
        // While the placement lived on the host it ran on every frame of a pull whatever the row was
        // doing. It lives here now, so an early return is not "the row has nothing to lay out" any
        // more — it is "the story does not get shrunk", and a story that ignores the sheet rising
        // over it is the full-size-behind-the-sheet picture. Both conditions are real and both are
        // brief: no stories yet on a first open, no bounds before the first layout pass.
        guard view.bounds.width > 0, !stories.isEmpty else {
            placeLiveStoryWithoutARow()
            return
        }
        pinToCentralWhileCollapsed()
        let central = centralIndex
        let rowPos = geometry.rowPosition(scroll: scroll, centralIndex: central, pageDrag: pageDrag)
        let containerW = view.bounds.width
        let screenW = UIScreen.main.bounds.width
        // EVERY PLACEMENT IS COMPUTED IN WINDOW COORDINATES, and that is not bookkeeping.
        //
        // The cards used to be positioned in the row's own coordinates while the live story was
        // positioned in the screen's, which meant two of the numbers that had to agree were not even
        // measured against the same origin — they agreed only because the row happens to span the
        // full width with its centre line on the screen's. One coordinate space removes the
        // coincidence: the cards convert on the way out, and the live story, which is not in this
        // hierarchy at all, needs no conversion.
        let midX = view.convert(CGPoint(x: view.bounds.midX, y: 0), to: nil).x
        let rest = restContentWindowRect(midX: midX)

        // ⚠️ READ ONCE, BEFORE THE LOOP. `placeLiveStory` rewrites `lastLiveDim`, and on a backward
        // move the arriving story is laid out BEFORE the leaving one — so a handover reading the
        // property directly would be handed the value this same pass had just written for the other
        // card. The pass's question is "what was the live card wearing when this pass began".
        let previousLiveDim = lastLiveDim
        var valid = Set<String>()
        var trulyValid = Set<String>()
        for (i, story) in stories.enumerated() {
            let cf = geometry.combinedFraction(index: i, rowPosition: rowPos)
            // THEIR VISIBILITY WINDOW (`:1541-1546`), measured on the LOGICAL distances rather than
            // the scaled ones — the same split they keep everywhere: logical for arithmetic, scaled
            // for anything that positions a pixel.
            // ⚠️ A CARD THAT IS LEAVING IS KEPT UNTIL IT HAS FINISHED LEAVING — their `validIds` vs
            // `trulyValidIds` (`:1553-1575`), which we had the first half of and not the second:
            //
            //     if !itemVisible {
            //         if transition.animation.isImmediate { continue }
            //         else if self.visibleItems[item.id] == nil { continue }
            //         else { reevaluateVisibilityOnCompletion = true }
            //     }
            //
            // Ours dropped every invisible card on every pass, animated or not. On a finger that is
            // right and it is what they do too. On an ANIMATED pass it is not: the card is mid-spring
            // toward the place it is going, and removing it there makes it vanish instead of glide.
            // That is a card popping out of existence during a tap's settle or a sheet page.
            //
            // Three cases, theirs exactly: no animation → drop it now; never existed → do not build
            // one just to animate it away; exists and we are animating → keep it, lay it out, and let
            // the completion below decide.
            let visible = geometry.isVisible(combinedFraction: cf, containerWidth: containerW)
            var leaving = false
            if visible {
                trulyValid.insert(story.id)
            } else {
                if settle == nil { continue }
                guard items[story.id] != nil else { continue }
                leaving = true
            }
            valid.insert(story.id)

            // THE ONE PLACEMENT, FOR THIS STORY, WHATEVER DRAWS IT. See `StoryRowGeometry.placement`.
            let p = geometry.placement(combinedFraction: cf, rest: rest, containerMidX: midX)
            let isLive = story.id == liveStoryId

            // ⚠️ A CARD BORN THIS PASS IS PLACED WITHOUT THE ANIMATION. A new item view starts at
            // the origin with an identity transform, so animating its first placement would slide it
            // in from the top-left corner of the row — which is exactly what a card entering the
            // visibility window during a sheet page commit would have done.
            let existing = items[story.id]
            let item = existing ?? addItem(story)
            let centre = view.convert(p.center, from: nil)
            // ⚠️ THE SCALE IS READ OFF THE PLACEMENT RATHER THAN ASKED FOR SEPARATELY, so a card and
            // the live story cannot be told two different sizes. The item's BOUNDS stay the slot's,
            // because the picture inside is laid out at the slot's shape and a bounds change would
            // re-run that layout; the transform is what makes it render at `p.size`.
            //
            // ⚠️ "THE FRACTION IS EXACTLY 1 WHENEVER THE ROW IS VISIBLE" WAS TRUE AND IS NOT ANY
            // MORE. The pull runs to the end of the sheet's travel now instead of finishing at 0.9,
            // so the row fades in over the last of the card's motion and these cards are drawn at
            // fractions a little under 1.
            //
            // That is safe for exactly one reason, and it is worth stating because it is the whole
            // reason the slot is built from the story's own aspect: the placement interpolates
            // between two rectangles OF THE SAME SHAPE, so `p.size` keeps that shape at every
            // fraction. A card's bounds are the slot and this transform is uniform, taken from the
            // width alone — so it renders `p.size` exactly. Were the two ends different shapes, the
            // rendered height would be one the placement never asked for, and the tint, which is
            // FRAMED at `p.size` rather than transformed, would overhang the card it is dimming.
            let scale = p.size.width / max(1, geometry.slotW)
            // ⛔ ONLY THE CENTRED CARD'S COUNT IS VISIBLE, AND IT FADES BY DISTANCE RATHER THAN BY A
            // THRESHOLD (owner 2026-08-22, confirmed in as many words: mid-swipe the outgoing numbers
            // fade out while the incoming fade in, both partly there for that moment).
            //
            // Measured in CARD STEPS off the row's own `fullDist` — the distance one card travels to
            // become the next — so it is the row's real geometry rather than a fraction of the screen
            // that happens to look right. One step out is zero, which is why a resting row shows
            // exactly one set of numbers and reads as a single section.
            //
            // ⚠️ NOT `centredIndex`. That is a decision made at the half-card and it can only ever
            // produce a swap. This is the card's own position, so the numbers are wherever the card
            // is, at every frame of the gesture, which is the whole of what he asked for.
            let step = max(1, geometry.fullDist)
            let fromCentre = abs(p.center.x - screenW / 2) / step
            // ⛔ OVER THREE STEPS, NOT ONE (owner 2026-08-22: "top preview left and right show View
            // and love, now I am not seeing").
            //
            // Falling to zero across a single step meant a resting neighbour — which sits exactly one
            // step out — was fully invisible. That matched the letter of his written spec (side cards
            // clean) but not what he wanted once he saw it: the counts are meant to be THERE on the
            // cards either side, quieter, so the eye can see them arriving.
            //
            // The divisor is the reference's own, read from its source earlier: its footer alpha
            // collapses to `1 - min(1, distanceToCentre / 3)`, which puts the neighbour at about two
            // thirds and the next at a third. The centred card is still the only one at full
            // strength, so there is still exactly one prominent set of numbers.
            let countAlpha = max(0, min(1, 1 - fromCentre / 3))
            // The card's own size. Set OUTSIDE the animation and only when it differs: a bounds
            // change re-lays-out the hosted content, and it changes for one reason (the sheet's slot
            // was re-measured) which is not something a scroll ever does.
            let size = CGSize(width: geometry.slotW, height: geometry.slotH)
            if item.bounds.size != size {
                item.bounds = CGRect(origin: .zero, size: size)
            }
            let tint = tints[story.id]
            // Decided BEFORE the closure is built, because the closure reads it: a card born this
            // pass is placed without the animation (see the note above), so "is this pass animated"
            // is per item, not per pass.
            let willAnimate = settle != nil && existing != nil
            // ⚠️ WHOSE BLACK LAYER IS THIS CARD'S BRIGHTNESS, AND IS THIS THE PASS IT CHANGES HANDS.
            //
            // Read `item.isLive` while it is still the PREVIOUS answer — `setLive` is called further
            // down, after the seed, and the seed needs the old tint to read its leaving dim off.
            let tintOpacity: Float = isLive ? 0 : Float(p.dim)
            let handover = item.isLive != isLive
            let write = {
                item.center = centre
                item.transform = CGAffineTransform(scaleX: scale, y: scale)
                // Inside `write`, so it rides the same animation the card does on a settle and is
                // written raw on every frame of a drag — exactly like the card's own position.
                item.count.alpha = countAlpha
                if let tint {
                    // ⚠️ THE SAME BOUNDS, THE SAME POSITION AND THE SAME SCALE AS THE CARD — NOT A
                    // RECTANGLE WORKED OUT SEPARATELY. This is the whole of the 2026-08-13 seam fix.
                    //
                    // It used to be `tint.frame = CGRect(centre ± p.size / 2)`: a second, independent
                    // calculation of where the card had ended up, standing beside the card's own
                    // `bounds` + `transform`. Two routes to one rectangle, and the owner photographed
                    // them disagreeing — a hard vertical edge down the middle of the two outermost
                    // cards, the outward half shaded and the inward half not, because the tint was
                    // arriving at a different width from the card it was supposed to be covering.
                    //
                    // Theirs never computes it (`:1719-1741`). The tint is handed the identical
                    // `itemPositionX`, the identical `contentFrame.size` and the identical
                    // `transform` variable the card is given seven lines earlier:
                    //
                    //     itemTransition.setPosition(layer: contentTintLayer, position: ...)
                    //     itemTransition.setBounds(layer: contentTintLayer, bounds: contentFrame.size)
                    //     itemTransition.setTransform(layer: contentTintLayer, transform: transform)
                    //
                    // so it does not match the card, it IS the card's geometry with a black fill. A
                    // tint cannot be the wrong size for its card if it was never told a size of its
                    // own. `bounds` and `position` rather than `frame`, because `frame` is undefined
                    // on a layer carrying a transform.
                    tint.bounds = CGRect(origin: .zero, size: size)
                    tint.position = centre
                    tint.transform = CATransform3DMakeScale(scale, scale, 1)
                    // Their `12.0 * (1.0 / itemScale)` at `:1736`: the radius lives in the layer's own
                    // untransformed space now, so it has to be pre-divided by the scale it is about to
                    // be multiplied by. `p.cornerRadius` is already the number this is meant to READ
                    // as on screen, so dividing by the scale lands exactly on it at every fraction.
                    tint.cornerRadius = p.cornerRadius / max(scale, 0.0001)
                    // ⚠️ THE LIVE CARD IS DIMMED BY THE MORPH, NOT BY THIS LAYER, AND WRITING BOTH IS
                    // HIS "the thumbnails on the left go far too dark while my finger is still down".
                    //
                    // Two tints were being drawn over one card. This one — `tints[storyId]`, a sibling
                    // in the ROW's view — and `StoryCardMorph.contentTint`, a sublayer of the live
                    // card itself. Both black, both handed the same `p.dim`, and black over black
                    // does not average, it COMPOUNDS: `1 - (1 - d)²`. A card one slot out asks for
                    // 0.333 and renders 0.556; two slots out asks for 0.667 and renders 0.889.
                    //
                    // ⚠️ AND IT WAS INVISIBLE FOR FOUR DAYS BECAUSE THE LIVE CARD USED TO SIT AT THE
                    // CENTRE, WHERE `d` IS 0 AND TWICE NOTHING IS STILL NOTHING. The morph's tint was
                    // added while the live story had no item in this row at all (it was pinned at the
                    // slot centre by the old architecture), so at the time it really was the one card
                    // nothing dimmed. The one-item ruling then gave that story a real item here — and
                    // a real tint with it — and nobody could see the second one, because the only
                    // place the live card ever went was the middle.
                    //
                    // What made it visible is the deferred pager jump: the live story now keeps its
                    // id for the WHOLE swipe and only hands over at rest, so the doubly-dimmed card
                    // travels a full slot off centre in front of him and snaps back to the honest
                    // number the instant the settle moves the live layer on. That is the whole of his
                    // "as soon as I release my finger the brightness returns to normal" — nothing
                    // brightens at the release, the second tint simply stops having anywhere to show.
                    //
                    // The morph's is the one kept, because it is a sublayer of the card: it rides the
                    // card's own transform and its own crop mask, so it cannot be a frame or a pixel
                    // out of step with the thing it is darkening, and it still covers the live story
                    // in the states where this row has culled that story's item.
                    //
                    // On a handover pass this is still written, and it is still right: the unanimated
                    // seat below has already put the layer where the eye last saw it, so what this
                    // line does there is carry it to the destination with the movement — zero for the
                    // card taking the live layer on (which is where the seat already put it, so the
                    // animation is a no-op) and the honest cover-flow dim for the card giving it up.
                    tint.opacity = tintOpacity
                }
                // ⚠️ INSIDE THE SAME WRITE AS THE CARDS, AND ON THE ANIMATED PASS THAT IS THE POINT.
                //
                // The live story used to be placed at the END of this method, outside any animation
                // block, so a movement the row SPRINGS — the page-drag completion, a tap that
                // navigates — glided the cards to their new seats while the story arrived at its own
                // in one step. Position and scale disagreeing by exactly that spring is the shape he
                // photographed. Whatever clock the cards are on, this is on it.
                //
                // ⚠️ AND IT HAS TO BE TOLD, NOT JUST WRAPPED. Being inside `UIView.animate` is not
                // enough on its own: `applyCore` writes the card's transform inside a
                // `CATransaction` with actions DISABLED — right for a finger, and it beats the
                // enclosing animation — so the live story arrived in one step anyway. The flag is
                // what turns that transaction into the row's own curve for this pass.
                if isLive { self.placeLiveStory(p, settle: willAnimate ? settle : nil) }
            }
            // ⚠️ NO `zPosition` HERE ANY MORE, AND ITS REMOVAL IS THE WHOLE OF THE BRIGHTNESS FIX.
            //
            // `zPosition` is an implicitly animated CALayer property. Written per frame from outside
            // a disabled transaction, every write started a quarter-second animation on a number
            // that was changing again on the next frame — so what the compositor sorted by was a
            // lagging PRESENTATION value, not the one just written. That is survivable while layer
            // order only decides which of two cards is in front, because our cards never overlap.
            // It stopped being survivable the moment the dim became a tint layer, because then layer
            // order is the only thing making the dim visible at all: a tint whose presentation
            // zPosition is momentarily below its own card renders BEHIND it, and the card is
            // therefore FULLY BRIGHT until the animation catches up.
            //
            // The worst case is a card entering the window mid-swipe. Its tint is created this pass
            // with zPosition 0 and animates UP to its target over 0.25s, so for a quarter of a
            // second the incoming card has no dim at all and then snaps into it. That is his "the
            // card I am swiping toward becomes bright too early", and the flashing with it.
            //
            // ⚠️ THE REFERENCE APP DOES NOT SET `zPosition` ANYWHERE IN THIS FILE. Not once. Their
            // order is INSERTION order: `addSubview(contentContainerView)` immediately followed by
            // `layer.addSublayer(contentTintLayer)`, per item, so a tint is always directly above
            // the card it belongs to and can never be anywhere else. There is nothing to animate,
            // nothing to lag, and nothing to get wrong. `addItem` pairs them the same way.
            //
            // What we lose is the old `zIndex(2 - |cf|)`, the centre card drawn on top. That was
            // decorative rather than load-bearing — at any `|cf|` the centre distance is the sum of
            // the two half widths plus 12pt, so no two cards ever overlap — and theirs does not have
            // it either.
            // ⚠️ THE ARRIVING STORY HAS TO TRAVEL, AND THIS SEEDS THE JOURNEY IT WOULD OTHERWISE SKIP.
            //
            // The owner's tap report, and it is the last of that family. On the pass where a tap
            // lands, this item stops being an ordinary card and becomes the live one — and the live
            // layer is a SINGLE surface that is always wherever the central story is. It was already
            // at the centre, drawing the story we are leaving; the only thing that changed is the
            // picture inside it. So the incoming story did not move at all: it APPEARED at the
            // centre, full size, while the outgoing card was revealed underneath it and sprang away
            // sideways. Two stories in the middle for the length of the spring, one of them
            // teleported there. That is his screenshot, and his "it goes one way and comes back".
            //
            // Theirs has no such moment because every story owns its own view for the whole of its
            // life: on the commit pass A's view springs centre → side and B's view springs side →
            // centre, and nothing is revealed, hidden or swapped (`:1719-1741`, one `itemTransition`
            // over every item).
            //
            // We cannot give the live layer a second surface, but we can give it the journey. This
            // item's view is still standing exactly where the arriving story was drawn a moment ago
            // — that is the card the finger tapped — so the live layer is put THERE first, without
            // animation, and the animated write below then carries it to the centre. Same two
            // movements as theirs, from the same two starting points, in one spring.
            //
            // Only when it is BECOMING live. While it already is, its position is the pull's and
            // seeding would fight it.
            if willAnimate, isLive, !item.isLive {
                // ⚠️ THE PRESENTATION LAYER, NOT THE MODEL — AND THE DIFFERENCE IS THE WHOLE OF HIS
                // "the thumbnail coming into the centre appears extremely large" ON THE SHEET-PAGE
                // PATH.
                //
                // The point of this seed is to start the journey where the picture VISUALLY is. On
                // the tap path the row is at rest when the flip lands, so the model and the pixels
                // agree and reading `item.transform` was accidentally right. On the sheet's page
                // path the flip lands INSIDE the commit's 0.3s settle — and an animation sets the
                // MODEL to its destination the moment it starts, so `transform.a` answered 1.0 (the
                // centre, full slot size) while the card on screen was still half-way out at side
                // scale. The seed then put the live layer at the centre, full size, unanimated, in
                // the middle of the flight: the enormous card arriving from the side in his
                // screenshot. Same seed, same arithmetic — fed a destination instead of a position.
                //
                // `presentation()` is the pixels' own answer and exists exactly while an animation
                // is in flight; at rest it is nil and the model is the truth, so the tap path is
                // unchanged by construction. The side test and the leaving dim read the same way,
                // for the same reason.
                let pres = item.layer.presentation()
                let wasScale = pres?.transform.m11 ?? item.transform.a
                if wasScale > 0.0001 {
                    // ⚠️ THE SEED IS BUILT BY `placement`, THE SAME FUNCTION EVERY OTHER CARD IS
                    // BUILT BY. MEASURED OFF HIS SCREEN RECORDING, FRAME BY FRAME:
                    //
                    //   frames 1-3   card 50pt wide   (the side size, correct)
                    //   frame  4     card 134pt wide  (ONE frame, wider than the centre card)
                    //   frames 5-20  134 → 84         (the settle, correct)
                    //
                    // 84 is the centre size, so the seed put it at something the row's own
                    // arithmetic never produces — and the spring then spent its whole length
                    // undoing that. THAT is "the card comes late, after the brightness": the card
                    // was not travelling from the thumbnail, it was travelling back from a size it
                    // should never have had, while the tint — which IS built by `placement` — went
                    // straight where it belonged.
                    //
                    // The size was the mistake. `slotW * wasScale` is a plausible-looking number and
                    // it is not the one `placement` computes: that lerps between the RESTING
                    // rectangle and the target by the sheet's fraction, so anything worked out from
                    // the slot alone lands somewhere else entirely. Reading the fraction back out of
                    // the scale (`itemScale` is a straight lerp, so it inverts exactly) and asking
                    // `placement` is what makes the seed and its destination two points on one
                    // journey rather than two different calculations.
                    let span = max(0.0001, 1 - geometry.sideRelScale)
                    let mag = min(1, max(0, (1 - wasScale) / span))
                    let visualCenterX = pres?.position.x ?? item.center.x
                    let cfBefore = visualCenterX < view.bounds.midX ? -mag : mag
                    let from = geometry.placement(combinedFraction: cfBefore,
                                                  rest: rest, containerMidX: midX)
                    // ⚠️ THE DIM IS SEEDED AT THE VALUE IT IS LEAVING, NOT THE ONE IT IS GOING TO,
                    // AND THAT IS HIS "the brightness does not follow the card when I tap".
                    //
                    // Everything else in this seed is the card's OLD state — its old centre, its old
                    // size — because the point of the seed is to start the journey where the picture
                    // already is. The dim was the one number taken from the DESTINATION, so the
                    // unanimated seed wrote the arriving brightness onto the departing position: the
                    // card went dark (or bright) on the spot and only then travelled. The swipe
                    // never showed it because a swipe has no seed; it is the tap's alone, which is
                    // exactly the difference he reported.
                    //
                    // The tint layer this item is already wearing knows what it is leaving, so it is
                    // asked rather than recomputed — and asked for its PRESENTATION, the same rule
                    // as the scale above: a tint mid-animation has already written its destination
                    // into the model.
                    let leavingDim = tints[story.id]
                        .map { CGFloat(($0.presentation() ?? $0).opacity) } ?? from.dim
                    self.placeLiveStory(
                        StoryRowPlacement(center: from.center,
                                          size: from.size,
                                          cornerRadius: from.cornerRadius,
                                          dim: leavingDim),
                        settle: nil)
                }
            }
            // ⚠️ THE BRIGHTNESS CHANGES OWNER HERE, IN ONE UNANIMATED STEP, AND AFTER THE SEED.
            //
            // After, because the seed above reads this exact layer's presentation opacity to learn
            // what the arriving story is LEAVING — zero it first and the live layer would be seeded
            // bright and then darken on the spot, which is the 2026-08-16 "the brightness does not
            // follow the card" report arriving from the other side.
            //
            // Unanimated, and seated at what the eye is ALREADY reading rather than at where this
            // card is going: the one becoming live gives its tint up to zero at the same instant the
            // morph is seeded with what that tint was showing, and the one giving the live layer up
            // takes back `previousLiveDim`, which is the number the morph had over it on the pass
            // that just ended. Either way the black over that rectangle does not change at the swap;
            // the settle then carries both to their destinations on the movement's own curve.
            //
            // On a curve instead, the two owners overlap for 0.3s and compound through the middle of
            // it — the same doubling this whole note is about, just shorter and harder to name.
            if handover, let tint {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                tint.opacity = isLive ? 0 : Float(previousLiveDim)
                CATransaction.commit()
            }
            item.setLive(isLive)
            item.updateMedia(story: story, slotW: geometry.slotW, slotH: geometry.slotH,
                             shot: cardShot(for: story, current: item))
            if willAnimate {
                // Their `.curve(duration: 0.3, curve: .spring)` for a movement that did not come from
                // the finger. `run` is the one statement of that spring, and it keeps what the old
                // options bought: an interrupting swipe is still heard during it, and an interrupting
                // write starts where this one got to.
                let curve = settle ?? .commit
                // Their `reevaluateVisibilityOnCompletion`, hung on the same position animation
                // (`:1701-1712`): when the glide is over, if this card is STILL not one the row can
                // see, it goes. Re-asked rather than remembered, because a later pass may well have
                // brought it back — which is why theirs tests `trulyValidIds` in the completion and
                // not a boolean captured when the animation started.
                curve.run(write, completion: leaving ? { [weak self] _ in
                    guard let self, !self.trulyValidIds.contains(story.id),
                          let it = self.items[story.id] else { return }
                    self.removeItem(story.id, it)
                } : nil)
            } else {
                // A bare `CALayer`'s frame, cornerRadius and opacity are all implicitly animated, so
                // outside a deliberate animation they must be written with actions off or the tint
                // chases the card it is supposed to be sitting on by a quarter second.
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                write()
                CATransaction.commit()
            }
        }

        // Published BEFORE the removals, because the completions above read it — theirs assigns
        // `self.trulyValidIds` at the end of its own pass for the same reason.
        trulyValidIds = trulyValid
        // Anything the row does not even hold a place for goes now. A card that is only LEAVING is
        // in `valid` and is not touched here; its own animation's completion removes it.
        for (id, item) in items where !valid.contains(id) {
            removeItem(id, item)
        }
        // THE LIVE STORY WHEN ITS OWN ITEM IS NOT IN THE ROW. Two ways that happens: the story was
        // deleted under the sheet, or the row has not been handed it yet. Either way the pull is
        // still shrinking something, and leaving it wearing the last transform it was given is the
        // "story sitting at full size behind the sheet" screenshot.
        //
        // ⚠️ "NOT IN THE ROW" IS NOT THE SAME QUESTION AS "NOT IN THE WINDOW", AND ANSWERING THE
        // SECOND ONE IS HIS 2026-08-14 "the top preview thumbnail became big when it is coming to
        // the centre".
        //
        // `valid` is this pass's VISIBILITY window. A sideways sheet swipe moves the row, so the
        // live story's own card can fall out of that window for a few frames while still being a
        // perfectly real story at a perfectly known position — and this then placed it at
        // `combinedFraction: 0`, the CENTRE, at the centre's full size, unanimated, in the middle of
        // the drag. That is both halves of his screenshot: a card at centre size sitting where no
        // card belongs, and a second copy of the same story at its true position, because the item
        // it was drawn from is elsewhere.
        //
        // The story's own fraction is known whenever the story is known — the row has its index —
        // so it is used, culled or not. The centre is kept for the one case it was written for: a
        // live id that is not in this row's list at all.
        if !valid.contains(liveStoryId) {
            let cf = stories.firstIndex(where: { $0.id == liveStoryId })
                .map { geometry.combinedFraction(index: $0, rowPosition: rowPos) } ?? 0
            placeLiveStory(geometry.placement(combinedFraction: cf, rest: rest, containerMidX: midX))
        }

        // ⚠️ AND THE SAME SET DECIDES WHICH STORIES KEEP THEIR PLAYER. One loop, one answer, which is
        // their shape: `validIds` is built by the layout pass and is what the item views are kept or
        // dropped by. The library used to hold a SECOND, narrower window of its own (centre ±1) and
        // it won, so a story still being drawn two cards out had its player torn down — watch A,
        // open the sheet, swipe to B then C, and coming back to A found nothing and started a new
        // player at zero. See `StoryVideoHost.previewWindow`.
        StoryVideoHost.previewWindow(valid)
        // ⚠️ AND THE SAME LOOP SAYS WHICH ONE MAY PLAY. Theirs pauses every item whose index is not
        // the central one, inside this loop, on every pass — see `StoryVideoHost.central`. Told only
        // when the answer changes, because the answer is a string and the alternative is walking a
        // weak table on every frame of a drag for a value that moves once a card.
        if lastCentralTold != liveStoryId {
            lastCentralTold = liveStoryId
            StoryVideoHost.central(liveStoryId)
        }
    }

    /// WHAT AN ITEM IS AT FRACTION 0 — the story content's own rectangle, full screen, in window
    /// coordinates.
    ///
    /// Every item interpolates from this toward its card, so the live story's journey into the slot
    /// and its neighbours' are literally the same journey with a different `combinedFraction`. Asking
    /// the morph rather than deriving it is the same rule the slot follows: `contentRect` is the
    /// rectangle the crop will actually be taken against, and a second copy of it computed here is
    /// how the picture-jumping-inside-its-frame bug happened.
    ///
    /// Nil is normal before a pager has registered a card. The fallback is the slot itself, which
    /// makes the interpolation degenerate — rest and target are the same rectangle — so the row is
    /// exactly what it has always been at fraction 1, which is the only fraction it is visible at.
    private func restContentWindowRect(midX: CGFloat) -> CGRect {
        if let r = StoryCardMorph.shared.restContentWindowRect, r.width > 1, r.height > 1 {
            return r
        }
        // ⚠️ THE FALLBACK IS THE SLOT'S SHAPE AT FULL WIDTH, AND THE SHAPE IS THE LOAD-BEARING PART.
        //
        // `placement` lerps width and height independently from this rectangle to the slot. Two
        // rectangles of the SAME shape interpolate to that shape at every fraction; two of different
        // shapes do not, and the difference is what the card and the crop then disagree about. A
        // card's bounds are the slot and its transform is uniform from the width alone, so a lerped
        // rect whose aspect is walking renders a height the placement never asked for — the tint,
        // which is FRAMED at the placement's size, then overhangs it by that difference. Give the
        // journey the same shape at both ends and none of that can happen.
        //
        // It used to return the slot rect itself, which is the same shape but degenerate: rest and
        // target identical means a story drawn at card size while it is still meant to be full
        // screen. Full width at the slot's aspect is the same shape AND the right size.
        //
        // The Y is the screen's middle rather than the card's true centre, which is a few points
        // high. This runs only before any card has reported its metrics, and with the estimate now
        // matching the measurement that window is a frame or two on the first open of a process.
        let scr = UIScreen.main.bounds
        let w = scr.width
        let h = geometry.slotW > 1 ? w * (geometry.slotH / geometry.slotW) : geometry.slotH
        return CGRect(x: midX - w / 2, y: scr.midY - h / 2, width: w, height: h)
    }

    /// THE PULL IS RISING AND THERE IS NO ROW TO PUT THE STORY IN.
    ///
    /// Not an edge case to be tidy about: it is every first frame of a first open, before the
    /// stories have landed or the row has been laid out. The screen is measured directly here
    /// because the row's own bounds are exactly what is missing, and cf is 0 because with no row
    /// there is nothing for the story to be off-centre from.
    private func placeLiveStoryWithoutARow() {
        guard geometry.slotH > 1 else { return }
        let midX = UIScreen.main.bounds.midX
        placeLiveStory(geometry.placement(combinedFraction: 0,
                                          rest: restContentWindowRect(midX: midX),
                                          containerMidX: midX))
    }

    /// THE LIVE STORY, PLACED FROM THE SAME `StoryRowPlacement` AS EVERY CARD.
    ///
    /// This is the whole of what used to be `StoryRowGeometry.placeLiveStory` plus the host's
    /// `placeLiveStory(fraction:)` plus `publishRowPosition`: three call sites, two files and a
    /// division that existed to cancel a lerp on the far side. What is left is a hand-off — the row
    /// has already decided where this story goes, and this writes it.
    ///
    /// The row's own curve for a movement that did not come from a finger, in the form the morph
    /// takes it. ⚠️ BOTH NUMBERS COME OUT OF `StoryRowSettle` AND NEITHER IS WRITTEN HERE — the
    /// duration always did; the curve is the one that used to be stated twice, differently, and
    /// that was his 2026-08-14 report. Read the note on `timing`.
    static func settleAnimation(_ settle: StoryRowSettle) -> StoryCardMorph.Animation {
        StoryCardMorph.Animation(duration: settle.duration, timing: settle.timing)
    }

    private func placeLiveStory(_ p: StoryRowPlacement, settle: StoryRowSettle? = nil) {
        // A hero open or close owns the card outright, and it is the gesture that removes the screen.
        guard !StoryCardMorph.heroDismissActive, StoryCardMorph.shared.isAvailable else { return }
        // ⚠️ THE ROW OWNS THE PUT-BACK NOW, AND THAT IS A CHANGE OF OWNER RATHER THAN OF BEHAVIOUR.
        //
        // It used to be forbidden from driving the fraction to zero, because the HOST owned that
        // transition and two writers for "put the story back to full screen" is one too many. The
        // host does not write this at all any more, so the rule inverts: the row is the only writer,
        // and a collapse that ends at zero has to be passed through or the story is left card-sized
        // behind a sheet that has gone.
        guard geometry.fraction > 0.0001 else {
            // ⚠️ A PLACEHOLDER GEOMETRY IS NOT A COLLAPSE, AND TELLING THE TWO APART IS HIS "SWIPE
            // THE SHEET SIDEWAYS AND THE STORY GOES BIG".
            //
            // A controller is built with `StoryRowGeometry(slotW: 1, slotH: 1, …, fraction: 0)` and
            // holds it until the first `apply` arrives carrying the measured slot. So a row that
            // comes into existence during a sideways page drag answers "fraction 0" for its first
            // pass — which reads here as "the sheet has gone" and puts the story back to FULL
            // SCREEN, while the row beside it is still laying cards out at row scale. That is the
            // two sizes at once in his screenshot: a full-size story in the corner with small cards
            // drawn over it.
            //
            // `placeAtRest` is the whole screen, so it is the one decision in this file a 1×1
            // placeholder must never be allowed to make. The other two entry points already refuse
            // it — `setFraction` guards `slotH > 1` before it will even record a fraction, and
            // `placeLiveStoryWithoutARow` guards the same thing before it places anything — and
            // this was the only one that did not. It is their rule, applied where it was missing,
            // not a new one.
            //
            // A real collapse still passes through: the sheet cannot reach fraction 0 without the
            // row having been measured first, so the close is unaffected.
            guard geometry.slotH > 1 else { return }
            // ⚠️ AND A MEASURED SLOT IS NOT ENOUGH EITHER — HIS 2026-08-14 "ONLY WHEN I SWIPE THE
            // SHEET FAST", WITH THE STORY DRAWN THREE TIMES ITS SLOT.
            //
            // The guard above tells a 1×1 placeholder from a collapse. It cannot tell a row that has
            // been MEASURED but never RAISED from one — and a fast sideways swipe builds exactly
            // that: the incoming panel's row arrives already knowing the slot (the host measures it)
            // while the sheet's own fraction has not reached it yet. Its very first pass therefore
            // reads "measured, and at zero", which is the sentence "the sheet has gone", and it puts
            // the live story back to FULL SCREEN — over a row that is still laying its cards out at
            // row scale. That is his screenshot: one enormous card with the real one inside it.
            //
            // A row cannot collapse without having risen. `everRaised` is that in one word, and it
            // is the same shape of fix as every other one in this file: a zero that means "not yet"
            // must not be spent as a zero that means "finished".
            guard everRaised else { return }
            StoryCardMorph.shared.placeAtRest()
            return
        }
        // ⚠️ `p.dim` GOES WITH THE PLACEMENT NOW, AND IT IS THE SAME NUMBER EVERY OTHER CARD GETS.
        //
        // This card was the only one in the row nothing ever dimmed. The tints above are siblings in
        // THIS view; the live story is drawn by the morph in the presenter's hierarchy, so a tint
        // added here is not above it and cannot darken it — the morph's own note said the row would
        // cover this card "like every other one", which was true of every card except this one. His
        // 2026-08-13 video: the moving card at full brightness between two dimmed ones.
        //
        // One number, computed once by `StoryRowGeometry.placement` for every card including this,
        // and handed to whoever draws it. Nothing here works out a second dim of its own.
        // What the live card is wearing, for the pass that takes the live layer off it. See
        // `lastLiveDim`.
        lastLiveDim = p.dim
        StoryCardMorph.shared.place(contentCenter: p.center, contentSize: p.size,
                                    cornerRadius: p.cornerRadius, fraction: geometry.fraction,
                                    dim: p.dim,
                                    animated: settle.map { Self.settleAnimation($0) })
    }

    /// THE CARD FRAME FOR THIS CLIP, AND WHETHER THE ROW IS WILLING TO CHANGE IT YET.
    ///
    /// The lookup is the same one the card used to make in its own body; what is new is where it is
    /// made and when it is allowed to take effect. `StoryVideoFrames.card` answers nil until the
    /// frame has been generated off the main thread, so its answer changes at a moment nobody chose —
    /// and if that moment lands mid-swipe, a travelling thumbnail changes its picture.
    ///
    /// Theirs decides a cover when it lays an item out and holds it for that layout; a cover never
    /// changes during a transition. So while the row is moving, a card that already has a picture
    /// keeps it, and `frameArrived()` re-runs the pass once the row is still.
    private func cardShot(for story: Story, current: StoryRowItemView) -> UIImage? {
        guard story.isVideo, let u = URL(string: story.mediaUrl) else { return nil }
        let shot = StoryVideoFrames.card(u, storyId: story.id, width: geometry.slotW)
        if isRowMoving || isSettling, let held = current.appliedShot { return held }
        return shot
    }

    /// A frame finished generating. ONE sink for the whole row, not one observer per card.
    private func frameArrived() {
        guard !isRowMoving, !isSettling else { framesPending = true; return }
        framesPending = false
        updateScrolling()
    }

    /// Spend a frame that landed while the row was moving. Called from every place a movement ends.
    private func flushPendingFrames() {
        guard framesPending else { return }
        framesPending = false
        updateScrolling()
    }

    private func addItem(_ story: Story) -> StoryRowItemView {
        let media = StoryRowCardMedia(story: story,
                                      slotW: geometry.slotW,
                                      slotH: geometry.slotH,
                                      shot: story.isVideo ? URL(string: story.mediaUrl).flatMap {
                                          StoryVideoFrames.card($0, storyId: story.id, width: geometry.slotW)
                                      } : nil)
        let item = StoryRowItemView(storyId: story.id, media: media)
        addChild(item.host)
        view.addSubview(item)
        item.host.didMove(toParent: self)
        let c = counts[story.id]
        item.count.set(views: c?.views ?? 0, likes: c?.likes ?? 0, known: c != nil)
        items[story.id] = item
        // Their `contentTintLayer`, black at alpha 1 and revealed by its opacity — a sibling of the
        // card, added to the same container, so it can cover a card or the live story without
        // knowing which it is covering.
        let tint = CALayer()
        tint.backgroundColor = UIColor.black.cgColor
        tint.opacity = 0
        tint.cornerCurve = .continuous
        tint.isDoubleSided = false
        // ⚠️ INSERTED DIRECTLY ABOVE ITS OWN CARD, WHICH IS THE ONLY THING KEEPING IT IN FRONT.
        //
        // Theirs, per item, in this order and with no `zPosition` anywhere:
        //
        //     self.itemsContainerView.addSubview(visibleItem.contentContainerView)
        //     self.itemsContainerView.layer.addSublayer(visibleItem.contentTintLayer)
        //
        // Pairing the two at insertion makes "the tint is above its card" a structural fact rather
        // than a number that has to be re-asserted every frame — and a number written per frame is
        // a number being implicitly ANIMATED, which is what broke the dim. A later card's layer
        // lands after this pair and so sits above this tint; that is theirs too, and it is harmless
        // because no two cards ever overlap.
        view.layer.insertSublayer(tint, above: item.layer)
        tints[story.id] = tint
        return item
    }

    private func removeItem(_ id: String, _ item: StoryRowItemView) {
        item.host.willMove(toParent: nil)
        item.host.view.removeFromSuperview()
        item.host.removeFromParent()
        item.removeFromSuperview()
        items.removeValue(forKey: id)
        tints.removeValue(forKey: id)?.removeFromSuperlayer()
    }

    // MARK: Scroll delegate — theirs, method for method

    /// A finger cancels a snap animation, and UIKit does NOT deliver
    /// `didEndScrollingAnimation` for one it interrupted. Same reason as the clear in `navigate`.
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isSnapping = false
        // A FINGER SUPERSEDES A TAP THAT IS STILL WAITING. The row is about to be driven directly,
        // so seating it on a story tapped a moment ago would fight the drag — and this is also the
        // release valve for a navigation that never lands, which would otherwise leave the row
        // unable to accept any jump for the rest of the sitting.
        //
        // The sheet's page-drag comes down with it. It is frozen while a page commit waits for its
        // story (see `setPageDrag`), and a finger arriving in that window ends the wait — a drag
        // measured against a row still displaced by somebody else's gesture is measured against the
        // wrong place.
        animateNextStoryId = nil
        pageDrag = 0
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !ignoreScrolling else { return }
        updateScrolling()
        // THE SELECTION MOVES DURING THE SCROLL, NOT AT THE END OF IT. Theirs:
        //
        //     var index = Int(round(scrollView.contentOffset.x / itemLayout.fullItemScrollDistance))
        //     index = max(0, min(index, component.slice.allItems.count - 1))
        //     if index != currentIndex { component.navigate(.id(allItems[index].id)) }
        //
        // gated on the row being fully a row. So the card you are looking at and the story the viewer
        // is on are never two different things for longer than half a card.
        guard geometry.fraction >= 1.0 - 0.0001 else { return }
        let i = centredIndex
        guard i != reportedIndex else { return }
        reportedIndex = i
        onIndexChanged(i)
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard geometry.fullDist > 0.5 else { return }
        // Their early return at both edges, which is what lets the rubber band finish its own spring
        // instead of being pulled out of it by a correction.
        if targetContentOffset.pointee.x <= 0
            || targetContentOffset.pointee.x >= scrollView.contentSize.width - scrollView.bounds.width {
            return
        }
        let closest = (targetContentOffset.pointee.x / geometry.fullDist).rounded()
        targetContentOffset.pointee.x = closest * geometry.fullDist
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { snapScrolling() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { snapScrolling() }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        isSnapping = false
        updateScrolling()
        reportScrollSettled()   // flushes any held frame itself
    }

    /// Their `snapScrolling`, which we only ever had half of: the `willEndDragging` rounding is the
    /// belt for a FLICK and never fires for a drag released too slowly to decelerate.
    ///
    /// ⚠️ EVERY WAY OUT OF THIS FUNCTION THAT DOES NOT START AN ANIMATION IS A SETTLE, and each of
    /// them reports it. The edge return is a movement that ENDED at the first or last story (the
    /// scroller is at rest against the rubber band's home); the small-delta return is a drag that
    /// ended already on the grid. Only the animated snap defers the report, to
    /// `scrollViewDidEndScrollingAnimation` — miss any of the three and the pager's deferred jump
    /// never fires for that movement, which strands the full-screen story on the card the swipe left.
    private func snapScrolling() {
        guard geometry.fullDist > 0.5 else { return }
        let off = scroller.contentOffset.x
        let maxOff = max(0, scroller.contentSize.width - scroller.bounds.width)
        guard off > 0, off < maxOff else {
            reportScrollSettled()
            return
        }
        let target = (off / geometry.fullDist).rounded() * geometry.fullDist
        guard abs(target - off) > 0.5 else {
            reportScrollSettled()
            return
        }
        isSnapping = true
        scroller.setContentOffset(CGPoint(x: target, y: 0), animated: true)
    }

    /// The one report that a movement is OVER, with the index it rests on. `centredIndex` is already
    /// the clamped rounded offset, so the number reported is the number the row is showing.
    private func reportScrollSettled() {
        // A movement is over whether or not the row is in a state to report it, so a frame held back
        // during that movement is spent either way.
        flushPendingFrames()
        guard geometry.fraction >= 1.0 - 0.0001, stories.indices.contains(centredIndex) else { return }
        onIndexSettled(centredIndex)
    }

    // MARK: Tap — theirs

    /// THE CARD UNDER THE FINGER, FOUND BY ASKING THE CARDS. Theirs:
    ///
    ///     for (id, visibleItem) in self.visibleItems {
    ///         if visibleItem.contentContainerView.convert(bounds, to: self).contains(point) {
    ///             if id == component.slice.item.id { hide the list } else { navigate(.id(id)) }
    ///         }
    ///     }
    ///
    /// The row used to divide the tap's distance from the centre by `fullDist` to work out how many
    /// cards over it was. That is only correct for the first neighbour: past it the spacing is
    /// `halfDist`, so the arithmetic and the picture disagreed about which card had been tapped.
    /// Hit-testing the real frames cannot be wrong about it.
    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        let point = g.location(in: view)
        // Most central first, so an ambiguous point resolves to the card nearest the middle.
        //
        // ⚠️ THIS USED TO SORT ON `layer.zPosition`, WHICH IS NOW ALWAYS ZERO — see the note in the
        // layout pass. Measuring the distance to the row's centre says the same thing the old
        // `2 - |cf|` said, without a per-frame write to an implicitly animated property. Theirs does
        // not order at all: it walks `visibleItems` in dictionary order and breaks on the first hit,
        // because no two cards ever overlap and at most one of them can contain the point.
        let mid = view.bounds.midX
        let ordered = items.values.sorted {
            abs($0.center.x - mid) < abs($1.center.x - mid)
        }
        // ⚠️ `convert(bounds:)`, NOT `frame`. UIKit documents `frame` as undefined once a view carries
        // a transform, and every card here carries one. Theirs asks the same question the same way:
        // `visibleItem.contentContainerView.convert(visibleItem.contentContainerView.bounds, to: self)`.
        for item in ordered where item.convert(item.bounds, to: view).contains(point) {
            if item.storyId == liveStoryId {
                onActiveTap()
            } else if let i = stories.firstIndex(where: { $0.id == item.storyId }) {
                // ⚠️ THE ROW DOES NOT MOVE YET, AND THAT IS THEIRS EXACTLY.
                //
                //     } else {
                //         self.animateNextNavigationId = id
                //         component.navigate(.id(id))
                //     }
                //
                // The tap ASKS for the story and remembers that the answer is its own to animate. It
                // moves nothing. The move happens later, on the pass where the model has actually
                // arrived at that id (`animateNextNavigationId == component.slice.item.id`), and
                // then the offset jumps and the layout springs in ONE pass.
                //
                // Ours used to seat the row on the tap and tell the outside world afterwards, which
                // opened a window — a few frames, and 0.3s of spring — where the row was on B and
                // the live story was still A. Story A was consequently being flown out to the side
                // slot as a LIVE story while B's poster sat in the centre, and the hand-over landed
                // somewhere inside that. That is the old story jumping and briefly staying in the
                // centre. Waiting removes the window rather than timing it.
                animateNextStoryId = item.storyId
                onIndexChanged(i)
            }
            return
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    /// The tap waits for the pan, which is theirs verbatim (`:909-917`):
    ///
    ///     if gestureRecognizer is UITapGestureRecognizer {
    ///         if otherGestureRecognizer is UIPanGestureRecognizer { return true }
    ///     }
    ///
    /// Without it, the first touch of a swipe can be delivered as a tap and navigate the row to
    /// whichever card the finger happened to land on before it started moving.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
        gestureRecognizer is UITapGestureRecognizer && other is UIPanGestureRecognizer
    }
}

// MARK: - The SwiftUI face

/// The row, for the one SwiftUI view that owns it.
struct StoryRow: UIViewControllerRepresentable {
    let stories: [Story]
    let liveStoryId: String
    let geometry: StoryRowGeometry
    let counts: [String: StoryRowCounts]
    /// The index the host wants centred, or nil when the host has nothing to say. Used only to catch
    /// a selection somebody else moved — the row's own scrolling reports outward, never inward.
    let activeIndex: Int?
    /// Lets the animatable page-drag reporter reach the controller without going through a SwiftUI
    /// update. See `StoryRowPositionReporter`.
    let link: StoryRowLink

    var onIndexChanged: (Int) -> Void = { _ in }
    var onIndexSettled: (Int) -> Void = { _ in }
    var onActiveTap: () -> Void = {}

    func makeUIViewController(context: Context) -> StoryRowController {
        let c = StoryRowController()
        c.onIndexChanged = { i in onIndexChanged(i) }
        c.onIndexSettled = { i in onIndexSettled(i) }
        c.onActiveTap = { onActiveTap() }
        link.controller = c
        c.apply(stories: stories, liveStoryId: liveStoryId, geometry: geometry,
                counts: counts, activeIndex: activeIndex)
        return c
    }

    func updateUIViewController(_ c: StoryRowController, context: Context) {
        // The closures are re-installed because they capture this frame's host state.
        c.onIndexChanged = { i in onIndexChanged(i) }
        c.onIndexSettled = { i in onIndexSettled(i) }
        c.onActiveTap = { onActiveTap() }
        link.controller = c
        c.apply(stories: stories, liveStoryId: liveStoryId, geometry: geometry,
                counts: counts, activeIndex: activeIndex)
    }
}

/// A weak pointer at the row's controller, so a per-frame value can be handed to UIKit without a
/// SwiftUI update in between.
///
/// Both of the row's per-frame inputs come through here, and for the same reason: a finger is
/// writing them, and routing a finger through a SwiftUI state write to reach a UIKit layout is how
/// the row got a frame behind the thing dragging it.
@MainActor final class StoryRowLink {
    weak var controller: StoryRowController?
    func setPageDrag(_ v: CGFloat, settle: StoryRowSettle = .commit) {
        controller?.setPageDrag(v, settle: settle)
    }
    func setFraction(_ v: CGFloat) { controller?.setFraction(v) }
    func commitPage(toStoryId id: String) { controller?.commitPage(toStoryId: id) }
    /// Read at the instant the row reports an index change — see the note on the controller's
    /// property. No controller yet = no tap, which is the honest answer.
    var tapNavigationPending: Bool { controller?.tapNavigationPending ?? false }
    /// The host's pager-jump deferral asks this in its `sheetStoryId` onChange: a change that lands
    /// while the row is moving is a crossing, not a destination. No controller = not moving.
    var isRowMoving: Bool { controller?.isRowMoving ?? false }
}
