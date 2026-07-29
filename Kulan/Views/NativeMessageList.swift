import SwiftUI
import UIKit

// UIKit-backed conversation list. A UICollectionView hosts our existing SwiftUI rows (MessageBubble etc.)
// via UIHostingConfiguration, so no bubble feature is lost â€” only the scroll container differs.
//
// ============================================================================================
// THE INVERTED MODEL, AND WHY THE LIST IS BUILT UPSIDE DOWN (2026-07-28 rewrite)
// ============================================================================================
// This list used to stack messages downward from content y = 0, oldest first, exactly like a normal
// table. That single decision is what produced the scroll jump, and it produced it four different ways
// over ten days â€” every fix found a real cause, and the bug came back from a new direction, because in a
// top-down chat list KEEPING THE READER STILL IS A CALCULATION rather than a property:
//
//   * Older messages page in ABOVE the reader, so every row they can see moves down by the height of
//     what landed. The only thing holding them in place is a compensating contentOffset write that has
//     to be exactly right and land in exactly the same transaction as the content change.
//   * That compensation needs the exact height of every row above the viewport â€” including forty rows
//     that have never been on screen, sized by an off-screen SwiftUI sizer that is documented (see
//     `sizerRefused`) to be permanently wrong for async content. A height that is wrong by four points
//     is a four-point jump now and a second jump later when the row is finally rendered and corrected.
//   * Because every mechanism (a load, a reaction, a media height, a reconfigure, the keyboard, the
//     composer, a rotation) can move rows above the reader, EVERY mechanism needed its own compensation
//     and its own guard. There were roughly twenty-five contentOffset/contentInset writers in this file,
//     each guarded by whoever wrote it, and each one was a chance to get it wrong.
//
// So the list is now INVERTED, which is what Telegram, WhatsApp and iMessage all do:
//
//   * The collection view carries a scaleY(-1) transform and so does every cell, so the two flips cancel
//     and content renders upright. Only the VIEWPORT is mirrored.
//   * Item 0 is the NEWEST message and sits at content y = 0, which the flip puts at the bottom of the
//     screen. Older messages extend to larger y, which the flip puts further up.
//   * Paging in history therefore APPENDS beyond the far edge of the content. Nothing between the origin
//     and the viewport changes, so no frame the reader can see moves, so there is nothing to compensate
//     for and nothing that can be got wrong. A badly measured row that the reader has never seen can no
//     longer move them: it is on the far side of the viewport from the coordinate origin.
//   * "At the bottom" becomes `contentOffset.y == -adjustedContentInset.top`, a fixed number that does
//     not depend on contentSize at all. Every bug in the old at-bottom family died with it: the negative
//     `safeDistanceFromBottom` during a keyboard fold that read as "at the bottom" and yanked a reader
//     down, the pin that fired against a stale contentSize, the clamp that stranded content after a
//     resize. Staying at the newest message is now free â€” the scroll view already does it.
//
// What remains is one narrow case that genuinely needs compensation: a NEW message arriving while the
// reader is scrolled up in history. That inserts at index 0 and does shift everything. It is one row, of
// a height we measured a moment ago, through one code path, and it rides the layout's own
// `contentOffsetAdjustment` inside the update transaction. There is exactly one at-rest verification net
// behind it, in one place.
//
// Heights are still measured up-front (UIHostingController.sizeThatFits at the real width, cached by row
// id) and fed to a layout that stacks exact frames, so cells never self-size and the first frame drawn is
// already final. That part was never the problem and is unchanged.
struct NativeMessageList: UIViewControllerRepresentable {
    var rowIds: [String]                       // stable ids in CHRONOLOGICAL order (Message.rowId)
    var rowSignatures: [String: String] = [:]  // per-row CONTENT signature â†’ same-ids apply reconfigures ONLY changed rows
    var row: (String) -> AnyView               // ThreadView builds the full row (date/divider/bubble) for an id
    // UIKit bubble migration: messages the native path fully supports (plain 1:1 delivered text) render
    // as UIKit cells â€” no SwiftUI, no per-cell animation/re-measure during scroll. The models arrive as a
    // SNAPSHOT DICTIONARY resolved once per body run (not a live closure): measure() and the cell
    // provider read the same frozen routing, so a state flip can never route a row differently between
    // its measurement and its render (the mismatch that stranded the layout when this path first ran).
    var uikitModels: [String: UIKitBubbleModel] = [:]
    // Bumped by ThreadView only when the model dictionary is genuinely rebuilt. `repaintUikitCells` walks
    // the visible cells on every SwiftUI update, and the body re-runs on typing flags, presence dots and
    // keyboard focus â€” all of which leave the models identical. Comparing one integer skips that walk.
    var uikitModelsVersion: Int = 0
    var uikitMenu: (String) -> UIMenu? = { _ in nil }        // long-press menu for UIKit-routed rows
    // Floating reactions bar (ReactionBar.swift): my current reaction on a row, and the tap handler.
    var onReactionSelected: (String) -> String? = { _ in nil }
    var onReactionPick: (String, String?) -> Void = { _, _ in }
    var onUikitDoubleTap: (String) -> Void = { _ in }        // double-tap quick reaction (heart)
    var onReachedTop: () -> Void               // near the oldest loaded row -> page older
    var selecting: Bool = false                // selection mode â€” drives the selection-animation land gate
    // The initial scroll position: when the conversation has unread messages, the FIRST open lands with
    // the first-unread row (its unread divider) near the top â€” not at the newest. Consumed exactly once at
    // first open; nil (or an id outside the loaded window) falls back to the newest message.
    var initialScrollId: String? = nil
    var canSwipeReply: (String) -> Bool = { _ in false }   // is this rowId reply-eligible (on the server)?
    var onSwipeReply: (String) -> Void = { _ in }          // swipe past threshold released â†’ reply to this rowId
    var loadingOlder: Bool = false             // show the top spinner while older messages page in
    // Composer bar height (SwiftUI-measured). Extra clearance at the VISUAL BOTTOM so the newest message
    // clears the bar: the list is full-bleed UNDER the composer, so the composer's own safe-area inset is
    // not folded for us. Under the flip the visual bottom is contentInset.top â€” see updateInsets().
    var composerBarHeight: CGFloat = 0
    // Bumped by ThreadView from inside a SWIFTUI context-menu action (e.g. Select). UIKit's
    // context-menu callbacks cannot see SwiftUI-presented menus, so this is how the controller learns
    // "a menu is dismissing right now" and holds cell reloads until the animation is over.
    var menuActionTick: Int = 0
    // Height of the top overlay (pinned-message bar) the list runs UNDER. The floating date pill drops below
    // it so it isn't hidden behind the pin (Signal behavior). 0 â†’ pill sits at its normal top position.
    var topOverlayHeight: CGFloat = 0
    var onTopInset: (CGFloat) -> Void = { _ in }   // reports the GEOMETRIC nav-bar overlap (UIKit safe area â€” reliable)
    @Binding var isAtBottom: Bool
    @Binding var scrollTarget: String?         // set to a rowId to scroll it into view (reply/search jump), then cleared
    // Day label for the floating date pill, resolved from a rowId. Called from scrollViewDidScroll and
    // rendered by a UIKit pill INSIDE the controller â€” so scrolling no longer writes SwiftUI state (a
    // per-tick `topVisibleId` binding write re-ran the whole ThreadView tree mid-scroll = the round-trip
    // that made scrolling feel unstable). Reading repo.items here is a pure read; it triggers no re-render.
    var dayLabelFor: (String) -> String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> MessageListController {
        let vc = MessageListController()
        vc.coordinator = context.coordinator
        context.coordinator.controller = vc
        vc.loadViewIfNeeded()   // force viewDidLoad now so collectionView + dataSource exist before apply
        return vc
    }

    func updateUIViewController(_ vc: MessageListController, context: Context) {
        context.coordinator.parent = self
        vc.loadViewIfNeeded()
        vc.uikitModels = uikitModels   // BEFORE apply: measure + cell provider see the same frozen routing
        vc.uikitMenu = uikitMenu
        vc.onReactionSelected = onReactionSelected
        vc.onReactionPick = onReactionPick
        vc.onUikitDoubleTap = onUikitDoubleTap
        vc.setComposerBarHeight(composerBarHeight)
        vc.setTopOverlayHeight(topOverlayHeight)
        vc.noteMenuActionTick(menuActionTick)   // BEFORE setSelecting/apply: arm the dismissal grace first
        vc.setSelecting(selecting)
        vc.initialScrollId = initialScrollId
        vc.canSwipeReply = canSwipeReply
        vc.onSwipeReply = onSwipeReply
        vc.dayLabelFor = dayLabelFor
        vc.onTopInset = onTopInset
        vc.setLoadingOlder(loadingOlder)
        vc.rowSignatures = rowSignatures
        // The scroll target RIDES the apply (a jump is a scroll ACTION attached to the load, landed
        // atomically with it). Calling scrollTo after apply was a race: for a jump into older history
        // (ensureLoaded â†’ page older), apply's async completion ran AFTER the scroll had already happened
        // and stomped it ("reply/search jump doesn't work").
        vc.apply(rowIds: rowIds, scrollTarget: scrollTarget)
        // Belt-and-braces from the 325 field failure: push geometry-neutral model changes (read ticks)
        // STRAIGHT onto the visible uikit cells â€” even if the reconfigure chain misses, ticks repaint.
        // Only when the models actually changed: `repaintIfMetaChanged` reads nothing but the model, so an
        // identical dictionary can have nothing to repaint, and this used to walk every visible cell on
        // every body run.
        if vc.lastRepaintedModelsVersion != uikitModelsVersion {
            vc.lastRepaintedModelsVersion = uikitModelsVersion
            vc.repaintUikitCells()
        }
        if scrollTarget != nil {
            DispatchQueue.main.async { scrollTarget = nil }   // one-shot
        }
    }

    final class Coordinator {
        var parent: NativeMessageList
        weak var controller: MessageListController?
        init(_ parent: NativeMessageList) { self.parent = parent }
    }
}

// Per-cell rendered-height report (SwiftUI truth). Scoped per hosting cell, so cells never interfere.
private struct RowHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// Hardened collection view: Auto Layout transiently zeroes frames during presentation, and accepting a
// zero size destroys the contentOffset/scroll state.
//
// The old file also overrode contentOffset to reject UIScrollView's internal pre-content reset to zero,
// which used to snap a top-down list to its very first message. Inverted, content y = 0 IS the newest
// message â€” the position the list wants to be in â€” so that reset is no longer something to defend
// against, and the override is gone with it.
final class HardenedCollectionView: UICollectionView {
    override var frame: CGRect {
        get { super.frame }
        set { if newValue.width > 0, newValue.height > 0 { super.frame = newValue } }
    }
    override var bounds: CGRect {
        get { super.bounds }
        set { if newValue.width > 0, newValue.height > 0 { super.bounds = newValue } }
    }
}

final class MessageListController: UIViewController, UICollectionViewDelegate, UIGestureRecognizerDelegate {
    var coordinator: NativeMessageList.Coordinator!
    private var collectionView: UICollectionView!
    private var layout: InvertedMessageLayout!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var reg: UICollectionView.CellRegistration<UICollectionViewCell, String>!

    // LAYOUT ORDER: index 0 is the NEWEST message. This is the reverse of the chronological `rowIds`
    // ThreadView hands us, and it is reversed exactly once, at the top of apply(). Everything below this
    // line thinks in layout order, so there are no mixed conventions to get wrong.
    private var currentIds: [String] = []
    private var heights: [String: CGFloat] = [:]   // rowId -> exact measured height (cell-size cache)
    private var measuredWidth: CGFloat = 0
    private var hostWidth: CGFloat = 0             // final cell width, pinned into each hosted row's first layout

    // Off-screen SwiftUI sizer: hosts a row and returns its exact height for a given width (no display).
    // A child VC so it inherits our trait collection (Dynamic Type), matching the on-screen render.
    private let sizer = UIHostingController(rootView: AnyView(Color.clear))

    // Load-older indicator: a small spinner pinned at the top of the screen while older messages page in.
    // A fixed overlay, not a cell and not an inset, so it can never disturb the exact-frame layout.
    private let topSpinner = UIActivityIndicatorView(style: .medium)

    private var didFirstLand = false          // the first open has been positioned
    private var didReveal = false             // hidden until the first frame is final
    private var scheduledEmptyReveal = false  // one-shot fallback for a genuinely-empty / slow-decrypt chat
    private var sendAnimating = false         // an animated send/receive glide is in flight
    private var needsRefreshOnSettle = false  // a refresh blocked by an ANIMATION â†’ coalesced, lands when it ends
    private var pendingSettleHeights: Set<String> = []   // rows whose height changed while an animation blocked us
    var initialScrollId: String?              // first-unread rowId â†’ the FIRST open lands here
    var lastRepaintedModelsVersion = -1       // -1 so the first update always repaints

    // Rows whose rendered height the SIZER can never reproduce (async content, e.g. link-preview cards).
    private var sizerRefused = Set<String>()
    private var captureFreezeUntil = Date.distantPast    // system screenshot capture owns the scroll until then
    private var popGestureHooked = false                 // interactive-pop target attached once
    private var scrollWorkTimer: Timer?                  // 0.1s debounce for pagination + isAtBottom writes
    private var userScrolledSinceTimer = false           // the debounced work only pages on USER scrolls
    // Every programmatic animated scroll is tracked: while one is in flight, no land may invalidate the
    // layout under it. A 5s watchdog force-clears the flag if UIKit cancels the animation without a
    // completion callback â€” a wedged flag would block lands forever.
    private var programmaticScrollAnimating = false
    private var scrollAnimationWatchdog: Timer?
    private var lastLoadOlderAt = Date.distantPast       // pagination throttle (2s window)
    private var keyboardAnimating = false                // a keyboard-synced offset animation is in flight
    private var shouldAnimateKeyboardChanges = false     // true only between viewDidAppear and viewWillDisappear
    private var keyboardWasAtNewest = false              // latched at willHide: reader was at the newest message
    private var keyboardSettlePending = false            // didHide fired mid-drag; settle at drag/decel end
    private var keyboardClosing = false                  // willHide → didHide: the per-layout glue window
    private var isDisappearing = false        // swipe-back / pop in progress â†’ freeze all content-offset work
    private var lastStableOffset: CGFloat = 0 // last user/our-intent offset â†’ screenshot-capture recovery
    // Selection-mode animation coordination: the land that CARRIES the checkbox change passes (even
    // mid-motion), then further lands defer until the slide animation window closes â€” a reconfigure
    // mid-slide clobbered the checkbox animation.
    private enum SelectionAnimationState { case idle, willAnimate, animating }
    private var selectionAnimationState: SelectionAnimationState = .idle
    private var isSelecting = false

    func setSelecting(_ s: Bool) {
        guard s != isSelecting else { return }
        isSelecting = s
        selectionAnimationState = .willAnimate   // the next land carries the checkboxes â€” let it through
    }

    // THE SWIFTUI CONTEXT MENU IS INVISIBLE TO UIKIT'S CALLBACKS â€” the third and, read from the user's
    // screenshot, the ACTUAL cause of the stranded selection blur. `contextMenuVisible` is fed by the
    // collection view delegate (willDisplay/willEnd ContextMenu), which only fires for menus the
    // COLLECTION VIEW presents â€” the UIKit text cells. Media, album, voice and reply bubbles are
    // SwiftUI cells whose `.contextMenu` presents through its own interaction on the hosted view: those
    // callbacks never fire, `contextMenuVisible` stays false, and the Select action's every-cell reload
    // landed exactly mid-dismissal â€” destroying the cell the lifted preview was animating back into,
    // stranding the system's full-screen blur (the sharp album strip at the top of the screenshot IS
    // the orphaned preview). The two earlier fixes were real but only covered the UIKit-menu path.
    //
    // SwiftUI cannot tell us when its menu's dismissal ENDS, but the action closure tells us exactly
    // when it BEGINS â€” actions run as the menu starts to dismiss. So the action marks a grace window
    // sized to UIKit's dismissal animation, canLandLoad holds every land inside it, and a scheduled
    // settleFlush lands the deferred work the moment it closes.
    private var lastMenuActionTick = 0
    private var menuDismissGraceUntil = Date.distantPast
    private var menuDismissArmedAt = Date.distantPast
    func noteMenuActionTick(_ t: Int) {
        guard t != lastMenuActionTick else { return }
        let isFirstObservation = lastMenuActionTick == 0 && t != 0
        lastMenuActionTick = t
        guard !isFirstObservation || t == 1 else { return }   // adopting a mid-flight tick on (re)attach is not an action
        // 0.6s BACKSTOP: UIKit's dismissal spring runs ~0.4-0.5s and a LARGE lifted preview (an album
        // mosaic) rides the long end. This window is a GATE, not a schedule — and it normally ends
        // EARLY, the moment the menu's own window hides (menuWindowDidHide), which is the same instant
        // Signal's animator completion fires. The timer only covers the case that notification never
        // comes. (User report on the timer-only version: "the checkmark is coming late" — checkboxes
        // sat on the full 0.65s even though the menu was gone at ~0.4.)
        menuDismissArmedAt = Date()
        menuDismissGraceUntil = Date().addingTimeInterval(0.6)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in self?.settleFlush() }
    }

    // The moment a SwiftUI context menu's dismissal actually ENDS: its menu lives in its own UIWindow,
    // and that window becoming hidden is the completion callback SwiftUI never gives us. Ends the grace
    // and lands the deferred selection reload immediately. The 0.25s floor shields against an unrelated
    // window hiding right after the action; our own window never counts.
    @objc private func menuWindowDidHide(_ note: Notification) {
        guard Date() < menuDismissGraceUntil else { return }
        guard Date().timeIntervalSince(menuDismissArmedAt) > 0.25 else { return }
        guard (note.object as? UIWindow) !== view.window else { return }
        menuDismissGraceUntil = .distantPast
        settleFlush()
    }

    var rowSignatures: [String: String] = [:] // set before each apply â€” per-row content signature
    private var lastRowSigs: [String: String] = [:]  // signatures at the last apply â†’ diff to find changed rows

    // Swipe-to-reply: ONE pan gesture on the collection view drags the touched cell's bubble left and
    // reveals a reply arrow, instead of a SwiftUI drag gesture per bubble (which fought the scroll pan and
    // jittered). Callbacks are fed from SwiftUI.
    var canSwipeReply: (String) -> Bool = { _ in false }
    var onSwipeReply: (String) -> Void = { _ in }
    var uikitModels: [String: UIKitBubbleModel] = [:]   // frozen routing snapshot (set before every apply)
    var uikitMenu: (String) -> UIMenu? = { _ in nil }
    var onUikitDoubleTap: (String) -> Void = { _ in }
    // Route each id was last CONFIGURED with (uikit vs SwiftUI cell). A content change that flips the
    // route needs reloadItems (re-dequeue the other cell class) â€” reconfigureItems reuses the same cell
    // instance, which can't switch renderers.
    private var configuredRoutes: [String: Bool] = [:]
    private var doubleTapGesture: UITapGestureRecognizer!
    private var holdPress: UILongPressGestureRecognizer!     // passive: marks the context-menu lift window
    private var interactionHoldUntil = Date.distantPast      // lands defer while a long-press is in flight
    private var contextMenuVisible = false                   // UIKit says a context menu is on screen
    private var contextMenuSourceId: String?                 // the row that menu lifted from
    private var uikitReg: UICollectionView.CellRegistration<UIKitBubbleCell, String>!
    private var swipePan: UIPanGestureRecognizer!
    private weak var swipingCell: UICollectionViewCell?
    private var swipingId: String?
    private var swipeArrow: UIImageView?
    private var swipeTriggered = false         // crossed the reply threshold this drag (haptic + fire on release)

    // Floating date pill (the sticky day header), rendered in UIKit and updated directly from
    // scrollViewDidScroll â€” NOT via a SwiftUI binding. Shows the topmost visible row's day while scrolling,
    // fades ~1.2s after scrolling stops. This is what removes the per-scroll SwiftUI round-trip.
    var dayLabelFor: (String) -> String? = { _ in nil }
    private let datePill: UIVisualEffectView = {
        if #available(iOS 26.0, *) { return UIVisualEffectView(effect: UIGlassEffect()) }
        return UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    }()
    private var datePillTop: NSLayoutConstraint!   // top constant grows by the pinned-bar height when pinned
    private var topOverlayHeight: CGFloat = 0
    private var composerBarH: CGFloat = 0
    private let dateLabel = UILabel()
    private var dateFadeWork: DispatchWorkItem?
    private var lastDateId: String?
    var onTopInset: ((CGFloat) -> Void)?      // ThreadView positions the date pill / pinned bar with this
    private var lastReportedTop: CGFloat = -1

    override func viewDidLoad() {
        super.viewDidLoad()
        layout = InvertedMessageLayout()
        layout.heightForItem = { [weak self] index in
            guard let self, index < self.currentIds.count else { return 44 }
            return self.heights[self.currentIds[index]] ?? 44
        }
        collectionView = HardenedCollectionView(frame: view.bounds, collectionViewLayout: layout)
        // THE INVERSION. Mirroring the viewport is what puts content y = 0 (the newest message) at the
        // bottom of the screen and makes paging history a pure append beyond the far edge. Each cell
        // carries the same flip (applied through its layout attributes), so the two cancel and every
        // bubble draws upright. Nothing else in the app needs to know.
        collectionView.transform = InvertedMessageLayout.flip
        collectionView.isPrefetchingEnabled = false   // off until first appearance (faster, jank-free open)
        collectionView.backgroundColor = .clear
        collectionView.alpha = 0   // invisible until the first render is final â€” never shows a mid-measure frame
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .interactive
        // .never â€” WE own both insets. This was `.always` for one build and it was wrong, in the exact way
        // the comment here predicted: UIKit does NOT map the safe area through the flip. It kept adding
        // `safeAreaInsets.top` (the status bar and nav bar, about 103pt) to `contentInset.top`, which under
        // the flip is the VISUAL BOTTOM â€” so roughly 80pt of dead space opened between the last bubble and
        // the composer, while the visual top got the home indicator's 34pt instead of the nav bar's 103.
        // The two contributions were simply swapped, and swapping our own two writes could not fix that
        // because the safe-area half was not ours to swap.
        //
        // So the safe area is read from THIS CONTROLLER'S VIEW instead, which carries no transform and is
        // the same value the old top-down list called reliable and un-desyncable. updateInsets() adds it on
        // the correct side by hand. The totals are identical to what `.always` produced before the
        // inversion (safe.bottom + composerBar + 12 at the composer edge, safe.top + pinned bar at the nav
        // edge) â€” only the side changed.
        // REVERTED TO .always (2026-07-28, build 388 regression). I switched this to .never and computed
        // both insets from `view.safeAreaInsets`, on the theory that the controller's own view carries
        // the real safe area. On device it does not â€” the values came out near zero, so the list lost
        // BOTH its clearances at once: bubbles ran under the nav bar and under the composer, and because
        // minContentOffsetY is derived from the same inset, the keyboard and scroll positions went with
        // them. The user asked for one spacing fix and got a change of inset OWNERSHIP; that was my
        // mistake, not a tuning error.
        //
        // UIKit computes the collection view's safe area from the WINDOW, which is why .always worked
        // here for months. Do not take these insets over again without device proof.
        collectionView.contentInsetAdjustmentBehavior = .always
        // SCROLL EDGE BLUR: PERMANENTLY OFF for this list, verdict FINAL (2026-07-29, three device
        // strikes). Apple's effect cannot survive the inverted list in ANY configuration: the default
        // washed whole chats on iOS 26; blindly enabled it drew nothing on 27; and PROPERLY REGISTERED
        // (UIScrollEdgeElementContainerInteraction on containers over the real bar regions, .soft, the
        // documented custom-bar way) it washed the ENTIRE chat again — user screenshot, every bubble
        // ghosted. The hand-made gradient bands failed separately (frosted blocks mid-chat).
        // DO NOT TRY AGAIN without a device in hand: not the system effect, not custom bands. The chat
        // scrolls raw under its bars, which the user has accepted over any of the failure modes.
        if #available(iOS 26.0, *) {
            collectionView.topEdgeEffect.isHidden = true
            collectionView.bottomEdgeEffect.isHidden = true
        }
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        // Single swipe-to-reply pan. Its delegate gates it to horizontal-left drags so vertical scrolling
        // is never hijacked, and it coexists with the scroll pan.
        swipePan = UIPanGestureRecognizer(target: self, action: #selector(handleSwipePan(_:)))
        swipePan.delegate = self
        collectionView.addGestureRecognizer(swipePan)

        // Double-tap quick-react for UIKit-routed rows (the SwiftUI rows carry their own gesture).
        doubleTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTapGesture.numberOfTapsRequired = 2
        doubleTapGesture.delegate = self
        collectionView.addGestureRecognizer(doubleTapGesture)

        // PASSIVE long-press observer (never consumes touches): marks the context-menu lift window so
        // canLandLoad blocks content lands during it â€” a reconfigure landing mid-lift replaced the menu's
        // source view (flickering / vanishing long-press menu).
        holdPress = UILongPressGestureRecognizer(target: self, action: #selector(handleHoldWindow(_:)))
        holdPress.minimumPressDuration = 0.25
        holdPress.cancelsTouchesInView = false
        holdPress.delegate = self
        collectionView.addGestureRecognizer(holdPress)

        // Off-screen sizer, in the hierarchy (0-alpha) so it inherits traits for accurate measurement.
        // CRITICAL: it must NOT reserve safe area. It's a child of this controller, and the list runs
        // under the nav bar, so this controller's view has a top safe-area inset â€” a plain
        // UIHostingController would ADD that inset to every measured row height, inflating the gap under
        // every bubble. safeAreaRegions = [] measures the row content ONLY.
        addChild(sizer)
        if #available(iOS 16.4, *) { sizer.safeAreaRegions = [] }
        sizer.view.alpha = 0
        sizer.view.isUserInteractionEnabled = false
        sizer.view.frame = .zero
        view.addSubview(sizer.view)
        sizer.didMove(toParent: self)

        topSpinner.hidesWhenStopped = true
        topSpinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topSpinner)
        NSLayoutConstraint.activate([
            topSpinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            topSpinner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
        ])

        // Floating date pill (top-center, below the nav bar). A UIKit capsule updated in scrollViewDidScroll.
        datePill.translatesAutoresizingMaskIntoConstraints = false
        datePill.layer.cornerRadius = 15
        datePill.layer.cornerCurve = .continuous
        datePill.clipsToBounds = true
        datePill.alpha = 0
        datePill.isUserInteractionEnabled = false
        dateLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        dateLabel.textColor = .label
        dateLabel.translatesAutoresizingMaskIntoConstraints = false
        datePill.contentView.addSubview(dateLabel)
        view.addSubview(datePill)
        datePillTop = datePill.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6)
        NSLayoutConstraint.activate([
            datePill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            datePillTop,
            datePill.heightAnchor.constraint(equalToConstant: 30),
            dateLabel.centerYAnchor.constraint(equalTo: datePill.contentView.centerYAnchor),
            dateLabel.leadingAnchor.constraint(equalTo: datePill.contentView.leadingAnchor, constant: 14),
            dateLabel.trailingAnchor.constraint(equalTo: datePill.contentView.trailingAnchor, constant: -14),
        ])

        // KEYBOARD. In the inverted list the keyboard is no longer a position problem, only an inset one:
        // the newest message lives at a fixed offset, so all that is needed is to move the offset by the
        // same amount the clearance grows, with the keyboard's own duration and curve. Two observers
        // replace the display-link close drive, the at-bottom latches, the backstop volley and the
        // geometric composer signal that all used to be needed to keep a moving target in view.
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow(_:)),
                                               name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardDidHide),
                                               name: UIResponder.keyboardDidHideNotification, object: nil)
        // Context-menu dismissal end detector — see menuWindowDidHide. Registered permanently; the
        // handler is inert outside an armed menu-dismissal grace window.
        NotificationCenter.default.addObserver(self, selector: #selector(menuWindowDidHide(_:)),
                                               name: UIWindow.didBecomeHiddenNotification, object: nil)
        // Screenshot recovery: iOS 26's full-page capture scrolls the list; snap back afterwards.
        NotificationCenter.default.addObserver(self, selector: #selector(screenshotTaken),
                                               name: UIApplication.userDidTakeScreenshotNotification, object: nil)

        buildDataSource()
    }

    func setLoadingOlder(_ loading: Bool) {
        if loading { topSpinner.startAnimating() } else { topSpinner.stopAnimating() }
    }

    private func buildDataSource() {
        reg = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, id in
            let content = self?.coordinator.parent.row(id) ?? AnyView(EmptyView())
            // PIN the row to the FINAL cell width on its very first layout pass. A freshly configured
            // UIHostingConfiguration lays its SwiftUI out before the cell has its final frame, so Text
            // computed line breaks at a transient narrower width and never re-wrapped â€” the "newest
            // message wraps narrow with empty space until the next send re-renders it" bug. Proposing the
            // known width up-front means the first wrap IS the final wrap.
            let hostW = self?.hostWidth ?? 0
            cell.contentConfiguration = UIHostingConfiguration {
                content
                    .frame(width: hostW > 0 ? hostW : nil)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: RowHeightKey.self, value: g.size.height)
                    })
                    .onPreferenceChange(RowHeightKey.self) { h in
                        self?.reportHeight(h, for: id)
                    }
            }
            .margins(.all, 0)
            cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
        }
        // Native UIKit bubble registration (the migration path).
        uikitReg = UICollectionView.CellRegistration<UIKitBubbleCell, String> { [weak self] cell, _, id in
            guard let self, let m = self.uikitModels[id] else { return }
            cell.configure(m)
            // Safety net: UIKit cells never report a rendered height (they can't drift on their own), but
            // an OFFSCREEN content change can leave a stale cached height. Verify at dequeue â€” one cheap
            // text measure â€” and adopt if the cache drifted.
            //
            // This used to be a jump. It called a reconcile that invalidated the layout and then SKIPPED
            // the offset correction whenever the list was moving, so frames shifted under a fast scroll
            // with nothing holding the reader. It is safe now for a structural reason: adoptHeight routes
            // through the layout, and a row further from the origin than the reader cannot move them at
            // all, which is every row you are scrolling towards in a conversation.
            if let cached = self.heights[id], self.collectionView.bounds.width > 0 {
                let h = UIKitBubbleView.sizes(m, width: self.collectionView.bounds.width).cell.height
                if abs(cached - h) > 2 {
                    DispatchQueue.main.async { [weak self] in self?.adoptHeight(h, for: id) }
                }
            }
        }
        dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) { [weak self] cv, ip, id in
            guard let self else { return UICollectionViewCell() }
            // ROUTER: native UIKit cell when the message is supported (plain 1:1 delivered text), else the
            // SwiftUI hosting cell. Routing reads the FROZEN snapshot dict, never live view state.
            let isUikit = self.uikitModels[id] != nil
            self.configuredRoutes[id] = isUikit
            if isUikit {
                return cv.dequeueConfiguredReusableCell(using: self.uikitReg, for: ip, item: id)
            }
            return cv.dequeueConfiguredReusableCell(using: self.reg, for: ip, item: id)
        }
        // Install section 0 IMMEDIATELY (empty) so the very first layout pass never sees a section-less
        // data source â€” an empty new chat previously reached prepare() with zero sections and crashed.
        var initial = NSDiffableDataSourceSnapshot<Int, String>()
        initial.appendSections([0])
        dataSource.apply(initial, animatingDifferences: false)
    }

    // MARK: - Measurement (pre-measured cell size)

    // Exact height of a row for the given width, measured off-screen.
    private func measure(_ id: String, width: CGFloat) -> CGFloat {
        // Native UIKit bubble: deterministic UIKit measurement (matches the cell's own layout exactly â€”
        // same sizes() function, same frozen model the cell provider will configure with).
        if let m = uikitModels[id], width > 0 {
            return UIKitBubbleView.sizes(m, width: width).cell.height
        }
        // Measure EXACTLY as the cell renders: the cell wraps its content in `.frame(width: hostWidth)`,
        // so the sizer must apply the SAME explicit width frame â€” not just a sizeThatFits width proposal.
        // The two constraint mechanisms wrap Text differently in edge cases, and any disagreement made the
        // layout frame not match the rendered cell â†’ overlap, and a permanent rendered-vs-measured
        // mismatch that reconciled forever.
        sizer.rootView = AnyView(coordinator.parent.row(id).frame(width: width))
        let size = sizer.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        return ceil(size.height)
    }

    // Ensure every id in `ids` has a cached height (measured at the current width). No-op once cached.
    private func measureMissing(_ ids: [String], width: CGFloat) {
        guard width > 0 else { return }
        for id in ids where heights[id] == nil { heights[id] = measure(id, width: width) }
        measuredWidth = width
    }

    // Frame minY per row for an id order â€” exactly what InvertedMessageLayout will produce (y-accumulated
    // heights from the newest). Used to build the before/after maps of the scroll-continuity token.
    private func frameMinY(for ids: [String]) -> [String: CGFloat] {
        var out = [String: CGFloat](minimumCapacity: ids.count)
        var y: CGFloat = 0
        for id in ids {
            out[id] = y
            y += heights[id] ?? 44
        }
        return out
    }

    // Late rendered-height report from a hosted cell.
    private func reportHeight(_ h: CGFloat, for id: String) {
        let hh = ceil(h)
        guard hh > 0 else { return }
        if let old = heights[id] {
            guard abs(old - hh) > 2 else { return }   // ignore sub-pixel noise
        } else {
            heights[id] = hh
            return
        }
        guard didReveal else { return }   // never re-lay-out during the open â€” the pre-measure owns it
        // ROWS THE SIZER CAN NEVER AGREE WITH. A LinkPreviewCard renders nothing until an async fetch
        // completes, while measure() is synchronous â€” so for any message containing a link the sizer is
        // permanently short and the rendered height NEVER matches. Left alone, such a row re-armed the
        // settle machinery on every single dequeue. Once the sizer has refused a row, stop asking it.
        if sizerRefused.contains(id) { return }
        guard canLandLoad else { needsRefreshOnSettle = true; pendingSettleHeights.insert(id); return }
        // The rendered report is only a SIGNAL that something changed â€” the SIZER is the single height
        // authority. (Adopting the rendered value here while the apply path adopts the sizer value made
        // two authorities fight: any row where they disagreed by more than 2pt reconciled back and forth
        // forever, invalidating the layout mid-scroll = overlapping bubbles.)
        let w = collectionView.bounds.width
        guard w > 0 else { return }
        let sized = measure(id, width: w)
        // The sizer disagrees with what was actually rendered and will keep doing so. Record it once so
        // the loop above never re-arms for this row again.
        if abs(sized - hh) > 2 { sizerRefused.insert(id) }
        adoptHeight(sized, for: id)
    }

    // MARK: - The single position owner

    // ADOPT A NEW HEIGHT FOR ONE ROW, KEEPING THE READER STILL.
    //
    // This is the only path by which a height changes after a row has been measured, and it is the whole
    // late-height story: there is no second mechanism, no capture/restore, no post-hoc setContentOffset.
    //
    // The correction rides `contentOffsetAdjustment` on the invalidation context, so it lands in the same
    // layout transaction as the frame change â€” never a frame late. And because the list is inverted, the
    // delta is ZERO unless the changed row lies BETWEEN the coordinate origin and the reader, which means
    // between the newest message and where they are reading. A row older than the reader â€” every row a
    // history reader is scrolling towards, and every row a page-in brings â€” moves nothing at all.
    private func adoptHeight(_ h: CGFloat, for id: String) {
        guard collectionView.bounds.height > 0, let cached = heights[id], abs(cached - h) > 2 else { return }
        guard canLandLoad else {
            pendingSettleHeights.insert(id)
            needsRefreshOnSettle = true
            return
        }
        let beforeY = frameMinY(for: currentIds)
        heights[id] = h
        let afterY = frameMinY(for: currentIds)
        layout.generation += 1
        let anchor = continuityAnchor()
        let delta = anchor.flatMap { a -> CGFloat? in
            guard let b = beforeY[a.id], let f = afterY[a.id] else { return nil }
            return f - b
        } ?? 0
        let ctx = UICollectionViewLayoutInvalidationContext()
        if delta != 0 { ctx.contentOffsetAdjustment = CGPoint(x: 0, y: delta) }
        layout.invalidateLayout(with: ctx)
        collectionView.layoutIfNeeded()
        if delta != 0 { verifyAnchor(anchor) }
    }

    // The row the reader's position is measured against: the visible row CLOSEST TO THE ORIGIN, i.e. the
    // lowest one on screen. Everything between it and the origin is content that has already been
    // rendered, so a delta computed against it is a delta over known-good heights.
    //
    // A cascade rather than a single pick, so a row that is deleted or trimmed in the same update falls
    // through to the next candidate instead of giving up.
    private func continuityAnchors() -> [Anchor] {
        viewportIndexPaths().prefix(6).compactMap { ip -> Anchor? in
            guard let id = dataSource.itemIdentifier(for: ip),
                  let attr = collectionView.layoutAttributesForItem(at: ip) else { return nil }
            return Anchor(id: id, distanceFromOrigin: attr.frame.minY - collectionView.contentOffset.y)
        }
    }
    private func continuityAnchor() -> Anchor? {
        continuityAnchors().first
    }

    // Where one row sat, measured from the coordinate origin. The whole "keep the reader still" contract
    // is expressed in this one value: put that row back at that distance and nothing has moved.
    private struct Anchor {
        let id: String
        let distanceFromOrigin: CGFloat
    }

    // THE ONLY VERIFICATION NET IN THE FILE, and the only place outside a declared scroll intent that
    // writes contentOffset. It runs after a land that carried a non-zero adjustment, which in the inverted
    // model means only "a new message arrived while you were reading history". It never runs during a
    // healthy scroll and it never runs when the adjustment was zero, which is the overwhelming majority of
    // updates. A live finger is excluded because a pan re-derives the offset from its own baseline every
    // tick and would visibly fight a correction.
    private func verifyAnchor(_ anchor: Anchor?) {
        guard let anchor,
              !collectionView.isDragging, !collectionView.isTracking, !collectionView.isDecelerating,
              let ip = dataSource.indexPath(for: anchor.id),
              let attr = layout.layoutAttributesForItem(at: ip) else { return }
        let want = clampOffset(attr.frame.minY - anchor.distanceFromOrigin)
        if abs(collectionView.contentOffset.y - want) > 2 {
            collectionView.setContentOffset(CGPoint(x: 0, y: want), animated: false)
            lastStableOffset = want
        }
    }

    // MARK: - Scroll intents
    //
    // Every deliberate move of the reader is one of these three. Nothing else in this file is allowed to
    // write contentOffset (the sole exception is verifyAnchor above, which enforces the reader NOT moving).
    // Each intent states what it wants, and one shared rule decides whether it may happen â€” instead of
    // fifteen call sites each inventing their own guard, which is how four unrelated bugs produced one
    // symptom.
    private enum ScrollIntent {
        case newest(animated: Bool)   // jump-to-latest button, own send, first open with nothing unread
        case message(String)          // reply / search jump to a specific row
        case initialPosition          // the very first landing, before the list is visible
    }

    // The one safety rule: never move the reader while their finger is on the glass. Deceleration is
    // deliberately NOT included (Signal tracks it separately): a fling that is still coasting toward the
    // newest message should absolutely end up there. The first landing happens before the list is even
    // visible, so it is never gated.
    private func perform(_ intent: ScrollIntent) {
        switch intent {
        case .newest(let animated):
            guard didFirstLand, !isUserScrolling else { return }
            scrollToOffset(minContentOffsetY, animated: animated)
        case .message(let id):
            guard let ip = dataSource.indexPath(for: id),
                  let attr = collectionView.layoutAttributesForItem(at: ip) else { return }
            // Centre-if-not-entirely-on-screen: when the target row is already fully visible, don't move
            // at all â€” repeated next/prev taps between two on-screen results then feel stable instead of
            // re-centering the list on every tap.
            let visible = CGRect(x: 0,
                                 y: collectionView.contentOffset.y + collectionView.adjustedContentInset.top,
                                 width: collectionView.bounds.width,
                                 height: collectionView.bounds.height
                                    - collectionView.adjustedContentInset.top
                                    - collectionView.adjustedContentInset.bottom)
            if visible.contains(attr.frame) { return }
            scrollToOffset(clampOffset(attr.frame.midY - collectionView.bounds.height / 2), animated: true)
        case .initialPosition:
            // With nothing unread the answer needs no measurement at all: the newest message is at the
            // coordinate origin by construction, so the first open is exact before a single height is
            // known. This is the one line that replaced the whole measure-everything-then-land-then-
            // re-land-then-reveal open sequence.
            guard let target = initialScrollId,
                  let ip = dataSource.indexPath(for: target),
                  let attr = layout.layoutAttributesForItem(at: ip) else {
                collectionView.setContentOffset(CGPoint(x: 0, y: minContentOffsetY), animated: false)
                lastStableOffset = minContentOffsetY
                return
            }
            // First unread near the VISUAL TOP, with 12pt of breathing room under the nav bar. Under the
            // flip the visual top of the viewport is the far edge of the visible content rect.
            let visualTopInset = collectionView.adjustedContentInset.bottom
            let y = clampOffset(attr.frame.maxY - collectionView.bounds.height + visualTopInset + 12)
            collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
            lastStableOffset = y
        }
    }

    private func scrollToOffset(_ y: CGFloat, animated: Bool) {
        let target = clampOffset(y)
        guard abs(collectionView.contentOffset.y - target) > 0.5 else { return }
        lastStableOffset = target
        if animated {
            scrollingAnimationDidStart()   // lands defer until the glide completes
            collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: true)
        } else {
            collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: false)
        }
    }

    // MARK: - Land-when-safe
    //
    // Signal's actual gate (CVLoadCoordinator.loadLandWhenSafe â†’ canLandLoad, read from their source
    // 2026-07-27). Note what is NOT in it: isDragging, isTracking, isDecelerating. Loads land WHILE your
    // finger is down; the reader is kept still by the layout, not by refusing the work.
    //
    // The one place we used to diverge â€” a PREPEND waited for the finger to lift, because a page-in
    // shifted every visible frame and we could not prove UIScrollView would honour the adjustment under a
    // live pan â€” is GONE. Inverted, a page-in does not move a visible frame at all, so there is nothing to
    // hold back and nothing left to prove.
    private var canLandLoad: Bool {
        if keyboardAnimating, selectionAnimationState != .willAnimate { return false }
        if selectionAnimationState == .animating { return false }
        // Signal's `contextMenuVisible`, from UIKit's own callbacks. NO selection exception here: the land
        // that opens selection mode is exactly the one that must wait, because it reloads the cell the
        // menu is animating back into.
        if contextMenuVisible { return false }
        // The same rule for SWIFTUI-presented menus, which UIKit's callbacks cannot see â€” the action
        // closure marks this window as its menu starts dismissing (see noteMenuActionTick).
        if Date() < menuDismissGraceUntil { return false }
        // Belt to the same braces, covering the press before UIKit decides a menu is happening.
        if Date() < interactionHoldUntil { return false }
        // Our send glide and any programmatic animated scroll.
        if sendAnimating || programmaticScrollAnimating { return false }
        // A reply swipe owns its cell's transform; a relayout under it moves the thing being dragged.
        if swipingCell != nil { return false }
        // The system's full-page screenshot capture scrolls the list programmatically with no drag flags.
        if Date() < captureFreezeUntil { return false }
        return true
    }

    // Signal's `viewState.isUserScrolling`: FINGER DOWN ONLY. Deceleration is tracked separately and
    // deliberately does not count.
    private var isUserScrolling: Bool { collectionView.isDragging || collectionView.isTracking }

    private func scrollingAnimationDidStart() {
        programmaticScrollAnimating = true
        scrollAnimationWatchdog?.invalidate()
        scrollAnimationWatchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            self?.scrollingAnimationDidComplete()
        }
    }

    private func scrollingAnimationDidComplete() {
        scrollAnimationWatchdog?.invalidate()
        scrollAnimationWatchdog = nil
        programmaticScrollAnimating = false
        settleFlush()
        autoLoadMoreIfNeeded()
    }

    // Flush whatever was blocked by a genuine animation (see canLandLoad) once that animation ends.
    // Loads do not come through here â€” they retry on their own tight loop â€” so what is left is the tail of
    // work that a keyboard, selection, context-menu or send animation legitimately held back.
    private func settleFlush() {
        guard canLandLoad else { return }
        if let pending = pendingIdsApply {
            pendingIdsApply = nil
            apply(rowIds: pending, scrollTarget: nil)
            // The land may have STARTED an animation (send glide) â€” continuing into the reconfigure work
            // below would land content mid-animation, the exact violation the gate exists to prevent.
            guard canLandLoad else { return }
        }
        guard needsRefreshOnSettle else { return }
        needsRefreshOnSettle = false
        // A DEFERRED SELECTION FLIP MUST FLUSH AS A SELECTION FLIP. This path used to run only the
        // signature diff â€” and entering selection changes no row's CONTENT signature, so the deferred
        // every-cell reload silently became a no-op: the gate correctly held the land back and the flush
        // then dropped it, leaving `.willAnimate` stuck and the checkboxes missing until the next
        // unrelated land. Mirror apply()'s selection branch here.
        if selectionAnimationState == .willAnimate {
            beginSelectionAnimationWindow()
            lastRowSigs = rowSignatures
            pendingSettleHeights.removeAll()
            let live = collectionView.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) }
            if !live.isEmpty { refreshVisible(live) }
            return
        }
        let visible = collectionView.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) }
        let changed = visible.filter { rowSignatures[$0] != lastRowSigs[$0] }   // content changes
        lastRowSigs = rowSignatures
        let heightIds = pendingSettleHeights                                    // late height reports
        pendingSettleHeights.removeAll()
        let target = Array(Set(changed).union(heightIds))
        guard !target.isEmpty else { return }
        refreshVisible(target)
    }

    // Split ids into (reconfigure, reload): a row whose RENDER ROUTE flipped since it was last configured
    // (uikit â†” SwiftUI â€” e.g. a plain text message gained a reaction) must be RELOADED so the other cell
    // class is dequeued; reconfigureItems reuses the same cell instance, which can't switch renderers.
    private func splitByRouteFlip(_ ids: [String]) -> (reconfigure: [String], reload: [String]) {
        var reconf: [String] = [], reload: [String] = []
        for id in ids {
            let newRoute = uikitModels[id] != nil
            if let old = configuredRoutes[id], old != newRoute { reload.append(id) } else { reconf.append(id) }
        }
        return (reconf, reload)
    }

    // Re-measure + reconfigure on-screen rows whose content changed, then let the layout absorb any height
    // change with the reader held still.
    //
    // WHILE THE LIST IS MOVING, ONLY ROWS INSIDE THE VIEWPORT ARE TOUCHED, and that is a correctness rule
    // rather than an optimisation. The anchor is the visible row nearest the origin, so a height change on
    // any row the reader can actually see produces a delta of exactly zero: rows above it grow away from
    // them, and the anchor's own frame origin does not move. A row BELOW the viewport is the only one that
    // can shift the reader, it is not on screen, and there is nothing to gain by landing it under a moving
    // finger. Those wait for the settle, where the correction is atomic and verified.
    private func refreshVisible(_ subset: [String]? = nil) {
        let width = collectionView.bounds.width
        let listIsMoving = collectionView.isDragging || collectionView.isTracking || collectionView.isDecelerating
        let reachable = listIsMoving
            ? viewportIndexPaths().compactMap { dataSource.itemIdentifier(for: $0) }
            : collectionView.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) }
        let reachableSet = Set(reachable)
        var target = subset.map { s in s.filter(reachableSet.contains) } ?? reachable
        if listIsMoving, let subset {
            // Park what we deliberately skipped so it is not silently dropped.
            let skipped = subset.filter { !reachableSet.contains($0) }
            if !skipped.isEmpty {
                skipped.forEach { pendingSettleHeights.insert($0) }
                needsRefreshOnSettle = true
            }
        }
        target = target.filter { currentIds.contains($0) }
        guard !target.isEmpty else { return }
        // Before-map first: any of these measurements may change a height, and the correction has to be
        // computed against the frames as they stand right now.
        let beforeY = frameMinY(for: currentIds)
        let anchor = continuityAnchor()
        var heightChanged = false
        if width > 0 {
            for id in target {
                let h = measure(id, width: width)
                if let old = heights[id], abs(old - h) <= 2 { continue }
                heights[id] = h
                heightChanged = true
            }
        }
        var snapshot = dataSource.snapshot()
        // Filter against the SNAPSHOT, not against `currentIds`. Both reconfigureItems and reloadItems
        // abort the app on an identifier the snapshot does not hold, and `currentIds` is our own array â€”
        // it is assigned before the data source's async apply completes, so the two disagree for a
        // window. The snapshot in hand is the only thing that can answer this without a race. Same guard
        // reflowInserted already uses; the crash on delete proved the apply path needed it too.
        let present = Set(snapshot.itemIdentifiers)
        let split = splitByRouteFlip(target.filter(present.contains))
        if !split.reconfigure.isEmpty { snapshot.reconfigureItems(split.reconfigure) }
        if !split.reload.isEmpty { snapshot.reloadItems(split.reload) }
        var delta: CGFloat = 0
        if heightChanged {
            layout.generation += 1
            let afterY = frameMinY(for: currentIds)
            if let a = anchor, let b = beforeY[a.id], let f = afterY[a.id] { delta = f - b }
            if delta != 0 { layout.pendingContentOffsetAdjustment = delta }
        }
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self else { return }
            self.layout.pendingContentOffsetAdjustment = 0
            if delta != 0 { self.verifyAnchor(anchor) }
        }
    }

    // MARK: - Apply

    // The box a load waits in when it cannot land yet. It holds ONE set of ids â€” the latest â€” so a burst
    // of Firestore emissions collapses into a single land instead of a queue of stale ones.
    private var pendingIdsApply: [String]?

    /// Signal's retry loop: `asyncAfter` takes longer than `async` under load, which is what you want here
    /// â€” it backs off exactly when the CPU is busy. The load lands the instant the block clears.
    private func scheduleLandRetry() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.001) { [weak self] in
            guard let self, let pending = self.pendingIdsApply else { return }
            self.pendingIdsApply = nil
            self.apply(rowIds: pending, scrollTarget: nil)   // re-parks itself if it still cannot land
        }
    }

    func apply(rowIds rawIds: [String], scrollTarget: String? = nil) {
        // LAST LINE OF DEFENCE, AND IT IS NOT OPTIONAL. `appendItemsWithIdentifiers:` throws on a repeated
        // identifier and the throw is an abort â€” the app is gone, mid-scroll, with no recovery. The repo
        // guarantees uniqueness upstream, but this is a boundary into UIKit and a crash is far worse than
        // a dropped row, so the invariant is enforced here too rather than trusted.
        var seen = Set<String>()
        seen.reserveCapacity(rawIds.count)
        let unique = rawIds.filter { seen.insert($0).inserted }
        #if DEBUG
        if unique.count != rawIds.count {
            let dupes = Set(rawIds).filter { id in rawIds.filter { $0 == id }.count > 1 }
            assertionFailure("Duplicate rowIds reached the list: \(dupes.sorted())")
        }
        #endif
        // THE ONE REVERSAL. Everything below thinks in layout order: index 0 is the newest message.
        let ids = Array(unique.reversed())
        let width = collectionView.bounds.width

        if didFirstLand, ids != currentIds, scrollTarget == nil, !canLandLoad {
            let wasWaiting = pendingIdsApply != nil
            pendingIdsApply = ids
            if !wasWaiting { scheduleLandRetry() }
            return
        }
        pendingIdsApply = nil       // an immediate land supersedes anything deferred (ids are the latest)

        guard ids != currentIds else {
            // A jump with no data change (target already in the loaded window).
            if let target = scrollTarget { performScrollTarget(target) }
            // THE GATE COMES FIRST, INCLUDING FOR THE SELECTION LAND. It used to sit below the selection
            // branch, so entering selection mode was the one update that bypassed every block â€” and it is
            // the single most destructive one to let through, because selection routes every row to the
            // SwiftUI cell and therefore RELOADS every visible cell. Landing that while a context menu is
            // dismissing destroys the cell the menu is animating back into. (Motion is not a reason to
            // defer anything any more, so the exception it was written for no longer exists.)
            guard canLandLoad else {
                needsRefreshOnSettle = true
                // THE CHECKBOXES DO NOT HAVE TO WAIT FOR THE WHOLE MENU (user: "checkbox is coming
                // late", three times). Selection was blocked wholesale until the context menu had
                // finished dismissing, because reloading the cell the menu is animating BACK INTO
                // strands the system's blur. That is true of exactly ONE cell — the source. Every
                // other visible row can take its checkbox right now, while the menu is still fading,
                // which is what Signal looks like: their selection UI appears with the dismissal, not
                // after it. The source row fills in a beat later when the animator completes.
                if selectionAnimationState == .willAnimate { refreshSelectionExceptMenuSource() }
                return
            }
            // Selection flip: refresh EVERY live cell, not the signature-diffed subset. Entering or
            // leaving selection changes the render route of every row at once, so a per-row diff is just a
            // slower way of reaching the same answer â€” and any row the diff misses keeps its checkbox
            // after you have left selection mode.
            if selectionAnimationState == .willAnimate {
                beginSelectionAnimationWindow()
                lastRowSigs = rowSignatures
                let live = collectionView.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) }
                if !live.isEmpty { refreshVisible(live) }
                return
            }
            // Same rows, SwiftUI state changed (reaction added/removed, edit, media loaded, read tick).
            // A read tick arriving while you scroll reconfigures its row there and then; any height change
            // it causes goes through the layout, so it cannot move the reader.
            // Reconfigure ONLY the visible rows whose CONTENT signature changed since the last apply â€”
            // NOT every visible cell on every SwiftUI re-render. ThreadView's body re-runs constantly on
            // presence/typing/read churn with the SAME row content; reconfiguring all visible cells each
            // time re-rendered every bubble = the flashing.
            let visible = collectionView.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) }
            let changed = visible.filter { rowSignatures[$0] != lastRowSigs[$0] }
            lastRowSigs = rowSignatures
            guard !changed.isEmpty else { return }
            refreshVisible(changed)
            return
        }

        // WHAT KIND OF CHANGE IS THIS, in layout order.
        //
        // `newlyNewest` is the count of rows added at the FRONT (index 0), which is a sent or received
        // message. Those are the only rows that can move the reader, because they are the only ones
        // between the origin and the viewport.
        //
        // Rows added at the BACK are paged-in history. They are deliberately not detected, counted or
        // classified anywhere: appending beyond the far edge of the content is invisible to the reader by
        // construction, so there is no case to handle. The old file's isAppend/isPrepend pair â€” which
        // silently classified a mixed batch (history AND a new message in one Firestore emission) as
        // NEITHER, skipping the join re-measure and mis-firing the pin â€” has no counterpart here.
        let oldSet = Set(currentIds)
        let newlyNewest = ids.prefix(while: { !oldSet.contains($0) }).count
        let wasAtNewest = isAtNewest

        // Content changes that BATCH with an ids change (a reaction or read-tick arriving in the same repo
        // emission as a new message â€” constant with Firestore listener batches) must still reconfigure:
        // diffable apply does NOT touch rows present in both snapshots, and they would be left stale.
        // CRASH FIX (.ips 2026-07-28-181456, SIGABRT on deleting a message). UIKit named it with no
        // symbolication needed: `-[__UIDiffableDataSourceSnapshot reconfigureItemsWithIdentifiers:]` â†’
        // `_validateReloadUpdateThrowingIfNeeded:` â†’ `objc_exception_throw` â†’ abort.
        //
        // reconfigureItems THROWS if an identifier is not in the snapshot, and the snapshot being built
        // below holds the NEW ids. This filtered against `oldSet` â€” the ids as they were BEFORE the
        // update â€” so a deleted message passed the filter, was handed to reconfigureItems, and was not
        // there. My regression, introduced when the list was inverted: the original filtered on `ids`,
        // and I swapped it to `oldSet` while rewriting around it.
        //
        // It must be BOTH: present in the new snapshot (or the reconfigure aborts the app) and changed
        // since the last apply (or every visible bubble re-renders on every emission â€” the flashing).
        let newSet = Set(ids)
        let liveIds = collectionView.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) }
        let contentChanged = liveIds.filter { newSet.contains($0) && rowSignatures[$0] != lastRowSigs[$0] }
        lastRowSigs = rowSignatures

        // Radar 28167779: settle any dirty layout against the OLD data BEFORE mutating heights/ids â€” a
        // dirty layout preparing after the mutation would mix old counts with new heights.
        collectionView.layoutIfNeeded()
        let beforeY = frameMinY(for: currentIds)
        let anchors = continuityAnchors()

        measureMissing(ids, width: width)   // exact heights BEFORE the layout prepares (no self-size correction)
        for id in contentChanged { heights[id] = measure(id, width: width) }
        // THE DATE-SEPARATOR JOIN. Date pills and cluster spacing are baked into the message row, and
        // ThreadView computes them from the CHRONOLOGICAL index â€” so the oldest loaded row always carries
        // a date pill, and paging history takes it away from the row that used to be oldest. That row's
        // height genuinely changes.
        //
        // In the old top-down list this was a bug: the stale height fed the offset compensation, which was
        // then wrong by that amount and corrected a frame late â€” the small jump when older messages
        // landed. Here the same rows are at the FAR END of the layout, past everything the reader can see,
        // so a stale height there cannot move anyone. It is re-measured purely so the row RENDERS
        // correctly. (Modelling the separator as its own list item, the way Signal does, would remove even
        // this; it is no longer urgent.)
        let keep = newSet
        if currentIds.last != ids.last {   // the oldest loaded row changed â†’ the join moved
            for id in currentIds.suffix(3) where keep.contains(id) {
                heights[id] = measure(id, width: width)
            }
        }
        if !oldSet.isSubset(of: keep) {   // rows left (trim/delete): drop their caches
            heights = heights.filter { keep.contains($0.key) }
            configuredRoutes = configuredRoutes.filter { keep.contains($0.key) }
            sizerRefused = sizerRefused.filter { keep.contains($0) }
        }
        let afterY = frameMinY(for: ids)

        if selectionAnimationState == .willAnimate { beginSelectionAnimationWindow() }

        // THE CONTINUITY DELTA. One formula for every kind of change â€” insert, delete, trim, height
        // change, or any mixture: how far did the reader's anchor row move? Because the anchor is the
        // visible row nearest the origin, this only ever sums rows NEWER than the reader. Paging history
        // leaves every term untouched and the delta comes out exactly zero, which is the entire point of
        // the rewrite: the common case is not compensated correctly, it is not compensated at all.
        var adjustment: CGFloat = 0
        var landedAnchor: Anchor?
        if !wasAtNewest {
            for a in anchors {
                if let b = beforeY[a.id], let f = afterY[a.id] { adjustment = f - b; landedAnchor = a; break }
            }
        }

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids, toSection: 0)
        if !contentChanged.isEmpty {
            let split = splitByRouteFlip(contentChanged)
            if !split.reconfigure.isEmpty { snapshot.reconfigureItems(split.reconfigure) }
            if !split.reload.isEmpty { snapshot.reloadItems(split.reload) }
        }
        currentIds = ids
        layout.generation += 1   // ids/heights changed â†’ next prepare() rebuilds frames

        if !didFirstLand {
            dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
                self?.performFirstLandIfReady()
            }
            return
        }

        // THE SEND / RECEIVE GLIDE. At the newest message a new row inserts at the origin, which shifts
        // everything else away and would simply appear, instantly. To keep the glide the list has always
        // had, hold the reader where they are for one frame (an adjustment equal to what was inserted,
        // exactly the same mechanism continuity uses) and then animate back to the origin, so the list
        // slides up to reveal the new bubble. The bubble itself never animates â€” only the scroll does.
        let insertedHeight = ids.prefix(newlyNewest).reduce(CGFloat(0)) { $0 + (heights[$1] ?? 0) }
        let glide = wasAtNewest && newlyNewest == 1 && scrollTarget == nil && !isUserScrolling
        if glide {
            adjustment = insertedHeight
            sendAnimating = true
        }
        if adjustment != 0 { layout.pendingContentOffsetAdjustment = adjustment }

        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self else { return }
            self.layout.pendingContentOffsetAdjustment = 0   // never let the fallback channel go stale
            self.lastStableOffset = self.collectionView.contentOffset.y
            if let target = scrollTarget {
                self.performScrollTarget(target)
            } else if glide {
                self.collectionView.layoutIfNeeded()
                self.perform(.newest(animated: true))
                // If the animated scroll produces no end-callback (already exactly at the origin), clear
                // the gate so coalesced refreshes still flush.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    guard let self, self.sendAnimating else { return }
                    self.sendAnimating = false
                    self.settleFlush()
                }
            } else if adjustment != 0 {
                // A new message landed while the reader is in history. The layout has already held them
                // still; this is the one net that checks it actually happened.
                self.collectionView.layoutIfNeeded()
                self.verifyAnchor(landedAnchor)
            }
            // Post-land auto-load re-check, async so it is never re-entrant inside the land: a short page
            // can leave the reader still within the load threshold.
            DispatchQueue.main.async { [weak self] in self?.autoLoadMoreIfNeeded() }
        }

        // Re-flow the just-inserted bubble at its FINAL cell width. UIHostingConfiguration lays a freshly
        // inserted cell's SwiftUI out at the pre-final width and does NOT re-flow it until a later update
        // â€” that's the "newest bubble wraps narrow until the next message" bug.
        if newlyNewest > 0 {
            let inserted = Array(ids.prefix(newlyNewest))
            DispatchQueue.main.async { [weak self] in self?.reflowInserted(inserted) }
        }
    }

    /// Land the selection flip on every visible row EXCEPT the one the context menu lifted from, so the
    /// checkboxes appear immediately instead of after the menu's dismissal. The source row is left
    /// alone — destroying it mid-flight is what stranded the blur — and is refreshed by the normal
    /// settle once the animator completes. `selectionAnimationState` deliberately stays `.willAnimate`
    /// so that later pass still runs and picks the source row up.
    private func refreshSelectionExceptMenuSource() {
        let live = collectionView.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) }
        let target = live.filter { $0 != contextMenuSourceId }
        guard !target.isEmpty else { return }
        refreshVisible(target)
    }

    private func beginSelectionAnimationWindow() {
        selectionAnimationState = .animating
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.selectionAnimationState = .idle
            self?.settleFlush()
        }
    }

    private func performScrollTarget(_ target: String) {
        // Sentinel: the scroll-to-latest button and an own send while scrolled up route here.
        if target == "BOTTOM" { perform(.newest(animated: true)) } else { perform(.message(target)) }
    }

    private func reflowInserted(_ ids: [String]) {
        // Dispatched one runloop after apply â€” squarely inside the send glide: a reconfigure plus a height
        // mutation mid-animation renders new-height content in old frames. Defer; pendingSettleHeights
        // re-measures exactly these rows when the glide ends.
        guard canLandLoad else {
            ids.forEach { pendingSettleHeights.insert($0) }
            needsRefreshOnSettle = true
            return
        }
        var snap = dataSource.snapshot()
        let present = ids.filter { snap.itemIdentifiers.contains($0) }
        guard !present.isEmpty, collectionView.bounds.width > 0 else { return }
        // ONE-SHEET RULE: reconfigure ONLY the rows whose height actually changed. Plain text lands at its
        // final wrap already (the hostWidth pin makes the first wrap the final wrap), so reconfiguring it
        // here just re-rendered the new bubble alone one beat after it appeared.
        let beforeY = frameMinY(for: currentIds)
        let anchor = continuityAnchor()
        var changed: [String] = []
        for id in present {
            let h = measure(id, width: collectionView.bounds.width)
            if let old = heights[id], abs(old - h) <= 2 { continue }
            heights[id] = h
            changed.append(id)
        }
        guard !changed.isEmpty else { return }
        layout.generation += 1
        // These rows are at the origin end of the list, so unlike every other late height change they CAN
        // move a reader who is up in history. Same one mechanism: the delta rides the update, the net
        // checks it at rest.
        let afterY = frameMinY(for: currentIds)
        var delta: CGFloat = 0
        if let a = anchor, let b = beforeY[a.id], let f = afterY[a.id] { delta = f - b }
        if delta != 0 { layout.pendingContentOffsetAdjustment = delta }
        snap.reconfigureItems(changed)
        dataSource.apply(snap, animatingDifferences: false) { [weak self] in
            guard let self else { return }
            self.layout.pendingContentOffsetAdjustment = 0
            if delta != 0 { self.verifyAnchor(anchor) }
        }
    }

    // MARK: - First landing

    // The first open. Rows are still measured before the first frame is drawn â€” that is what stops the
    // open from shaking, and it was never the problem. What is gone is the position dance around it: the
    // old file landed at the bottom, re-landed a runloop later as a "belt-and-suspenders guard", held a
    // pendingBottomOnOpen window that suppressed half the file's other logic, and re-pinned on every layout
    // pass until it closed â€” all because the bottom was a number derived from the total height of
    // everything, so it moved whenever a measurement landed. The newest message is at the origin, so there
    // is one landing and it is exact.
    private func performFirstLandIfReady() {
        guard !didFirstLand,
              collectionView.bounds.width > 0, collectionView.bounds.height > 0,
              !currentIds.isEmpty else { return }
        // The landing offset is -contentInset.top, so the insets must be current BEFORE we land. Now that
        // we own them outright (contentInsetAdjustmentBehavior = .never) nothing else will have set them
        // for us, and the composer height and safe area can both arrive after the first apply.
        updateInsets()
        measureMissing(currentIds, width: collectionView.bounds.width)
        layout.generation += 1
        layout.invalidateLayout()
        collectionView.layoutIfNeeded()
        didFirstLand = true
        perform(.initialPosition)
        DispatchQueue.main.async { [weak self] in self?.reveal() }
    }

    private func reveal() {
        guard !didReveal, collectionView.bounds.height > 0 else { return }
        didReveal = true
        collectionView.alpha = 1
        // First frame is on screen â€” from here on, keep an extra viewport of rows rendered on each side so
        // scrolling always reveals already-rendered bubbles (the connected-sheet feel).
        layout.overdrawEnabled = true
        DispatchQueue.main.async { [weak self] in self?.layout.invalidateLayout() }
    }

    // Empty on first layout (cold decrypt in flight): reveal WITH content if it lands within ~0.6s (via
    // the normal open path), else reveal the empty state so the composer still shows.
    private func scheduleEmptyReveal() {
        guard !scheduledEmptyReveal else { return }
        scheduledEmptyReveal = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, !self.didReveal else { return }
            self.reveal()
        }
    }

    // MARK: - Geometry helpers

    // Index paths of cells actually INSIDE the viewport, in LAYOUT order â€” so `.first` is the row nearest
    // the origin (visually the LOWEST on screen) and `.last` is the visually topmost. The layout keeps an
    // extra viewport of cells alive on each side for the pre-render, so indexPathsForVisibleItems includes
    // off-screen rows; anchors and the date pill must never pick one of those.
    private func viewportIndexPaths() -> [IndexPath] {
        collectionView.indexPathsForVisibleItems
            .filter { ip in
                guard let f = collectionView.layoutAttributesForItem(at: ip)?.frame else { return false }
                return f.maxY > collectionView.bounds.minY && f.minY < collectionView.bounds.maxY
            }
            .sorted()
    }

    private var minContentOffsetY: CGFloat { -collectionView.adjustedContentInset.top }
    private var maxContentOffsetY: CGFloat {
        max(minContentOffsetY,
            collectionView.contentSize.height + collectionView.adjustedContentInset.bottom - collectionView.bounds.height)
    }
    private func clampOffset(_ y: CGFloat) -> CGFloat { min(max(minContentOffsetY, y), maxContentOffsetY) }

    // AT THE NEWEST MESSAGE. Note what this does NOT read: contentSize. In the top-down list the same
    // question was `maxContentOffsetY - contentOffset.y <= 44`, which depended on the total height of
    // every loaded row and on both insets â€” so a keyboard fold could drop the maximum by the keyboard's
    // height and make a reader scrolled far up measure a large NEGATIVE distance and answer "yes, at the
    // bottom", which then yanked them down. Here the newest message is at a fixed coordinate and the
    // question is just "are we there". It cannot be wrong. 5pt is Signal's tolerance.
    private var isAtNewest: Bool { collectionView.contentOffset.y <= minContentOffsetY + 5 }

    /// AT REST, THE READER CAN NEVER BE BEYOND THE NEWEST MESSAGE. This is the invariant the keyboard
    /// close kept violating (Pro Max / iOS 27 report, and it was never really about the screen size).
    ///
    /// `minContentOffsetY` is `-adjustedContentInset.top`, and under the flip that inset CONTAINS the
    /// bottom safe area — which is the keyboard while it is up. A reader sitting exactly at the newest
    /// message with the keyboard up is at offset `-(composer + 12 + keyboardHeight)`. When the keyboard
    /// leaves, that inset shrinks by the keyboard's height, so the SAME offset is now ~250-300pt BELOW
    /// the new bound: the list is parked in its bottom bounce region and the last bubble sits under the
    /// composer. Nothing pulls it back on its own, because the finger is not there to end a drag.
    ///
    /// Why the existing corrections missed it: `updateInsets()` deliberately stands down while the list
    /// is moving ("never fight the finger") — and `keyboardDismissMode = .interactive` means dismissing
    /// the keyboard by dragging IS a live drag, for the whole time the inset is shrinking. The
    /// keyboardDidHide settle then fixed it a beat later, which is exactly the "jumps back after about a
    /// second" the user sees. On the smaller device the timings happened to line up so a layout pass
    /// landed the correction first; that is luck, not correctness.
    ///
    /// So instead of another timing-shaped patch, state the invariant and enforce it wherever the list
    /// comes to rest. Being beyond the newest bound at rest is never a legitimate state: it is the
    /// bounce region, which only exists while a finger or a fling owns the list.
    private func clampToNewestIfBeyond() {
        guard didFirstLand, !isDisappearing,
              !collectionView.isTracking, !collectionView.isDragging, !collectionView.isDecelerating,
              !sendAnimating, !programmaticScrollAnimating else { return }
        let bound = minContentOffsetY
        guard collectionView.contentOffset.y < bound - 0.5 else { return }
        UIView.performWithoutAnimation {
            collectionView.setContentOffset(CGPoint(x: 0, y: bound), animated: false)
        }
    }
    // The looser test, for the jump-to-latest BUTTON only: an affordance, not a decision about moving
    // someone. Deliberately separate so the two can never be confused again.
    private var isNearNewest: Bool { collectionView.contentOffset.y <= minContentOffsetY + 44 }

    // MARK: - Insets

    // Under the flip, contentInset.top is the VISUAL BOTTOM (where the composer is) and contentInset.bottom
    // is the VISUAL TOP (where the nav bar and any pinned-message bar are).
    //
    // Both totals are assembled here, from this controller's own untransformed `view.safeAreaInsets` plus
    // the one thing UIKit cannot know (the SwiftUI composer bar's height). They come to exactly what the
    // top-down list produced when UIKit folded the safe area for us:
    //
    //   visual bottom = safe.bottom + composerBar + 12   home indicator, or the keyboard when it is up,
    //                                                    then the bar riding on top of it, then Signal's
    //                                                    small gap so the last bubble clears the pills
    //   visual top    = safe.top + pinned bar            status bar + nav bar, plus the pin bar if shown
    //
    // The list is full-bleed under both bars (ThreadView ignores the container safe area), which is why the
    // composer's height has to be added by hand â€” its own safe-area inset is not folded in for us.
    //
    // In the top-down list an inset write MOVED THE DESTINATION: "the bottom" was derived from the total
    // content height plus both insets, so growing the composer changed where the newest message belonged
    // and every writer needed its own re-pin. The newest message is now at a fixed coordinate that no
    // inset can move. What is left is two cases, both stated once, both at rest: a reader who is AT the
    // newest message follows the clearance so the last bubble stays just above the composer, and a reader
    // in history does not move at all.
    private func updateInsets() {
        guard isViewLoaded, !isDisappearing else { return }
        if let pop = navigationController?.interactivePopGestureRecognizer {
            switch pop.state { case .possible, .failed: break; default: return }
        }
        // UNDO UIKIT'S SWAP, WITHOUT TAKING THE INSETS OVER.
        //
        // `.always` folds the collection view's safe area into adjustedContentInset, and that safe area
        // is NOT mapped through the flip â€” `safeAreaInsets.top` is still the nav bar even though, under
        // the transform, contentInset.top is the VISUAL BOTTOM. So UIKit reliably puts the nav bar's
        // clearance where the composer is and the home indicator's where the nav bar is. Both halves of
        // what the user sees: content running up under the header, and a gap above the composer.
        //
        // Two failed attempts are worth recording, because the obvious ones are both wrong:
        //   * Changing only OUR number cannot fix it. The wrong part is the safe-area half, which is
        //     UIKit's, and shrinking our own contribution to compensate breaks the moment the keyboard
        //     changes the safe area.
        //   * Taking the insets over with `.never` and computing from `view.safeAreaInsets` is what
        //     regressed build 388 â€” that view does not carry the real safe area, so both clearances
        //     collapsed at once.
        //
        // What does work is to keep UIKit's values, which ARE right, and cancel the swap: add the far
        // edge's inset and subtract the near one, so each side ends up with the total it should have.
        // `collectionView.safeAreaInsets` (window-derived, the same value `.always` is folding) is the
        // reliable source here â€” not the controller's view.
        let safe = collectionView.safeAreaInsets
        let visualBottom = composerBarH + 12 + safe.bottom - safe.top
        let visualTop = topOverlayHeight + safe.top - safe.bottom
        guard abs(collectionView.contentInset.top - visualBottom) > 0.5
                || abs(collectionView.contentInset.bottom - visualTop) > 0.5 else { return }
        let wasAtNewest = isAtNewest
        let stash = collectionView.contentOffset
        collectionView.contentInset.top = visualBottom
        collectionView.contentInset.bottom = visualTop
        collectionView.verticalScrollIndicatorInsets.top = visualBottom
        collectionView.verticalScrollIndicatorInsets.bottom = visualTop
        // While the list is moving, UIKit is already compensating for the range change on the finger's or
        // the fling's behalf. A write from us here would fight it, and a write LATER â€” which is what the
        // old deferred inset update did â€” lands as a visible jump the moment the user lets go. Do neither:
        // the inset above has already landed, and only the offset work stands down.
        let listIsMoving = collectionView.isDragging || collectionView.isTracking || collectionView.isDecelerating
        guard !listIsMoving, !keyboardAnimating, didFirstLand else { return }
        UIView.performWithoutAnimation {
            if wasAtNewest {
                // Follow the clearance: the newest message stays exactly above the composer.
                collectionView.setContentOffset(CGPoint(x: 0, y: minContentOffsetY), animated: false)
            } else if collectionView.contentOffset != stash {
                // A reader in history must not move at all. Changing an inset can make UIScrollView move
                // the offset on its own; put it back, and only when it actually did (an unconditional
                // write here is a second offset write per call, and at the end of a drag it kills
                // residual velocity).
                collectionView.setContentOffset(stash, animated: false)
            }
        }
    }

    func setComposerBarHeight(_ h: CGFloat) {
        // Reject implausible reports: the composer bar is never under ~40pt â€” a transient near-zero from
        // the SwiftUI reader mid-transition would zero the clearance and drop the last messages straight
        // under the input field.
        guard h > 30, abs(h - composerBarH) > 0.5 else { return }
        composerBarH = h
        updateInsets()
    }

    // The floating date pill normally sits just under the nav bar. When a pinned-message bar is showing,
    // the list runs UNDER it, so the pill would hide behind the pin â€” drop it below the bar, and reserve
    // the same space at the visual top of the list.
    func setTopOverlayHeight(_ h: CGFloat) {
        // CHANGE DETECTION FIRST. This is called from every SwiftUI body pass â€” including the ones
        // scrolling itself causes, via the isAtBottom binding. Without this guard it ran on every pass of
        // every scroll, and the work it armed was paid back at finger-lift: a full re-measure and
        // reconfigure of every visible cell for a value that had never changed. That was the split-second
        // jump at the end of a scroll. The pinned bar's height changes when someone pins or unpins a
        // message, and that is the only time any of this should run.
        guard abs(h - topOverlayHeight) > 0.5 else { return }
        topOverlayHeight = h
        datePillTop?.constant = 6 + h
        updateInsets()
    }

    // MARK: - Keyboard
    //
    // The whole keyboard story, and it is now this short. The newest message sits at
    // -adjustedContentInset.top; the keyboard grows that inset by its own height; so a reader who is at the
    // newest message moves by exactly the keyboard height, riding the keyboard's own duration and curve
    // (curve 7 is the private keyboard curve) so the bubbles track it frame for frame instead of snapping.
    // A reader in history is not moved at all, and does not need to be.
    //
    // Gone with the top-down layout: the keyboardCloseFromBottom latch, the CADisplayLink close drive, the
    // four-shot backstop volley, atBottomForKeyboard, keyboardSessionWasAtBottom, the geometric composer
    // signal and its trailing settle. Every one of them existed to keep a target still that has stopped
    // moving.
    @objc private func keyboardWillShow(_ note: Notification) { rideKeyboard(note) }
    @objc private func keyboardWillHide(_ note: Notification) { rideKeyboard(note) }

    private func rideKeyboard(_ note: Notification) {
        guard shouldAnimateKeyboardChanges, didFirstLand, !isDisappearing else { return }
        if let pop = navigationController?.interactivePopGestureRecognizer {
            switch pop.state { case .possible, .failed: break; default: return }
        }
        // Only a reader who is AT the newest message follows the keyboard. This is the exact test, not the
        // 44pt affordance: moving someone is a decision, and a decision takes the strict answer.
        // SIGNAL'S MODEL, replacing everything that used to be below this line.
        //
        // Read from ConversationViewController+OWS.swift `updateContentInsets()`. They never touch the
        // keyboard notification's geometry. The inset comes from the bottom bar's own frame height minus
        // the safe area â€” the bar rides the keyboard, so its height already contains it, and the
        // subtraction is there so the home-indicator strip is not counted twice. Then, for position:
        //
        //     } else if wasScrolledToBottom {
        //         // "If we were scrolled to the bottom, don't do any fancy math. Just stay at the bottom."
        //
        // An ABSOLUTE destination, not a delta. That is the whole fix. Our ride moved the content by the
        // keyboard's on-screen height, but `adjustedContentInset.top` does not change by that amount: with
        // the keyboard up the safe area's bottom IS the keyboard and the home indicator hides inside it;
        // with it down the safe area's bottom is the home indicator alone. The inset moves by
        // keyboard-minus-home-indicator, so every transition over-moved by ~34pt â€” down past the composer
        // on close, and back again when the settle corrected it. Exactly the reported overshoot, and
        // exactly the double-count Signal's subtraction exists to avoid.
        //
        // With no delta there is no arithmetic left to be wrong. updateInsets already recomputes the
        // clearance and, if the reader was at the newest message, puts them at the newest message â€”
        // which is Signal's rule verbatim. Signal does this with performWithoutAnimation on every layout
        // pass while the bar moves; the smoothness comes from the BAR animating, not from us animating
        // alongside it. So the private-curve ride, the notification frames, the begin/end delta and the
        // close-ownership flag are all gone.
        //
        // LATCH "was at the newest message" for the CLOSE (Signal's `wasScrolledToBottom` — theirs is
        // captured before the bar moves too). The live test cannot answer this later: a close can leave
        // the reader displaced (see keyboardDidHide), and once displaced they look like a reader in
        // history, whom nothing may move. So the question is asked NOW, while it is still answerable:
        //   * non-interactive close (send bar, Done): geometry has not moved yet at willHide — exact test.
        //   * interactive close (dragging the list down over the keyboard): the finger has already moved
        //     the offset, so the exact test is noise. But a dismiss drag at the newest message only pulls
        //     INTO the bottom bounce (below the minimum), never far above it — while a reader who
        //     genuinely scrolled up sits far beyond the 44pt neighbourhood. The loose test is the
        //     readable signal there.
        if note.name == UIResponder.keyboardWillHideNotification {
            keyboardWasAtNewest = collectionView.isTracking || collectionView.isDecelerating
                ? collectionView.contentOffset.y <= minContentOffsetY + 44
                : isAtNewest
            keyboardClosing = true   // the glue in viewDidLayoutSubviews runs until didHide
        } else {
            keyboardClosing = false  // reopened mid-close — stop gluing, the open owns it now
        }
        updateInsets()
    }


    // The keyboard is fully gone and the safe area has finished shrinking. Settle onto the exact newest
    // position, but ONLY for a session that latched "was at newest" at willHide â€” never as a blanket
    // re-pin, which is how the old close path could yank a reader who had scrolled up mid-session.
    @objc private func keyboardDidHide() {
        // One more recompute once the safe area has stopped moving.
        updateInsets()
        clampToNewestIfBeyond()   // the invariant, before the latch logic below
        // THE SETTLE THE CLOSE WAS MISSING (build 8069d37, user screenshot: the newest bubble at rest
        // under the composer after open-then-close). Two holes conspired:
        //   * updateInsets' change-detection guard protects the OFFSET work too â€” once the insets are
        //     already correct, no later call can ever fix a wrong offset. And a displaced reader fails
        //     the live at-newest test, so the at-newest branch cannot rescue them either.
        //   * during an INTERACTIVE close (list dragged down over the keyboard) every offset write
        //     stands down while the finger owns the list â€” correctly â€” but nothing was left to run
        //     AFTER. The displacement survived at rest.
        // The latch from willHide is the answer to "may I move this reader": it was captured while the
        // question was still answerable. Consume it here if the list is at rest; if the dismiss drag is
        // still live, hand it to the scroll-end callbacks â€” never fight the finger.
        if keyboardWasAtNewest, didFirstLand, !isDisappearing {
            if collectionView.isTracking || collectionView.isDragging || collectionView.isDecelerating {
                keyboardSettlePending = true
            } else if !isAtNewest {
                collectionView.setContentOffset(CGPoint(x: 0, y: minContentOffsetY), animated: false)
            }
        }
        keyboardWasAtNewest = false
        keyboardClosing = false   // the glue window ends where the settle takes over
        settleFlush()
    }

    // The deferred half of keyboardDidHide's settle: the keyboard finished hiding while the dismiss drag
    // still owned the list. Runs from the scroll-end callbacks, when the offset is finally at rest.
    private func consumeKeyboardSettleIfPending() {
        guard keyboardSettlePending else { return }
        keyboardSettlePending = false
        guard didFirstLand, !isDisappearing, !isAtNewest else { return }
        // Neighbourhood rule, sized to the failure it fixes: the close's displacement can reach the
        // keyboard-minus-home-indicator inset delta (~300pt), so the gate is half a screen — big enough
        // to always catch the bug, small enough that a reader who deliberately carried the dismiss drag
        // far into history is respected.
        guard collectionView.contentOffset.y <= minContentOffsetY + collectionView.bounds.height * 0.5 else { return }
        collectionView.setContentOffset(CGPoint(x: 0, y: minContentOffsetY), animated: false)
    }

    // MARK: - Lifecycle

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isDisappearing = true
        shouldAnimateKeyboardChanges = false
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isDisappearing = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isDisappearing = false
        shouldAnimateKeyboardChanges = true
        collectionView.isPrefetchingEnabled = true     // re-enable after the jank-sensitive first presentation
        updateInsets()
        // Swiping back with the KEYBOARD UP: dismiss the keyboard the moment the pop gesture begins, so the
        // transition runs against a settled layout instead of fighting a live keyboard teardown.
        if !popGestureHooked, let pop = navigationController?.interactivePopGestureRecognizer {
            pop.addTarget(self, action: #selector(popGestureChanged(_:)))
            popGestureHooked = true
        }
    }

    @objc private func popGestureChanged(_ g: UIGestureRecognizer) {
        switch g.state {
        case .began:
            if view.safeAreaInsets.bottom > 100 { view.window?.endEditing(true) }
        case .ended, .cancelled, .failed:
            UIView.performWithoutAnimation { updateInsets() }
        default:
            break
        }
    }

    // Rotation / size change. The reader is held by the same anchor mechanism as everything else: capture
    // where their nearest-to-origin visible row sits, re-measure at the new width, put it back.
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        guard didFirstLand else { return }
        let wasAtNewest = isAtNewest
        let anchor = wasAtNewest ? nil : continuityAnchor()
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self else { return }
            self.collectionView.layoutIfNeeded()   // the width-change re-measure ran in viewWillLayoutSubviews
            if wasAtNewest { self.perform(.newest(animated: false)) }
            else { self.verifyAnchor(anchor) }
        }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updateInsets()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // Keep the registration's width pin fresh: cells configured during this pass read hostWidth.
        if collectionView.bounds.width > 0 { hostWidth = collectionView.bounds.width }
        // Width change (rotation / split view): every measured height is width-dependent â€” drop and
        // re-measure, and RECONFIGURE the on-screen cells so their hard width pin updates. Position is
        // restored by viewWillTransition's anchor, which brackets this.
        let w = collectionView.bounds.width
        if w > 0, measuredWidth > 0, w != measuredWidth {
            heights.removeAll(keepingCapacity: true)
            sizerRefused.removeAll()
            for id in currentIds { heights[id] = measure(id, width: w) }
            measuredWidth = w
            layout.generation += 1
            layout.invalidateLayout()
            let visible = collectionView.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) }
            if !visible.isEmpty {
                var snap = dataSource.snapshot()
                snap.reconfigureItems(visible)
                dataSource.apply(snap, animatingDifferences: false)
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // We own the insets now, so nothing folds a geometry change in for us. Cheap: updateInsets()
        // returns immediately unless a value actually moved.
        updateInsets()
        // THE CLOSE GLUE (larger-iPhone report: the last bubble visibly sat under the composer for the
        // beat between the close and the didHide settle — a taller keyboard displaces more, so big
        // screens made the transient obvious). One settle at the END means every frame before it can be
        // wrong. Signal recomputes on every layout pass while the bar moves; this is that: for the whole
        // willHide→didHide window, a reader the latch says was at the newest message is HELD there on
        // every pass — updateInsets can't do it, its change-detection guard stops running once the
        // insets have landed. Never while a finger or fling owns the list.
        if keyboardClosing, keyboardWasAtNewest, didFirstLand, !isDisappearing,
           !collectionView.isTracking, !collectionView.isDragging, !collectionView.isDecelerating,
           abs(collectionView.contentOffset.y - minContentOffsetY) > 0.5 {
            collectionView.setContentOffset(CGPoint(x: 0, y: minContentOffsetY), animated: false)
        }
        // The invariant net, independent of any keyboard bookkeeping: at rest, never beyond the newest
        // bound. Catches the interactive keyboard dismissal, where every keyboard-aware correction
        // above correctly stands down because a finger owns the list while the inset shrinks.
        clampToNewestIfBeyond()
        // The visible message viewport in window coordinates, for the media transitions' clipping view
        // (Signal passes `collectionView.adjustedContentInset` as `clippingAreaInsets`; this is the same
        // region expressed as a rect). Remember the flip: adjusted .bottom is the VISUAL TOP inset (nav
        // bar) and adjusted .top is the visual bottom (composer). The controller's view is untransformed,
        // so its window frame is the plain screen region the list occupies.
        let winFrame = view.convert(view.bounds, to: nil)
        let inset = collectionView.adjustedContentInset
        MediaOpenRects.clipRect = CGRect(x: winFrame.minX,
                                         y: winFrame.minY + inset.bottom,
                                         width: winFrame.width,
                                         height: max(0, winFrame.height - inset.bottom - inset.top))
        // Report the GEOMETRIC nav-bar overlap (view.safeAreaInsets.top â€” this controller's view is NOT
        // transformed, so this is the plain, reliable value). Async so the SwiftUI state write never lands
        // mid-layout.
        let top = view.safeAreaInsets.top
        if abs(top - lastReportedTop) > 0.5 {
            lastReportedTop = top
            DispatchQueue.main.async { [weak self] in self?.onTopInset?(top) }
        }
        // Keep the system edge effects OFF (UIKit can reset the flags) — see the verdict at setup.
        if #available(iOS 26.0, *) {
            if !collectionView.topEdgeEffect.isHidden { collectionView.topEdgeEffect.isHidden = true }
            if !collectionView.bottomEdgeEffect.isHidden { collectionView.bottomEdgeEffect.isHidden = true }
        }
        // SCROLL-LOCK BACKSTOP. handleSwipePan disables the scroll view's pan for the duration of a
        // swipe-to-reply and resetSwipe is the single choke point that restores it â€” so ANY path that ends
        // a swipe without reaching resetSwipe leaves the thread permanently unscrollable, with nothing to
        // recover it because a disabled pan cannot produce the scroll events that would notice. Cheap,
        // unconditional truth instead: no swipe in progress means the pan must be enabled.
        if swipingId == nil, !collectionView.panGestureRecognizer.isEnabled {
            collectionView.panGestureRecognizer.isEnabled = true
        }
        // NOTHING HERE TOUCHES THE OFFSET. The old file re-pinned the bottom or clamped the offset on
        // every layout pass, guarded by seven flags, because a layout pass could move where "the bottom"
        // was. It cannot any more, so there is nothing to re-assert and no flags to get wrong.
        if !didFirstLand {
            if !currentIds.isEmpty { performFirstLandIfReady() } else { scheduleEmptyReveal() }
        }
    }

    // MARK: - Swipe to reply

    // Begin ONLY for a horizontal-left drag over a reply-eligible row, so vertical scrolling is untouched
    // and a right-swipe (interactive pop) is untouched. This is what makes one pan safe where N SwiftUI
    // drags were not: the scroll gesture keeps every vertical drag.
    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === doubleTapGesture {
            let loc = g.location(in: collectionView)
            guard let ip = collectionView.indexPathForItem(at: loc),
                  let id = dataSource.itemIdentifier(for: ip), uikitModels[id] != nil else { return false }
            // The BUBBLE only, not the full-width row: double-tapping the empty area beside a uikit bubble
            // hearted it, while SwiftUI rows react on the bubble content only.
            guard let cell = collectionView.cellForItem(at: ip) as? UIKitBubbleCell else { return false }
            let p = collectionView.convert(loc, to: cell.previewBubble)
            return cell.previewBubble.bounds.contains(p)
        }
        guard g === swipePan else { return true }
        if isSelecting { return false }                            // selection mode: rows toggle, never reply-swipe
        if VoiceScrubState.active { return false }                 // waveform scrub owns the touch
        let v = swipePan.velocity(in: collectionView)
        guard v.x < 0, abs(v.x) > abs(v.y) else { return false }   // horizontal-left dominant only
        let loc = swipePan.location(in: collectionView)
        guard let ip = collectionView.indexPathForItem(at: loc),
              let id = dataSource.itemIdentifier(for: ip), canSwipeReply(id) else { return false }
        // The UIKit pan ONLY drives NATIVE text cells (which transform cleanly). SwiftUI-hosted cells
        // (reply/image/video) handle their own swipe via a SwiftUI .offset INSIDE the bubble â€” the
        // build-285 approach that moves the content within the cell, so the cell frame never changes and
        // neighbours can't drift (transforming a hosted cell was the regression â†’ neighbour drift plus the
        // snapshot's duplication).
        guard uikitModels[id] != nil else { return false }
        return true
    }

    // Coexist with the collection view's own scroll pan (the list scrolls vertically, we translate a cell
    // horizontally â€” different axes, no conflict). shouldBegin already gates us to horizontal-left.
    // holdPress is a PASSIVE observer â€” it must never block the SwiftUI context-menu press or anything else.
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g === swipePan || g === holdPress
    }

    @objc private func handleHoldWindow(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            // A CEILING, never .distantFuture. This flag closes canLandLoad, so a press that somehow never
            // delivers .ended or .cancelled used to freeze every content update in the conversation for the
            // rest of the session with no way back â€” the same wedged-flag shape the programmatic-scroll
            // watchdog already exists to prevent. Nobody holds a finger down for eight seconds on purpose,
            // and the real menu lifetime is tracked below by UIKit itself.
            interactionHoldUntil = Date().addingTimeInterval(8)
        case .ended, .cancelled, .failed:
            // Keep the gate up briefly past the lift-off: the menu presentation is still settling.
            interactionHoldUntil = Date().addingTimeInterval(1.0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) { [weak self] in
                self?.settleFlush()
            }
            // NOTE: the old file also captured the offset at press-start and restored it 1.05s later,
            // because the settle burst it released moved the reader ("all bubbles auto-scroll on the first
            // long-press"). That was a symptom of the settle funnel doing position work. settleFlush no
            // longer moves anyone, so the restore â€” itself a bare setContentOffset a second after a touch
            // â€” is gone.
        default:
            break
        }
    }

    @objc private func handleSwipePan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            let loc = g.location(in: collectionView)
            guard let ip = collectionView.indexPathForItem(at: loc),
                  let id = dataSource.itemIdentifier(for: ip),
                  let cell = collectionView.cellForItem(at: ip), canSwipeReply(id) else {
                swipingCell = nil; swipingId = nil; return
            }
            swipingCell = cell; swipingId = id; swipeTriggered = false
            // LOCK vertical scrolling for the swipe WITHOUT the neighbor-jump. Setting
            // `isScrollEnabled = false` forces UIScrollView to RE-CLAMP contentOffset â€” off an exact row
            // boundary that clamp shifted the whole list about a row â€” and it also flips isTracking false
            // mid-touch. Cancel just the scroll view's PAN recogniser instead: it stops any in-flight
            // vertical scroll but does NOT re-evaluate contentOffset. Restored in resetSwipe.
            collectionView.panGestureRecognizer.isEnabled = false
            layout.frozen = true   // freeze frames for the swipe; a horizontal transform never reflows
            addSwipeArrow(for: cell)
        case .changed:
            guard let cell = swipingCell else { return }
            if VoiceScrubState.active { resetSwipe(animated: false); return }   // waveform took over mid-drag
            // 1:1 with the finger to the threshold, then RUBBER-BAND (drag past -70 moves at quarter speed,
            // capped) â€” attached to the finger up close, physical resistance past the commit point.
            let t = min(0, g.translation(in: collectionView).x)
            let tx = t > -70 ? t : -70 + max(-30, (t + 70) * 0.25)
            // Move the BUBBLE VIEW inside the cell, NOT the cell: the cell's frame never changes, so the
            // collection view has nothing to react to and the neighbours stay frozen.
            (cell as? UIKitBubbleCell)?.previewBubble.transform = CGAffineTransform(translationX: tx, y: 0)
            let progress = min(1, abs(tx) / 50)
            swipeArrow?.alpha = progress
            swipeArrow?.transform = CGAffineTransform(scaleX: 0.6 + 0.4 * progress, y: 0.6 + 0.4 * progress)
            if abs(tx) >= 50, !swipeTriggered {
                swipeTriggered = true
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } else if abs(tx) < 50 {
                swipeTriggered = false
            }
        case .ended, .cancelled, .failed:
            layout.frozen = false
            let fire = swipeTriggered ? swipingId : nil
            resetSwipe(animated: true, velocity: g.velocity(in: collectionView).x)
            if let id = fire { onSwipeReply(id) }
            settleFlush()   // land anything that was deferred while the swipe owned the cell
        default:
            break
        }
    }

    // The reply arrow sits in the space the bubble vacates. It goes into the CELL's content view, not the
    // collection view: the cell is already counter-flipped, so the arrow draws upright there, and the cell
    // itself never moves during a swipe (only the bubble inside it does).
    private func addSwipeArrow(for cell: UICollectionViewCell) {
        swipeArrow?.removeFromSuperview()
        let img = UIImageView(image: UIImage(systemName: "arrowshape.turn.up.left.fill"))
        img.tintColor = .secondaryLabel
        img.contentMode = .scaleAspectFit
        img.alpha = 0
        // Anchor to the BUBBLE's trailing edge, not the row's. Rows are full width, so for an INCOMING
        // (left-aligned) bubble anchoring to the row put the arrow at the screen edge while the bubble slid.
        let bubbleRect: CGRect = {
            guard let b = (cell as? UIKitBubbleCell)?.previewBubble else { return cell.contentView.bounds }
            return b.convert(b.bounds, to: cell.contentView)
        }()
        img.frame = CGRect(x: min(cell.contentView.bounds.maxX - 36, bubbleRect.maxX + 8),
                           y: bubbleRect.midY - 9, width: 20, height: 18)
        cell.contentView.addSubview(img)
        swipeArrow = img
    }

    private func resetSwipe(animated: Bool, velocity: CGFloat = 0) {
        layout.frozen = false   // choke point for EVERY teardown path (VoiceScrub abort, recycle, normal end)
        let cell = swipingCell
        let arrow = swipeArrow
        swipingCell = nil; swipingId = nil; swipeArrow = nil; swipeTriggered = false
        // Restore the scroll pan HERE, at the single choke point, so a swipe can never leave the thread
        // unscrollable.
        collectionView.panGestureRecognizer.isEnabled = true
        let bubble = (cell as? UIKitBubbleCell)?.previewBubble
        let reset = { bubble?.transform = .identity; arrow?.alpha = 0 }
        if animated {
            // Seed the spring with the release velocity so a fast flick snaps back livelier than a slow let-go.
            let distance = abs(bubble?.transform.tx ?? 0)
            let v = distance > 0 ? min(3, abs(velocity) / max(1, distance)) : 0.4
            // 0.28/0.72 matches the SwiftUI bubbles' spring exactly, so a text message and a voice/media
            // message return with the same weight instead of two different feels.
            UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.72, initialSpringVelocity: v,
                           options: [.allowUserInteraction], animations: reset) { _ in arrow?.removeFromSuperview() }
        } else {
            reset(); arrow?.removeFromSuperview()
        }
    }

    // The swiped cell scrolled off and is being RECYCLED for another row: kill the swipe immediately â€”
    // keeping the transform would slide the WRONG row left when the cell is reused.
    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        guard cell === swipingCell else { return }
        resetSwipe(animated: false)
        swipePan.isEnabled = false; swipePan.isEnabled = true   // cancel the in-flight pan
    }

    // MARK: - Taps, repaint and context menu

    func repaintUikitCells() {
        guard !uikitModels.isEmpty else { return }
        for ip in collectionView.indexPathsForVisibleItems {
            guard let id = dataSource.itemIdentifier(for: ip),
                  let m = uikitModels[id],
                  let cell = collectionView.cellForItem(at: ip) as? UIKitBubbleCell else { continue }
            cell.repaintIfMetaChanged(m)
        }
    }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended else { return }
        let loc = g.location(in: collectionView)
        guard let ip = collectionView.indexPathForItem(at: loc),
              let id = dataSource.itemIdentifier(for: ip), uikitModels[id] != nil else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onUikitDoubleTap(id)
    }

    // MODERN API (iOS 16+): UIKit calls the PLURAL method on current SDKs â€” implementing only the
    // deprecated single-item variant meant uikit-routed rows never showed a menu at all.
    func collectionView(_ collectionView: UICollectionView,
                        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard let ip = indexPaths.first else { return nil }
        return contextMenuConfig(at: ip)
    }

    func collectionView(_ collectionView: UICollectionView,
                        contextMenuConfigurationForItemAt indexPath: IndexPath,
                        point: CGPoint) -> UIContextMenuConfiguration? {
        contextMenuConfig(at: indexPath)
    }

    private func contextMenuConfig(at indexPath: IndexPath) -> UIContextMenuConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), uikitModels[id] != nil,
              let menu = uikitMenu(id) else { return nil }   // SwiftUI rows: their own .contextMenu owns it
        return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) { _ in menu }
    }

    // Lift ONLY the bubble (rounded to its exact corner path) â€” the default would lift the whole
    // full-width transparent cell.
    //
    // The bubble is inside a cell that carries the counter-flip, so its transform to the window has no net
    // scale and UIKit's snapshot of it is upright. This is exactly why the flip is applied per cell rather
    // than only to the collection view.
    private func bubbleTargetedPreview(at indexPath: IndexPath) -> UITargetedPreview? {
        guard let cell = collectionView.cellForItem(at: indexPath) as? UIKitBubbleCell else { return nil }
        let bubble = cell.previewBubble
        let params = UIPreviewParameters()
        params.backgroundColor = .clear
        if let path = bubble.lastCornerPath { params.visiblePath = path }
        return UITargetedPreview(view: bubble, parameters: params)
    }

    func collectionView(_ collectionView: UICollectionView,
                        contextMenuConfiguration configuration: UIContextMenuConfiguration,
                        highlightPreviewForItemAt indexPath: IndexPath) -> UITargetedPreview? {
        bubbleTargetedPreview(at: indexPath)
    }

    func collectionView(_ collectionView: UICollectionView,
                        contextMenuConfiguration configuration: UIContextMenuConfiguration,
                        dismissalPreviewForItemAt indexPath: IndexPath) -> UITargetedPreview? {
        bubbleTargetedPreview(at: indexPath)
    }

    // THE REAL MENU LIFETIME, from UIKit, replacing a long-press proxy that could not see it.
    //
    // Signal's land gate blocks on `collectionViewActiveContextMenuInteraction.contextMenuVisible`. Ours
    // approximated that with the passive long-press recogniser, whose window closes one second after the
    // finger lifts â€” but a menu ACTION is tapped seconds later, while the user reads the menu. So when
    // "Select" was chosen, the gate was already wide open and the route flip it triggers (selection mode
    // routes every row to the SwiftUI cell, so every visible row RELOADS) landed in the middle of the
    // menu's dismissal.
    //
    // A context menu dismisses by animating its lifted preview back INTO the source cell. Destroy that
    // cell mid-flight and the animation has nowhere to land: it strands the system's full-screen blurred
    // backdrop on screen with no menu on it, which is the user's "when I select, all screen is going
    // blur". Waiting for the animator's completion is the whole fix.
    func collectionView(_ collectionView: UICollectionView,
                        willDisplayContextMenu configuration: UIContextMenuConfiguration,
                        animator: UIContextMenuInteractionAnimating?) {
        contextMenuVisible = true
        // THE FLOATING REACTIONS BAR (Signal's, in our own window — see ReactionBar.swift). It is
        // presented here and dismissed in willEndContextMenuInteraction, which are the only two facts
        // it needs from the system menu. It never modifies the menu, and the menu never knows it
        // exists: `UIContextMenuInteraction` is untouched, which was the whole requirement.
        if let id = configuration.identifier as? String,
           let scene = view.window?.windowScene,
           let ip = dataSource.indexPath(for: id),
           let cell = collectionView.cellForItem(at: ip) as? UIKitBubbleCell,
           let model = uikitModels[id] {
            let bubble = cell.previewBubble
            let frame = bubble.convert(bubble.bounds, to: nil)
            ReactionBarPresenter.shared.show(
                in: scene,
                bubbleFrame: frame,
                alignTrailing: model.isMe,       // Signal aligns the bar to the bubble's own edge
                selected: onReactionSelected(id)
            ) { [weak self] emoji in
                guard let self else { return }
                // Apply, then take the menu down the same way a menu action would. The bar asks the
                // interaction to dismiss; it does not reach inside it.
                onReactionPick(id, emoji)
                ReactionBarPresenter.shared.hide()
                // Ask the menu to close, the way tapping one of its own actions would. `interactions`
                // and `dismissMenu()` are both public UIKit — we are requesting a dismissal through
                // the front door, not reaching into the menu's internals.
                collectionView.interactions
                    .compactMap { $0 as? UIContextMenuInteraction }
                    .forEach { $0.dismissMenu() }
            }
        }
        // WHICH row the menu belongs to. The configuration's identifier IS the row id (see
        // contextMenuConfig). Only THIS cell must survive untouched until the dismissal ends — the
        // stranded-blur bug was its destruction mid-flight, not any other cell's. Knowing which one
        // lets the selection UI land on every OTHER row immediately (see refreshSelectionExceptMenuSource).
        contextMenuSourceId = configuration.identifier as? String
    }

    func collectionView(_ collectionView: UICollectionView,
                        willEndContextMenuInteraction configuration: UIContextMenuConfiguration,
                        animator: UIContextMenuInteractionAnimating?) {
        // The bar leaves WITH the menu, riding the same duration — it was never part of it, so this is
        // simply the moment we were told the interaction is ending.
        ReactionBarPresenter.shared.hide()
        guard let animator else {
            contextMenuVisible = false; contextMenuSourceId = nil; settleFlush(); return
        }
        animator.addCompletion { [weak self] in
            self?.contextMenuVisible = false
            self?.contextMenuSourceId = nil
            self?.settleFlush()   // land everything the menu held back, now that the cell is free
        }
    }

    // MARK: - Scroll observation

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        sendAnimating = false
        scrollingAnimationDidComplete()
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        // The finger has left. If the keyboard shrank the inset out from under a reader who was at the
        // newest message (interactive dismissal), this is the first honest moment to put them back.
        if !decelerate { consumeKeyboardSettleIfPending(); clampToNewestIfBeyond(); settleFlush() }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        consumeKeyboardSettleIfPending(); clampToNewestIfBeyond(); settleFlush()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // During the screenshot-capture freeze the SYSTEM owns the offset: write no SwiftUI state and fire
        // nothing.
        if Date() < captureFreezeUntil { return }
        if scrollView.isDragging || scrollView.isTracking || scrollView.isDecelerating {
            lastStableOffset = scrollView.contentOffset.y
            userScrolledSinceTimer = true
            // Topmost visible row â†’ the floating date pill. Under the flip that is the LAST viewport index
            // path, not the first: layout order runs from the newest (visually lowest) upward.
            let top = viewportIndexPaths().last.flatMap { dataSource.itemIdentifier(for: $0) }
            updateDatePill(topId: top)
        }
        // Heavier per-scroll work (pagination trigger, the isAtBottom SwiftUI write) is DEBOUNCED onto a
        // 0.1s one-shot timer on the COMMON runloop mode: scrollViewDidScroll itself stays cheap and never
        // mutates state that re-enters layout inline.
        scheduleScrollWorkTimer()
    }

    private func scheduleScrollWorkTimer() {
        guard scrollWorkTimer == nil else { return }
        let t = Timer(timeInterval: 0.1, repeats: false) { [weak self] _ in self?.scrollWorkTimerDidFire() }
        scrollWorkTimer = t
        RunLoop.main.add(t, forMode: .common)   // .common or it won't fire during scrolling
    }

    private func scrollWorkTimerDidFire() {
        scrollWorkTimer?.invalidate()
        scrollWorkTimer = nil
        guard isViewLoaded, Date() >= captureFreezeUntil else { return }
        // The jump-to-latest button's affordance, coalesced to at most ten writes a second.
        let atBottom = isNearNewest
        if coordinator.parent.isAtBottom != atBottom { coordinator.parent.isAtBottom = atBottom }
        if userScrolledSinceTimer { autoLoadMoreIfNeeded() }
        userScrolledSinceTimer = false
    }

    // Page history in when the reader gets within three screens of the OLDEST loaded row â€” which under the
    // flip is the far end of the content, not the near end. Throttled to one load per 2s. There is no
    // zone-entry debounce: a short page leaves the reader still inside the zone, and the time throttle
    // alone lets the chain continue until content outruns the threshold.
    private func autoLoadMoreIfNeeded() {
        guard didReveal, Date() >= captureFreezeUntil else { return }
        let threshold = max(72, collectionView.bounds.height * 3)
        guard maxContentOffsetY - collectionView.contentOffset.y <= threshold,
              Date().timeIntervalSince(lastLoadOlderAt) > 2 else { return }
        lastLoadOlderAt = Date()
        coordinator.parent.onReachedTop()
    }

    // Status-bar tap. The default scroll-to-top would fly to content y = 0, which under the flip is the
    // NEWEST message â€” the opposite of what the gesture means. Take it over and glide to the visual top of
    // what is loaded, which is what it did before the inversion.
    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        guard abs(collectionView.contentOffset.y - maxContentOffsetY) > 0.5 else { return false }
        scrollToOffset(maxContentOffsetY, animated: true)
        return false
    }

    // Show the day of the topmost visible row while scrolling; fade ~1.2s after it stops. Runs entirely in
    // UIKit â€” no binding write, so scrolling never re-runs the SwiftUI conversation tree.
    private func updateDatePill(topId: String?) {
        guard didReveal, let topId, let label = dayLabelFor(topId) else { return }
        if topId != lastDateId { lastDateId = topId; dateLabel.text = label }
        if datePill.alpha < 1 {
            UIView.animate(withDuration: 0.15) { self.datePill.alpha = 1 }
        }
        dateFadeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.35) { self?.datePill.alpha = 0 }
        }
        dateFadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    // MARK: - Screenshot recovery

    // iOS 26 full-page screenshots scroll the view PROGRAMMATICALLY (no drag flags) right after the
    // notification, to capture every page. Freeze all landings for the capture window and snap back to the
    // last stable offset once it has finished.
    @objc func screenshotTaken() {
        guard didFirstLand, !isDisappearing,
              !collectionView.isDragging, !collectionView.isTracking,
              !collectionView.isDecelerating else { return }
        captureFreezeUntil = Date().addingTimeInterval(1.5)
        let snapBack: () -> Void = { [weak self] in
            guard let self else { return }
            let target = self.clampOffset(self.lastStableOffset)
            if abs(self.collectionView.contentOffset.y - target) > 4 {
                self.collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: false)
            }
        }
        DispatchQueue.main.async(execute: snapBack)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.55) { [weak self] in
            snapBack()
            self?.settleFlush()
        }
    }
}

// Pre-measured, INVERTED layout: cell heights are known before layout (never self-sized), so every frame
// is exact on the first pass, and item 0 (the newest message) sits at content y = 0. `heightForItem` reads
// the controller's measured-height cache; prepare() stacks the rows into exact frames and an exact content
// height.
//
// Every cell carries the counter-flip in its attributes, so the collection view's own scaleY(-1) is
// cancelled and content draws upright. Doing it here rather than in the cell means it survives reuse,
// reconfiguration and every cell class without anyone having to remember.
final class InvertedMessageLayout: UICollectionViewLayout {
    static let flip = CGAffineTransform(scaleX: 1, y: -1)

    var heightForItem: ((Int) -> CGFloat)?
    // A render-state id: an O(1) identity check instead of re-stacking frames on every prepare(). The
    // controller bumps this whenever ids/heights change; unchanged generation + width + count â†’ the cached
    // frames are reused untouched (prepare() is called constantly during scrolling).
    var generation = 0

    private var frames: [CGRect] = []
    private var contentHeight: CGFloat = 0
    private(set) var layoutWidth: CGFloat = 0
    private var builtGeneration = -1
    private var builtCount = -1
    // FROZEN during a reply swipe: a horizontal gesture has no reason to change any frame, so the layout is
    // fully locked and the only thing that moves is the swiped bubble's transform.
    var frozen = false

    override func prepare() {
        super.prepare()
        if frozen { return }   // keep the current frames untouched for the whole swipe
        guard let cv = collectionView else { return }
        // CRASH GUARD (build 283 SIGABRT): before the FIRST snapshot lands, the diffable data source
        // reports ZERO sections â€” asking numberOfItems(inSection: 0) then trips UIKit's internal assertion
        // and aborts. An empty brand-new chat hit exactly this.
        guard cv.numberOfSections > 0 else {
            frames = []; contentHeight = 0; builtCount = -1; builtGeneration = -1
            return
        }
        let count = cv.numberOfItems(inSection: 0)
        if builtGeneration == generation, cv.bounds.width == layoutWidth, count == builtCount { return }
        layoutWidth = cv.bounds.width
        frames.removeAll(keepingCapacity: true)
        frames.reserveCapacity(count)
        var y: CGFloat = 0
        for i in 0..<count {
            let h = heightForItem?(i) ?? 44
            frames.append(CGRect(x: 0, y: y, width: layoutWidth, height: h))
            y += h
        }
        contentHeight = y
        builtGeneration = generation
        builtCount = count
    }

    override var collectionViewContentSize: CGSize { CGSize(width: layoutWidth, height: contentHeight) }

    // ONE-CONNECTED-SHEET (the Telegram model): keep a full viewport of rows rendered on each side of the
    // visible rect, so every bubble is already fully rendered before it scrolls on screen. Without this,
    // each hosted bubble builds its SwiftUI at the moment it enters the viewport â€” bubbles pop in one at a
    // time behind the moving sheet, which reads as independent elements instead of one surface. Gated
    // until after the first reveal so the carefully-tuned instant open never pays the extra cells.
    var overdrawEnabled = false

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        let overdraw = overdrawEnabled ? (collectionView?.bounds.height ?? 0) : 0
        let expanded = rect.insetBy(dx: 0, dy: -overdraw)
        var result: [UICollectionViewLayoutAttributes] = []
        for i in frames.indices where frames[i].intersects(expanded) {
            result.append(attributes(for: i))
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.item < frames.count else { return nil }
        return attributes(for: indexPath.item)
    }

    private func attributes(for item: Int) -> UICollectionViewLayoutAttributes {
        let a = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: item, section: 0))
        a.frame = frames[item]
        a.transform = Self.flip   // cancel the collection view's flip so the row draws upright
        return a
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        if frozen { return false }   // never re-stack during a swipe
        return newBounds.width != layoutWidth
    }

    // AUTHORITATIVE heights: never let a cell self-size and override our pre-measured frames. A
    // UIHostingConfiguration cell reports a preferred size on any re-layout (including the transform
    // applied during a reply swipe) â€” answering false here means those reports can never shift a
    // neighbour. The controller's measured cache remains the only height authority.
    override func shouldInvalidateLayout(forPreferredLayoutAttributes preferredAttributes: UICollectionViewLayoutAttributes,
                                         withOriginalAttributes originalAttributes: UICollectionViewLayoutAttributes) -> Bool {
        false
    }

    // ===== Scroll continuity =====
    // When a load lands, the controller computes the anchor row's frame delta (before vs after the update)
    // and parks it here. UIKit consults targetContentOffset(forProposedContentOffset:) DURING the batch
    // update â€” answering with proposed + delta shifts the offset ATOMICALLY with the layout change, so no
    // frame ever renders at the stale offset.
    //
    // In the inverted list this is almost always zero, because almost every update happens on the far side
    // of the viewport from the origin. It is fed for exactly one case: a new message arriving while the
    // reader is scrolled up in history.
    var pendingContentOffsetAdjustment: CGFloat = 0

    override func targetContentOffset(forProposedContentOffset proposed: CGPoint) -> CGPoint {
        guard pendingContentOffsetAdjustment != 0 else { return proposed }
        return CGPoint(x: proposed.x, y: proposed.y + pendingContentOffsetAdjustment)
    }

    override func finalizeCollectionViewUpdates() {
        pendingContentOffsetAdjustment = 0   // one-shot: consumed by the batch update that lands the load
        super.finalizeCollectionViewUpdates()
    }
}

