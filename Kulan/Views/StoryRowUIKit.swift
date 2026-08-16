import SwiftUI
import UIKit
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

    /// ⚠️ A REDRAW NUDGE, NOT DATA, and it belongs to THIS card now rather than to the whole row.
    /// `StoryVideoFrames.card` answers nil the first time and generates the frame off the main
    /// thread; without something to observe, the better picture would sit in the cache until an
    /// unrelated change happened to redraw. It used to be observed by the row, so one clip's frame
    /// arriving rebuilt every card in it. Observed here, it rebuilds one.
    @ObservedObject private var frameTick = StoryFrameTick.shared

    var body: some View {
        media
            .frame(width: slotW, height: slotH)
            .clipped()
    }

    @ViewBuilder private var media: some View {
        // ⚠️ ASKED FOR BY STORY, AT DRAW TIME. There is no capture here, no timing and no moment to
        // get right — this card asks for a picture of ITS OWN clip, and the answer is generated from
        // that clip's own file at the second its own player is paused on.
        //
        // Nil is the normal answer for a photo (nothing is ever banked for one, and a photo's poster
        // IS the photo) and for a video nobody has watched this session. Both fall through to the
        // poster below.
        if story.isVideo, let u = URL(string: story.mediaUrl),
           let shot = StoryVideoFrames.card(u, storyId: story.id, width: slotW) {
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
        let font = UIFont.systemFont(ofSize: 11, weight: .semibold)   // .caption2.weight(.semibold)
        let symbol = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        eye.image = UIImage(systemName: "eye.fill", withConfiguration: symbol)
        eye.tintColor = .white
        heart.image = UIImage(systemName: "heart.fill", withConfiguration: symbol)
        heart.tintColor = .systemRed
        for l in [views, likes] {
            l.font = font
            l.textColor = .white
        }
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 5
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

    func set(views v: Int, likes l: Int) {
        views.text = Self.compact(v)
        likes.text = Self.compact(l)
        // The SwiftUI original omitted the heart entirely at zero rather than showing "0".
        let showLikes = l > 0
        heart.isHidden = !showLikes
        likes.isHidden = !showLikes
        // `.padding(.leading, 4)` on the heart, which a stack expresses as custom spacing.
        stack.setCustomSpacing(showLikes ? 9 : 5, after: views)
        setNeedsLayout()
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
    private var applied: (mediaUrl: String, previewUrl: String, w: CGFloat, h: CGFloat)?

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
        addSubview(count)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Rebuild the hosted picture only if something it is drawn from moved.
    func updateMedia(story: Story, slotW: CGFloat, slotH: CGFloat) {
        // Labelled to match the stored tuple exactly: `==` on tuples wants the same labels, not just
        // the same types.
        let want = (mediaUrl: story.mediaUrl, previewUrl: story.previewUrl, w: slotW, h: slotH)
        if let applied, applied == want { return }
        applied = want
        host.rootView = StoryRowCardMedia(story: story, slotW: slotW, slotH: slotH)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        host.view.frame = bounds
        let size = count.fittedSize()
        count.frame = CGRect(x: (bounds.width - size.width) / 2,
                             y: bounds.height - size.height - 10,   // `.padding(.bottom, 10)`
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
    /// how their central, playing item is dimmed by the same code path as a thumbnail, and how ours
    /// dims the live story, which is not in this view hierarchy at all. The row's own view sits ABOVE
    /// the live layer, so a black layer in it covers the story the same way it covers a card.
    private var tints: [String: CALayer] = [:]
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
                let c = counts[id] ?? .zero
                item.count.set(views: c.views, likes: c.likes)
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
        let rowIsStill = !scroller.isDragging && !scroller.isTracking
            && !scroller.isDecelerating && !isSnapping
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
                navigate(to: i, animated: true)
                seatedByTap = true
            } else if !stories.contains(where: { $0.id == pending }) {
                // The story went away before it could arrive — deleted under the sheet. Waiting for
                // it forever would leave the row unable to accept any jump for the rest of the
                // sitting, which is a worse failure than a missed animation.
                animateNextStoryId = nil
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
        if scroller.isScrollEnabled != enabled { scroller.isScrollEnabled = enabled }
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
        pageDrag = 0
        guard let i = stories.firstIndex(where: { $0.id == id }) else {
            updateScrolling(settle: .commit)
            return
        }
        navigate(to: i, animated: true)
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

        var valid = Set<String>()
        for (i, story) in stories.enumerated() {
            let cf = geometry.combinedFraction(index: i, rowPosition: rowPos)
            // THEIR VISIBILITY WINDOW (`:1541-1546`), measured on the LOGICAL distances rather than
            // the scaled ones — the same split they keep everywhere: logical for arithmetic, scaled
            // for anything that positions a pixel.
            guard geometry.isVisible(combinedFraction: cf, containerWidth: containerW) else { continue }
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
            // A card hides its own small count as it reaches the centre, where the big count below
            // takes over. Ported from the row's old `centreDistance` visual effect, which measured
            // the card's midpoint against the screen's.
            let dist = min(abs(p.center.x - screenW / 2) / (screenW * 0.42), 1)
            let countAlpha: CGFloat = dist < 0.35 ? 0 : 1
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
            let write = {
                item.center = centre
                item.transform = CGAffineTransform(scaleX: scale, y: scale)
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
                    tint.opacity = Float(p.dim)
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
                let wasScale = item.transform.a
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
                    let cfBefore = item.center.x < view.bounds.midX ? -mag : mag
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
                    // asked rather than recomputed.
                    let leavingDim = tints[story.id].map { CGFloat($0.opacity) } ?? from.dim
                    self.placeLiveStory(
                        StoryRowPlacement(center: from.center,
                                          size: from.size,
                                          cornerRadius: from.cornerRadius,
                                          dim: leavingDim),
                        settle: nil)
                }
            }
            item.setLive(isLive)
            item.updateMedia(story: story, slotW: geometry.slotW, slotH: geometry.slotH)
            if willAnimate {
                // Their `.curve(duration: 0.3, curve: .spring)` for a movement that did not come from
                // the finger. `run` is the one statement of that spring, and it keeps what the old
                // options bought: an interrupting swipe is still heard during it, and an interrupting
                // write starts where this one got to.
                let curve = settle ?? .commit
                curve.run(write)
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

        // Anything outside the window goes. Theirs defers removal to the end of an animation when one
        // is running; ours has nothing mid-flight to protect because a culled card is, by definition,
        // a container width off the side of the screen.
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
        StoryCardMorph.shared.place(contentCenter: p.center, contentSize: p.size,
                                    cornerRadius: p.cornerRadius, fraction: geometry.fraction,
                                    dim: p.dim,
                                    animated: settle.map { Self.settleAnimation($0) })
    }

    private func addItem(_ story: Story) -> StoryRowItemView {
        let media = StoryRowCardMedia(story: story,
                                      slotW: geometry.slotW,
                                      slotH: geometry.slotH)
        let item = StoryRowItemView(storyId: story.id, media: media)
        addChild(item.host)
        view.addSubview(item)
        item.host.didMove(toParent: self)
        let c = counts[story.id] ?? .zero
        item.count.set(views: c.views, likes: c.likes)
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
        animateNextStoryId = nil
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
    }

    /// Their `snapScrolling`, which we only ever had half of: the `willEndDragging` rounding is the
    /// belt for a FLICK and never fires for a drag released too slowly to decelerate.
    private func snapScrolling() {
        guard geometry.fullDist > 0.5 else { return }
        let off = scroller.contentOffset.x
        let maxOff = max(0, scroller.contentSize.width - scroller.bounds.width)
        guard off > 0, off < maxOff else { return }
        let target = (off / geometry.fullDist).rounded() * geometry.fullDist
        guard abs(target - off) > 0.5 else { return }
        isSnapping = true
        scroller.setContentOffset(CGPoint(x: target, y: 0), animated: true)
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
    var onActiveTap: () -> Void = {}

    func makeUIViewController(context: Context) -> StoryRowController {
        let c = StoryRowController()
        c.onIndexChanged = { i in onIndexChanged(i) }
        c.onActiveTap = { onActiveTap() }
        link.controller = c
        c.apply(stories: stories, liveStoryId: liveStoryId, geometry: geometry,
                counts: counts, activeIndex: activeIndex)
        return c
    }

    func updateUIViewController(_ c: StoryRowController, context: Context) {
        // The closures are re-installed because they capture this frame's host state.
        c.onIndexChanged = { i in onIndexChanged(i) }
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
}
