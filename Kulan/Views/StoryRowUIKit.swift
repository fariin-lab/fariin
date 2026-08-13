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
    /// The live story is drawn by the story layer itself, at this exact size and position. This card
    /// holds its place in the row and draws no pixels.
    ///
    /// ⚠️ KEYED ON THE STORY THE LIVE LAYER IS HOLDING, NOT ON THE CENTRED ONE. Those two were the
    /// same thing while the live story was pinned to the centre, and they are not the same thing now:
    /// mid-swipe the live story is off to one side and a different card is centred. Blanking the
    /// centred one would leave the real story drawing underneath a second picture of itself.
    let isLive: Bool

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
            .opacity(isLive ? 0 : 1)
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
    private var applied: (mediaUrl: String, previewUrl: String, isLive: Bool, w: CGFloat, h: CGFloat)?

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
    func updateMedia(story: Story, slotW: CGFloat, slotH: CGFloat, isLive: Bool) {
        // Labelled to match the stored tuple exactly: `==` on tuples wants the same labels, not just
        // the same types.
        let want = (mediaUrl: story.mediaUrl, previewUrl: story.previewUrl,
                    isLive: isLive, w: slotW, h: slotH)
        if let applied, applied == want { return }
        applied = want
        host.rootView = StoryRowCardMedia(story: story, slotW: slotW, slotH: slotH, isLive: isLive)
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
    /// Where the row is, every frame, so the live story can be placed by the same numbers.
    var onRowPosition: (_ scroll: CGFloat, _ pageDrag: CGFloat) -> Void = { _, _ in }

    // MARK: Machinery

    /// THE ENGINE. A hidden `UIScrollView` whose pan is re-homed onto the row — their `Scroller`,
    /// added to `itemsContainerView` with `itemsContainerView.addGestureRecognizer(scroller.panGestureRecognizer)`.
    /// The scroll view does the physics; nothing is ever drawn by it.
    private let scroller = UIScrollView()
    /// Their `visibleItems`: one entry per story that is inside the window, keyed by story id.
    private var items: [String: StoryRowItemView] = [:]
    /// Their `ignoreScrolling` fence. A programmatic offset must not be mistaken for a finger.
    private var ignoreScrolling = false
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
        self.counts = counts

        // Their `scroller.isScrollEnabled = itemLayout.contentScaleFraction >= 1.0 - 0.0001`: the row
        // is only scrollable once it has finished becoming a row.
        let enabled = geometry.fraction >= 1.0 - 0.0001
        if scroller.isScrollEnabled != enabled { scroller.isScrollEnabled = enabled }

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
        if let activeIndex, activeIndex != reportedIndex, activeIndex != centredIndex,
           stories.indices.contains(activeIndex), !scroller.isDragging, !scroller.isTracking {
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
            updateScrolling()
        }
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
    func setPageDrag(_ v: CGFloat) {
        guard v.isFinite, v != pageDrag else { return }
        let completing = v == 0 && pageDrag != 0
        pageDrag = v
        updateScrolling(animated: completing)
    }

    /// Put the row on this story. `animated` runs their 0.3s spring over the layout while the offset
    /// itself moves immediately, which is what keeps the cards and the live story on one clock.
    func navigate(to index: Int, animated: Bool) {
        guard stories.indices.contains(index), geometry.fullDist > 0.5 else { return }
        ignoreScrolling = true
        scroller.setContentOffset(CGPoint(x: CGFloat(index) * geometry.fullDist, y: 0), animated: false)
        ignoreScrolling = false
        reportedIndex = index
        updateScrolling(animated: animated)
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
    private func updateScrolling(animated: Bool = false) {
        guard view.bounds.width > 0, !stories.isEmpty else { return }
        pinToCentralWhileCollapsed()
        let central = centralIndex
        let rowPos = geometry.rowPosition(scroll: scroll, centralIndex: central, pageDrag: pageDrag)
        let centralX = view.bounds.midX
        let containerW = view.bounds.width
        let screenW = UIScreen.main.bounds.width

        var valid = Set<String>()
        for (i, story) in stories.enumerated() {
            let cf = geometry.combinedFraction(index: i, rowPosition: rowPos)
            // THEIR VISIBILITY WINDOW (`:1541-1546`), measured on the LOGICAL distances rather than
            // the scaled ones — the same split they keep everywhere: logical for arithmetic, scaled
            // for anything that positions a pixel.
            guard geometry.isVisible(combinedFraction: cf, containerWidth: containerW) else { continue }
            valid.insert(story.id)

            // ⚠️ A CARD BORN THIS PASS IS PLACED WITHOUT THE ANIMATION. A new item view starts at
            // the origin with an identity transform, so animating its first placement would slide it
            // in from the top-left corner of the row — which is exactly what a card entering the
            // visibility window during a sheet page commit would have done.
            let existing = items[story.id]
            let item = existing ?? addItem(story)
            let scale = geometry.itemScale(combinedFraction: cf)
            let centre = CGPoint(x: centralX + geometry.offsetX(combinedFraction: cf),
                                 y: geometry.slotH / 2)
            let alpha = CGFloat(geometry.itemOpacity(combinedFraction: cf))
            // A card hides its own small count as it reaches the centre, where the big count below
            // takes over. Ported from the row's old `centreDistance` visual effect, which measured
            // the card's midpoint against the screen's.
            let dist = min(abs(centre.x - screenW / 2) / (screenW * 0.42), 1)
            let countAlpha: CGFloat = dist < 0.35 ? 0 : 1
            // The card's own size. Set OUTSIDE the animation and only when it differs: a bounds
            // change re-lays-out the hosted content, and it changes for one reason (the sheet's slot
            // was re-measured) which is not something a scroll ever does.
            let size = CGSize(width: geometry.slotW, height: geometry.slotH)
            if item.bounds.size != size {
                item.bounds = CGRect(origin: .zero, size: size)
            }
            let write = {
                item.center = centre
                item.transform = CGAffineTransform(scaleX: scale, y: scale)
                item.alpha = alpha
                item.count.alpha = countAlpha
            }
            // The centred card on top, exactly as the old `zIndex(2 - |cf|)`.
            item.layer.zPosition = 2 - abs(cf)
            item.updateMedia(story: story, slotW: geometry.slotW, slotH: geometry.slotH,
                             isLive: story.id == liveStoryId)
            if animated, existing != nil {
                // Their `.curve(duration: 0.3, curve: .spring)` for a movement that did not come from
                // the finger. `.allowUserInteraction` so an interrupting swipe is heard during it,
                // and `.beginFromCurrentState` so an interrupting one starts where this one got to.
                UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.82,
                               initialSpringVelocity: 0,
                               options: [.allowUserInteraction, .beginFromCurrentState],
                               animations: write)
            } else {
                write()
            }
        }

        // Anything outside the window goes. Theirs defers removal to the end of an animation when one
        // is running; ours has nothing mid-flight to protect because a culled card is, by definition,
        // a container width off the side of the screen.
        for (id, item) in items where !valid.contains(id) {
            removeItem(id, item)
        }

        // ⚠️ AND THE SAME SET DECIDES WHICH STORIES KEEP THEIR PLAYER. One loop, one answer, which is
        // their shape: `validIds` is built by the layout pass and is what the item views are kept or
        // dropped by. The library used to hold a SECOND, narrower window of its own (centre ±1) and
        // it won, so a story still being drawn two cards out had its player torn down — watch A,
        // open the sheet, swipe to B then C, and coming back to A found nothing and started a new
        // player at zero. See `StoryVideoHost.previewWindow`.
        StoryVideoHost.previewWindow(valid)

        onRowPosition(scroll, pageDrag)
    }

    private func addItem(_ story: Story) -> StoryRowItemView {
        let media = StoryRowCardMedia(story: story,
                                      slotW: geometry.slotW,
                                      slotH: geometry.slotH,
                                      isLive: story.id == liveStoryId)
        let item = StoryRowItemView(storyId: story.id, media: media)
        addChild(item.host)
        view.addSubview(item)
        item.host.didMove(toParent: self)
        let c = counts[story.id] ?? .zero
        item.count.set(views: c.views, likes: c.likes)
        items[story.id] = item
        return item
    }

    private func removeItem(_ id: String, _ item: StoryRowItemView) {
        item.host.willMove(toParent: nil)
        item.host.view.removeFromSuperview()
        item.host.removeFromParent()
        item.removeFromSuperview()
        items.removeValue(forKey: id)
    }

    // MARK: Scroll delegate — theirs, method for method

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
        // Front to back, so an overlap resolves to the card drawn on top.
        let ordered = items.values.sorted { $0.layer.zPosition > $1.layer.zPosition }
        // ⚠️ `convert(bounds:)`, NOT `frame`. UIKit documents `frame` as undefined once a view carries
        // a transform, and every card here carries one. Theirs asks the same question the same way:
        // `visibleItem.contentContainerView.convert(visibleItem.contentContainerView.bounds, to: self)`.
        for item in ordered where item.convert(item.bounds, to: view).contains(point) {
            if item.storyId == liveStoryId {
                onActiveTap()
            } else if let i = stories.firstIndex(where: { $0.id == item.storyId }) {
                navigate(to: i, animated: true)
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
    var onRowPosition: (CGFloat, CGFloat) -> Void = { _, _ in }

    func makeUIViewController(context: Context) -> StoryRowController {
        let c = StoryRowController()
        c.onIndexChanged = { i in onIndexChanged(i) }
        c.onActiveTap = { onActiveTap() }
        c.onRowPosition = { s, d in onRowPosition(s, d) }
        link.controller = c
        c.apply(stories: stories, liveStoryId: liveStoryId, geometry: geometry,
                counts: counts, activeIndex: activeIndex)
        return c
    }

    func updateUIViewController(_ c: StoryRowController, context: Context) {
        // The closures are re-installed because they capture this frame's host state.
        c.onIndexChanged = { i in onIndexChanged(i) }
        c.onActiveTap = { onActiveTap() }
        c.onRowPosition = { s, d in onRowPosition(s, d) }
        link.controller = c
        c.apply(stories: stories, liveStoryId: liveStoryId, geometry: geometry,
                counts: counts, activeIndex: activeIndex)
    }
}

/// A weak pointer at the row's controller, so a per-frame value can be handed to UIKit without a
/// SwiftUI update in between.
@MainActor final class StoryRowLink {
    weak var controller: StoryRowController?
    func setPageDrag(_ v: CGFloat) { controller?.setPageDrag(v) }
}
