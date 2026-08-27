import SwiftUI
import UIKit

extension Notification.Name {
    /// "Take me to the newest message." Posted by the down-arrow button, answered by whichever
    /// message list is currently on screen — see `jumpToNewestRequested` for why it is a wire rather
    /// than a piece of state.
    static let chatListJumpToNewest = Notification.Name("chatListJumpToNewest")
}

// UIKit-backed conversation list. A UICollectionView hosts our existing SwiftUI rows (MessageBubble etc.)
// via UIHostingConfiguration, so no bubble feature is lost â€” only the scroll container differs.
//
// ============================================================================================
// TOP-DOWN, THE WAY THE REFERENCE APP'S LIST IS (2026-08-25, un-inverting the 2026-07-28 rewrite)
// ============================================================================================
// From 2026-07-28 to today this list was drawn UPSIDE DOWN: the collection view carried a scaleY(-1)
// transform, every cell carried the counter-flip, item 0 was the newest message at content y = 0, and
// paging history appended beyond the far edge so nothing the reader could see ever moved. That bought
// a real thing: "keep the reader still" became a property of the coordinate system instead of a
// calculation, and a family of scroll-jump bugs died with it. The record of those bugs, and of the
// four fixes that each found a real cause before the inversion, is in the git history of this file.
//
// IT IS TOP-DOWN AGAIN, AND THE REASON IS THE HEADER (owner, 2026-08-25: "where is the iOS 26 Liquid
// Glass blur in the top header? [The reference app] has it."). That blur is not a view anybody writes;
// it is the system's scroll edge effect, which iOS 26 draws under a navigation bar for any scroll view
// by default. Their list is a plain top-down collection view, so they get it free. Ours was inverted,
// and the system's effect cannot tell which edge is which on a mirrored scroll view: on device it
// washed the whole chat three separate ways in July, and five hand-made blur bands failed after that.
// The verdict written at the old setup site ended: "the honest answer is to stop imitating it and
// un-invert the list so Apple's own effect works." This is that.
//
// WHAT THE UN-INVERSION KEEPS, so the jump family does not simply come back:
//
//   * Heights are still measured up-front (UIHostingController.sizeThatFits at the real width, cached
//     by row id) and fed to a layout that stacks exact frames. Cells never self-size and the first
//     frame drawn is final. That was never the problem.
//   * The continuity mechanism is unchanged and it was always orientation-agnostic: the visible row
//     nearest the coordinate origin is the anchor, its frame is mapped before and after every change,
//     and the difference rides the layout's own `contentOffsetAdjustment` INSIDE the update
//     transaction, never a frame late. In the inverted list that delta was almost always zero. Here it
//     is non-zero for exactly the changes that happen ABOVE the reader: a page of history landing, a
//     row above them growing, a deletion above them. Same one formula, one net behind it.
//   * "At the newest message" is `contentOffset.y >= maxContentOffsetY - 5`, which depends on
//     contentSize. That is the dependency the inversion removed, and the reason it was removed is
//     written down: a keyboard fold could shrink the maximum under a reader in history and read as
//     "at the bottom". Every place that asks the question now asks it at rest, with the layout
//     settled, and the keyboard path asks it against the clearance it last established, i.e. BEFORE
//     geometry moves (see `updateInsets`).
//
// What can bite again, said plainly: a row the reader has never seen, sized wrong by the off-screen
// sizer (see `sizerRefused`), now sits ABOVE them after a page-in, and a wrong height there is a jump
// of that many points when the row finally renders and corrects. The reference app carries the same
// exposure with the same mitigation, measurement before layout, and lives with it.
struct NativeMessageList: UIViewControllerRepresentable {
    var rowIds: [String]                       // stable ids in CHRONOLOGICAL order (Message.rowId)
    var rowSignatures: [String: String] = [:]  // per-row CONTENT signature â†’ same-ids apply reconfigures ONLY changed rows
    var row: (String) -> AnyView               // ThreadView builds the full row (date/divider/bubble) for an id
    // UIKit bubble migration: messages the native path fully supports (plain 1:1 delivered text) render
    // as UIKit cells â€” no SwiftUI, no per-cell animation/re-measure during scroll. The models arrive as a
    // SNAPSHOT DICTIONARY resolved once per body run (not a live closure): measure() and the cell
    // provider read the same frozen routing, so a state flip can never route a row differently between
    // its measurement and its render (the mismatch that stranded the layout when this path first ran).
    var rowModels: [String: MessageRowModel] = [:]
    // Bumped by ThreadView only when the model dictionary is genuinely rebuilt. `repaintUikitCells` walks
    // the visible cells on every SwiftUI update, and the body re-runs on typing flags, presence dots and
    // keyboard focus â€” all of which leave the models identical. Comparing one integer skips that walk.
    var uikitModelsVersion: Int = 0
    // The UIKit rows route their taps back up through these. A link, a quote, a reaction badge, the
    // retry line and a group sender are rectangles in the row's plan, so the CELL hit-tests them and
    // reports which one was hit — no gesture recogniser per element, and a row with none of them
    // installs nothing.
    var onTapLink: (URL) -> Void = { _ in }
    var onTapQuote: (String) -> Void = { _ in }              // jump to the quoted message
    var onTapStoryQuote: (_ rowId: String, _ replyId: String) -> Void = { _, _ in }
    var onTapMedia: (String) -> Void = { _ in }        // the picture opens the viewer
    var onTapPill: (String) -> Void = { _ in }         // a view-once photo or voice note
    var onTapReadMore: (String) -> Void = { _ in }     // expand a collapsed long text
    var onTapAlbumTile: (_ rowId: String, _ index: Int) -> Void = { _, _ in }
    var onTapFile: (String) -> Void = { _ in }
    var onToggleVoice: (String) -> Void = { _ in }
    var onTapStoryReplyCard: (String) -> Void = { _ in }
    var onTapLinkCard: (String) -> Void = { _ in }
    var onTapLinkProfile: (String) -> Void = { _ in }
    var onTapLocation: (String) -> Void = { _ in }
    var onTapContactCard: (String) -> Void = { _ in }
    var onTapContactMessage: (String) -> Void = { _ in }
    var onTapReactions: (String) -> Void = { _ in }
    var onTapRetry: (String) -> Void = { _ in }
    var onToggleSelect: (String) -> Void = { _ in }
    var onTapSender: (String) -> Void = { _ in }
    var onTapCallRow: (String) -> Void = { _ in }
    var onTapPinNotice: (String) -> Void = { _ in }
    var uikitMenu: (String) -> UIMenu? = { _ in nil }        // long-press menu for UIKit-routed rows
    var onUikitDoubleTap: (String) -> Void = { _ in }        // double-tap quick reaction (heart)
    // CUSTOM LONG-PRESS MENU (experiment — see CMContextMenu.swift). ThreadView supplies the row's
    // actions and reaction config; the controller owns the press, the snapshot and the overlay.
    var customMenuActions: (String) -> [CMAction] = { _ in [] }
    var customReactConfig: (String) -> (emojis: [String], selected: String?)? = { _ in nil }
    var onCustomReact: (String, CMReactionSelection) -> Void = { _, _ in }
    var onMenuCloseKeyboard: () -> Bool = { false }          // closes if open; returns whether it WAS open
    var onMenuRestoreKeyboard: () -> Void = {}
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
    // not folded for us. It goes into contentInset.bottom; see updateInsets().
    var composerBarHeight: CGFloat = 0
    var voiceControl: Int = 0                  // 0 none · 1 pause · 2 continue — the recording's floating control
    var onVoiceControlTap: () -> Void = {}
    /// ⛔ THE FLOATING OVERLAYS LIVE ON THE DOCK NOW — the reference app's arrangement. Theirs are
    /// UIKit subviews pinned to the bottom bar's container
    /// (`autoPinEdge(.bottom, to: .top, of: bottomBarContainer, withOffset: -24)`), so when the
    /// keyboard moves they travel inside UIKit's own animation with the bar, for free and on the same
    /// curve. Ours were SwiftUI overlays positioned from `composerLift` / `composerSide`, two numbers
    /// this controller reports back ASYNCHRONOUSLY from a layout pass — so the arrow arrived a runloop
    /// turn after the bar and then ran its own spring beside the keyboard's. That is the same "two
    /// curves, one keyboard" shape that made a bubble appear to slide under the composer, just moved
    /// to the arrow.
    ///
    /// ⚠️ THE CONTENT IS STILL SWIFTUI, UNCHANGED, AND THAT IS DELIBERATE. Only the POSITIONING moves
    /// to UIKit. Re-drawing a Liquid Glass disc, its unread capsule and its transitions in UIKit would
    /// have been a rewrite of the owner's UI, and he asked for the architecture to change and the UI
    /// not to. Hosted here, the same view draws the same pixels while Auto Layout — not an async state
    /// write — decides where it sits.
    var dockOverlayTrailing: AnyView = AnyView(EmptyView())
    var dockOverlayLeading: AnyView = AnyView(EmptyView())
    /// The @-mention picker, which sits ON the composer's top edge rather than floating above it. It
    /// used to live in the SwiftUI composer slot, which is a `safeAreaBar` — so it rode SwiftUI's own
    /// keyboard avoidance, a THIRD clock on one screen. Pinned to the bar's top here, it rides the
    /// same one the bar does.
    var dockOverlayComposerTop: AnyView = AnyView(EmptyView())
    /// ⛔ WHERE THE READER IS, FOR REOPENING THE CHAT — the reference app's `lastVisibleInteraction`
    /// plus its on-screen position. Reported from the list's own settle points, because this
    /// controller is the only thing that knows which row is at the top of the viewport and by how
    /// much it is clipped. `nil` means "at the newest message", which is the absence of a position
    /// rather than a kind of one — see `ChatScrollStore.clear`.
    var onReadingPosition: (ChatReadingPosition?) -> Void = { _ in }
    /// How far below the viewport's top the restored row should sit, in points. Applied only to the
    /// `initialScrollId` landing, and only when that id came from a saved reading position.
    var initialScrollOffset: CGFloat? = nil
    // Bumped by ThreadView from inside a SWIFTUI context-menu action (e.g. Select). UIKit's
    // context-menu callbacks cannot see SwiftUI-presented menus, so this is how the controller learns
    // "a menu is dismissing right now" and holds cell reloads until the animation is over.
    var menuActionTick: Int = 0
    /// Bumped by ThreadView the instant Send is tapped — before it clears the input and the reply
    /// banner. The list holds its offset until the row lands; see `noteSendTick`.
    var sendTick: Int = 0
    // Height of the top overlay (pinned-message bar) the list runs UNDER. The floating date pill drops below
    // it so it isn't hidden behind the pin (the reference app behavior). 0 â†’ pill sits at its normal top position.
    var topOverlayHeight: CGFloat = 0
    /// (lift, side): how far the composer stands above the keyboard, and its side inset — both
    /// measured where the controller places the bar, so SwiftUI's floating overlays sit on the
    /// bar's own edges without computing them a second time.
    var onTopInset: (CGFloat) -> Void = { _ in }   // reports the GEOMETRIC nav-bar overlap (UIKit safe area â€” reliable)
    // Whether the floating jump-to-latest button should be on screen. Reported on its own instead of
    // being derived from `isAtBottom`, because the two answer different questions: isAtBottom decides
    // whether the reader gets MOVED (44pt, and half the conversation reads it), while the button is
    // only an affordance and now waits far longer. See `shouldShowJumpButton`. Defaulted, so the
    // announcements list, which has no such button, passes nothing.
    var onJumpButtonVisibility: (Bool) -> Void = { _ in }
    @Binding var isAtBottom: Bool
    @Binding var scrollTarget: String?         // set to a rowId to scroll it into view (reply/search jump), then cleared
    // Day label for the floating date pill, resolved from a rowId. Called from scrollViewDidScroll and
    // rendered by a UIKit pill INSIDE the controller â€” so scrolling no longer writes SwiftUI state (a
    // per-tick `topVisibleId` binding write re-ran the whole ThreadView tree mid-scroll = the round-trip
    // that made scrolling feel unstable). Reading repo.items here is a pure read; it triggers no re-render.
    var dayLabelFor: (String) -> String?
    // ⛔ THE COMPOSER IS PLACED BY THIS CONTROLLER NOW, not by SwiftUI's `safeAreaBar` — see
    // `bottomBarContainer`. Its STATE still comes from ThreadView, which owns the text, the
    // banners and every action; only the PLACEMENT moved, which is the whole fix.
    var composerState: ChatComposerState? = nil
    var composerActions: ChatComposerActions? = nil
    var composerRecorder: AudioRecorder? = nil
    /// The system layout margin (16/20 per device), read by ThreadView's `SystemChromeReader`. The
    /// bar's side and bottom insets are DERIVED from it and the keyboard by the controller itself —
    /// see `positionBottomBar` — so the rest/keyboard switch happens inside the keyboard's animation.
    var composerMargin: CGFloat = 20
    /// The conversation id. The UIKit rows decrypt their own thumbnails, so they need the key's
    /// scope — the SwiftUI rows got it from the closure that built them.
    var cid: String = ""

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
        // ⛔ THE SEND HOLD IS ARMED BEFORE THE COMPOSER IS APPLIED. Since the bar moved into the
        // controller, `applyComposer` is where the reply banner's collapse actually happens (the
        // bar re-lays out, reports its new height, and the container shrinks on the spot). The tick
        // used to be noted thirty lines further down — AFTER that shrink — so the hold was not in
        // place when the clearance dropped, the bottom-pinned offset followed the bar down, and the
        // glide then carried it back up. His report, 2026-08-26, keyboard open: "tap Reply, press
        // Send, the message briefly moves underneath the composer and then jumps back into place."
        vc.noteSendTick(sendTick)
        // BEFORE apply: the bar's own height feeds the list's bottom clearance, and a clearance a
        // pass late is a reader left short.
        if let st = composerState, let acts = composerActions, let rec = composerRecorder {
            vc.applyComposer(state: st, actions: acts, recorder: rec, margin: composerMargin)
        } else {
            // Selection, search, blocked, a message request: SwiftUI draws the bar for those, so
            // ours must leave rather than sit under it. See `hideComposer`.
            vc.hideComposer()
        }
        vc.rowModels = rowModels   // BEFORE apply: measure + cell provider see the same frozen routing
        vc.cid = cid
        vc.uikitMenu = uikitMenu
        vc.onUikitDoubleTap = onUikitDoubleTap
        vc.onTapLink = onTapLink
        vc.onTapQuote = onTapQuote
        vc.onTapStoryQuote = onTapStoryQuote
        vc.onTapMedia = onTapMedia
        vc.onTapPill = onTapPill
        vc.onTapReadMore = onTapReadMore
        vc.onTapAlbumTile = onTapAlbumTile
        vc.onTapFile = onTapFile
        vc.onToggleVoice = onToggleVoice
        vc.onTapStoryReplyCard = onTapStoryReplyCard
        vc.onTapLinkCard = onTapLinkCard
        vc.onTapLinkProfile = onTapLinkProfile
        vc.onTapLocation = onTapLocation
        vc.onTapContactCard = onTapContactCard
        vc.onTapContactMessage = onTapContactMessage
        vc.onTapReactions = onTapReactions
        vc.onTapRetry = onTapRetry
        vc.onToggleSelect = onToggleSelect
        vc.onTapSender = onTapSender
        vc.onTapCallRow = onTapCallRow
        vc.onTapPinNotice = onTapPinNotice
        vc.customMenuActions = customMenuActions
        vc.customReactConfig = customReactConfig
        vc.onCustomReact = onCustomReact
        vc.onMenuCloseKeyboard = onMenuCloseKeyboard
        vc.onMenuRestoreKeyboard = onMenuRestoreKeyboard
        vc.setComposerBarHeight(composerBarHeight)
        vc.onVoiceControlTap = onVoiceControlTap
        vc.setVoiceControl(voiceControl)
        vc.setDockOverlays(trailing: dockOverlayTrailing, leading: dockOverlayLeading,
                           composerTop: dockOverlayComposerTop)
        vc.onReadingPosition = onReadingPosition
        vc.initialScrollOffset = initialScrollOffset
        vc.setTopOverlayHeight(topOverlayHeight)
        // (`noteSendTick` is at the top of this method — it has to precede `applyComposer`.)
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

/// TRUE WHILE A ROW IS BEING RENDERED BY THE OFF-SCREEN SIZER rather than by a real cell.
///
/// ⛔ THE SIZER RENDERS THE SAME VIEW AS THE CELL, SIDE EFFECTS AND ALL — owner, 2026-08-25, on the
/// chat reopening in the wrong place. `measure()` hands `parent.row(id)` to a `UIHostingController`
/// that lives in the view hierarchy (at alpha 0, deliberately, so it inherits traits). SwiftUI does
/// not know that host is a measuring rig: it fires `onAppear` for whatever is in it. The row's
/// `onAppear` inserts its id into ThreadView's visible-rows set and schedules the "where I left off"
/// save — so measuring a row told the app that row was ON SCREEN, and the position it then persisted
/// was a row nobody was looking at.
///
/// Rows read this and skip anything that reports visibility. Nothing about their LAYOUT changes, which
/// is the point: the measurement has to stay identical to the render, and only the side effect goes.
private struct MeasuringRowKey: EnvironmentKey { static let defaultValue = false }

/// THE WIDTH THE ROW IS BEING LAID OUT AT, from the list, for anything in a row that sizes itself
/// against "the width". `MessageBubble.maxBubbleWidth` used to read `UIScreen.main.bounds.width`,
/// which equals the list on a phone and is wrong the moment the list is narrower than the screen
/// (iPad multitasking, Stage Manager). Set identically on the sizer and on the cell, so measurement
/// and render still agree; only the number they agree on is now the right one.
private struct RowWidthKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }

extension EnvironmentValues {
    var isMeasuringRow: Bool {
        get { self[MeasuringRowKey.self] }
        set { self[MeasuringRowKey.self] = newValue }
    }
    var rowWidth: CGFloat {
        get { self[RowWidthKey.self] }
        set { self[RowWidthKey.self] = newValue }
    }
}

/// Report a row's on-screen visibility, except when the off-screen sizer is the one rendering it.
struct RowVisibilityReporter: ViewModifier {
    @Environment(\.isMeasuringRow) private var isMeasuring
    var onVisible: () -> Void
    var onHidden: () -> Void
    func body(content: Content) -> some View {
        content
            .onAppear { if !isMeasuring { onVisible() } }
            .onDisappear { if !isMeasuring { onHidden() } }
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
// The pre-inversion file also overrode contentOffset to reject UIScrollView's internal pre-content
// reset to zero, which snapped a top-down list to its very first message. That override is NOT back:
// it was a blanket refusal, and a blanket refusal also eats a legitimate scroll to the top. If the
// snap reappears, the answer is the layout's `targetContentOffset(forProposedContentOffset:)`
// (the reference app's route), not this class.
final class HardenedCollectionView: UICollectionView {
    override var frame: CGRect {
        get { super.frame }
        set { if newValue.width > 0, newValue.height > 0 { super.frame = newValue } }
    }
    override var bounds: CGRect {
        get { super.bounds }
        set { if newValue.width > 0, newValue.height > 0 { super.bounds = newValue } }
    }
    /// ⛔ NO SCROLL POSITION BEFORE THERE IS CONTENT — the reference app's own guard, read from
    /// their `ConversationCollectionView` and ported 2026-08-25.
    ///
    /// ⚠️ A WRITE OF ZERO-OR-LESS INTO AN EMPTY LAYOUT IS NEVER A READER'S INTENT. It is a stray
    /// correction landing in the gap between a reset and the first measure — the layout has no
    /// frames yet, so every bound computes to the top — and it parks the list at the top of an
    /// empty list, which is precisely where the first real content then appears. The size guards
    /// above cover the same window for geometry; this covers it for position.
    override var contentOffset: CGPoint {
        get { super.contentOffset }
        set {
            if contentSize.height < 1, newValue.y <= 0 { return }
            super.contentOffset = newValue
        }
    }
}

final class MessageListController: UIViewController, UICollectionViewDelegate, UIGestureRecognizerDelegate {
    var coordinator: NativeMessageList.Coordinator!
    private var collectionView: UICollectionView!
    private var layout: MessageLayout!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var reg: UICollectionView.CellRegistration<UICollectionViewCell, String>!

    // LAYOUT ORDER IS CHRONOLOGICAL: index 0 is the OLDEST loaded message and the newest is last, the
    // same order ThreadView hands us. Nothing is reversed anywhere.
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
    var initialScrollOffset: CGFloat?         // and where in the viewport it should sit, if restored
    var onReadingPosition: (ChatReadingPosition?) -> Void = { _ in }
    var lastRepaintedModelsVersion = -1       // -1 so the first update always repaints

    // Rows whose rendered height the SIZER can never reproduce (async content, e.g. link-preview cards).
    private var sizerRefused = Set<String>()
    /// The height a refused row actually RENDERED at. Once the sizer has been proven wrong for a row,
    /// this is that row's height everywhere — `measure()` returns it, so the apply path and the report
    /// path cannot hand the layout two different answers. See `reportHeight`.
    private var renderedHeights: [String: CGFloat] = [:]
    // ⛔ THE BOTTOM BAR LIVES HERE NOW — the reference app's own arrangement, read from their
    // `ConversationViewController+BottomBar.swift`: the bar is a subview of the CONVERSATION
    // controller and its bottom is pinned to the keyboard, so UIKit moves it inside the keyboard's
    // animation — the same animation this list's insets already ride. One clock, nothing to
    // coordinate.
    //
    // ⚠️ AND IT PINS TO `keyboardLayoutGuide.topAnchor`, EXACTLY AS THEIRS DOES. An earlier note
    // here said we could not, on the strength of build 682, where the guide never moved inside this
    // hosted controller — but that measurement predates the priming in `viewDidLoad`
    // (`_ = view.keyboardLayoutGuide`), which is the reference's own documented workaround for the
    // iOS 26 regression where a guide first read late reports the home-indicator height. Everything
    // that stood in for the guide — the notification observers, the band, the report, the finger
    // feeder — is deleted. See `keyboardOverlap`.
    //
    // ⚠️ AND THEIRS DOES NOT ATTACH EVERY BAR. `ConversationBottomBar.shouldAttachToKeyboardLayoutGuide`
    // is false for their blocking/error panels, which pin to the screen bottom instead — there is no
    // keyboard when you cannot type. Ours keeps its blocked / request / muted bars in SwiftUI for
    // the same reason.
    let bottomBarContainer = UIView()
    private var bottomBarHeight: NSLayoutConstraint?
    private var barLeading: NSLayoutConstraint?
    private var barTrailing: NSLayoutConstraint?
    private var barBottom: NSLayoutConstraint?
    private var barHeightC: NSLayoutConstraint?
    /// The container's top, tied to the bar's. Deactivated while the composer is hidden so the
    /// container can collapse — a hidden view still takes part in Auto Layout. See `hideComposer`.
    private var barTopPin: NSLayoutConstraint?
    /// The system layout margin, from ThreadView. The bar's insets are derived from it in
    /// `positionBottomBar`, which is the ONE writer of the bar's constraints.
    private var composerMargin: CGFloat = 20
    /// Under the pill when the bar rides the keyboard: the reference app's own vMargin,
    /// 0.5 * (56 - 40). Unchanged from the SwiftUI placement (ThreadView's `composerKeyboardGap`).
    private static let composerKeyboardGap: CGFloat = 8
    /// The pad above the pill, inside the bar's container: their toolbar's vMargin, the same
    /// 0.5 * (56 - 40) = 8. Was 6 (the 2026-08-26 audit).
    private static let barTopPad: CGFloat = 8
    /// How far the pill sinks below the safe-area line at rest, into the indicator band, the way
    /// the system bars sit (owner's number, 2026-08-24; ThreadView's `composerRestDip`).
    private static let composerRestDip: CGFloat = 5
    /// The composer, once ThreadView hands it over. Nil for the announcements list, which has none.
    private(set) weak var composerBar: UIView?

    /// ⛔ THE DOCK OVERLAYS — the reference app's scroll buttons, in our shape. Two hosted SwiftUI
    /// views (the reaction-jump badge stacked over the jump-to-latest arrow on the trailing side, the
    /// other side's recording bubble on the leading one), positioned by Auto Layout from this
    /// controller so they ride the keyboard's animation with the bar instead of arriving a runloop
    /// later on a spring of SwiftUI's own. The CONTENT is ThreadView's, untouched.
    ///
    /// ⚠️ 10, not their 24. Theirs pins `-24` from the container's top; ours keeps the number the
    /// SwiftUI overlay was already using, because the instruction was to change the architecture and
    /// leave the appearance alone.
    private static let dockOverlayGap: CGFloat = 10
    private var dockOverlayTrailingHost: UIHostingController<AnyView>?
    private var dockOverlayLeadingHost: UIHostingController<AnyView>?
    private var dockOverlayComposerTopHost: UIHostingController<AnyView>?
    private var dockOverlayBottom: NSLayoutConstraint?
    private var dockOverlayTrailingC: NSLayoutConstraint?
    private var dockOverlayLeadingBottom: NSLayoutConstraint?
    private var dockOverlayTopLeadingC: NSLayoutConstraint?
    private var dockOverlayTopTrailingC: NSLayoutConstraint?

    /// Hand the overlays their content. Called on every SwiftUI update; assigning `rootView` is how a
    /// hosting controller takes a new body, and SwiftUI diffs it exactly as it would in place.
    func setDockOverlays(trailing: AnyView, leading: AnyView, composerTop: AnyView) {
        if dockOverlayTrailingHost == nil { buildDockOverlays() }
        dockOverlayTrailingHost?.rootView = trailing
        dockOverlayLeadingHost?.rootView = leading
        dockOverlayComposerTopHost?.rootView = composerTop
    }

    private func buildDockOverlays() {
        guard isViewLoaded else { return }
        func makeHost() -> UIHostingController<AnyView> {
            let host = UIHostingController(rootView: AnyView(EmptyView()))
            host.view.backgroundColor = .clear
            // The host is a transparent lid over the list: it must never take a touch that was meant
            // for a bubble, and its own SwiftUI content still takes its own.
            host.view.isUserInteractionEnabled = true
            host.view.translatesAutoresizingMaskIntoConstraints = false
            addChild(host)
            view.addSubview(host.view)
            host.didMove(toParent: self)
            return host
        }
        let trailingHost = makeHost()
        let leadingHost = makeHost()
        let topHost = makeHost()
        dockOverlayTrailingHost = trailingHost
        dockOverlayLeadingHost = leadingHost
        dockOverlayComposerTopHost = topHost

        let tBottom = trailingHost.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        let tTrail = trailingHost.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        let lBottom = leadingHost.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        dockOverlayBottom = tBottom
        dockOverlayTrailingC = tTrail
        dockOverlayLeadingBottom = lBottom
        // The picker's bottom edge is the BAR's top edge. In the slot it came from that worked out
        // as `composerLift - 8` above the keyboard's top, and the container's top is `barTopPad`
        // above the bar's — so the same line, expressed against the thing it was always describing.
        let topLead = topHost.view.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        let topTrail = topHost.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        dockOverlayTopLeadingC = topLead
        dockOverlayTopTrailingC = topTrail
        NSLayoutConstraint.activate([
            tBottom, tTrail,
            lBottom,
            // The recording bubble's own inset, the same 12 the SwiftUI overlay used.
            leadingHost.view.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            topLead, topTrail,
            topHost.view.bottomAnchor.constraint(equalTo: bottomBarContainer.topAnchor,
                                                 constant: Self.barTopPad),
        ])
        // Above the composer, never under it.
        view.bringSubviewToFront(bottomBarContainer)
    }

    private var captureFreezeUntil = Date.distantPast    // system screenshot capture owns the scroll until then
    /// A send has begun and its row has not landed yet: hold the offset so the composer's own
    /// shrink cannot walk the content down before the glide walks it back up. See `updateInsets`.
    private var sendHoldUntil = Date.distantPast
    private var lastSendTick = 0
    private var popGestureHooked = false                 // interactive-pop target attached once
    // The recognizer we attached to, so it can be released again. It belongs to the NAVIGATION
    // controller, which outlives every pushed thread, and a recognizer retains its targets — leaving
    // this attached kept the whole controller (its cells, height cache, sizer, repository and every
    // decrypted message) alive for the session, once per chat opened (audit).
    private weak var hookedPopGesture: UIGestureRecognizer?
    private var scrollWorkTimer: Timer?                  // 0.1s debounce for pagination + isAtBottom writes
    private var userScrolledSinceTimer = false           // the debounced work only pages on USER scrolls
    // Every programmatic animated scroll is tracked: while one is in flight, no land may invalidate the
    // layout under it. A 5s watchdog force-clears the flag if UIKit cancels the animation without a
    // completion callback â€” a wedged flag would block lands forever.
    private var programmaticScrollAnimating = false
    private var scrollAnimationWatchdog: Timer?
    private var lastLoadOlderAt = Date.distantPast       // pagination throttle (2s window)
    private var isDisappearing = false        // swipe-back / pop in progress â†’ freeze all content-offset work
    /// ⛔ THEIR `isViewCompletelyAppeared`, AND `isDisappearing` WAS ONLY HALF OF IT. Theirs is set in
    /// `viewDidAppear` and cleared in `viewWillDisappear`, and it gates the lockstep shift alone
    /// (`} else if isViewCompletelyAppeared {`). Ours cleared its flag on the way out but raised it
    /// again in `viewWillAppear` — so coming BACK from a pushed screen the lockstep ran for the whole
    /// return transition, which is exactly the window where the keyboard is being restored and the
    /// composer re-measured, and offsets were written from geometry that had not settled. The leaving
    /// half stays `isDisappearing`, which must freeze more than the lockstep; this is the arriving half.
    private var isViewCompletelyAppeared = false
    /// ⛔ THE CLEARANCE THE READER LAST ACTUALLY HAD, and the honest input to the lockstep shift.
    ///
    /// Reading the delta off the content inset — raw OR adjusted, they are the same number — measures
    /// the wrong thing, and this is the real remainder of his 2026-08-27 report. `oldInsets.bottom`
    /// was written against the safe area of an EARLIER pass, while `safe.bottom` is read now, so when
    /// SwiftUI flaps the hosted safe area at the focus instant the difference contains the flap:
    /// `Δclearance − Δsafe` rather than `Δclearance`. The list did not move — the clearance is
    /// identical — and a scrolled reader was shifted by the flap anyway.
    ///
    /// The clearance is the number the reader actually experiences (the container's height: keyboard
    /// plus composer plus gap), it is immune to which safe area any particular pass happened to see,
    /// and after the plain subtraction it is exactly what the adjusted inset equals.
    ///
    /// ⚠️ IT IS ONLY ADVANCED WHEN THE SHIFT WAS ACTUALLY MADE, OR WAS GENUINELY NOT OWED. Every
    /// stand-down in `updateInsets` writes the insets and then returns — a send hold, a context menu,
    /// a view that has not finished appearing — and because that method is edge-triggered
    /// (`guard didChangeInsets`) the very next pass sees nothing to do and the shift is lost for good.
    /// Leaving this value behind on those paths turns the debt into something the next pass can still
    /// see and pay.
    private var lastAppliedClearance: CGFloat?
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
        // the reference app's animator completion fires. The timer only covers the case that notification never
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
    var rowModels: [String: MessageRowModel] = [:]   // frozen routing snapshot (set before every apply)
    /// The plans behind those models. One per (row, width), so the height pass and the cell's own
    /// layout are literally the same value object — see RowPlanStore.
    let planStore = RowPlanStore()
    var cid: String = ""                              // the conversation, for the rows' own image loads
    var uikitMenu: (String) -> UIMenu? = { _ in nil }
    var onUikitDoubleTap: (String) -> Void = { _ in }
    var onTapLink: (URL) -> Void = { _ in }
    var onTapQuote: (String) -> Void = { _ in }
    var onTapStoryQuote: (_ rowId: String, _ replyId: String) -> Void = { _, _ in }
    var onTapMedia: (String) -> Void = { _ in }
    var onTapPill: (String) -> Void = { _ in }
    var onTapReadMore: (String) -> Void = { _ in }
    var onTapAlbumTile: (_ rowId: String, _ index: Int) -> Void = { _, _ in }
    var onTapFile: (String) -> Void = { _ in }
    var onToggleVoice: (String) -> Void = { _ in }
    var onTapStoryReplyCard: (String) -> Void = { _ in }
    var onTapLinkCard: (String) -> Void = { _ in }
    var onTapLinkProfile: (String) -> Void = { _ in }
    var onTapLocation: (String) -> Void = { _ in }
    var onTapContactCard: (String) -> Void = { _ in }
    var onTapContactMessage: (String) -> Void = { _ in }
    var onTapReactions: (String) -> Void = { _ in }
    var onTapRetry: (String) -> Void = { _ in }
    var onToggleSelect: (String) -> Void = { _ in }
    var onTapSender: (String) -> Void = { _ in }
    var onTapCallRow: (String) -> Void = { _ in }
    var onTapPinNotice: (String) -> Void = { _ in }
    // CUSTOM LONG-PRESS MENU (experiment — CMContextMenu.swift). Fed from SwiftUI like every callback.
    var customMenuActions: (String) -> [CMAction] = { _ in [] }
    var customReactConfig: (String) -> (emojis: [String], selected: String?)? = { _ in nil }
    var onCustomReact: (String, CMReactionSelection) -> Void = { _, _ in }
    var onMenuCloseKeyboard: () -> Bool = { false }
    var onMenuRestoreKeyboard: () -> Void = {}
    private var customPress: UILongPressGestureRecognizer!   // the driver: 0.2s, streams into the overlay
    // One active presentation at a time. sourceView is the REAL bubble (hidden while the menu is up);
    // squeezeToken cancels a squeeze whose press ended before the 0.2s ripened.
    private var activeMenu: (overlay: CMOverlay, sourceView: UIView, keyboardWasUp: Bool)?
    private weak var activeMenuCell: UICollectionViewCell?   // its touches are cut while the menu is up
    private var squeezeToken = 0
    // Route each id was last CONFIGURED with (uikit vs SwiftUI cell). A content change that flips the
    // route needs reloadItems (re-dequeue the other cell class) â€” reconfigureItems reuses the same cell
    // instance, which can't switch renderers.
    private var configuredRoutes: [String: Bool] = [:]
    private var doubleTapGesture: UITapGestureRecognizer!
    private var holdPress: UILongPressGestureRecognizer!     // passive: marks the context-menu lift window
    private var interactionHoldUntil = Date.distantPast      // lands defer while a long-press is in flight
    private var contextMenuVisible = false                   // UIKit says a context menu is on screen
    private var contextMenuSourceId: String?                 // the row that menu lifted from
    private var uikitReg: UICollectionView.CellRegistration<MessageRowCell, String>!
    private var swipePan: UIPanGestureRecognizer!
    private weak var swipingCell: UICollectionViewCell?
    private var swipingId: String?
    private var swipeArrow: UIImageView?
    private var swipeTriggered = false         // crossed the reply threshold this drag (haptic + fire on release)
    /// Their `swipeActionOffsetThreshold`, verbatim. Ours was 50.
    private static let swipeThreshold: CGFloat = 55

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
    /// THE REFERENCE APP'S `lastKnownDistanceFromBottom`, and the whole answer to "what happens to the
    /// reader when the geometry changes". Recorded whenever the reader (or one of our own scroll
    /// intents) puts the list somewhere; consulted whenever an inset, the keyboard, the composer or the
    /// safe area moves the bounds. Zero means "at the newest message", which is where a keyboard open
    /// must keep them: the composer rides up, and the last bubble stays just above it.
    ///
    /// ⛔ THE LIST SLID UNDER THE KEYBOARD IN BUILD 674 — owner, 2026-08-25, screenshot. Un-inverting
    /// moved the safe-area terms out of `updateInsets` (UIKit folds them correctly now), and with them
    /// went the only thing that made that method NOTICE a keyboard: its early-return compared our two
    /// contentInset values, which a keyboard does not change. The adjusted inset grew by 300pt, the
    /// offset stayed, and the content sat under the keys. Reading the live "am I at the newest?" at that
    /// moment is no good either, because the bound has already moved. A distance recorded BEFORE the
    /// change is the only honest answer, which is exactly why theirs keeps one.
    ///
    /// ⚠️ OPTIONAL, as theirs is. `nil` is "nothing has been recorded yet", which is a different fact
    /// from "recorded as zero" and must not be spelled the same way: a non-optional zero default made
    /// "never asked" indistinguishable from "at the newest message" for every reader of this value.
    /// It is nil only before the first land, and the first land positions the reader itself.
    private var lastKnownDistanceFromBottom: CGFloat?
    /// Theirs: safe-area changes are debounced (0.01s, last only) because an interactive dismiss
    /// updates the safe area "rapidly in quick succession". The layout path is never debounced.
    private var safeAreaInsetsWork: DispatchWorkItem?

    /// Record where the reader is, as a distance from the newest message. Cheap; called often.
    private func recordDistanceFromBottom() {
        guard didFirstLand else { return }
        lastKnownDistanceFromBottom = max(0, maxContentOffsetY - collectionView.contentOffset.y)
        reportReadingPosition()
    }

    /// ⛔ THE READING POSITION, FOR REOPENING THE CHAT. Theirs saves the last visible interaction and
    /// how much of it was on screen, then restores to that exact place on the next open. Ours is the
    /// same pair — the top-most visible row and how far its top sits below the viewport's top edge —
    /// reported from here because `recordDistanceFromBottom` already runs at every moment the list
    /// has come to rest, which is exactly when the answer is worth writing down.
    ///
    /// ⚠️ AT THE NEWEST MESSAGE IT REPORTS NIL, and nil is not "unknown", it is "the bottom". A chat
    /// left at the newest should open at the newest, which is what no stored position already means;
    /// storing a sentinel for it would be a second way to say the same thing and the two could
    /// disagree. Theirs takes the same view — a reader within a screenful of the end short-circuits
    /// to the bottom of the load window rather than restoring a row.
    private func reportReadingPosition() {
        guard didFirstLand, !isDisappearing else { return }
        if isAtNewest { onReadingPosition(nil); return }
        guard let ip = viewportIndexPaths().first,
              let id = dataSource.itemIdentifier(for: ip),
              let attr = collectionView.layoutAttributesForItem(at: ip) else { return }
        let viewportTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        onReadingPosition(ChatReadingPosition(rowId: id,
                                              offsetFromTop: attr.frame.minY - viewportTop))
    }
    private let dateLabel = UILabel()
    private var dateFadeWork: DispatchWorkItem?
    private var lastDateId: String?
    var onTopInset: ((CGFloat) -> Void)?      // ThreadView positions the date pill / pinned bar with this
    /// ⛔ HOW FAR THE COMPOSER RISES ABOVE THE KEYBOARD (or above the safe-area line at rest): the
    /// container's height less the keyboard band. SwiftUI's floating overlays — the jump-to-latest
    /// arrow, the reaction jump, the other side's recording bubble — sit above the bar by this.
    ///
    /// They used to need no such number: the bar was SwiftUI's `safeAreaBar`, so it GREW the bottom
    /// safe area and a `.padding(.bottom, 10)` landed above it for free. The bar is UIKit's now and
    /// the SwiftUI slot is a zero-height spacer, so that padding started from the keyboard instead
    /// and the arrow came down on top of the mic button — his report, 2026-08-26, and the same shape
    /// of failure as the pause button in `positionVoiceControl`.
    ///
    /// The second number is the bar's SIDE inset, so the overlays sit on the bar's own edge. It used
    /// to be recomputed in ThreadView from the keyboard's notification — a second copy of
    /// `positionBottomBar`'s arithmetic, a pass behind it.
    private var lastReportedLift: CGFloat = -1
    private var lastReportedSide: CGFloat = -1
    private var lastReportedTop: CGFloat = -1

    override func viewDidLoad() {
        super.viewDidLoad()
        layout = MessageLayout()
        // ⛔ THE HEIGHT IS RESOLVED THROUGH THE DATA SOURCE, NEVER THROUGH `currentIds` — owner,
        // 2026-08-25, reporting rows that jump and draw on top of each other while scrolling.
        //
        // ⚠️ TWO SOURCES OF TRUTH, AND THEY DISAGREE FOR A WINDOW. `prepare()` walks
        // `0..<collectionView.numberOfItems`, i.e. the COLLECTION VIEW's idea of the list. This closure
        // used to index `currentIds`, which `apply()` assigns BEFORE handing the snapshot over — so
        // between those two statements the collection view still holds the OLD order while this array
        // holds the NEW one, and index i means two different rows to the two of them.
        //
        // While the list was inverted that was harmless: history was APPENDED, so indices 0..<oldCount
        // still meant the same rows and the frames came out identical. Top-down, history is PREPENDED —
        // index 0 becomes a different message — so every frame in the rebuild got some other row's
        // height. Rows land in the wrong places and a tall row inside a short frame spills over its
        // neighbour: exactly the jumping and overlapping he photographed.
        //
        // Asking the data source removes the second source entirely. `itemIdentifier(for:)` and
        // `numberOfItems` are the same object's view of the world, so they cannot disagree: mid-window
        // the rebuild produces correct OLD frames, and the moment the snapshot lands the count/generation
        // guard rebuilds correct NEW ones.
        layout.heightForItem = { [weak self] index in
            guard let self,
                  let id = self.dataSource.itemIdentifier(for: IndexPath(item: index, section: 0))
            else { return 44 }
            return self.heights[id] ?? 44
        }
        collectionView = HardenedCollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.isPrefetchingEnabled = false   // off until first appearance (faster, jank-free open)
        collectionView.backgroundColor = .clear
        collectionView.alpha = 0   // invisible until the first render is final â€” never shows a mid-measure frame
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .interactive
        // `.always`: UIKit folds the safe area in on the correct sides now that nothing is mirrored.
        // The nav bar lands in adjustedContentInset.top and the home indicator in .bottom. NOT the
        // keyboard: the SwiftUI side ignores the keyboard region for this list (see `nativeList` in
        // ThreadView for the clamp-jump that came with it), so the keyboard reaches this view only
        // through `view.keyboardLayoutGuide`, inside the keyboard's own animation block.
        // updateInsets() adds the rest: the keyboard band, the pinned bar and the composer.
        collectionView.contentInsetAdjustmentBehavior = .always
        // THE SYSTEM'S SCROLL EDGE EFFECTS ARE ON, UNTOUCHED (owner, 2026-08-25). This is the iOS 26
        // Liquid Glass blur under the header he asked for, and it is the whole reason the list is
        // top-down again (see the file comment). They were hidden here from 2026-07-29, after three
        // device attempts on the inverted list washed the entire chat; the verdict that stood here
        // recommended exactly this un-inversion. Nothing is configured: `.automatic` on both edges is
        // what the reference app's list has, because it sets nothing either.
        // ⛔ EXCEPT THE BOTTOM ONE, ON HIS ORDER — 2026-08-25, build 682, screenshot of a wall of
        // frost over the chat: "remove chat bottom blur, don't touch top header". The bottom edge
        // effect covers the whole clearance band above the composer, and our clearance is large.
        // The TOP one stays: it is the header blur he asked for.
        collectionView.bottomEdgeEffect.isHidden = true
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        bottomBarContainer.translatesAutoresizingMaskIntoConstraints = false
        bottomBarContainer.backgroundColor = .clear
        // The container paints nothing and must not swallow touches meant for the list; its
        // SUBVIEW (the composer) takes its own.
        view.addSubview(bottomBarContainer)
        // ⛔ THEIR SHAPE, AND THE HEIGHT IS THE WHOLE POINT. The container's BOTTOM is the view's
        // bottom — not the keyboard's top — so it spans from the bar's top all the way down and its
        // height ALREADY CONTAINS THE KEYBOARD. That is what lets the content inset be one
        // expression rather than a sum of parts that arrive a beat apart:
        //
        //     newInsets.bottom = bottomBarContainer.frame.height - collectionView.safeAreaInsets.bottom
        //
        // Ours used to assemble `keyboardBand + composerBarH + 12`, and this file's own notes record
        // what that cost: "the clearance is assembled from parts arriving a beat apart… a reader
        // pinned before a late part is left that part short".
        // ⛔ LOW PRIORITY, AND THAT IS THE WHOLE POINT. Once the bar exists, the container's height
        // is fully determined by three REQUIRED constraints: its bottom is the view's, its top is
        // the bar's top less `barTopPad`, and the bar has its own height and bottom. This constant
        // is a fourth answer to the same question, and Auto Layout may satisfy it by breaking one
        // of the others — including the top pin, which leaves the bar's upper part (the reply
        // banner, and its X) OUTSIDE the container's bounds. A view does not hit-test outside its
        // own bounds, and the container does not clip, so the banner drew normally and its close
        // button was dead. His report, 2026-08-26: "Reply X button is not working."
        //
        // At `defaultLow` the constant can never break anything: it only answers when there is no
        // bar at all (the announcements list), where nothing else gives the container a height.
        let containerHeight = bottomBarContainer.heightAnchor.constraint(equalToConstant: 0)
        containerHeight.priority = .defaultLow
        bottomBarHeight = containerHeight
        NSLayoutConstraint.activate([
            bottomBarContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBarContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBarContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            containerHeight,
        ])

        // Touched once here first: theirs notes that on iOS 26 a guide first read late reports the
        // home-indicator height (34) instead of the keyboard's, and that reading it early fixes it.
        _ = view.keyboardLayoutGuide

        // ⛔ THE KEYBOARD IS `view.keyboardLayoutGuide`, AND THAT IS THE WHOLE OF IT. Theirs, on iOS 16
        // and up: the bottom bar's bottom anchor is constrained to the guide's top and there is no
        // other keyboard code in the conversation view at all — no observers, no stored height, no
        // animation bookkeeping. UIKit moves the guide inside the keyboard's own animation, the
        // constraint dirties this view's layout, `viewDidLayoutSubviews` therefore runs INSIDE that
        // animation, and `updateInsets` recomputes the list's clearance from the container's height
        // there. The interactive dismiss follows the finger for free, for the same reason.
        //
        // The composer takes that constraint in `applyComposer`. Nothing to build here.

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

        // THE CUSTOM MENU DRIVER (experiment — CMContextMenu.swift). the reference app's press: 0.2s to begin,
        // squeeze while it ripens, then the SAME press keeps streaming into the overlay so a finger
        // can slide onto a row or an emoji and lift to select. cancelsTouchesInView stays true (the
        // default): once the menu ripens, the touch belongs to it, not to the row underneath.
        customPress = UILongPressGestureRecognizer(target: self, action: #selector(handleCustomPress(_:)))
        customPress.minimumPressDuration = 0.2
        customPress.delegate = self
        collectionView.addGestureRecognizer(customPress)

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

        // Context-menu dismissal end detector — see menuWindowDidHide. Registered permanently; the
        // handler is inert outside an armed menu-dismissal grace window.
        NotificationCenter.default.addObserver(self, selector: #selector(menuWindowDidHide(_:)),
                                               name: UIWindow.didBecomeHiddenNotification, object: nil)
        // NO KEYBOARD OBSERVERS. Theirs has none on iOS 16+, and neither do we: the composer's bottom
        // is constrained to `view.keyboardLayoutGuide` and UIKit does the rest. See `keyboardOverlap`.
        // Screenshot recovery: iOS 26's full-page capture scrolls the list; snap back afterwards.
        NotificationCenter.default.addObserver(self, selector: #selector(screenshotTaken),
                                               name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        // THE DOWN ARROW'S DIRECT LINE (owner 2026-08-13, third report, still dead on build 570 with
        // all three earlier fixes in it).
        //
        // Everything tried so far assumed the request was arriving and something downstream was
        // undoing it. Two fixes to the scroll itself and an arrival check that FORCES the offset half
        // a second later did not change what he sees, and the only honest reading left is that the
        // request never gets here at all. It had five layers to survive: a SwiftUI @State, a
        // Binding into the representable, an updateUIView pass, an apply() with its own early
        // returns and id comparison, and finally the intent gate — and the binding that carries it
        // is ONE-SHOT, cleared a runloop later, so anything that drops it drops it for good.
        //
        // So the button gets a wire straight to this controller. No state, no binding, no apply, no
        // id comparison: post, receive, scroll. The old path stays for the reply/search jumps, which
        // legitimately ride the load.
        NotificationCenter.default.addObserver(self, selector: #selector(jumpToNewestRequested),
                                               name: .chatListJumpToNewest, object: nil)

        buildDataSource()
    }

    /// One live list at a time answers this. A pushed-then-popped thread leaves its controller alive
    /// until ARC catches up, and a controller with no window has no reader to move.
    @objc private func jumpToNewestRequested() {
        guard collectionView.window != nil else { return }
        // Only the down-arrow posts this (see the observer above), so it is user-initiated by
        // definition and does not wait for a finger to lift.
        perform(.newest(animated: true, userInitiated: true))
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
                    .environment(\.rowWidth, hostW)   // same number the sizer measured with
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
        // Native UIKit row registration (the migration path).
        uikitReg = UICollectionView.CellRegistration<MessageRowCell, String> { [weak self] cell, _, id in
            guard let self, let m = self.rowModels[id], self.collectionView.bounds.width > 0 else { return }
            let plan = self.planStore.plan(for: m, width: self.collectionView.bounds.width)
            cell.delegate = self
            cell.configure(m, plan: plan, cid: self.cid)
            // Safety net: UIKit rows never report a rendered height (they cannot drift on their own —
            // the plan IS the height), but an OFFSCREEN content change can leave a stale cached
            // number. Verify at dequeue and adopt if the cache drifted.
            //
            // This used to be a jump. It called a reconcile that invalidated the layout and then SKIPPED
            // the offset correction whenever the list was moving, so frames shifted under a fast scroll
            // with nothing holding the reader. It is safe now for a structural reason: adoptHeight routes
            // through the layout, and a row further from the origin than the reader cannot move them at
            // all, which is every row you are scrolling towards in a conversation.
            if let cached = self.heights[id], abs(cached - plan.height) > 2 {
                DispatchQueue.main.async { [weak self] in self?.adoptHeight(plan.height, for: id) }
            }
        }
        dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) { [weak self] cv, ip, id in
            guard let self else { return UICollectionViewCell() }
            // ROUTER: native UIKit cell when the message is supported (plain 1:1 delivered text), else the
            // SwiftUI hosting cell. Routing reads the FROZEN snapshot dict, never live view state.
            let desired = self.rowModels[id] != nil
            // CRASH GUARD (.ips build 542, SIGABRT mid fast chat). A queued reconfigure can execute
            // LATER than the code that queued it — UIKit holds a prefetched cell's reconfigure until
            // the cell scrolls in. If the route flipped in that gap (a send confirming, a re-sort
            // moving the date pill or the cluster caps), dequeueing the new class here hands the
            // reconfigure a different cell type than the one it is refreshing, and UIKit aborts the
            // app. So: serve the class this id's cell was LAST configured with — always legal — and
            // swap renderers with a real reload one runloop later.
            let route = self.configuredRoutes[id] ?? desired
            if route != desired { self.scheduleRouteRepair(id) }
            self.configuredRoutes[id] = route
            if route {
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
        // Native UIKit row: this is not a measurement in the old sense at all. It asks for the row's
        // PLAN — the same value object the cell provider will lay the row out from, cached per
        // (row, width) — and returns its height. Measurement and render cannot disagree because
        // there is only one of them.
        if let m = rowModels[id], width > 0 {
            return planStore.plan(for: m, width: width).height
        }
        // A ROW THE SIZER HAS BEEN PROVEN WRONG ABOUT KEEPS WHAT IT RENDERED. Asking again would return
        // the same wrong number; the render is the only measurement of such a row that was ever true.
        if let rendered = renderedHeights[id] { return rendered }
        // Measure EXACTLY as the cell renders: the cell wraps its content in `.frame(width: hostWidth)`,
        // so the sizer must apply the SAME explicit width frame â€” not just a sizeThatFits width proposal.
        // The two constraint mechanisms wrap Text differently in edge cases, and any disagreement made the
        // layout frame not match the rendered cell â†’ overlap, and a permanent rendered-vs-measured
        // mismatch that reconciled forever.
        // `.isMeasuringRow` mutes the row's visibility side effects for this pass; see the key's note.
        // It changes nothing about layout, so the measurement stays identical to the render.
        sizer.rootView = AnyView(coordinator.parent.row(id).frame(width: width)
            .environment(\.isMeasuringRow, true)
            .environment(\.rowWidth, width))
        let size = sizer.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        return ceil(size.height)
    }

    // Ensure every id in `ids` has a cached height (measured at the current width). No-op once cached.
    private func measureMissing(_ ids: [String], width: CGFloat) {
        guard width > 0 else { return }
        for id in ids where heights[id] == nil { heights[id] = measure(id, width: width) }
        measuredWidth = width
    }

    // Frame minY per row for an id order, exactly what MessageLayout will produce (y-accumulated heights
    // from the oldest). Used to build the before/after maps of the scroll-continuity token.
    /// ⛔ A ROW THAT CHANGED WHILE OFF SCREEN STILL CHANGED HEIGHT — his report, 2026-08-26, with a
    /// photograph of the unread divider stacked into the bubbles around it, and the second time that
    /// exact picture has been sent.
    ///
    /// Every path that lands content asks `rowSignatures` which rows changed, and every one of them
    /// asked it about the VISIBLE rows only — then wrote `lastRowSigs = rowSignatures`, marking the
    /// off-screen changes as seen. That is right for RECONFIGURE (reconfiguring a cell you cannot
    /// see is wasted work, and reconfiguring every visible cell on every emission was the flashing),
    /// and wrong for MEASUREMENT, which is not about cells at all.
    ///
    /// The unread divider is the case that proves it: the chat opens at the newest message and
    /// `anchorUnread` then marks the first unread, which is by definition a screen or more above the
    /// reader. That row grows by ~33pt, nothing re-measures it, and when the reader scrolls up the
    /// cell draws a divider inside a frame that never made room for it.
    ///
    /// The reader is held still by the same anchor the load paths use: rows above them that changed
    /// height move their content, and the delta puts it back.
    private func remeasureOffscreenChanged(_ changed: [String], visible: Set<String>) {
        let width = collectionView.bounds.width
        guard width > 0 else { return }
        let offscreen = changed.filter { !visible.contains($0) }
        guard !offscreen.isEmpty else { return }
        collectionView.layoutIfNeeded()
        // A row changing height in place, which is their `.loadSameLocation`: bottom-biased.
        let anchors = continuityAnchors(relativeToTop: false)
        let before = frameMinY(for: currentIds)
        var moved = false
        for id in offscreen {
            let h = measure(id, width: width)
            guard abs((heights[id] ?? h) - h) > 0.5 else { continue }
            heights[id] = h
            moved = true
        }
        guard moved else { return }
        let after = frameMinY(for: currentIds)
        layout.generation += 1
        layout.invalidateLayout()
        guard let landed = continuityDelta(anchors, before: before, after: after),
              abs(landed.delta) > 0.5 else { return }
        collectionView.layoutIfNeeded()
        // ⛔ NEVER INSIDE ANOTHER WRITER'S PASS. This is the one offset write in the file that had no
        // stand-down at all, and it is reachable from `apply`'s same-ids path — which an inset update
        // can be running underneath. Writing here then hands the rest of that update an offset it did
        // not measure. (A finger is deliberately NOT excluded: unlike `verifyAnchor`, this correction
        // is the only thing keeping the reader still when an OFF-SCREEN row above them changes
        // height, and skipping it would move them rather than merely fail to hold them.)
        guard !isUpdatingInsets else { return }
        let y = clampOffset(collectionView.contentOffset.y + landed.delta)
        guard abs(collectionView.contentOffset.y - y) > 0.5 else { return }
        UIView.performWithoutAnimation {
            collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        }
    }

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
        guard didReveal else { return }   // never re-lay-out during the open — the pre-measure owns it
        // ⛔ AND NEVER SYNCHRONOUSLY, BECAUSE THIS IS A RENDER PASS. `reportHeight` is called from a
        // SwiftUI `onPreferenceChange` inside the cell's own update, and the tail of this method
        // invalidates the layout and calls `layoutIfNeeded()`. Doing that from inside a layout/render
        // pass re-enters UIKit's layout while it is still walking the previous one, which is a
        // documented way to get inconsistent frames — bubbles landing on top of one another mid-scroll.
        // The reference app never invalidates layout from a cell at all; a size change there goes
        // through a fresh load. One runloop hop is the cheap equivalent of that rule.
        DispatchQueue.main.async { [weak self] in self?.applyReportedHeight(hh, for: id) }
    }

    /// The tail of `reportHeight`, one runloop tick later. Re-checks staleness because the row may have
    /// been re-measured, replaced or trimmed in the gap.
    private func applyReportedHeight(_ hh: CGFloat, for id: String) {
        guard isViewLoaded, !isDisappearing, currentIds.contains(id) else { return }
        guard let cached = heights[id], abs(cached - hh) > 2 else { return }
        guard canLandLoad else { needsRefreshOnSettle = true; pendingSettleHeights.insert(id); return }
        let w = collectionView.bounds.width
        guard w > 0 else { return }
        // ⛔ A REFUSED ROW TAKES THE HEIGHT IT RENDERED AT — owner, 2026-08-25, bubbles drawn on top of
        // one another. This used to `return` for a refused row and, before that, adopt the SIZER's
        // number for every row: so a row the sizer measured SHORT kept a short frame while its content
        // drew at full height, and `MessageLayout` refuses self-sizing, so the overflow landed on the
        // next bubble. `sizerRefused` then guaranteed it was never revisited: permanent overlap.
        //
        // ⚠️ THE JUSTIFICATION THAT USED TO STAND HERE IS STALE, and it is worth knowing why. It said a
        // LinkPreviewCard "renders nothing until an async fetch completes". That has not been true since
        // previews started travelling WITH the message (see `ThreadView`, the card is built from
        // `message.linkPreview` and there is no viewer-side fetch). Audited today, EVERY bubble type
        // measures deterministically — images and video from stored width/height, albums from a pure
        // solver, voice from stated constants. So this branch should now be close to dead. It is kept
        // as a net, not a routine path: if a row ever does render at a height the sizer cannot produce,
        // the render is what the person can see, and the layout must agree with it rather than with a
        // number that has already been proven wrong.
        //
        // ⚠️ THE OLD COMMENT'S FEAR WAS REAL BUT ITS FIX WAS BACKWARDS. Two authorities did fight:
        // reportHeight adopted the render, the apply path re-measured with the sizer and put the wrong
        // number back, and the pair reconciled forever. The answer is not to crown the wrong one — it is
        // to make there be ONE. `renderedHeights` records the truth for that row and `measure()` returns
        // it, so both paths now say the same thing and the loop cannot form. It also self-terminates:
        // once adopted, the next report matches the cache and returns at the guard above.
        if sizerRefused.contains(id) {
            renderedHeights[id] = hh
            adoptHeight(hh, for: id)
            return
        }
        let sized = measure(id, width: w)
        if abs(sized - hh) > 2 {
            sizerRefused.insert(id)
            renderedHeights[id] = hh
            adoptHeight(hh, for: id)   // the render is the truth for this row from here on
            return
        }
        adoptHeight(sized, for: id)
    }

    // MARK: - The single position owner

    // ADOPT A NEW HEIGHT FOR ONE ROW, KEEPING THE READER STILL.
    //
    // This is the only path by which a height changes after a row has been measured, and it is the whole
    // late-height story: there is no second mechanism, no capture/restore, no post-hoc setContentOffset.
    //
    // The correction rides `contentOffsetAdjustment` on the invalidation context, so it lands in the same
    // layout transaction as the frame change, never a frame late. The delta is zero unless the changed row
    // lies ABOVE the reader's anchor; a row below the viewport moves nothing they can see.
    private func adoptHeight(_ h: CGFloat, for id: String) {
        guard collectionView.bounds.height > 0, let cached = heights[id], abs(cached - h) > 2 else { return }
        guard canLandLoad else {
            pendingSettleHeights.insert(id)
            needsRefreshOnSettle = true
            return
        }
        // Captured BEFORE the height lands, so the anchors describe the layout the reader is
        // looking at rather than the one being built (their token is taken before the update too).
        //
        // ⛔ BOTTOM-BIASED, AND THIS IS THE SITE THE 2026-08-27 BUG RAN THROUGH. A row adopting its
        // real rendered height is a change in place; the rows that do it while the reader comes back
        // down a conversation sit BELOW the top of the viewport, so a top-biased anchor could not see
        // them move and returned a zero correction while the content grew taller.
        let anchors = continuityAnchors(relativeToTop: false)
        let beforeY = frameMinY(for: currentIds)
        heights[id] = h
        let afterY = frameMinY(for: currentIds)
        layout.generation += 1
        let landed = continuityDelta(anchors, before: beforeY, after: afterY)
        let delta = landed?.delta ?? 0
        let ctx = UICollectionViewLayoutInvalidationContext()
        if delta != 0 { ctx.contentOffsetAdjustment = CGPoint(x: 0, y: delta) }
        layout.invalidateLayout(with: ctx)
        collectionView.layoutIfNeeded()
        if delta != 0 { verifyAnchor(landed?.anchor) }
    }

    // The row the reader's position is measured against. WHICH visible row that is depends on the
    // caller's bias — see `continuityAnchors(relativeToTop:)`. Top-biased (a page of older history, a
    // rotation-free mid-drag refresh) it is the row closest to the origin, and a change above it is
    // what moves the reader. Bottom-biased, the default everywhere else and the reference app's rule
    // for every load but `.loadOlder`, it is the last row on screen, so a change anywhere above it is
    // compensated and the bottom of the viewport is what stays still.
    //
    // A cascade rather than a single pick, so a row that is deleted or trimmed in the same update falls
    // through to the next candidate instead of giving up.
    /// ⛔ THE BIAS FLIPS WITH THE KIND OF CHANGE — the reference app's rule, and ours had only half of
    /// it. Their `ScrollContinuity` carries an `isRelativeToTop` flag, and their own comment explains
    /// both settings: relative to the top means "the top-most visible interaction should remain the
    /// same distance from the top of the chat history", relative to the bottom means "the bottom-most
    /// visible interaction should remain the same distance from the top of the keyboard". They pick
    /// the first ONLY for a page of older history and the second for everything else — a new message,
    /// a row re-measuring, a load in place. Their search order is the same list either way, reversed
    /// for the bottom bias: *"Honor the scroll continuity bias. If we prefer continuity with regard
    /// to the bottom of the viewport, start with the last items."*
    ///
    /// Ours took the top-most rows in every case, and that is the shortfall injector behind the
    /// owner's 2026-08-27 report. Coming back down a conversation, the rows that render for the first
    /// time and adopt a corrected height are the ones BELOW the top-most anchor — an anchor which
    /// therefore does not move, so the delta is zero, so the offset is held while the content grows
    /// taller under the reader and the newest message drifts out of reach.
    ///
    /// Both directions still fall back through the same cascade in `continuityDelta`: the bias only
    /// decides which end of the viewport is asked first.
    ///
    /// ⚠️ EVERY VISIBLE ROW IS A CANDIDATE, not the first six. Theirs walks the whole visible list in
    /// bias order and then falls through to any row present in both load windows; ours capped at six,
    /// and when all six leave in one update — deleting a screenful of selected messages does exactly
    /// that — `continuityDelta` finds nothing, returns a delta of zero, and the reader jumps by
    /// whatever moved above them. A viewport holds a dozen or so rows, so the cap bought nothing.
    /// (Their third tier, any row in the window, is still not implemented here.)
    private func continuityAnchors(relativeToTop: Bool) -> [Anchor] {
        let visible = viewportIndexPaths()
        let ordered: [IndexPath] = relativeToTop ? visible : Array(visible.reversed())
        return ordered.compactMap { ip -> Anchor? in
            guard let id = dataSource.itemIdentifier(for: ip),
                  let attr = collectionView.layoutAttributesForItem(at: ip) else { return nil }
            return Anchor(id: id, distanceFromOrigin: attr.frame.minY - collectionView.contentOffset.y)
        }
    }

    /// ⛔ THE FIRST ANCHOR THAT SURVIVED THE CHANGE, NOT THE FIRST ANCHOR — the reference app's
    /// fallback chain (`invalidationContentOffsetAdjustment`: preferred row → every visible row →
    /// any row present both before and after), ported 2026-08-25 after reading their layout.
    ///
    /// ⚠️ ONE ANCHOR IS A SINGLE POINT OF FAILURE, AND IT FAILS SILENTLY. The row a correction is
    /// measured against can be gone by the time the correction is computed — deleted, expired, or
    /// trimmed off the far end of the load window by the very update being landed. With one anchor
    /// there is then nothing to measure, the delta comes out ZERO, and the offset is left alone
    /// while the content above the reader has moved: a jump, arriving from the one path that exists
    /// to prevent jumps. The cascade was already written and only the load path used it.
    ///
    /// ⛔ THREE TIERS, AS THEIRS HAS. `applyContentOffsetAdjustmentIfNecessary` tries the preferred
    /// anchor, then every visible row in bias order, and then — the tier we were missing — ANY row
    /// present in both the before and after windows, again in bias order, with their own comment:
    /// *"Fail over to trying to use any interaction in the before & after load windows."*
    ///
    /// Ours stopped after the visible rows, and when every one of them leaves in a single update the
    /// delta came out zero and the reader jumped by whatever had moved above them. Deleting a
    /// screenful of selected messages does exactly that, and so does a trim that takes the whole
    /// viewport. The third tier costs one dictionary walk on a path that has already given up.
    ///
    /// ⚠️ THE THIRD TIER CANNOT PRODUCE AN `Anchor`, and that is not a defect. An `Anchor` carries
    /// `distanceFromOrigin`, which only means something for a row that was ON SCREEN when the anchors
    /// were captured; a row from the far end of the window has no such distance. So the delta is
    /// returned with a nil anchor: the correction is applied, and `verifyAnchor` — which re-pins
    /// against a remembered on-screen position — correctly does nothing afterwards.
    private func continuityDelta(_ anchors: [Anchor],
                                 before: [String: CGFloat],
                                 after: [String: CGFloat]) -> (delta: CGFloat, anchor: Anchor?)? {
        for a in anchors {
            guard let b = before[a.id], let f = after[a.id] else { continue }
            return (f - b, a)
        }
        // Tier three: any row that survived the update, walked in document order (oldest first).
        // ⚠️ Theirs walks this tier in BIAS order and ours does not — the bias lives with the anchor
        // list, which by definition has already failed by the time we are here. For a delta it makes
        // no difference which surviving row is measured, because every one of them moved by the same
        // amount unless content changed BETWEEN them, and a tier-three fallback is already the case
        // where the viewport's own rows are gone.
        for (id, b) in before.sorted(by: { $0.value < $1.value }) {
            guard let f = after[id] else { continue }
            return (f - b, nil)
        }
        return nil
    }

    /// Re-pin against the first anchor that still resolves, for the same reason.
    private func verifyAnchor(_ anchors: [Anchor]) {
        for a in anchors where dataSource.indexPath(for: a.id) != nil {
            verifyAnchor(a)
            return
        }
    }

    // Where one row sat, measured from the coordinate origin. The whole "keep the reader still" contract
    // is expressed in this one value: put that row back at that distance and nothing has moved.
    private struct Anchor {
        let id: String
        let distanceFromOrigin: CGFloat
    }

    // THE ONLY VERIFICATION NET IN THE FILE, and the only place outside a declared scroll intent that
    // writes contentOffset. It runs after a land that carried a non-zero adjustment: a page of history
    // landing above a reader, a row above them changing height, a deletion above them. It never runs
    // during a healthy scroll and it never runs when the adjustment was zero. A live finger is excluded because a pan re-derives the offset from its own baseline every
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
        /// `userInitiated` = the reader ASKED for this, by tapping the down-arrow. Automatic ones
        /// (own send, a width-change re-anchor) leave it false and keep the finger rule.
        case newest(animated: Bool, userInitiated: Bool = false)
        case message(String)          // reply / search jump to a specific row
        case initialPosition          // the very first landing, before the list is visible
    }

    // The one safety rule: never move the reader while their finger is on the glass. Deceleration is
    // deliberately NOT included (the reference app tracks it separately): a fling that is still coasting toward the
    // newest message should absolutely end up there. The first landing happens before the list is even
    // visible, so it is never gated.
    private func perform(_ intent: ScrollIntent) {
        switch intent {
        case .newest(let animated, let userInitiated):
            guard didFirstLand else { return }
            // A TAP IS NOT A DROP. The finger rule stands for AUTOMATIC jumps — nothing moves the
            // reader while they are touching the glass — and they wait for the lift rather than
            // being dropped (see scrollViewDidEndDragging), because the binding that carries them
            // is one-shot.
            //
            // ⛔ BUT AN ASKED-FOR JUMP OUTRANKS THE FINGER — owner, 2026-08-24: "the arrow button
            // works only when the swipe is finished". Parking his tap was the whole delay. The rule
            // exists so an ARRIVING MESSAGE cannot yank the list out from under someone who is
            // reading; a thumb on the arrow is the reader asking to be moved, which is the opposite
            // situation, and deferring it makes the button feel broken rather than careful.
            //
            // Two fingers is all it takes to reach this: one still coasting the list, one on the
            // arrow. `scrollToOffset` kills the coast on its way past, so landing mid-fling is
            // already handled — this only stops us refusing the request in the first place.
            if !userInitiated {
                guard !isUserScrolling else { pendingNewestJump = animated; return }
            }
            pendingNewestJump = nil
            scrollToOffset(maxContentOffsetY, animated: animated)
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
            // Nothing unread: the newest message, which is the bottom of the content.
            guard let target = initialScrollId,
                  let ip = dataSource.indexPath(for: target),
                  let attr = layout.layoutAttributesForItem(at: ip) else {
                collectionView.setContentOffset(CGPoint(x: 0, y: maxContentOffsetY), animated: false)
                lastStableOffset = maxContentOffsetY
                return
            }
            // ⛔ TWO KINDS OF LANDING, AND THE OFFSET SAYS WHICH. A first-unread row lands near the
            // top with 12pt of breathing room under the nav bar — a placement chosen for reading
            // forward. A RESTORED reading position lands at exactly the offset it was left at, which
            // is the whole point of having remembered it: theirs restores the last visible
            // interaction to its own on-screen position, not to a fresh one.
            // Both are "how far below the viewport's top edge this row should sit", which is exactly
            // what `reportReadingPosition` measured, so the two are the same quantity and the
            // arithmetic is one line for both.
            let belowTop = initialScrollOffset ?? 12
            let y = clampOffset(attr.frame.minY - collectionView.adjustedContentInset.top - belowTop)
            collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
            lastStableOffset = y
        }
    }

    private func scrollToOffset(_ y: CGFloat, animated: Bool) {
        let target = clampOffset(y)
        guard abs(collectionView.contentOffset.y - target) > 0.5 else { return }
        lastStableOffset = target
        // ⛔ THE DESTINATION IS RECORDED HERE, BEFORE THE MOVE, AND IT HAS TO BE. `recordDistanceFromBottom`
        // only ever ran on the UNANIMATED branch below and on finger-driven scrolls — during an
        // animated glide none of `isDragging` / `isTracking` / `isDecelerating` is set, so
        // `scrollViewDidScroll` skips its record for every frame of it. The recorded place therefore
        // still described where the reader was BEFORE the jump, and `restoreReaderPosition` reads
        // exactly that value to decide whether they belong at the newest message: jump from the
        // newest to a quoted message a screen up, and the stale zero said "this reader is at the
        // bottom", so the landing was snapped straight back down. A jump states where the reader
        // asked to be; that is what the record must hold from the moment it is issued.
        //
        // It also fixes the send glide honestly rather than by accident: a glide aimed at the bound
        // records zero, so if the composer shrinks mid-flight and the landing comes up short, the
        // net still knows this reader belongs at the newest message and closes the gap.
        lastKnownDistanceFromBottom = max(0, maxContentOffsetY - target)
        if animated {
            // KILL THE COAST FIRST. An animated setContentOffset issued while the list is still
            // decelerating is swallowed: UIScrollView keeps driving the offset from its own fling and our
            // animation never takes. That is the reported "tap the down arrow mid-swipe and nothing
            // happens, it only works once the scrolling stops". The intent gate above deliberately allows
            // a jump during deceleration (finger down only), so the refusal was never ours — it was UIKit.
            // Writing the offset it already has, unanimated, ends the deceleration in place. This is
            // the reference app's `stopScrolling()` verbatim, and like theirs it is UNCONDITIONAL: they
            // never test isDecelerating, because the flag can read false while an animation is still in
            // flight, and re-writing an offset that is already at rest costs nothing.
            // ⚠️ THE MARK COMES FIRST, AND THAT ORDERING IS THE WHOLE OF THE SECOND REPORT (owner
            // 2026-08-13: still dead mid-scroll on a build that has the coast-kill above). Killing
            // the coast makes UIKit fire `scrollViewDidEndDecelerating` immediately, and that
            // callback runs `settleFlush()` — so with the mark still down, `canLandLoad` was true
            // inside it and whatever land had been parked went through right there, its async
            // snapshot completion arriving in the middle of the glide we were about to start and
            // putting the reader back. The kill worked; what came in through the door it opened did
            // not. Marked first, that same callback sees an animation in flight and defers.
            scrollingAnimationDidStart()   // lands defer until the glide completes
            stopScrolling()
            collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: true)
            // AND THEN CHECK THAT IT ACTUALLY HAPPENED. Everything above is a chain of things that
            // each have to hold; this asks the only question that matters — am I there? — and puts
            // the reader there if not. Skipped the moment the reader takes over or a newer move
            // supersedes this one, so it can never fight a hand on the glass.
            glideSeq &+= 1
            let seq = glideSeq
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                // ⛔ THE SAME STAND-DOWNS EVERY OTHER OFFSET WRITER HONOURS. This checked only for a
                // finger, so: tap jump-to-latest, flick the list within half a second, and at t=0.5
                // the reader is coasting with no finger down and no NEW scroll issued — so `glideSeq`
                // still matches and this hard-writes the old target, killing the fling. Deceleration
                // is a reader in motion. A context menu is up means nothing may move (the menu's
                // snapshot is anchored to a frame from before). A screenshot capture owns the offset.
                // And a controller on its way out should write nothing at all.
                guard let self, seq == self.glideSeq,
                      !self.collectionView.isDragging, !self.collectionView.isTracking,
                      !self.collectionView.isDecelerating,
                      !self.contextMenuVisible, !self.isDisappearing,
                      Date() >= self.captureFreezeUntil,
                      abs(self.collectionView.contentOffset.y - target) > 2 else { return }
                self.collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: false)
                self.lastStableOffset = target
                self.scrollingAnimationDidComplete()
            }
        } else {
            collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: false)
            recordDistanceFromBottom()
        }
    }

    // MARK: - Land-when-safe
    //
    // the reference app's actual gate (CVLoadCoordinator.loadLandWhenSafe â†’ canLandLoad, read from their source
    // 2026-07-27). Note what is NOT in it: isDragging, isTracking, isDecelerating. Loads land WHILE your
    // finger is down; the reader is kept still by the layout, not by refusing the work.
    //
    // A page of history landing above a live finger is held still by the layout's own
    // contentOffsetAdjustment inside the batch update, which UIScrollView honours under a pan; the
    // reference app lands loads mid-drag the same way.
    private var canLandLoad: Bool {
        if selectionAnimationState == .animating { return false }
        // the reference app's `contextMenuVisible`, from UIKit's own callbacks. NO selection exception here: the land
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

    // the reference app's `viewState.isUserScrolling`: FINGER DOWN ONLY. Deceleration is tracked separately and
    // deliberately does not count.
    private var isUserScrolling: Bool { collectionView.isDragging || collectionView.isTracking }

    /// THEIR ANSWER TO THIS EXACT PROBLEM, read from their own list source (`ListView.stopScrolling()`,
    /// and the `ignoreScrollingEvents` guard at the top of their `scrollViewDidScroll`). Ending a
    /// fling means writing the offset the scroller already has, and that write makes UIKit call
    /// straight back into our delegate — so they raise a flag first and their own callbacks go deaf
    /// for the length of it. Every one of their programmatic offset writes is wrapped this way, not
    /// only this one.
    ///
    /// Ours needed it for the same reason and did not have it: the callback the stop fires runs
    /// `restoreReaderPosition()` and `settleFlush()`, either of which can move the reader, and both
    /// were running INSIDE the stop that was supposed to be clearing the way for a jump.
    private var ignoringScrollEvents = false

    private func stopScrolling() {
        let was = ignoringScrollEvents
        ignoringScrollEvents = true
        collectionView.setContentOffset(collectionView.contentOffset, animated: false)
        ignoringScrollEvents = was   // restore, never assume false — theirs nests too
    }

    /// A jump-to-newest that arrived while a finger was down, waiting for the lift. `nil` = none.
    private var pendingNewestJump: Bool?
    /// Bumped by every animated glide so a late arrival check can tell whether it is still the
    /// current one — see scrollToOffset.
    private var glideSeq: Int = 0

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
        // ⛔ THE GLIDE WAS AIMED BEFORE THE COMPOSER SHRANK — the other half of the long-message gap.
        // `perform(.newest(animated:))` captures `maxContentOffsetY` when it starts, and on a long
        // send the composer collapses WHILE it is flying, which moves that bound. Landing on the old
        // one is short of the newest message by exactly the height the composer gave back, which is
        // the empty space he photographed. The clamp is already the app's stated invariant for this —
        // at rest the reader is never beyond the newest — so the landing simply has to consult it.
        //
        // ⚠️ AFTER the flags are cleared, never before: `restoreReaderPosition` stands down while
        // either animation flag is set, so calling it any earlier is a no-op.
        //
        // ⚠️ AND BEFORE `recordDistanceFromBottom` on the next line, which is why the order here is
        // not arbitrary: the glide's landing place is corrected first, and the corrected place is
        // what gets recorded as where the reader now is.
        restoreReaderPosition()
        recordDistanceFromBottom()   // a glide or jump has landed; this is where the reader now is
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
        let visibleSet = Set(collectionView.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) })
        let allChanged = currentIds.filter { rowSignatures[$0] != lastRowSigs[$0] }   // content changes
        lastRowSigs = rowSignatures
        remeasureOffscreenChanged(allChanged, visible: visibleSet)              // heights are not about cells
        let changed = allChanged.filter { visibleSet.contains($0) }
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
            let newRoute = rowModels[id] != nil
            if let old = configuredRoutes[id], old != newRoute { reload.append(id) } else { reconf.append(id) }
        }
        return (reconf, reload)
    }

    // Queue a split's reload half. Clearing configuredRoutes FIRST is load-bearing: the provider
    // serves the last-configured class when an entry exists (the crash guard), and a reload replaces
    // the cell, so the fresh dequeue must be free to take the new class or the swap never happens.
    private func queueReload(_ ids: [String], into snapshot: inout NSDiffableDataSourceSnapshot<Int, String>) {
        guard !ids.isEmpty else { return }
        ids.forEach { configuredRoutes.removeValue(forKey: $0) }
        snapshot.reloadItems(ids)
    }

    // Repair channel for the provider's crash guard: ids that were served their OLD cell class to
    // satisfy an in-flight reconfigure, and now need a real reload to swap renderers. Async because
    // the provider runs inside UIKit's update pass — applying a snapshot there would re-enter it.
    private var routeRepairIds = Set<String>()
    private func scheduleRouteRepair(_ id: String) {
        let firstInBatch = routeRepairIds.isEmpty
        routeRepairIds.insert(id)
        guard firstInBatch else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let ids = self.routeRepairIds
            self.routeRepairIds.removeAll()
            var snap = self.dataSource.snapshot()
            let present = ids.filter { snap.itemIdentifiers.contains($0) }
            guard !present.isEmpty else { return }
            // The other renderer can measure differently — refresh the cache so the reload lands in
            // a frame of the right size.
            let width = self.collectionView.bounds.width
            if width > 0 {
                for id in present {
                    let h = self.measure(id, width: width)
                    if abs((self.heights[id] ?? 0) - h) > 2 { self.heights[id] = h; self.layout.generation += 1 }
                }
            }
            self.queueReload(Array(present), into: &snap)
            self.dataSource.apply(snap, animatingDifferences: false)
        }
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
        // ⛔ TOP-BIASED, AND THIS SITE ALONE KEEPS IT. Every other in-place re-measure is bottom-biased
        // to match the reference, but this one runs WHILE A FINGER IS ON THE GLASS and the rule above
        // is what makes that safe: it touches only rows inside the viewport, so with a top anchor the
        // changed row is always at or below the anchor and the delta is structurally zero. Bottom-
        // biasing it would make a reaction landing, a tick flipping or a preview resolving on any
        // visible row above the last one produce a real delta — written into
        // `pendingContentOffsetAdjustment`, which UIScrollView honours under a pan — and the
        // conversation would shift under the reader's thumb. The shortfall this leaves for a reader at
        // the newest message is exactly what `restoreReaderPosition`'s second invariant now closes, so
        // nothing is lost by keeping the guarantee that costs nothing.
        let anchors = continuityAnchors(relativeToTop: true)
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
        queueReload(split.reload, into: &snapshot)
        var delta: CGFloat = 0
        var landedAnchor: Anchor?
        if heightChanged {
            layout.generation += 1
            let afterY = frameMinY(for: currentIds)
            if let landed = continuityDelta(anchors, before: beforeY, after: afterY) {
                delta = landed.delta
                landedAnchor = landed.anchor
            }
            if delta != 0 { layout.pendingContentOffsetAdjustment = delta }
        }
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self else { return }
            self.layout.pendingContentOffsetAdjustment = 0
            if delta != 0 { self.verifyAnchor(landedAnchor) }
        }
    }

    // MARK: - Apply

    // The box a load waits in when it cannot land yet. It holds ONE set of ids â€” the latest â€” so a burst
    // of Firestore emissions collapses into a single land instead of a queue of stale ones.
    private var pendingIdsApply: [String]?

    /// the reference app's retry loop: `asyncAfter` takes longer than `async` under load, which is what you want here
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
        // Chronological, as handed to us. Index 0 is the oldest loaded row, the newest is last.
        let ids = unique
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
                // which is what the reference app looks like: their selection UI appears with the dismissal, not
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
            let visible = Set(collectionView.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) })
            let allChanged = ids.filter { rowSignatures[$0] != lastRowSigs[$0] }
            lastRowSigs = rowSignatures
            guard !allChanged.isEmpty else { return }
            // The unread divider arrives on exactly this path: the chat opens at the newest message
            // and `anchorUnread` then marks a row well above the reader.
            remeasureOffscreenChanged(allChanged, visible: visible)
            let changed = allChanged.filter { visible.contains($0) }
            guard !changed.isEmpty else { return }
            refreshVisible(changed)
            return
        }

        // WHAT KIND OF CHANGE IS THIS. `newlyNewest` counts rows added at the END, which is a sent or
        // received message. Rows added at the FRONT are paged-in history; they sit above the reader and
        // the continuity delta below holds the reader still across them. A mixed batch (history AND a
        // new message in one emission) is handled by the same delta, not classified.
        let oldSet = Set(currentIds)
        let newlyNewest = ids.reversed().prefix(while: { !oldSet.contains($0) }).count
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
        let liveSet = Set(collectionView.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) })
        // EVERY changed row is re-measured; only the visible ones are reconfigured. See
        // `remeasureOffscreenChanged` for why those are two different questions.
        let sigChanged = ids.filter { rowSignatures[$0] != lastRowSigs[$0] }
        let contentChanged = sigChanged.filter { liveSet.contains($0) }
        lastRowSigs = rowSignatures

        // Radar 28167779: settle any dirty layout against the OLD data BEFORE mutating heights/ids â€” a
        // dirty layout preparing after the mutation would mix old counts with new heights.
        collectionView.layoutIfNeeded()
        let beforeY = frameMinY(for: currentIds)
        // ⛔ THE ONE SITE WHERE THE BIAS IS A RUNTIME QUESTION, because this method lands every kind
        // of change. The reference app picks the bias from the load type: top-biased ONLY for
        // `.loadOlder`, bottom-biased for a load in place, a newer page and the newest page. Our
        // equivalent signal is whether the OLDEST loaded row changed, which is exactly what a page of
        // history does (and what the date-separator join below already tests for).
        // ⚠️ "THE OLDEST ROW CHANGED" IS NOT THE SAME QUESTION, and asking it that way was wrong in
        // three ways: a front-trim, a deletion of the oldest row, and a jump into history all change
        // it, and the reference treats every one of those as bottom-biased. A page of older history
        // is specifically a PREPEND — the row that used to be oldest is still here and is no longer
        // first. If it left, this was a trim or a delete, not a page.
        let pagedOlder: Bool = {
            guard let wasOldest = currentIds.first else { return false }   // first apply: no anchors anyway
            guard let idx = ids.firstIndex(of: wasOldest) else { return false }
            return idx > 0
        }()
        let anchors = continuityAnchors(relativeToTop: pagedOlder)
        // ⛔ RE-RECORD THE READER'S DISTANCE BEFORE THE LOAD LANDS. Theirs does exactly this and says
        // why: *"CVC will often use this state to ensure scroll continuity when landing loads, so
        // ensure the value is updated before landing loads."* Ours recorded only on scroll ticks and
        // at settles, so by the time a load landed the value could be several changes old — which is
        // what made it unsafe to use as a continuity fallback, and why it had ended up with a single
        // reader. Fresh at land time, it becomes the honest answer to "where was this reader" for the
        // one case the anchor cascade cannot answer at all.
        recordDistanceFromBottom()

        measureMissing(ids, width: width)   // exact heights BEFORE the layout prepares (no self-size correction)
        // Every row whose content changed, on screen or not — this whole block is already bracketed
        // by `beforeY` / `afterY`, so a row above the reader growing is compensated like any other.
        for id in sigChanged { heights[id] = measure(id, width: width) }
        // THE DATE-SEPARATOR JOIN. Date pills and cluster spacing are baked into the message row and
        // computed from the chronological index, so the oldest loaded row always carries a date pill and
        // paging history takes it away from the row that used to be oldest. That row's height changes,
        // and it is ABOVE the reader, so it is re-measured BEFORE the frames are mapped: the continuity
        // delta then includes it, and the reader does not move. (Modelling the separator as its own
        // item, as the reference app does, would remove even this.)
        let keep = newSet
        if currentIds.first != ids.first {   // the oldest loaded row changed, so the join moved
            for id in currentIds.prefix(3) where keep.contains(id) {
                heights[id] = measure(id, width: width)
            }
        }
        if !oldSet.isSubset(of: keep) {   // rows left (trim/delete): drop their caches
            heights = heights.filter { keep.contains($0.key) }
            configuredRoutes = configuredRoutes.filter { keep.contains($0.key) }
            sizerRefused = sizerRefused.filter { keep.contains($0) }
            renderedHeights = renderedHeights.filter { keep.contains($0.key) }
        }
        let afterY = frameMinY(for: ids)

        if selectionAnimationState == .willAnimate { beginSelectionAnimationWindow() }

        // THE CONTINUITY DELTA. One formula for every kind of change: how far did the reader's anchor
        // row move? For a page of older history (`pagedOlder` above) the anchor is the topmost visible
        // row, so the delta sums exactly the rows that landed above the reader. For everything else it
        // is the BOTTOM-most visible row, so anything that grew, shrank or left anywhere above it is
        // compensated and the bottom of the viewport holds still — the reference app's split, and the
        // reason a row re-measuring below the fold no longer walks the newest message out of reach.
        // Either way it is compensated inside the same update transaction (see
        // MessageLayout.targetContentOffset).
        var adjustment: CGFloat = 0
        var landedAnchor: Anchor?
        // Computed for EVERY reader, including one at the newest message: a page of history landing
        // above them moves their rows too, and the delta is what holds them still. (In the inverted
        // list this was skipped at the newest message because an append could not move anyone; an
        // append still cannot, the anchor row does not move, so the delta comes out zero on its own.)
        // Whether the cascade could answer AT ALL, which is a different question from whether the
        // answer was zero — see the fallback in the completion below.
        var anchorsResolved = false
        if let landed = continuityDelta(anchors, before: beforeY, after: afterY) {
            adjustment = landed.delta
            landedAnchor = landed.anchor
            anchorsResolved = true
        }

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids, toSection: 0)
        if !contentChanged.isEmpty {
            let split = splitByRouteFlip(contentChanged)
            if !split.reconfigure.isEmpty { snapshot.reconfigureItems(split.reconfigure) }
            queueReload(split.reload, into: &snapshot)
        }
        currentIds = ids
        layout.generation += 1   // ids/heights changed â†’ next prepare() rebuilds frames

        if !didFirstLand {
            dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
                self?.performFirstLandIfReady()
            }
            return
        }

        // THE SEND / RECEIVE GLIDE. At the newest message a new row appends below the viewport; nothing
        // the reader can see moves, and the list then animates down to reveal it. The bubble itself
        // never animates, only the scroll does.
        let glide = wasAtNewest && newlyNewest == 1 && scrollTarget == nil && !isUserScrolling
        if glide { sendAnimating = true }
        // The row this send was waiting for has landed: the hold is over, and `sendAnimating` (or,
        // for a row that does not glide, the ordinary path) owns the offset from here. Cleared for
        // ANY new row, not only a glide — a send that arrived while the reader is up in history
        // must not keep the hold either.
        if newlyNewest > 0 { sendHoldUntil = .distantPast }
        if adjustment != 0 { layout.pendingContentOffsetAdjustment = adjustment }

        // THE GLIDE STARTS ON THE FRAME THE ROW LANDS. It used to start in the apply's completion,
        // which fires on a LATER runloop tick — so for a beat the screen sat on the old messages with
        // the new bubble parked behind the composer, and only then did the slide begin. Slow motion
        // shows exactly that staging (user's video: composer clears → nothing moves → the bubble pops
        // in parked → THEN the slide), and it is what he reads as "it shows the other messages first,
        // then my real message". One idempotent starter, called from both sides: the synchronous call
        // right after apply wins on the normal path (apply on the main queue lands the snapshot
        // synchronously when it is not animating), and the completion call is the net for an apply
        // that deferred. The 0.6s backstop clears the gate if the animated scroll produces no
        // end-callback (already exactly at the origin).
        var glideStarted = false
        let startGlide = { [weak self] in
            guard let self, glide, !glideStarted else { return }
            glideStarted = true
            self.collectionView.layoutIfNeeded()
            self.perform(.newest(animated: true))
            // ⛔ THIS BACKSTOP NEEDS THE SEQUENCE NUMBER ITS SIBLING HAS. `scrollToOffset`'s 0.5s
            // arrival check refuses when a newer move has superseded it; this one only asked whether
            // `sendAnimating` was set — and it is set again by the NEXT send. Two sends 0.3s apart and
            // the first backstop fires in the middle of the second glide, clears the flag, opens
            // `canLandLoad`, and lets a parked land through mid-flight: literally the failure the
            // sibling's own comment describes, arriving by the door that was left open.
            let backstopSeq = self.glideSeq
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, self.sendAnimating, backstopSeq == self.glideSeq else { return }
                self.sendAnimating = false
                self.settleFlush()
            }
        }

        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self else { return }
            self.layout.pendingContentOffsetAdjustment = 0   // never let the fallback channel go stale
            self.lastStableOffset = self.collectionView.contentOffset.y
            if let target = scrollTarget {
                self.performScrollTarget(target)
            } else if glide {
                startGlide()
            } else if adjustment != 0 {
                // A new message landed while the reader is in history. The layout has already held them
                // still; this is the one net that checks it actually happened.
                self.collectionView.layoutIfNeeded()
                self.verifyAnchor(landedAnchor)
            } else if !anchorsResolved {
                // ⛔ THEIR LAST TIER, AND OURS HAD NO EQUIVALENT. When the anchor cascade cannot answer
                // at all — not one row of the before window survived the update — theirs falls through
                // `targetContentOffset(forProposedContentOffset:)` to
                // `contentOffset(forLastKnownDistanceFromBottom:)` and puts the reader back at the
                // distance they were last known to hold. Ours simply left the offset where it was and
                // the reader jumped by whatever the update moved.
                //
                // ⚠️ ONLY WHEN THE CASCADE FOUND NOTHING, never merely because the delta was zero. A
                // zero delta from a resolved anchor is a POSITIVE result — it means nothing above the
                // reader moved — and re-pinning them from a recorded distance there would fight every
                // ordinary message arrival with whatever rounding the record carries.
                self.collectionView.layoutIfNeeded()
                self.restoreRecordedDistance()
            }
            // Post-land auto-load re-check, async so it is never re-entrant inside the land: a short page
            // can leave the reader still within the load threshold.
            DispatchQueue.main.async { [weak self] in self?.autoLoadMoreIfNeeded() }
        }
        startGlide()   // same frame as the landed row — the completion above is only the net

        // Re-flow the just-inserted bubble at its FINAL cell width. UIHostingConfiguration lays a freshly
        // inserted cell's SwiftUI out at the pre-final width and does NOT re-flow it until a later update
        // â€” that's the "newest bubble wraps narrow until the next message" bug.
        if newlyNewest > 0 {
            let inserted = Array(ids.suffix(newlyNewest))
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
        // Rows just inserted at the newest end — their `.loadNewer` / `.loadNewest`: bottom-biased.
        let anchors = continuityAnchors(relativeToTop: false)
        var changed: [String] = []
        for id in present {
            let h = measure(id, width: collectionView.bounds.width)
            if let old = heights[id], abs(old - h) <= 2 { continue }
            heights[id] = h
            changed.append(id)
        }
        guard !changed.isEmpty else { return }
        layout.generation += 1
        // These rows are at the bottom of the list, below anyone reading history, so the delta is
        // normally zero. Same one mechanism regardless: the delta rides the update, the net checks it.
        let afterY = frameMinY(for: currentIds)
        let landed = continuityDelta(anchors, before: beforeY, after: afterY)
        let delta = landed?.delta ?? 0
        if delta != 0 { layout.pendingContentOffsetAdjustment = delta }
        // Route-flip split, same as every other refresh path (build-542 .ips): this runs one runloop
        // after the insert, and the just-sent message is EXACTLY the row whose route flips when the
        // server ack lands inside that gap — reconfiguring it across the flip aborts the app.
        let split = splitByRouteFlip(changed)
        if !split.reconfigure.isEmpty { snap.reconfigureItems(split.reconfigure) }
        queueReload(split.reload, into: &snap)
        dataSource.apply(snap, animatingDifferences: false) { [weak self] in
            guard let self else { return }
            self.layout.pendingContentOffsetAdjustment = 0
            if delta != 0 { self.verifyAnchor(landed?.anchor) }
        }
    }

    // MARK: - First landing

    // The first open. Rows are still measured before the first frame is drawn â€” that is what stops the
    // open from shaking, and it was never the problem. What is gone is the position dance around it: the
    // old file landed at the bottom, re-landed a runloop later as a "belt-and-suspenders guard", held a
    // pendingBottomOnOpen window that suppressed half the file's other logic, and re-pinned on every layout
    // pass until it closed â€” all because the bottom was a number derived from the total height of
    // everything, so it moved whenever a measurement landed. (The list is top-down: the newest message
    // sits at `maxContentOffsetY`, not at the origin — an inverted-list leftover corrected here.) There
    // is one landing and it is exact.
    private func performFirstLandIfReady() {
        guard !didFirstLand,
              collectionView.bounds.width > 0, collectionView.bounds.height > 0,
              !currentIds.isEmpty else { return }
        // The landing offset depends on contentSize and both insets, so the insets must be current and
        // the layout settled BEFORE we land; the composer height and safe area can arrive after the
        // first apply.
        //
        // ⛔ AND THE CALL BELOW HAS TO ACTUALLY RUN. `updateInsets` now refuses a nested call so that
        // the outermost caller owns the pass — but this method is not an inset update, it is a
        // CONSUMER of one, and it is reached from `viewDidLayoutSubviews`, which is exactly the pass
        // `updateInsets` forces from its own first line. Landing there means landing against the
        // insets as they were BEFORE the update wrote them: short by the whole composer clearance.
        // The no-unread path happens to heal (the outer update re-pins a reader it still sees at the
        // newest); a first-unread landing does not, and neither does a landing that arrives before
        // `isViewCompletelyAppeared`. So the land waits one turn for the pass to finish rather than
        // reading half of it. Idempotent by the guard above, and the main queue guarantees the retry.
        if isUpdatingInsets {
            DispatchQueue.main.async { [weak self] in self?.performFirstLandIfReady() }
            return
        }
        updateInsets()
        measureMissing(currentIds, width: collectionView.bounds.width)
        layout.generation += 1
        layout.invalidateLayout()
        collectionView.layoutIfNeeded()
        didFirstLand = true
        perform(.initialPosition)
        recordDistanceFromBottom()
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

    // Index paths of cells actually INSIDE the viewport, in layout order: `.first` is the topmost row on
    // screen (nearest the origin) and `.last` the lowest. The layout keeps an
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

    /// How far a thread falls short of filling the room between the bars, or zero once it fills it.
    ///
    /// Carried as extra TOP inset by `updateInsets`, which is what makes a short conversation hang
    /// from the composer the way every messenger draws it, instead of sitting under the header with
    /// the screen empty below. The room is measured against the bottom CLEARANCE (keyboard band, bar,
    /// gap), so with the keyboard up it shrinks by exactly what the keys took and the shortfall
    /// shrinks with it — the same arithmetic in both keyboard states rather than a special case.
    private func bottomAlignShortfall(bottomClearance: CGFloat) -> CGFloat {
        let safe = collectionView.safeAreaInsets
        let room = collectionView.bounds.height - (safe.top + topOverlayHeight) - bottomClearance
        guard room > 0 else { return 0 }
        // The layout's height, not the scroll view's — see `safeContentHeight`. This one is read on
        // the first land, before the scroll view has adopted anything, where the difference is a
        // whole conversation's worth of rows.
        return max(0, room - safeContentHeight)
    }

    /// ⛔ THE LAYOUT'S CONTENT HEIGHT, NEVER THE SCROLL VIEW'S. The reference app carries this as its
    /// own property and its comment says exactly why: *"Don't use collectionView.contentSize.height
    /// as the collection view's content size might not be set yet."* This list invalidates the layout
    /// constantly — a row adopting its rendered height, a route repair, a page of history, the
    /// composer resizing — and each of those bumps `layout.generation` and re-stacks the frames. For
    /// the window between the invalidation and the scroll view adopting the new size,
    /// `collectionView.contentSize` is the PREVIOUS answer while the layout already holds the current
    /// one, so every bound computed from it belongs to a moment that has passed. That is a bound the
    /// keyboard's own pass can land on: "was I at the bottom" takes the wrong branch, and the
    /// lockstep clamp measures against a limit that can be a screenful out.
    private var safeContentHeight: CGFloat {
        collectionView.collectionViewLayout.collectionViewContentSize.height
    }
    private var minContentOffsetY: CGFloat { -collectionView.adjustedContentInset.top }
    private var maxContentOffsetY: CGFloat {
        max(minContentOffsetY,
            safeContentHeight + collectionView.adjustedContentInset.bottom - collectionView.bounds.height)
    }
    private func clampOffset(_ y: CGFloat) -> CGFloat { min(max(minContentOffsetY, y), maxContentOffsetY) }

    /// AT THE NEWEST MESSAGE: within this of the bottom of the content. The reference app's number,
    /// and theirs is one constant used by one predicate — so this is the only place it is written.
    /// `updateInsets` asks the same question of the LIVE offset with the same tolerance.
    private static let atNewestTolerance: CGFloat = 5
    // This reads contentSize, so it is only asked with the layout settled; see the file comment.
    private var isAtNewest: Bool { collectionView.contentOffset.y >= maxContentOffsetY - Self.atNewestTolerance }

    /// ⛔ ONE BOTTOM MODEL, FOR THE WHOLE LIFE OF THE CHAT VIEW. This replaces the two nets that used
    /// to sit here — `clampToNewestIfBeyond` and `keepNewestUntilFirstScroll` — and the owner's
    /// 2026-08-27 report is exactly what having two of them cost.
    ///
    /// WHAT WAS WRONG. The pair divided the job by TIME rather than by MEANING:
    ///   · `keepNewestUntilFirstScroll` corrected BOTH directions (over and short) but switched
    ///     itself off permanently at the reader's first finger drag (`readerHasScrolled`, set once
    ///     and reset nowhere).
    ///   · `clampToNewestIfBeyond` never expired but was ONE-SIDED: it tested `offset > bound` only,
    ///     so it pulled back an overshoot and did nothing at all for a shortfall.
    /// So a freshly opened chat was held exactly at the newest message on every layout pass — which
    /// is why "open, keyboard up, keyboard down" was always correct — and a chat that had been
    /// scrolled had no defence left against being left SHORT of the bound. Scrolling is precisely
    /// what produces a shortfall: a row rendering for the first time adopts a height its prediction
    /// missed, and the correction for that is measured against an anchor row that did not move, so
    /// the delta is zero while the content grows taller underneath. From there `updateInsets` reads
    /// "was I at the bottom" as FALSE, takes the lockstep branch, and carries the gap faithfully
    /// through every keyboard open and close — the bubbles behind the composer he photographed.
    ///
    /// THE MODEL NOW, which is the reference app's. There is no "fresh chat" case and no first-drag
    /// cliff. Two invariants, both true for the entire lifetime of the view:
    ///   1. NO READER IS EVER BEYOND THE NEWEST MESSAGE. Past the bound is the bounce region; at
    ///      rest it is never legitimate for anybody, so it is corrected for everybody.
    ///   2. A READER WHO IS AT THE NEWEST MESSAGE IS AT IT, not near it. If their recorded place is
    ///      the newest, the bound is where they belong however the geometry moved to get here.
    /// A reader who has chosen a place further up is not touched by either: holding them still while
    /// content changes around them is the anchor system's job (`continuityAnchors`), and this method
    /// deliberately has no opinion about them.
    ///
    /// ⚠️ THE WRAPPER IS CONDITIONAL, and both of the old pair's positions were wrong. This runs from
    /// `viewDidLayoutSubviews`, which runs inside WHATEVER animation happens to be on the stack. Inside
    /// the keyboard's block the write should be bare, so it rides the keys instead of snapping while
    /// the bar glides — that is what the always-wrapped one got wrong. But the stack also holds the
    /// reply banner's dismissal, a composer growing a line, the selection toolbar and cell
    /// reconfigures, and a bare write inside any of those animates the offset on a curve that has
    /// nothing to do with the reader — which is what the always-bare one got wrong. `keyboardBlockUntil`
    /// is precisely the window in which the keys are moving, so it decides.
    private func restoreReaderPosition() {
        // ⛔ NOT DURING THE SEND HOLD. The hold exists so the composer's own shrink (the reply banner
        // leaving, the text clearing) cannot walk the content down before the row lands and the glide
        // walks it back up. His report, twice: "tap Reply, press Send, the message briefly moves
        // underneath the composer and jumps back."
        //
        // ⛔ AND NOT INSIDE AN INSET UPDATE. This runs from `viewDidLayoutSubviews`, and that pass is
        // often the one `updateInsets` forces from its own first line — so it would get a shot at the
        // offset in the MIDDLE of the update, against half-written geometry. This is a net for a list
        // at rest; an update in flight is the opposite of rest.
        // ⛔ AND NOT WHILE A CONTEXT MENU IS UP. `updateInsets` carries this guard already and says
        // why: it is not the menu that scrolls the chat, it is the KEYBOARD WE DISMISS to make room
        // for it — the clearance drops and the list follows, while the menu's lifted snapshot stays
        // anchored to the frame the bubble had before any of it. That method therefore changes the
        // insets and moves nothing. This one ran straight afterwards on the same layout pass, saw a
        // reader now beyond a shrunken bound, and moved them anyway — putting back the exact report
        // the guard next door exists to prevent.
        // ⛔ AND NOT DURING A SYSTEM SCREENSHOT CAPTURE, which owns the offset for its window and puts
        // it back itself — `scrollViewDidScroll`, `updateInsets` and the date pill all stand down on
        // the same clock.
        guard didFirstLand, !isDisappearing, !isUpdatingInsets, !contextMenuVisible,
              Date() >= captureFreezeUntil,
              !collectionView.isTracking, !collectionView.isDragging, !collectionView.isDecelerating,
              !sendAnimating, !programmaticScrollAnimating, Date() >= sendHoldUntil,
              // Never on a spiked safe area: the bound is garbage for exactly that frame.
              collectionView.safeAreaInsets.bottom <= restSafeBottom + 0.5 else { return }
        let bound = maxContentOffsetY
        let y = collectionView.contentOffset.y
        // The RECORDED place, deliberately, not the live offset: a first-unread landing records its
        // real distance and every programmatic jump records where it put the reader, so none of them
        // are dragged to the bottom by this. `nil` means nothing has been recorded yet, which only
        // happens before the first land — and the first land pins the reader itself.
        let readerIsAtNewest = (lastKnownDistanceFromBottom ?? 0) <= Self.atNewestTolerance
        let want: CGFloat
        if y > bound + 0.5 {
            want = bound                                   // invariant 1, for every reader
        } else if readerIsAtNewest, y < bound - 0.5 {
            want = bound                                   // invariant 2, for a reader at the newest
        } else {
            return
        }
        // ⛔ WRAPPED, BECAUSE THIS CORRECTOR IS OURS AND NOT THEIRS. Their bare offset write is in
        // `updateContentInsets`, and it is bare so it can ride the keyboard's block; ours does the
        // same, one method over. But `restoreReaderPosition` has no counterpart in their app at all —
        // it exists because our cells self-size and theirs do not — and it runs from EVERY layout
        // pass, which means every animation block on the stack: the reply banner's 0.2s dismissal, the
        // composer's 0.25s spring, a nav push or pop, a rotation, a SwiftUI `withAnimation`. Bare, it
        // animates the reader on whichever of those curves happens to be running, which is a bug this
        // file has already recorded once. On the keyboard's own pass `updateInsets` has normally
        // corrected the reader already, so there is nothing here to strip.
        UIView.performWithoutAnimation {
            collectionView.setContentOffset(CGPoint(x: 0, y: want), animated: false)
        }
        lastStableOffset = want
    }
    /// ⛔ THE REFERENCE APP'S `contentOffset(forLastKnownDistanceFromBottom:)`, and the only thing in
    /// this file that speaks for a reader who is NEITHER at the newest message nor beyond it.
    ///
    /// Theirs: `contentOffsetYBottom - max(0, distanceFromBottom)`, floored at the minimum. It is how
    /// they put a reader back after the ground moved under them, and it is the piece we had recorded
    /// and never used — `lastKnownDistanceFromBottom` was written on every scroll tick and read by
    /// nothing that could act on it.
    ///
    /// Called at the ONE moment we know we stood down while the geometry changed: coming back from a
    /// pushed screen, where the lockstep is gated shut by `isViewCompletelyAppeared` and
    /// `updateInsets` is edge-triggered, so the change is written once and never offered again.
    private func restoreRecordedDistance() {
        guard didFirstLand, !isDisappearing, !isUpdatingInsets, !contextMenuVisible,
              Date() >= captureFreezeUntil,
              !collectionView.isTracking, !collectionView.isDragging, !collectionView.isDecelerating,
              !sendAnimating, !programmaticScrollAnimating, Date() >= sendHoldUntil,
              collectionView.safeAreaInsets.bottom <= restSafeBottom + 0.5,
              let distance = lastKnownDistanceFromBottom else { return }
        let want = clampOffset(maxContentOffsetY - max(0, distance))
        guard abs(collectionView.contentOffset.y - want) > 0.5 else { return }
        UIView.performWithoutAnimation {
            collectionView.setContentOffset(CGPoint(x: 0, y: want), animated: false)
        }
        lastStableOffset = want
    }

    // The looser test, for the jump-to-latest BUTTON only: an affordance, not a decision about moving
    // someone. Deliberately separate so the two can never be confused again.
    private var isNearNewest: Bool { collectionView.contentOffset.y >= maxContentOffsetY - 44 }

    // The BUTTON's own test, and it has TWO distances, not one. Owner, 2026-08-25: one bubble of scroll
    // is not the moment anyone reaches for that arrow. It now waits until the newest message is properly
    // off screen (about five short bubbles) and hides again only back at the bottom. One number for both
    // is what made it flash on and off while a thumb rested on the line.
    private static let jumpButtonShowDistance: CGFloat = 225   // roughly five short bubbles
    private static let jumpButtonHideDistance: CGFloat = 44
    private var jumpButtonVisible = false
    private var shouldShowJumpButton: Bool {
        let distance = maxContentOffsetY - collectionView.contentOffset.y
        return jumpButtonVisible ? distance > Self.jumpButtonHideDistance
                                 : distance > Self.jumpButtonShowDistance
    }

    // MARK: - Insets

    // ⛔ THE REFERENCE APP'S `updateContentInsets`, AND ITS WHOLE KEYBOARD MECHANISM — owner,
    // 2026-08-25: "copy their approach for both directions… 100%, not an approximation", after the
    // open jumped on his iOS 27 phone and the close ran ahead of the keys on his iOS 26 one.
    //
    // WHAT THEIRS DOES, read from source (ConversationViewController+OWS.swift, +BottomBar.swift,
    // ConversationViewController.swift):
    //   · NO keyboard notification observers at all on iOS 16+. Their bottom bar is constrained to
    //     `view.keyboardLayoutGuide.topAnchor`. When the keyboard moves, UIKit changes that guide
    //     INSIDE its own keyboard animation block; the constraint dirties the view's layout, so
    //     `viewDidLayoutSubviews` runs inside that block and calls this, synchronously.
    //   · newInsets.bottom = bottomBarContainer.height − collectionView.safeAreaInsets.bottom. The
    //     container is pinned to the view's bottom and the bar to the guide, so its height carries
    //     the keyboard; the subtraction is because the safe area is folded in as well.
    //   · Snapshot "was I at the bottom" and the old offset BEFORE touching anything. Write the
    //     insets inside `performWithoutAnimation` and restore the offset, which cancels the implicit
    //     shift UIScrollView applies when contentInset changes. Stand down while the user drags:
    //     "UIKit updates collection view's scroll position when user drags with the keyboard." Then
    //     write the offset OUTSIDE the wrapper with `animated: false`: "This offset change will be
    //     animated by UIKit's UIView animation block which updateContentInsets() is called within."
    //   · Safe-area changes go through a 0.01s last-only debounce; the layout path never does.
    //
    // WHAT WAS WRONG HERE, and why every earlier attempt split between his two phones: the keyboard
    // reached this list only through the safe area SwiftUI hands the hosted controller, and WHEN that
    // arrives relative to the keyboard's animation block is SwiftUI's business and differs by OS.
    // Each attempt added a clock, a latch or a settle to paper over that ordering. Theirs has no
    // ordering to get wrong: the guide is UIKit's, it changes inside the keyboard's own block, and the
    // one offset write there inherits the keys' real duration and curve. Every notification observer,
    // the captured clock, the willHide latch, the did-show/did-hide settles and the pending-settle
    // hand-off are gone with it.
    //
    // OURS, in their terms:
    //   bottom clearance    = keyboard band + composer bar + 12. The band is the guide's height: the
    //                         keyboard when it is up, the home-indicator strip when it is down.
    //   contentInset.bottom = bottom clearance − safeAreaInsets.bottom, so the ADJUSTED bottom is the
    //                         clearance whatever SwiftUI puts in the safe area and whenever it does.
    //   top clearance       = pinned bar + a short thread's shortfall; `.always` folds the nav bar.
    //
    // "WAS AT THE BOTTOM" IS ASKED AGAINST THE LIVE BOUND, as theirs is. It used to be asked against
    // a stored clearance because SwiftUI's safe area could move the live bound before the guide did;
    // the list ignores the keyboard safe area now, so only this method moves the bound.
    /// ⛔ WHERE THE KEYBOARD IS: `view.keyboardLayoutGuide`, read and never stored. This controller
    /// keeps NO keyboard state at all — no band, no report, no docked height, no animation window, no
    /// notification observers. That is the reference app's entire keyboard handling on iOS 16 and up,
    /// and the whole of it is one constraint: the composer's bottom is pinned to this guide's top, so
    /// UIKit moves the bar inside the keyboard's own animation, the container's height follows through
    /// the same constraint chain, and the list's bottom clearance follows from the container. Nothing
    /// is computed, so nothing can be stale, late, or in disagreement with anything else.
    ///
    /// ⚠️ EVERY PIECE OF THE OLD MACHINERY IS GONE ON PURPOSE, at the owner's explicit instruction to
    /// use their approach rather than a workaround: `keyboardBand`, the `KeyboardReport` enum,
    /// `fingerBand`, `dockedBand`, `guideBand`, `guideIsLive`, `keyboardBlockUntil`, `dismissParkUntil`,
    /// the custom `UILayoutGuide` with its three feeders, `rideKeyboard`, `followKeyboardUnderFinger`,
    /// `followKeyboardGuide`, `keyboardTracker`, and all three notification observers.
    ///
    /// ⚠️ THE ONE THING THIS RESTS ON: that `view.keyboardLayoutGuide` actually tracks the keys inside
    /// this SwiftUI-hosted controller. Build 682 said it did not — but that predates the priming in
    /// `viewDidLoad` (`_ = view.keyboardLayoutGuide`), which is the documented workaround for the iOS 26
    /// regression where a guide first read late reports the home-indicator height instead of the
    /// keyboard's, and it was never re-measured afterwards. If the guide is genuinely dead here, the
    /// composer will not follow the keys at all and it will be obvious in the first seconds of a build.
    /// The interactive dismiss follows the guide for free where the guide works, which is why there is
    /// no finger code either.
    private var keyboardOverlap: CGFloat {
        let frame = view.keyboardLayoutGuide.layoutFrame
        // Unresolved guides report a zero rect; a resolved one on a home-button phone reports a
        // zero-HEIGHT rect whose minY is the view's bottom. Only the first is meaningless.
        guard frame.height > 0 || frame.minY > 0 else { return restSafeBottom }
        // ⛔ THE STALENESS TEST IS THE WIDTH, AND TESTING THE BOTTOM EDGE WAS A REAL BUG. His
        // screenshot, keyboard up: the composer glued to the keys with no gap and still at its
        // resting side insets. The bar was in the RIGHT PLACE — its constraint to the guide put it
        // there — but at the wrong CONSTANT, sitting at `guide.top + composerRestDip` instead of
        // `guide.top - composerKeyboardGap`, which is precisely the missing space. Everything that
        // reads `keyboardIsUp` was told the keys were down, and the jump arrow flew up for the same
        // reason: its lift is the container's height less this value.
        //
        // The cause was a guard I added defensively: "the guide sits at the bottom of the view, so
        // its maxY is the view's maxY." That is not reliably true for a hosted controller — the
        // guide's frame is the KEYBOARD's rect, and the keyboard does not stop where this view's
        // bounds do. Requiring equality threw away every good frame.
        //
        // What a stale frame from a rotation actually looks like is a frame the wrong WAY ROUND: the
        // view's bounds are already the new size while the guide still describes the old one, so the
        // widths disagree by hundreds of points. That is the honest test, it catches the case the old
        // guard was written for, and it cannot fire in ordinary use.
        guard abs(frame.width - view.bounds.width) <= 1 else { return restSafeBottom }
        // ⛔ THE FLOOR IS THEIRS, AND IT IS NOT DECORATION. Their guide's height is
        // `max(view.safeAreaInsets.bottom, view.bounds.maxY - frame.minY)`, and dropping the first
        // term here cost the resting strip: with the keys down the guide's top sits ON the view's
        // safe-area bottom, and SwiftUI collapses that value to zero at the focus instant (his diag
        // log, `SAFE v=0 w=34`). For those frames this returned 0 and every clearance derived from it
        // came out a home-indicator short. The floor reads the WINDOW for the same reason
        // `restSafeBottom` does — the window's inset never collapses.
        return max(restSafeBottom, view.bounds.maxY - frame.minY)
    }
    /// True while the keys are up. Used only for the composer's product rule (8pt above the keys while
    /// typing, sunk `composerRestDip` below the safe line at rest) and for the swipe-back dismissal.
    private var keyboardIsUp: Bool { keyboardOverlap > restSafeBottom + 0.5 }
    /// ⛔ ONE WRITER PER LAYOUT PASS. `updateInsets` opens with `view.layoutIfNeeded()` (the reference
    /// app's own first line), and eight of its ten call sites are OUTSIDE a layout pass — so that
    /// line runs `viewDidLayoutSubviews`, which calls `updateInsets` again. The nested call did the
    /// whole job: it wrote the insets, it wrote the offset, and then the two clamps beneath it got a
    /// shot at the offset as well; the outer call then read `oldInsets` AFTER the inner had already
    /// changed them, found nothing to do, and returned. Three offset writers with three different
    /// guard sets, on one keyboard frame, in an order that differs by OS — which is the shape of
    /// every two-phone split in this file's history. The outermost caller owns the pass now.
    private var isUpdatingInsets = false

    /// ⛔ THE BOTTOM SAFE AREA WITHOUT THE KEYBOARD, EVER — his frames on builds 696 and 697
    /// (2026-08-27): the instant the field takes focus, the bar VANISHES and the content drops,
    /// before the keys have moved; the keys then rise bare and the bar reappears at the end. Both
    /// keyboard-transport rebuilds behaved identically, because neither was the problem: at that
    /// instant iOS can hand this hosted view a safe area that momentarily CONTAINS THE KEYBOARD,
    /// and every rest-position number derived from it goes wild for a beat — the side inset becomes
    /// hundreds of points (a bar squeezed to nothing), the rest bottom lands mid-screen, the
    /// clearance math collapses. The WINDOW's safe area never includes the keyboard — UIKit's own
    /// rule, already recorded in SystemChrome.swift — so every keyboard/bar computation clamps to
    /// it. When the view's safe area is sane the two agree and this changes nothing.
    private var restSafeBottom: CGFloat {
        // ⛔ THE WINDOW'S VALUE, NOT A MIN — his diag screenshots, build `10fe54b6`: at the focus
        // instant the view's safe area COLLAPSES to zero (`SAFE v=0 w=34`), it does not spike up,
        // so min() picked the garbage side and the bar dropped and narrowed at the tap. The window
        // is stable in both directions.
        view.window?.safeAreaInsets.bottom ?? view.safeAreaInsets.bottom
    }

    // (`followKeyboardGuide` is gone. It existed to copy the system guide's position into the bar's
    // constraints on a layout pass, behind a `guideIsLive` latch that let a LATE guide outrank a
    // notification — the `f1e7e532` regression, "the keyboard opens but the composer stays where it
    // was". The bar hangs off our own guide by a constraint now, and the system guide is one of that
    // guide moves the bar directly through the constraint now, so there is nothing to copy.)
    /// ⛔ THEIR ONE EXPRESSION, verbatim in intent:
    ///
    ///     newInsets.bottom = bottomBarContainer.frame.height - collectionView.safeAreaInsets.bottom
    ///
    /// The container reaches from the bar's top to the screen bottom, so its height already
    /// contains the keyboard AND the bar AND the gap. This used to be `keyboardBand +
    /// composerBarH + 12` — three numbers that arrive a beat apart, which is the failure this
    /// file's own notes describe: "a reader pinned before a late part is left that part short".
    ///
    /// ⚠️ It falls back to the assembled sum only until the bar exists (the announcements list has
    /// none, and the first pass runs before ThreadView has handed the composer over).
    private var bottomClearance: CGFloat {
        // A HIDDEN bar is not a bar: while SwiftUI owns the bottom (selection, search, blocked) the
        // container is collapsed and the clearance comes from the fallback, exactly as it does for
        // the announcements list. See `hideComposer`.
        guard let bar = composerBar, !bar.isHidden else {
            return keyboardOverlap + composerBarH + 12
        }
        guard bottomBarContainer.frame.height > 1 else {
            // ⛔ OUR BAR IS THERE BUT ITS CONTAINER HAS NOT BEEN LAID OUT YET (the first open, a
            // re-attach, the pass before the composer is handed over). The old fallback used
            // `composerBarH` here, and `composerBarH` CANNOT BE WRITTEN while our bar is visible —
            // `setComposerBarHeight` refuses every report in exactly that state, on purpose, because
            // the SwiftUI slot it comes from is a zero-height spacer. So this branch was reading a
            // variable frozen at its initial 0 and returning a clearance short by the whole composer:
            // the newest message lands under the bar and heals only when something scrolls. The
            // container's own height expression is the honest answer until its frame exists.
            let width = max(1, view.bounds.width - (barLeading?.constant ?? 0) * 2)
            let barH = (bar as? ChatComposerView)?.preferredHeight(forWidth: width) ?? composerBarH
            return Self.barTopPad + barH + (-(barBottom?.constant ?? 0)) + keyboardOverlap
        }
        return bottomBarContainer.frame.height
    }


    private func updateInsets() {
        guard isViewLoaded, !isDisappearing else { return }
        // Theirs: not during an interactive pop.
        if let pop = navigationController?.interactivePopGestureRecognizer {
            switch pop.state { case .possible, .failed: break; default: return }
        }
        // The outermost caller owns this pass — see `isUpdatingInsets`. The line below runs a full
        // layout, which calls `viewDidLayoutSubviews`, which calls this again; that nested call used
        // to do the work and leave the real caller with nothing to write.
        guard !isUpdatingInsets else { return }
        isUpdatingInsets = true
        defer { isUpdatingInsets = false }
        view.layoutIfNeeded()   // theirs: the guide's frame is current before it is read

        let bottom = bottomClearance
        let top = topOverlayHeight + bottomAlignShortfall(bottomClearance: bottom)
        let safe = collectionView.safeAreaInsets
        let oldInsets = collectionView.contentInset
        // ⛔ THE ADJUSTED BOTTOM, CAPTURED BEFORE ANYTHING MOVES. This — not `contentInset.bottom` —
        // is the number that decides where the list actually ends, and the only honest input to the
        // lockstep shift below. See the note at the shift for what reading the raw inset cost.
        let oldAdjustedBottom = collectionView.adjustedContentInset.bottom
        var newInsets = oldInsets
        // ⛔ THEIRS, VERBATIM, AND THE `min()` THAT USED TO BE HERE IS GONE. The subtraction exists
        // for exactly one reason: `contentInsetAdjustmentBehavior = .always` (see `viewDidLoad`) adds
        // `collectionView.safeAreaInsets.bottom` back, so subtracting the SAME number leaves the
        // adjusted inset equal to the clearance — whatever the safe area happens to say this frame,
        // and whichever way it is wrong. Clamping the subtrahend to the window's value broke that
        // cancellation in both directions: where the hosted safe area COLLAPSES (his diag log,
        // `SAFE v=0 w=34`) the clamp picks the same 0 and changes nothing, and where it SPIKES —
        // 34 → 0 → 34, once 83, recorded in this file from the same logs, and by a full bar height
        // whenever SwiftUI owns the bottom — the clamp leaves the excess in the list as phantom
        // clearance. It defended a direction that never needed defending and injected error in the
        // one that did. The bar's own numbers still clamp to the window (`restSafeBottom`), because
        // a bar is placed at an absolute position; an inset is a difference, and differences cancel.
        newInsets.bottom = bottom - safe.bottom
        newInsets.top = top

        // Step 1: pre-change geometry. Theirs, verbatim: `isScrolledToBottom` against the LIVE
        // bound, 5pt tolerance. This used to be asked against a stored clearance because SwiftUI's
        // safe area could move the live bound before the guide did; the list ignores the keyboard
        // safe area now (`.ignoresSafeArea(.keyboard)` in ThreadView), so nothing but this method
        // moves the bound and the stored copy was one more thing to keep in step.
        let oldYOffset = collectionView.contentOffset.y
        let wasScrolledToBottom = oldYOffset >= maxContentOffsetY - Self.atNewestTolerance

        // ⚠️ THE RAW TEST IS THE ADJUSTED TEST, and a previous attempt to "fix" that added a second
        // term that could never fire. `oldAdjustedBottom` is read from the LIVE safe area, so it is
        // `oldInsets.bottom + safe.bottom`; the new adjusted bottom is `bottom` by construction. Their
        // difference is therefore `(bottom - safe.bottom) - oldInsets.bottom`, which is exactly the
        // raw bottom delta below, character for character. There is no pass where the adjusted bottom
        // moves and the raw one does not. Do not add that term back.
        let didChangeInsets = abs(oldInsets.top - newInsets.top) > 0.5 || abs(oldInsets.bottom - newInsets.bottom) > 0.5
        // Step 2: the insets, with UIScrollView's implicit offset shift cancelled.
        UIView.performWithoutAnimation {
            if didChangeInsets {
                let keep = collectionView.contentOffset
                collectionView.contentInset = newInsets
                if collectionView.contentOffset != keep { collectionView.setContentOffset(keep, animated: false) }
            }
            // The INDICATOR keeps the real top: the shortfall is padding, not content it should
            // pretend exists.
            collectionView.verticalScrollIndicatorInsets = UIEdgeInsets(top: topOverlayHeight, left: 0,
                                                                        bottom: newInsets.bottom, right: 0)
        }

        // Theirs: `guard didChangeInsets else { return }`.
        guard didChangeInsets else { return }

        // Step 3. Theirs: the finger owns the offset while it drags the keyboard down. UIKit moves the
        // content itself there, so nothing is owed and the clearance is banked.
        guard !collectionView.isDragging else { lastAppliedClearance = bottom; return }
        // ⛔ AND THE SYSTEM OWNS IT DURING A FULL-PAGE SCREENSHOT CAPTURE. Every other offset writer in
        // this file stands down on that clock and this one did not, so the capture's own scroll could
        // be walked by the lockstep below while it was in progress.
        guard Date() >= captureFreezeUntil else { return }
        // Ours additionally: a send glide or a jump is a programmatic animated scroll that already
        // knows where it is going, and `scrollViewDidEndScrollingAnimation` lands it. Theirs has no
        // glide (a sent row appears and the list is simply at the bottom), so it has nothing to
        // protect here; ours does, and a lockstep shift landing mid-glide would leave the glide
        // short of the newest message. Deceleration is NOT guarded any more — theirs writes through
        // it, and so does this.
        guard didFirstLand, !sendAnimating, !programmaticScrollAnimating else { return }
        // ⛔ AND A SEND THAT HAS STARTED BUT NOT LANDED — owner, 2026-08-26: "when I tap Send the
        // previous messages move down underneath the composer first, and only afterward does the
        // message list scroll back up".
        //
        // `sendAnimating` covers the glide, but the glide is not the first thing that happens.
        // `ThreadView.send()` clears the input and dismisses the reply banner FIRST, synchronously,
        // over its own 0.2s animation — and only then does the optimistic row reach the repo. So for
        // those 0.2s the composer is shrinking by the banner's ~54pt with no new row in sight: the
        // clearance drops, the list is pinned to the bottom, and the content dutifully follows the
        // composer DOWN. Then the row lands and the glide carries it back UP. Two moves where the
        // reader should see one, and the first of them is backwards.
        //
        // So the list holds its offset from the moment a send begins until its row lands. The
        // clearance and the insets still update on every pass above — only the offset write waits,
        // and the glide then makes the single move to the new bottom.
        //
        // ⚠️ IT MUST TIME OUT. A send that fails validation, or is swallowed anywhere between the
        // tap and the repo, would otherwise leave the offset frozen for the rest of the sitting.
        // `sendHoldUntil` is a deadline, not a flag.
        guard Date() >= sendHoldUntil else { return }

        // Step 4. Plain writes, outside the wrapper. Inside the keyboard's block they ride the keys;
        // anywhere else (composer growth, the pinned bar) they land at once, as theirs do.
        // ⛔ A CONTEXT MENU IS UP: CHANGE THE INSETS, MOVE NOTHING. Theirs, verbatim, in this
        // exact position in `updateContentInsets`:
        //
        //     } else if isPresentingContextMenu {
        //         // Do nothing
        //     }
        //
        // His report: keyboard open, long-press a message, and the chat scrolls. It is not the menu
        // that scrolls it — it is the KEYBOARD WE DISMISS to make room for the menu. That posts a
        // hide notification, the clearance drops by the keyboard's height, and the lockstep shift
        // walks the list. Meanwhile the menu's lifted snapshot is anchored to the frame the bubble
        // had BEFORE any of that, so the preview sits still while the conversation slides out from
        // under it.
        //
        // ⚠️ The flag has to be armed BEFORE the keyboard is asked to leave, or this guard is not
        // in place when the notification arrives — see `presentCustomMenu`.
        if contextMenuVisible {
            // Nothing — and the clearance is deliberately NOT banked, so the change is still owed when
            // the menu closes and the keyboard comes back. In practice the two net out.
        } else if wasScrolledToBottom {
            // Theirs, verbatim: "If we were scrolled to the bottom, don't do any fancy math. Just
            // stay at the bottom."
            let bound = maxContentOffsetY
            if abs(collectionView.contentOffset.y - bound) > 0.5 {
                collectionView.setContentOffset(CGPoint(x: 0, y: bound), animated: false)
            }
            lastAppliedClearance = bottom
        } else if isViewCompletelyAppeared {
            // ⛔ THEIR `isViewCompletelyAppeared` GATE, on the lockstep branch only, exactly where
            // theirs sits. During a push, a pop, or the return from a pushed screen the geometry is
            // still settling and an offset written from it is written from nothing.
            //
            // Theirs: "shift the content in lockstep with the keyboard, up to the limits of the
            // content bounds." Their delta is the bottom inset's, and for them the two are the same
            // number.
            //
            // ⛔ OURS IS THE CHANGE IN CLEARANCE, AND THIS IS THE BUG THE SCROLLED-UP READER WAS
            // FEELING. An inset delta — raw or adjusted, they are the same number — measures the
            // wrong thing here: `oldInsets.bottom` was written against the safe area of an EARLIER
            // pass while `safe.bottom` is read now, so when SwiftUI flaps the hosted safe area at the
            // focus instant of every open (34 → 0 → 34) the difference comes out as
            // `Δclearance − Δsafe`. The clearance did not change, the list did not move, and a
            // scrolled reader was shifted by the flap anyway — once per open and once per close.
            //
            // The clearance is what the reader actually has under the last bubble, it is the same
            // number in every pass whatever the safe area is doing, and after the plain subtraction
            // it is exactly what the adjusted inset equals. `lastAppliedClearance` also carries a
            // debt forward when an earlier pass stood down, so a shift swallowed by the send hold or
            // a context menu is still owed rather than lost to the edge-triggered gate above.
            //
            // A reader at the newest message never saw any of this: they take the branch above, which
            // re-pins to a bound that did not move. It is only ever visible to a reader who has
            // scrolled away from the bottom — which is why the chat looks correct the moment it is
            // opened, and why it did not stay correct once he had scrolled.
            let previous = lastAppliedClearance ?? oldAdjustedBottom
            let clearanceChange = bottom - previous
            if abs(clearanceChange) > 0.5 {
                let want = clampOffset(oldYOffset + clearanceChange)
                if abs(collectionView.contentOffset.y - want) > 0.5 {
                    collectionView.setContentOffset(CGPoint(x: 0, y: want), animated: false)
                }
            }
            lastAppliedClearance = bottom
        }
    }

    /// ThreadView bumps this the instant Send is tapped, BEFORE it clears the input and the reply
    /// banner. That ordering is the whole point: the hold has to be in place before the composer
    /// starts shrinking, which is the first thing a send does.
    func noteSendTick(_ t: Int) {
        guard t != lastSendTick else { return }
        let firstObservation = lastSendTick == 0 && t != 0
        lastSendTick = t
        // Adopting a mid-flight tick on (re)attach is not a send — the same rule `noteMenuActionTick`
        // follows, and for the same reason: a controller rebuilt while a chat is open would
        // otherwise freeze its offset for no reason.
        guard !firstObservation || t == 1 else { return }
        // 0.45s: the banner's dismissal is 0.2s and the optimistic row normally lands well inside
        // that. The rest is slack for a slow frame, and it is cleared early the moment the row
        // arrives, so the deadline is only ever reached by a send that never landed at all.
        sendHoldUntil = Date().addingTimeInterval(0.45)
    }

    /// SwiftUI's measurement of whatever IT draws at the bottom — the selection toolbar, the search
    /// bar, the blocked / message-request / muted notices, the announcements bar. Not the composer:
    /// that is this controller's own view and its container is the truth.
    ///
    /// ⛔ THE OLD `h > 30` GUARD IS GONE, AND IT HAD TURNED INTO A LATCH. It was written when the
    /// composer was SwiftUI's, to reject a transient near-zero from the reader mid-transition. Since
    /// the composer moved here, the slot the reader measures is a zero-height spacer, so every
    /// honest report (1pt at rest, 14 with the keyboard up) was rejected and the value froze — at 0
    /// for a whole session, or at the height of an @-mention popup that had once passed the test and
    /// then closed. Anything reading it got a number belonging to another moment.
    ///
    /// The report is ignored while our own bar is on screen, and taken at face value when it is not,
    /// which is exactly when it is the only source there is.
    func setComposerBarHeight(_ h: CGFloat) {
        if let bar = composerBar, !bar.isHidden { return }
        guard abs(h - composerBarH) > 0.5 else { return }
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
    // MARK: - Lifecycle

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isDisappearing = true
        isViewCompletelyAppeared = false   // theirs, same method
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Only once we are REALLY gone: an interactive pop that the user cancels runs
        // willDisappear then appears again, and viewDidAppear re-hooks on the way back in.
        unhookPopGesture()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isDisappearing = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isDisappearing = false
        isViewCompletelyAppeared = true   // theirs, same method — the lockstep may run from here on
        collectionView.isPrefetchingEnabled = true     // re-enable after the jank-sensitive first presentation
        updateInsets()
        // ⛔ AND CATCH UP ON WHATEVER MOVED WHILE THE GATE WAS SHUT. `updateInsets` is EDGE-TRIGGERED
        // (`guard didChangeInsets`), so a bottom change that landed during the return transition —
        // the keyboard restoring, the composer container getting its real frame — wrote the insets and
        // then found the lockstep branch closed by `isViewCompletelyAppeared`. The call above cannot
        // recover it: by now the insets already equal what they should be, nothing "changed", and it
        // returns at once. A scrolled-up reader would be left behind the keyboard with nothing in the
        // app able to notice, because the two other correctors only speak for a reader at or beyond
        // the newest message. So the one moment we know we stood down while the ground moved is the
        // moment to put the reader back where they were.
        restoreRecordedDistance()
        // Swiping back with the KEYBOARD UP: dismiss the keyboard the moment the pop gesture begins, so the
        // transition runs against a settled layout instead of fighting a live keyboard teardown.
        if !popGestureHooked, let pop = navigationController?.interactivePopGestureRecognizer {
            pop.addTarget(self, action: #selector(popGestureChanged(_:)))
            hookedPopGesture = pop
            popGestureHooked = true
        }
    }

    /// Release the nav controller's pop recognizer — see `hookedPopGesture`. Safe to call twice.
    private func unhookPopGesture() {
        hookedPopGesture?.removeTarget(self, action: nil)
        hookedPopGesture = nil
        popGestureHooked = false
    }

    deinit {
        // Belt for the case the controller dies without a disappear pass.
        hookedPopGesture?.removeTarget(self, action: nil)
    }

    @objc private func popGestureChanged(_ g: UIGestureRecognizer) {
        switch g.state {
        case .began:
            // "Is the keyboard up" is the band, not the safe area: the list ignores the keyboard's
            // safe area (ThreadView's `.ignoresSafeArea(.keyboard)`), so the old `safeAreaInsets
            // .bottom > 100` test could never be true and the keyboard stayed up through the pop.
            if keyboardIsUp { view.window?.endEditing(true) }
        case .ended, .cancelled, .failed:
            // ⛔ ONE RUNLOOP LATER, OR IT DOES NOTHING. `updateInsets` refuses to run while the pop
            // recogniser is in any state but `.possible` or `.failed` — the reference's own rule —
            // and at the moment this fires the state IS `.ended` or `.cancelled`. So the repair
            // this line exists for has never run for a completed or cancelled swipe-back. By the
            // next turn the recogniser is back to `.possible` and the call lands.
            DispatchQueue.main.async { [weak self] in
                UIView.performWithoutAnimation { self?.updateInsets() }
            }
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
        // ⛔ BOTTOM-BIASED, and an earlier comment here claimed the opposite. The reference app does
        // route a size transition through its own path rather than the load-type bias — but that path
        // is not bias-neutral, it is explicitly bottom-aligned: `setScrollActionForSizeTransition`
        // re-pins the LAST visible interaction with `alignment: .bottom` (and short-circuits to the
        // bottom of the load window when the recorded distance is under 50). Anchoring the top-most
        // row here was the opposite end of the viewport from theirs.
        let anchors = wasAtNewest ? [] : continuityAnchors(relativeToTop: false)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self else { return }
            self.collectionView.layoutIfNeeded()   // the width-change re-measure ran in viewWillLayoutSubviews
            if wasAtNewest { self.perform(.newest(animated: false)) }
            else { self.verifyAnchor(anchors) }
        }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        // Theirs: debounced, last-only, 0.01s — "when performing an interactive dismiss, safe area
        // updates rapidly in quick succession, which causes this method to go haywire, recomputing
        // insets a few times and incorrectly determining that it needs to scroll as a result." The
        // keyboard itself never comes through here any more; it comes through the layout pass the
        // guide dirties, which is synchronous. This path is for rotation and the bars.
        //
        // ⛔ THE BAR'S REST POSITION IS WRITTEN HERE TOO, at once. The composer is usually handed
        // over BEFORE the view is in a window, when the safe area still reads 0, and the rest
        // position depends on it (the pill sinks `composerRestDip` below the safe-area line). Until
        // this ran, nothing re-placed the bar when the real inset arrived — his 2026-08-26 report:
        // the composer sat ON the screen edge, inside the home-indicator band, until the first
        // keyboard event happened to rewrite the constraint.
        //
        // ⛔ ON iOS 26, WITHOUT ANIMATION AND LAID OUT ON THE SPOT. Theirs, verbatim in intent:
        // "Workaround for iOS 26 animating bottom bar getting in its final position during view
        // presentation animation." The safe area lands inside the push, and a bare constraint
        // write there rides the push's transaction — the bar visibly slides into place.
        // ⚠️ THE STAND-DOWN THAT USED TO BE HERE IS GONE WITH THE MACHINERY IT PROTECTED. It skipped
        // this re-place while an announced keyboard animation was running, because our own block was
        // walking the bar at the same time and the two disagreed. There is no announced animation any
        // more — UIKit owns the guide and the bar is constrained to it — so there is nothing to stand
        // down for, and the flag that expressed it (`let presenting = false`) has been deleted rather
        // than left hard-wired with a dead branch behind it.
        if #available(iOS 26, *) {
            UIView.performWithoutAnimation {
                positionBottomBar()
                syncBottomBarGeometry()
                view.layoutIfNeeded()
            }
        } else {
            positionBottomBar()
            syncBottomBarGeometry()
        }
        safeAreaInsetsWork?.cancel()
        // Theirs: safe-area changes go through a last-only 0.01s debounce, because "when performing an
        // interactive dismiss, safe area updates rapidly in quick succession, which causes this method
        // to go haywire". The bar has already been re-placed synchronously above; this is only the
        // inset half, debounced exactly as theirs is.
        let work = DispatchWorkItem { [weak self] in self?.updateInsets() }
        safeAreaInsetsWork = work
        let delay = 0.01   // theirs: a 0.01s last-only debounce, nothing more
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
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
            renderedHeights.removeAll()   // a rendered height is only true at the width it rendered at
            // A plan is only true at the width it was planned at, for the same reason.
            planStore.invalidateAll()
            for id in currentIds { heights[id] = measure(id, width: w) }
            measuredWidth = w
            layout.generation += 1
            layout.invalidateLayout()
            let visible = collectionView.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) }
            if !visible.isEmpty {
                var snap = dataSource.snapshot()
                // Route-flip split here too (build-542 .ips): a width change can arrive with stale
                // routes, and reconfigure cannot cross cell classes.
                let split = splitByRouteFlip(visible)
                if !split.reconfigure.isEmpty { snap.reconfigureItems(split.reconfigure) }
                queueReload(split.reload, into: &snap)
                dataSource.apply(snap, animatingDifferences: false)
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // ⛔ THE KEYBOARD'S ONE WRITER, THE REFERENCE APP'S WAY. Their `viewDidLayoutSubviews` calls
        // `inputToolbar.ensureTextViewHeight()` and then `updateContentInsets()` synchronously, and
        // that is their entire keyboard handling: when the keyboard moves, UIKit changes
        // `view.keyboardLayoutGuide` inside its own animation block, the composer's constraint to that
        // guide dirties this view's layout, and this pass therefore runs INSIDE that block — so the
        // one unanimated offset write in `updateInsets` inherits the keys' real duration and curve.
        // Not forced, not clocked, never deferred: a deferred write lands outside the block and
        // hard-jumps, which is why theirs debounces the safe-area path and not this one.
        //
        // ⛔ THE BAR'S PRODUCT RULE HAS TO RUN HERE TOO, and leaving it out was a real bug for the
        // length of one commit. The guide moves the bar on its own now — that is the point of the
        // constraint — but WHICH constant the bar sits at is still a decision: 8pt above the keys
        // while typing, sunk `composerRestDip` BELOW the safe line at rest, sides 20 against the keys
        // and 29 at rest. With every keyboard notification deleted, nothing else was left to make that
        // decision, so the bar would have followed the keys up while still holding its resting
        // constant — sitting 5pt INTO the top of the keyboard, at the wrong width. It is the
        // counterpart of their `ensureTextViewHeight()` on this line: the one thing about the bar that
        // a layout pass has to settle before the insets are read. Guarded writes, so a pass where the
        // keyboard state has not flipped costs three comparisons and dirties nothing.
        positionBottomBar()
        updateInsets()
        // The invariant net, independent of any keyboard bookkeeping: at rest, never beyond the newest
        // bound. Catches the tail of an interactive keyboard dismissal, where `updateInsets` correctly
        // stands down because a finger owns the list while the clearance shrinks.
        restoreReaderPosition()
        positionVoiceControl()
        // The visible message viewport in window coordinates, for the media transitions' clipping view
        // (the reference app passes `collectionView.adjustedContentInset` as `clippingAreaInsets`; this
        // is the same region expressed as a rect).
        let winFrame = view.convert(view.bounds, to: nil)
        let inset = collectionView.adjustedContentInset
        MediaOpenRects.clipRect = CGRect(x: winFrame.minX,
                                         y: winFrame.minY + inset.top,
                                         width: winFrame.width,
                                         height: max(0, winFrame.height - inset.top - inset.bottom))
        // Report the GEOMETRIC nav-bar overlap. Async so the SwiftUI state write never lands mid-layout.
        let top = view.safeAreaInsets.top
        if abs(top - lastReportedTop) > 0.5 {
            lastReportedTop = top
            DispatchQueue.main.async { [weak self] in self?.onTopInset?(top) }
        }
        // ⛔ THE FLOATING OVERLAYS ARE PLACED HERE, SYNCHRONOUSLY, AND THAT IS THE WHOLE POINT. These
        // two numbers used to be handed to SwiftUI on a `DispatchQueue.main.async` — forced, because a
        // state write inside a layout pass is the "modifying state during view update" warning — and
        // SwiftUI then animated the arrow to its new place on a spring of its own. So the bar moved on
        // the keyboard's curve and the arrow followed a runloop turn later on a different one.
        //
        // Written as constraint constants on this pass instead, the overlays are inside the keyboard's
        // animation block exactly as the bar is, because this pass IS that block. That is what the
        // reference gets for free by pinning its scroll buttons to `bottomBarContainer`.
        //
        // The arithmetic is deliberately unchanged from what SwiftUI was applying — `lift + 10` above
        // the screen bottom, `side` in from the edge, 12 in from the leading edge — so not a pixel
        // moves. Only the clock does.
        if composerBar != nil {
            let lift = max(0, bottomBarContainer.frame.height - keyboardOverlap)
            let side = barLeading?.constant ?? composerMargin
            if abs(lift - lastReportedLift) > 0.5 || abs(side - lastReportedSide) > 0.5 {
                lastReportedLift = lift
                lastReportedSide = side
                dockOverlayBottom?.constant = -(lift + Self.dockOverlayGap)
                dockOverlayTrailingC?.constant = -side
                dockOverlayLeadingBottom?.constant = -(lift + Self.dockOverlayGap)
                dockOverlayTopLeadingC?.constant = side
                dockOverlayTopTrailingC?.constant = -side
                // Nothing is reported to SwiftUI any more. All three overlays are hosted here and
                // placed by the two constants above, so the last async geometry hand-off on this
                // screen is gone — which is the state the reference app is in: it tells its own view
                // layer nothing about the keyboard, because Auto Layout has already said it.
            }
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
                  let id = dataSource.itemIdentifier(for: ip), rowModels[id] != nil else { return false }
            // The BUBBLE only, not the full-width row: double-tapping the empty area beside a uikit bubble
            // hearted it, while SwiftUI rows react on the bubble content only.
            guard let cell = collectionView.cellForItem(at: ip) as? MessageRowCell else { return false }
            // ⛔ NOT ON A ROW THAT OPENS ON A SINGLE TAP — his order, 2026-07-29: "video and images
            // please remove double tap react, I need to open fast".
            //
            // A double-tap recogniser makes every SINGLE tap wait to find out whether a second one
            // is coming; that wait is unavoidable, it is how tap counting works. On a photo it sits
            // between the tap and the viewer. The old gate excluded media from this path entirely,
            // so the migration silently re-armed it on every picture, video, album and file: slow
            // opens, and a double tap that BOTH opened the viewer and toggled a reaction.
            if case .bubble(let row)? = rowModels[id]?.content, row.opensOnTap { return false }
            let p = collectionView.convert(loc, to: cell.previewBubble)
            return cell.previewBubble.bounds.contains(p)
        }
        if g === customPress {
            // Only on a row that actually has a menu, and only ON its bubble — pressing the empty
            // space beside a bubble must scroll, not lift. Never during selection, a reply swipe, or
            // a voice scrub, and never while a menu is already up.
            guard !isSelecting, activeMenu == nil, swipingCell == nil, !VoiceScrubState.active else { return false }
            let loc = g.location(in: collectionView)
            guard let ip = collectionView.indexPathForItem(at: loc),
                  let id = dataSource.itemIdentifier(for: ip),
                  !customMenuActions(id).isEmpty else { return false }
            if let native = collectionView.cellForItem(at: ip) as? MessageRowCell {
                let p = collectionView.convert(loc, to: native.previewBubble)
                return native.previewBubble.bounds.contains(p)
            }
            if let rect = CMBubbleRects.rect(id) {
                return rect.contains(g.location(in: nil))
            }
            return true   // hosted row with no published rect yet: allow, fallback lifts the row
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
        guard rowModels[id] != nil else { return false }
        return true
    }

    // Coexist with the collection view's own scroll pan (the list scrolls vertically, we translate a cell
    // horizontally â€” different axes, no conflict). shouldBegin already gates us to horizontal-left.
    // holdPress is a PASSIVE observer â€” it must never block the SwiftUI context-menu press or anything else.
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // The custom press coexists ONLY with the passive hold observer. Letting it run with the
        // scroll pan let the still-down finger keep scrolling the list behind the menu's blur (user:
        // "you feel scroll jump") — exclusivity makes UIKit prevent the pan the moment the press
        // recognizes, which is exactly the reference app's behaviour.
        if g === customPress || other === customPress {
            return g === holdPress || other === holdPress
        }
        return g === swipePan || g === holdPress
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
            // ⛔ THEIR NUMBERS, read from `CVComponentMessage`. 1:1 with the finger up to the
            // threshold, then the overflow moves at a QUARTER speed — resistance past the commit
            // point, with no cap on how far it can go:
            //
            //     } else if alpha > swipeActionOffsetThreshold {
            //         let overflow = alpha - swipeActionOffsetThreshold
            //         alpha = swipeActionOffsetThreshold + overflow / 4
            //
            // Ours started resisting at 70 and capped the overflow at 30, which is a different feel
            // in both directions. Mirrored here because our reply swipe goes left where theirs goes
            // right.
            let raw = -min(0, g.translation(in: collectionView).x)          // magnitude, always >= 0
            let eased = raw > Self.swipeThreshold
                ? Self.swipeThreshold + (raw - Self.swipeThreshold) / 4
                : raw
            let tx = -eased
            // Move the BUBBLE VIEW inside the cell, NOT the cell: the cell's frame never changes, so the
            // collection view has nothing to react to and the neighbours stay frozen.
            (cell as? MessageRowCell)?.previewBubble.transform = CGAffineTransform(translationX: tx, y: 0)
            let progress = min(1, eased / Self.swipeThreshold)
            swipeArrow?.alpha = progress
            swipeArrow?.transform = CGAffineTransform(scaleX: 0.6 + 0.4 * progress, y: 0.6 + 0.4 * progress)
            // ⚠️ ARMED ON THE RAW TRANSLATION, not the eased one — theirs tests the unmodified
            // offset against the threshold, and the haptic fires the INSTANT it is crossed (and
            // again on any re-crossing), never on release.
            if raw >= Self.swipeThreshold, !swipeTriggered {
                swipeTriggered = true
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } else if raw < Self.swipeThreshold {
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

    // The reply arrow sits in the space the bubble vacates. It goes into the CELL's content view: the cell
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
            guard let b = (cell as? MessageRowCell)?.previewBubble else { return cell.contentView.bounds }
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
        let bubble = (cell as? MessageRowCell)?.previewBubble
        let reset = { bubble?.transform = .identity; arrow?.alpha = 0 }
        if animated {
            // ⛔ A PLAIN 0.2s EASE, NO SPRING AND NO VELOCITY HAND-OFF. Theirs is exactly:
            //
            //     UIView.animate(withDuration: 0.2, animations: animations)
            //
            // Ours seeded a spring from the release velocity, which is livelier than theirs and is
            // the reason the snap-back felt different. Their gesture reads velocity only for the
            // LEFT swipe's message-detail transition, never for the reply snap-back.
            UIView.animate(withDuration: 0.2, delay: 0, options: [.allowUserInteraction],
                           animations: reset) { _ in arrow?.removeFromSuperview() }
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
        guard !rowModels.isEmpty, collectionView.bounds.width > 0 else { return }
        for ip in collectionView.indexPathsForVisibleItems {
            guard let id = dataSource.itemIdentifier(for: ip),
                  let m = rowModels[id],
                  let cell = collectionView.cellForItem(at: ip) as? MessageRowCell else { continue }
            cell.repaintMetaIfChanged(m, plan: planStore.plan(for: m, width: collectionView.bounds.width),
                                      cid: cid)
        }
    }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended else { return }
        let loc = g.location(in: collectionView)
        guard let ip = collectionView.indexPathForItem(at: loc),
              let id = dataSource.itemIdentifier(for: ip), rowModels[id] != nil else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onUikitDoubleTap(id)
    }

    // DELETED HERE: the UIKit contextMenuConfiguration path (Apple's menu for uikit-routed text
    // rows). On this branch EVERY long press goes through the custom system below — one presenter,
    // our geometry, no Apple menu anywhere (see CMContextMenu.swift and the study memory).

    // MARK: - Custom long-press menu (experiment)

    /// The real bubble to hide/squeeze, an already-taken snapshot of it, and its window frame.
    /// Snapshot BEFORE the squeeze runs, so the preview is the unsqueezed truth.
    /// ⛔ A WALL OF TEXT IS LIFTED FROM ITS TOP, NOT SHRUNK TO NOTHING — his screenshot,
    /// 2026-08-27: expand a very long message with "Read more", long-press it, and the menu came up
    /// with an EMPTY space where the message should be. The overlay scales a tall preview down to
    /// fit and stops at 0.35; a message several screens tall is illegible long before that and, past
    /// the fit maths, effectively invisible. His own words for the fix: on a long press it should
    /// "become read more again", because the whole thing cannot be shown.
    ///
    /// Cropping happens at the SOURCE rect, so the snapshot is simply a shorter view — the
    /// container, the overlay's fit maths and the return animation all keep working unchanged.
    private func liftCap(_ frame: CGRect) -> CGRect {
        let screen = view.window?.bounds.height ?? view.bounds.height
        let cap = (screen * 0.34).rounded()          // ~13 lines on his phone
        guard frame.height > cap else { return frame }
        return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: cap)
    }

    private func bubbleSource(at indexPath: IndexPath, id: String)
        -> (source: UIView, snapshot: UIView, frame: CGRect)? {
        guard let cell = collectionView.cellForItem(at: indexPath) else { return nil }
        if let native = cell as? MessageRowCell {
            // The lift has to include the reaction badges: they hang 13pt off the bubble's bottom
            // corner, and a snapshot of the bubble's own bounds slices them in half. `liftFrameInWindow`
            // is the bubble unioned with its badges, which is what the SwiftUI path expressed as
            // `bottomOverhang: 13` on its published rect.
            let frame = liftCap(native.liftFrameInWindow)
            let inBubble = native.previewBubble.convert(frame, from: nil)
            guard let snap = native.previewBubble.resizableSnapshotView(from: inBubble,
                                                                       afterScreenUpdates: false,
                                                                       withCapInsets: .zero) else { return nil }
            return (native.previewBubble, snap, frame)
        }
        // Hosted (SwiftUI) row: crop the row snapshot to the published bubble rect. The bubble draws
        // its own rounded corners over a clear row background, so the crop needs no masking. When no
        // rect was published yet, fall back to the whole row content.
        if let rect = CMBubbleRects.rect(id).map(liftCap) {
            let inContent = cell.contentView.convert(rect, from: nil)
            guard let snap = cell.contentView.resizableSnapshotView(from: inContent,
                                                                    afterScreenUpdates: false,
                                                                    withCapInsets: .zero) else { return nil }
            return (cell.contentView, snap, rect)
        }
        guard let snap = cell.contentView.snapshotView(afterScreenUpdates: false) else { return nil }
        return (cell.contentView, snap, cell.contentView.convert(cell.contentView.bounds, to: nil))
    }

    @objc private func handleCustomPress(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            beginCustomMenu(at: g.location(in: collectionView))
        case .changed:
            activeMenu?.overlay.fingerMoved(to: g.location(in: nil))
        case .ended, .cancelled, .failed:
            if let menu = activeMenu {
                menu.overlay.fingerEnded(at: g.location(in: nil))
            } else {
                squeezeToken &+= 1   // the press died while the squeeze ripened → no menu
                // AND drop the land gate. beginCustomMenu holds it for 8s expecting the menu (or the
                // passive 0.25s hold recognizer) to release it; a press let go between 0.20s and
                // 0.25s hits neither, so new messages sat frozen for the full 8s (audit).
                interactionHoldUntil = Date()
            }
        default: break
        }
    }

    /// the reference app's two-beat open: the press has already ripened (0.2s), now the bubble squeezes to 0.95
    /// for 0.2s more. Finger still down at the end → present; lifted → bounce back, nothing opens.
    private func beginCustomMenu(at loc: CGPoint) {
        guard activeMenu == nil,
              let ip = collectionView.indexPathForItem(at: loc),
              let id = dataSource.itemIdentifier(for: ip),
              let src = bubbleSource(at: ip, id: id) else { return }
        let actions = customMenuActions(id)
        guard !actions.isEmpty else { return }
        interactionHoldUntil = Date().addingTimeInterval(8)   // land gate up while the menu ripens
        squeezeToken &+= 1
        let token = squeezeToken
        UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
            src.source.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
        } completion: { _ in
            let pressStillDown = self.customPress.state == .began || self.customPress.state == .changed
            guard token == self.squeezeToken, pressStillDown, self.activeMenu == nil else {
                UIView.animate(withDuration: 0.2) { src.source.transform = .identity }
                return
            }
            self.presentCustomMenu(id: id, actions: actions, src: src)
        }
    }

    private func presentCustomMenu(id: String, actions: [CMAction],
                                   src: (source: UIView, snapshot: UIView, frame: CGRect)) {
        guard let window = view.window else {
            UIView.animate(withDuration: 0.2) { src.source.transform = .identity }
            return
        }
        // Shadow-friendly wrapper: the overlay shadows the container, the snapshot keeps its alpha.
        // The snapshot MUST resize with the container — the overlay shrinks a tall message's frame to
        // fit bar + message + menu, and without this mask the picture inside stayed original size and
        // spilled off the screen's right edge while the menu parked on top of it (the owner's
        // long-message screenshot, build 414). A snapshot view stretches its captured content to its
        // bounds, so the flexible mask is the whole fix.
        src.snapshot.frame = CGRect(origin: .zero, size: src.frame.size)
        src.snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let container = UIView(frame: CGRect(origin: .zero, size: src.frame.size))
        container.addSubview(src.snapshot)

        let react = customReactConfig(id).map { cfg in
            CMReactConfig(emojis: cfg.emojis, selected: cfg.selected) { [weak self] selection in
                self?.onCustomReact(id, selection)
            }
        }
        // My messages hug the right edge; alignment follows the bubble's own side.
        let alignRight = src.frame.midX > window.bounds.midX

        // ⚠️ ARMED FIRST, BEFORE THE KEYBOARD IS TOUCHED. `onMenuCloseKeyboard` resigns the first
        // responder synchronously, which posts the hide notification on this same turn — so if the
        // flag were set after it (as it was), `updateInsets` would already have walked the list by
        // the time the guard existed.
        contextMenuVisible = true
        // ⛔ THE KEYBOARD STAYS UP, AS THEIRS DOES — owner, on a screenshot: "when i open keyboard then
        // message i hold longpress, copy from signal". Read from their delegate: every long-press path
        // calls `presentContextMenu` and NONE of them calls `dismissKeyBoard()`. They dismiss it for a
        // media tap, for opening a member sheet, for a handful of other navigations — never for the
        // message menu. The menu is presented over the keyboard and their inset update simply does
        // nothing while it is up (`isPresentingContextMenu`), which is the branch we already ported.
        //
        // Ours closed it, and closing it is what moved the conversation out from under the menu's
        // frozen snapshot in the first place — the report that `contextMenuVisible` was added for.
        // With the keyboard left alone there is no clearance change to absorb, so the whole class of
        // problem stops arising rather than being guarded against.
        let keyboardWasUp = false
        let overlay = CMOverlay(previewView: container, sourceFrame: src.frame,
                                alignRight: alignRight, actions: actions, react: react) { [weak self] in
            self?.customMenuDidEnd()
        }
        src.source.isHidden = true
        src.source.transform = .identity
        activeMenu = (overlay, src.source, keyboardWasUp)
        contextMenuVisible = true
        contextMenuSourceId = id
        // The pressed CELL goes touch-dead for the menu's lifetime: cutting it cancels the hosted
        // SwiftUI tap that was still tracking this finger — without this, lifting over a photo fired
        // its open-tap underneath the menu (user: "when long press some photo will open").
        if let ip = dataSource.indexPath(for: id), let cell = collectionView.cellForItem(at: ip) {
            cell.isUserInteractionEnabled = false
            activeMenuCell = cell
        }
        // The scroll stays LOCKED while the menu is up (exclusivity already prevents the pressing
        // finger's pan; this also blocks a second finger from scrolling the chat behind the blur).
        collectionView.panGestureRecognizer.isEnabled = false
        overlay.present(in: window, startAtSqueeze: true)
    }

    /// The overlay finished its return spring: unhide the real bubble, drop the gates, settle.
    private func customMenuDidEnd() {
        guard let menu = activeMenu else { return }
        menu.sourceView.isHidden = false
        menu.sourceView.transform = .identity
        activeMenuCell?.isUserInteractionEnabled = true
        activeMenuCell = nil
        collectionView.panGestureRecognizer.isEnabled = true
        // ⛔ CLEAR THE FLAG BEFORE THE KEYBOARD COMES BACK. Theirs is asymmetric on purpose, and
        // their own sequencing proves it: the menu controller is niled as the out-animation
        // completes, and only then does `popKeyBoard()` run — so the keyboard-show layout passes
        // land with `isPresentingContextMenu == false` and ARE compensated.
        //
        // Dismissing the keyboard for the menu is uncompensated (the list must not move); restoring
        // it afterwards is compensated (the list must come back). Restoring while the flag was still
        // up would suppress the return shift and leave the conversation a keyboard's height short.
        activeMenu = nil
        contextMenuVisible = false
        contextMenuSourceId = nil
        if menu.keyboardWasUp { onMenuRestoreKeyboard() }
        interactionHoldUntil = Date()
        settleFlush()   // land everything the menu held back
    }

    // THE REAL MENU LIFETIME, from UIKit, replacing a long-press proxy that could not see it.
    //
    // the reference app's land gate blocks on `collectionViewActiveContextMenuInteraction.contextMenuVisible`. Ours
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
        // WHICH row the menu belongs to. The configuration's identifier IS the row id (see
        // contextMenuConfig). Only THIS cell must survive untouched until the dismissal ends — the
        // stranded-blur bug was its destruction mid-flight, not any other cell's. Knowing which one
        // lets the selection UI land on every OTHER row immediately (see refreshSelectionExceptMenuSource).
        contextMenuSourceId = configuration.identifier as? String
    }

    func collectionView(_ collectionView: UICollectionView,
                        willEndContextMenuInteraction configuration: UIContextMenuConfiguration,
                        animator: UIContextMenuInteractionAnimating?) {
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
        guard !ignoringScrollEvents else { return }
        // The finger has left. If the keyboard shrank the inset out from under a reader who was at the
        // newest message (interactive dismissal), this is the first honest moment to put them back.
        if !decelerate { restoreReaderPosition(); recordDistanceFromBottom(); settleFlush() }
        // The lift is the moment a jump asked for mid-drag becomes allowed. It runs whether the list
        // is about to coast or not: perform() kills the coast on its way past.
        if let animated = pendingNewestJump {
            pendingNewestJump = nil
            perform(.newest(animated: animated))
        }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard !ignoringScrollEvents else { return }   // our own stop, not the reader's — see stopScrolling
        restoreReaderPosition(); recordDistanceFromBottom(); settleFlush()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // THE WALLPAPER SLICES FOLLOW THE SCROLL, BEFORE ANY OF THE GUARDS BELOW. An incoming bubble
        // on a wallpaper shows the piece of blurred wallpaper that sits under it (see
        // `WallpaperBlur`), and a cell that scrolls is moved by this view's offset, not laid out — so
        // nothing else would ever tell the slice it has moved. This is the reference app's
        // `updateScrollingContent`, called on every tick including the ones the pill and the
        // read-tracking below deliberately ignore: a programmatic scroll and a capture freeze both
        // still move the bubbles across the picture.
        WallpaperBlurSliceView.repositionAll()
        guard !ignoringScrollEvents else { return }   // ditto: a stop is not a scroll
        // During the screenshot-capture freeze the SYSTEM owns the offset: write no SwiftUI state and fire
        // nothing.
        if Date() < captureFreezeUntil { return }
        // A finger dragging the keyboard down moves the bar and the inset on this same event.
        if scrollView.isDragging || scrollView.isTracking || scrollView.isDecelerating {
            // ⛔ NOTHING IS LATCHED HERE ANY MORE. A `readerHasScrolled` flag used to be raised on
            // this line and never lowered, and it permanently disabled the only two-directional
            // bottom correction in the file — so the chat behaved one way before the reader's first
            // drag and another way for the rest of its life. The reader's place is a live fact,
            // recorded on the next line and re-read whenever it is needed; see `restoreReaderPosition`.
            lastStableOffset = scrollView.contentOffset.y
            recordDistanceFromBottom()   // the reader is choosing a position; remember it
            userScrolledSinceTimer = true
            // Topmost visible row, for the floating date pill.
            let top = viewportIndexPaths().first.flatMap { dataSource.itemIdentifier(for: $0) }
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
        let showJump = shouldShowJumpButton
        if jumpButtonVisible != showJump {
            jumpButtonVisible = showJump
            coordinator.parent.onJumpButtonVisibility(showJump)
        }
        if userScrolledSinceTimer { autoLoadMoreIfNeeded() }
        userScrolledSinceTimer = false
    }

    // Page history in when the reader gets within three screens of the OLDEST loaded row, the top of the
    // content. Throttled; there is no zone-entry debounce, a short page leaves the reader inside the zone
    // and the time throttle alone lets the chain continue until content outruns the threshold.
    private func autoLoadMoreIfNeeded() {
        guard didReveal, Date() >= captureFreezeUntil else { return }
        let threshold = max(72, collectionView.bounds.height * 3)
        guard collectionView.contentOffset.y - minContentOffsetY <= threshold,
              // ⚠️ THIS WAS 2 SECONDS AND IT WAS THE WALL. Three screens of lead is generous, but a
              // hard flick clears three screens in well under two seconds — so the reader arrived at
              // the oldest row with the next page still forbidden and the scroll stopped dead. That
              // is the "their scroll never stops until you reach the beginning" the owner described,
              // and it was our own limit doing it, not the network.
              //
              // It only has to swallow a burst of identical asks in the same instant. The repository
              // already refuses a second `loadOlder` while one is in flight, so serialising was never
              // this timer's job.
              Date().timeIntervalSince(lastLoadOlderAt) > 0.3 else { return }
        lastLoadOlderAt = Date()
        coordinator.parent.onReachedTop()
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
        // ⛔ THE SCREENSHOT WAS CLOSING THE KEYBOARD — owner, 2026-08-25, build 682: "when I open
        // keyboard then I take screenshot, keyboard start disappearing". The full-page capture
        // scrolls this list, and with `keyboardDismissMode = .interactive` a system-driven downward
        // scroll reads as a dismiss drag. The mode is parked at `.none` for the capture window and
        // restored with the snap-back.
        collectionView.keyboardDismissMode = .none
        let snapBack: () -> Void = { [weak self] in
            guard let self else { return }
            let target = self.clampOffset(self.lastStableOffset)
            if abs(self.collectionView.contentOffset.y - target) > 4 {
                self.collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: false)
            }
        }
        DispatchQueue.main.async(execute: snapBack)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.55) { [weak self] in
            guard let self else { return }
            snapBack()
            self.collectionView.keyboardDismissMode = .interactive
            self.settleFlush()
        }
    }

    // MARK: - Voice pause / continue (the recording's floating control)

    /// ⛔ THIRD HOME, AND THE ONE WHERE TOUCHES PROVABLY LAND — owner, 2026-08-25, build 682: "still
    /// is not working pause button". As a SwiftUI overlay over this list it was dead (08-24), and as
    /// the composer bar's own subview reaching outside its bounds it was dead again: the hosting
    /// view resolves hits from its own layout and never asks a platform view about points outside
    /// the frame SwiftUI gave it. The region ABOVE the bar belongs to THIS view — the jump arrow
    /// beside it takes taps every day — so the button lives here, told what to be by ThreadView.
    var onVoiceControlTap: () -> Void = {}
    private var voiceControlButton: UIButton?
    private var voiceControlKind = 0          // 0 none · 1 pause · 2 continue (reviewing)
    /// The bar's side inset, written by `positionBottomBar` — the one place that decides it.
    private var voiceControlInset: CGFloat = 20

    /// Build the bar on first sight, then hand it the state on every pass.
    ///
    /// ⚠️ NOT AUTO LAYOUT INSIDE THE BAR. `ChatComposerView` lays its contents out by frame from
    /// its own bounds — that is its whole design — so the container gives it a size and it does the
    /// rest. Only the OUTER insets are constraints, because those are what SwiftUI used to apply.
    func applyComposer(state: ChatComposerState, actions: ChatComposerActions,
                       recorder: AudioRecorder, margin: CGFloat) {
        let bar: ChatComposerView
        if let existing = composerBar as? ChatComposerView {
            bar = existing
        } else {
            bar = ChatComposerView(recorder: recorder)
            composerBar = bar
            bar.translatesAutoresizingMaskIntoConstraints = false
            bottomBarContainer.addSubview(bar)
            let lead = bar.leadingAnchor.constraint(equalTo: bottomBarContainer.leadingAnchor)
            let trail = bar.trailingAnchor.constraint(equalTo: bottomBarContainer.trailingAnchor)
            // ⛔ THEIRS, LITERALLY: `bottomView.bottomAnchor.constraint(equalTo:
            // keyboardLayoutGuide.topAnchor)`. It used to hang off the VIEW's bottom with the whole
            // keyboard band written into its constant. The constant is now only the product rule
            // (8pt above the keys, or sunk `composerRestDip` below the safe line at rest), never the
            // keyboard — that is the guide's job, and UIKit's.
            let bottom = bar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
            let height = bar.heightAnchor.constraint(equalToConstant: 40)
            barLeading = lead; barTrailing = trail; barBottom = bottom; barHeightC = height
            NSLayoutConstraint.activate([lead, trail, bottom, height])
            // The container's TOP follows the bar's, so its height is a CONSEQUENCE of the bar's
            // layout rather than a number kept in step by hand. When the bar grows a reply preview
            // inside its own animation, the container grows in that same animation, and so does the
            // inset — which is exactly why theirs never jumps.
            let topPin = bottomBarContainer.topAnchor.constraint(equalTo: bar.topAnchor,
                                                                 constant: -Self.barTopPad)
            barTopPin = topPin
            NSLayoutConstraint.activate([topPin])
            // The bar asks for a new height when its contents change (a banner, a second line).
            // It arrives on the bar's OWN animation clock, and the container follows on the same
            // one — which is the same rule the keyboard block follows one level up.
            bar.onHeightChange = { [weak self] _ in self?.resizeBottomBar() }
        }
        // ⛔ NO INSET IS WRITTEN STRAIGHT ONTO A CONSTRAINT HERE. `positionBottomBar` is the one
        // writer of all three (bottom and both sides) and it derives them from the keyboard band,
        // so the rest/keyboard switch rides the keyboard's own animation block. Two things went
        // wrong when ThreadView's values were written here instead: the keyboard handler and this
        // method were two authors of one constraint, and the bottom one was NEVER written until the
        // first keyboard event — the composer rested on the screen edge (his 2026-08-26 report).
        // Coming back from selection / search / a blocked chat — see `hideComposer`.
        if bar.isHidden {
            bar.isHidden = false
            barTopPin?.isActive = true
        }
        composerMargin = margin
        positionBottomBar()
        bar.actions = actions
        bar.apply(state)
        resizeBottomBar()
    }

    /// ⛔ THE COMPOSER LEAVES WHEN SOMETHING ELSE TAKES THE BOTTOM. The reference SWAPS its bottom
    /// bar — `updateBottomBar` installs the one the conversation currently needs and the previous
    /// one is gone. Ours built the composer once and never removed it, so entering selection,
    /// opening search, or a chat that is blocked / a message request / muted drew SwiftUI's bar on
    /// top of a composer that was still there and still taking taps. `canShowComposer`'s own note
    /// warns about two bars stacked; this is that, from the other side.
    ///
    /// ⚠️ HIDING IS NOT ENOUGH ON ITS OWN: a hidden view still takes part in Auto Layout, so the
    /// container's top pin would hold it open at the composer's full height. The pin comes out and
    /// the low-priority height constant (0) takes over, which is exactly the state the announcements
    /// list has always run in.
    func hideComposer() {
        guard let bar = composerBar, !bar.isHidden else { return }
        bar.isHidden = true
        barTopPin?.isActive = false
        bottomBarHeight?.constant = 0
        updateInsets()
    }

    /// The bar changed height — a reply preview arrived or left, the text grew a line.
    ///
    /// ⛔ THE INSET MOVES INSIDE THE SAME ANIMATION AS THE BAR. That is the entire reason their
    /// reply preview never jumps, and their own comment says so at the offset write: "This offset
    /// change will be animated by UIKit's UIView animation block which updateContentInsets() is
    /// called within." One animation, one curve, one layout pass — the bar grows, the container
    /// grows with it, the inset follows, and `updateInsets`'s lockstep shift keeps the reader on
    /// the same message.
    ///
    /// ⛔ NO ANIMATOR OF ITS OWN — the 2026-08-26 audit. Theirs animates in the TOOLBAR (one
    /// animator for the banner's alpha, its constraints and the layout), and the list follows
    /// because the toolbar's bounds observer runs inside that animator. This used to start a second
    /// spring here while the bar's contents ran their own 0.2s ease, so the banner faded in ahead of
    /// the frame. Now the bar calls this from INSIDE its own animation block (see
    /// `ChatComposerView.apply` and `textViewDidChange`), and every write below rides that block:
    /// the constants, the inset, and the one layout pass. Called outside any block — first sight —
    /// it lands at once, which is right for a bar that was not there a frame ago.
    private func resizeBottomBar() {
        // Hidden means hidden — the same rule as `syncBottomBarGeometry`, and for the same reason:
        // the collapsed container must stay collapsed until `applyComposer` puts the bar back.
        guard let bar = composerBar as? ChatComposerView, !bar.isHidden,
              let heightC = barHeightC, let containerC = bottomBarHeight else { return }
        let width = max(1, view.bounds.width - (barLeading?.constant ?? 0) * 2)
        let barH = bar.preferredHeight(forWidth: width)
        // The pad above the pill + the bar + everything below it (the keyboard and the bar's
        // bottom inset, both carried by `barBottom`). That total IS the content inset, which is why
        // it has to be complete — a term missing here is a term of clearance the newest message
        // loses, and it lands under the composer.
        let container = Self.barTopPad + barH + (-(barBottom?.constant ?? 0)) + keyboardOverlap
        // ⚠️ THEIR THRESHOLD IS 1pt, NOT A HAIR. Their toolbar's `bounds` observer reads
        // `abs(old.height - new.height) > 1` before telling anyone, so sub-point noise from a
        // layout pass never starts an animation or moves the reader.
        guard abs(heightC.constant - barH) > 1 || abs(containerC.constant - container) > 1 else { return }
        heightC.constant = barH
        containerC.constant = container
        updateInsets()
        view.layoutIfNeeded()
    }

    /// The composer's PRODUCT rule, and nothing else. The keyboard is not in here any more: the bar's
    /// bottom is constrained to `view.keyboardLayoutGuide.topAnchor`, so where the keys are is Auto Layout's
    /// business and this only decides how the pill sits relative to them:
    ///   · riding the keyboard: 8 above the keys, sides at the system margin;
    ///   · at rest: the pill sinks `composerRestDip` BELOW the safe-area line and the sides match that
    ///     height (owner, 2026-08-24: "use same size as bottom"); a home-button phone has no strip, so
    ///     it keeps the 8 and the margin.
    ///
    /// ⚠️ ONE WRITER, ALL THREE CONSTRAINTS. Writing the sides from ThreadView's pass put the width
    /// change OUTSIDE the keyboard's animation — a snap from 29 to 20 mid-open.
    ///
    /// ⚠️ A POSITIVE CONSTANT SINKS THE BAR BELOW THE GUIDE'S TOP, which is what the rest dip is: the
    /// guide is exactly the home-indicator strip tall when the keys are down, and the pill sits 5pt
    /// into it. Against the keys the constant is negative — 8pt of clearance above them.
    private func positionBottomBar() {
        let safe = restSafeBottom   // never the keyboard-polluted view value — see `restSafeBottom`
        let keyboardUp = keyboardIsUp
        let bottomInset = (keyboardUp || safe <= 0) ? Self.composerKeyboardGap : -Self.composerRestDip
        let side = keyboardUp ? composerMargin : max(composerMargin, safe - Self.composerRestDip)
        // Guarded writes — see `syncBottomBarGeometry`: this runs on layout passes too.
        let bottomTarget = -bottomInset
        if let c = barBottom, abs(c.constant - bottomTarget) > 0.01 {
            c.constant = bottomTarget
        }
        if let c = barLeading, abs(c.constant - side) > 0.01 { c.constant = side }
        if let c = barTrailing, abs(c.constant + side) > 0.01 { c.constant = -side }
        // The same numbers reach the bar itself (it places its overlays against the padded box)
        // and the floating pause button, from here — not from a SwiftUI copy of this arithmetic
        // that arrived a pass later and could disagree with it.
        voiceControlInset = side
        if let bar = composerBar as? ChatComposerView {
            let ins = UIEdgeInsets(top: Self.barTopPad, left: side, bottom: bottomInset, right: side)
            if bar.outerInsets != ins { bar.outerInsets = ins }
        }
    }

    /// The container's height without animating it — used inside a block that is already animating.
    private func syncBottomBarGeometry() {
        // ⛔ NOT WHILE THE COMPOSER IS HIDDEN. `hideComposer` collapses the container by taking the
        // top pin out and setting this constant to 0, and with the pin gone that low-priority
        // constant is the ONLY thing left answering for the container's height. This method rewrites
        // it from the hidden bar's own dimensions, and it used to run on every tracked scroll — so a
        // scroll in selection, search or a blocked chat silently re-inflated a container that is
        // supposed to be gone, and the dock overlays pinned to it jumped
        // by a composer's height.
        guard let bar = composerBar as? ChatComposerView, !bar.isHidden,
              let heightC = barHeightC, let containerC = bottomBarHeight else { return }
        let width = max(1, view.bounds.width - (barLeading?.constant ?? 0) * 2)
        let barH = bar.preferredHeight(forWidth: width)
        let container = Self.barTopPad + barH + (-(barBottom?.constant ?? 0)) + keyboardOverlap
        // Guarded writes: this runs from the safe-area handler on every change, and a
        // constant rewritten to its own value would dirty layout again for nothing.
        if abs(heightC.constant - barH) > 0.01 { heightC.constant = barH }
        if abs(containerC.constant - container) > 0.01 { containerC.constant = container }
    }

    func setVoiceControl(_ kind: Int) {
        positionVoiceControl()
        guard kind != voiceControlKind else { return }
        voiceControlKind = kind
        if kind == 0 {
            guard let b = voiceControlButton else { return }
            UIView.animate(withDuration: 0.2, animations: { b.alpha = 0 },
                           completion: { [weak self] _ in
                if self?.voiceControlKind == 0 { b.isHidden = true }
            })
            return
        }
        let b: UIButton
        if let existing = voiceControlButton {
            b = existing
        } else {
            var cfg = UIButton.Configuration.glass()
            cfg.cornerStyle = .capsule
            cfg.contentInsets = .zero
            b = UIButton(configuration: cfg)
            b.alpha = 0
            b.addAction(UIAction { [weak self] _ in self?.onVoiceControlTap() }, for: .touchUpInside)
            view.addSubview(b)
            voiceControlButton = b
        }
        // PAUSE (16 semibold) while recording; the review's red mic (18) to CONTINUE. RED, not the
        // accent — red is the recording signal everywhere in the bar.
        var cfg = b.configuration ?? .glass()
        cfg.image = UIImage(systemName: kind == 2 ? "mic.fill" : "pause.fill")
        cfg.preferredSymbolConfigurationForImage = kind == 2
            ? UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
            : UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        cfg.baseForegroundColor = .systemRed
        b.configuration = cfg
        b.accessibilityLabel = kind == 2 ? "Continue recording" : "Pause and listen back"
        b.isHidden = false
        view.bringSubviewToFront(b)
        positionVoiceControl()
        UIView.animate(withDuration: 0.2) { b.alpha = 1 }
    }

    /// The pause / continue button while recording: the composer's own side column, just above the
    /// bar's top edge.
    ///
    /// ⛔ THE SAME OVERLAP HAS NOW BEEN REPORTED TWICE, WITH TWO DIFFERENT CAUSES. Build 683,
    /// 2026-08-25: the pause and the send button "are overlapping" — that time the arithmetic
    /// forgot that the bar sits ON TOP of the home-indicator band, so measuring only the bar from
    /// the physical bottom put this a whole band too low. It was fixed by adding the band.
    ///
    /// ⛔ PLACED FROM THE BAR'S OWN CONTAINER, NOT FROM A MEASUREMENT THAT NO LONGER HAPPENS.
    /// His report, 2026-08-26: the pause button and the send button overlap while recording.
    ///
    /// This used to be `maxY - keyboardBand - composerBarH - 16 - 40`, where `composerBarH` was the
    /// bar's height as measured by SwiftUI's `GeometryReader`. When the bar moved into this
    /// controller, that reader was left measuring a zero-height spacer, and `setComposerBarHeight`
    /// rejects anything under 30 — so the value froze and the button was placed 56pt above the
    /// screen bottom, which is the bar's own row.
    ///
    /// The container's top edge IS the bar's top less its pad, and it is live: it moves with the
    /// keyboard and grows with the bar. The side inset is the bar's own leading constant, so the
    /// two edges are one number by construction (his 2026-08-24 rule for the floating buttons).
    private func positionVoiceControl() {
        guard let b = voiceControlButton else { return }
        let top = bottomBarContainer.frame.minY
        let side = barLeading?.constant ?? voiceControlInset
        b.frame = CGRect(x: view.bounds.maxX - side - 40,
                         y: top - 12 - 40,
                         width: 40, height: 40)
    }
}

// MARK: - The UIKit rows' taps
//
// The cell hit-tests its own plan and says WHICH part was hit; the controller only forwards. Nothing
// here reads app state, which is why a row's taps behave identically whether it is on screen, being
// recycled, or under a menu.

extension MessageListController: MessageRowCellDelegate {
    func rowCell(_ cell: MessageRowCell, didTapLink url: URL) {
        onTapLink(url)
    }

    func rowCell(_ cell: MessageRowCell, didTapQuoteJumpTo id: String) {
        onTapQuote(id)
    }

    func rowCell(_ cell: MessageRowCell, didTapStoryQuote id: String) {
        guard let rowId = cell.rowId else { return }
        onTapStoryQuote(rowId, id)
    }

    func rowCellDidTapPill(_ cell: MessageRowCell) {
        guard let id = cell.rowId else { return }
        onTapPill(id)
    }

    func rowCellDidTapReadMore(_ cell: MessageRowCell) {
        guard let id = cell.rowId else { return }
        onTapReadMore(id)
    }

    func rowCellDidTapMedia(_ cell: MessageRowCell) {
        guard let id = cell.rowId else { return }
        onTapMedia(id)
    }

    func rowCell(_ cell: MessageRowCell, didTapAlbumTile index: Int) {
        guard let id = cell.rowId else { return }
        onTapAlbumTile(id, index)
    }

    func rowCellDidToggleVoice(_ cell: MessageRowCell) {
        guard let id = cell.rowId else { return }
        onToggleVoice(id)
    }

    func rowCellDidTapStoryReply(_ cell: MessageRowCell) {
        guard let id = cell.rowId else { return }
        onTapStoryReplyCard(id)
    }

    func rowCellDidTapLinkCard(_ cell: MessageRowCell) {
        guard let id = cell.rowId else { return }
        onTapLinkCard(id)
    }

    func rowCellDidTapLinkProfile(_ cell: MessageRowCell) {
        guard let id = cell.rowId else { return }
        onTapLinkProfile(id)
    }

    func rowCellDidTapFile(_ cell: MessageRowCell) {
        guard let id = cell.rowId else { return }
        onTapFile(id)
    }

    func rowCellDidTapLocation(_ cell: MessageRowCell) {
        guard let id = cell.rowId else { return }
        onTapLocation(id)
    }

    func rowCellDidTapContactCard(_ cell: MessageRowCell) {
        guard let id = cell.rowId else { return }
        onTapContactCard(id)
    }

    func rowCellDidTapContactMessage(_ cell: MessageRowCell) {
        guard let id = cell.rowId else { return }
        onTapContactMessage(id)
    }

    func rowCellDidTapReactions(_ cell: MessageRowCell) {
        guard let id = cell.rowId else { return }
        onTapReactions(id)
    }

    func rowCellDidTapRetry(_ cell: MessageRowCell) {
        guard let id = cell.rowId else { return }
        onTapRetry(id)
    }

    func rowCellDidToggleSelection(_ cell: MessageRowCell) {
        guard let id = cell.rowId else { return }
        onToggleSelect(id)
    }

    func rowCell(_ cell: MessageRowCell, didTapSender uid: String) {
        onTapSender(uid)
    }

    func rowCellDidTapCallRow(_ cell: MessageRowCell) {
        guard let id = cell.rowId else { return }
        onTapCallRow(id)
    }

    func rowCellDidTapPinNotice(_ cell: MessageRowCell, jumpTo id: String) {
        onTapPinNotice(id)
    }
}

// Pre-measured layout: cell heights are known before layout (never self-sized), so every frame is
// exact on the first pass. Item 0 is the oldest loaded message at content y = 0; rows stack downward.
// `heightForItem` reads the controller's measured-height cache; prepare() stacks the rows into exact
// frames and an exact content height.
final class MessageLayout: UICollectionViewLayout {

    var heightForItem: ((Int) -> CGFloat)?
    // A render-state id: an O(1) identity check instead of re-stacking frames on every prepare(). The
    // controller bumps this whenever ids/heights change; unchanged generation + width + count â†’ the cached
    // frames are reused untouched (prepare() is called constantly during scrolling).
    var generation = 0

    private var frames: [CGRect] = []
    private var contentHeight: CGFloat = 0
    /// Their `ConversationStyle.contentMarginBottom` on iOS 26.
    static let contentMarginBottom: CGFloat = 8
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
        // Theirs, verbatim: `contentBottom += conversationStyle.contentMarginBottom` — 8pt of
        // content after the last message (24 before iOS 26), so the newest bubble never sits
        // directly on the inset line. The 2026-08-26 audit: ours added nothing here, which with the
        // bar's own pad made the bubble-to-pill gap 6pt against their 16.
        contentHeight = y + Self.contentMarginBottom
        builtGeneration = generation
        builtCount = count
    }

    override var collectionViewContentSize: CGSize { CGSize(width: layoutWidth, height: contentHeight) }

    // ONE-CONNECTED-SHEET (the the reference app model): keep a full viewport of rows rendered on each side of the
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
    // Fed by the controller for any change above the reader: a page of history, a row above them that
    // changed height, a deletion above them. Zero for everything at or below the viewport.
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

