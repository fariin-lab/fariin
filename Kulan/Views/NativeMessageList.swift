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
    var voiceControlInset: CGFloat = 20        // the composer's side inset (the send button's column)
    var onVoiceControlTap: () -> Void = {}
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
        vc.rowModels = rowModels   // BEFORE apply: measure + cell provider see the same frozen routing
        vc.cid = cid
        vc.uikitMenu = uikitMenu
        vc.onUikitDoubleTap = onUikitDoubleTap
        vc.onTapLink = onTapLink
        vc.onTapQuote = onTapQuote
        vc.onTapStoryQuote = onTapStoryQuote
        vc.onTapMedia = onTapMedia
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
        vc.setVoiceControl(voiceControl, inset: voiceControlInset)
        vc.setTopOverlayHeight(topOverlayHeight)
        vc.noteSendTick(sendTick)              // BEFORE apply: the hold must precede the composer's shrink
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
    var lastRepaintedModelsVersion = -1       // -1 so the first update always repaints

    // Rows whose rendered height the SIZER can never reproduce (async content, e.g. link-preview cards).
    private var sizerRefused = Set<String>()
    /// The height a refused row actually RENDERED at. Once the sizer has been proven wrong for a row,
    /// this is that row's height everywhere — `measure()` returns it, so the apply path and the report
    /// path cannot hand the layout two different answers. See `reportHeight`.
    private var renderedHeights: [String: CGFloat] = [:]
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
    // DEAD FLAG, kept only so the two guards below keep compiling: it is never set anywhere (audit).
    // The keyboard-synced offset animation these guards describe no longer exists — the inverted list
    // moves the offset by the clearance delta instead. Do NOT trust the comments at those two sites;
    // if a future keyboard fix needs a hold, wire this flag for real rather than assuming it works.
    private let keyboardAnimating = false
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
    private var lastKnownDistanceFromBottom: CGFloat = 0
    /// ⛔ THE KEYBOARD REACHES THIS LIST THROUGH UIKIT'S OWN LAYOUT GUIDE — the reference app's
    /// mechanism, ported on the owner's order 2026-08-25 ("copy their approach for both directions…
    /// 100%, not an approximation"). See the note above `updateInsets`.
    ///
    /// An invisible, zero-height view whose bottom is pinned to `view.keyboardLayoutGuide.topAnchor`.
    /// It draws nothing and is never read; its one job is theirs (their bottom bar is constrained to
    /// the guide): when the keyboard moves, UIKit changes the guide INSIDE its own keyboard animation
    /// block, this constraint dirties the view's layout, and `viewDidLayoutSubviews` therefore runs
    /// inside that block — which is what lets an unanimated offset write ride the keys.
    private let keyboardTracker = UIView()
    /// The clearance under the last bubble / over the first one that `updateInsets` last established,
    /// in ADJUSTED terms (what the reader actually had), so a change is noticed whichever of our
    /// inset and SwiftUI's safe area carried it, and so "was I at the bottom" can be asked against
    /// pre-change geometry.
    private var lastBottomClearance: CGFloat = 0
    private var lastTopClearance: CGFloat = 0
    /// Theirs: safe-area changes are debounced (0.01s, last only) because an interactive dismiss
    /// updates the safe area "rapidly in quick succession". The layout path is never debounced.
    private var safeAreaInsetsWork: DispatchWorkItem?

    /// Record where the reader is, as a distance from the newest message. Cheap; called often.
    private func recordDistanceFromBottom() {
        guard didFirstLand else { return }
        lastKnownDistanceFromBottom = max(0, maxContentOffsetY - collectionView.contentOffset.y)
    }
    private let dateLabel = UILabel()
    private var dateFadeWork: DispatchWorkItem?
    private var lastDateId: String?
    var onTopInset: ((CGFloat) -> Void)?      // ThreadView positions the date pill / pinned bar with this
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
        // through `keyboardTracker` and the layout guide, inside the keyboard's own animation block.
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

        // The keyboard's own layout guide, the way the reference app's bottom bar hangs from it. See
        // `keyboardTracker`. Touched once here first: theirs notes that on iOS 26 a guide first read
        // late reports the home-indicator height (34) instead of the keyboard's, and that reading it
        // early is what fixes that.
        _ = view.keyboardLayoutGuide
        keyboardTracker.isUserInteractionEnabled = false
        keyboardTracker.isHidden = true
        keyboardTracker.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keyboardTracker)
        NSLayoutConstraint.activate([
            keyboardTracker.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboardTracker.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyboardTracker.heightAnchor.constraint(equalToConstant: 0),
            keyboardTracker.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
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
        // KEYBOARD, BY NOTIFICATION — see `notifiedKeyboardBand` for why the layout guide alone
        // could not be trusted inside this hosted controller.
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHideNote(_:)),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)
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
        let anchors = continuityAnchors()
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

    // The row the reader's position is measured against: the visible row CLOSEST TO THE ORIGIN, i.e. the
    // topmost one on screen. A change above it is what can move the reader; the delta is measured there.
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
    private func continuityDelta(_ anchors: [Anchor],
                                 before: [String: CGFloat],
                                 after: [String: CGFloat]) -> (delta: CGFloat, anchor: Anchor)? {
        for a in anchors {
            guard let b = before[a.id], let f = after[a.id] else { continue }
            return (f - b, a)
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
            // First unread near the top, with 12pt of breathing room under the nav bar.
            let y = clampOffset(attr.frame.minY - collectionView.adjustedContentInset.top - 12)
            collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
            lastStableOffset = y
        }
    }

    private func scrollToOffset(_ y: CGFloat, animated: Bool) {
        let target = clampOffset(y)
        guard abs(collectionView.contentOffset.y - target) > 0.5 else { return }
        lastStableOffset = target
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
                guard let self, seq == self.glideSeq,
                      !self.collectionView.isDragging, !self.collectionView.isTracking,
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
        if keyboardAnimating, selectionAnimationState != .willAnimate { return false }
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
    /// `clampToNewestIfBeyond()` and `settleFlush()`, either of which can move the reader, and both
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
        // ⚠️ AFTER the flags are cleared, never before: `clampToNewestIfBeyond` stands down while
        // either animation flag is set, so calling it any earlier is a no-op.
        clampToNewestIfBeyond()
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
        let anchors = continuityAnchors()
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
            let visible = collectionView.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) }
            let changed = visible.filter { rowSignatures[$0] != lastRowSigs[$0] }
            lastRowSigs = rowSignatures
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
        // row move? The anchor is the topmost visible row, so the delta sums exactly the rows that
        // landed, grew, shrank or left ABOVE the reader. A page of history is the common case now, and
        // it is compensated inside the same update transaction (see MessageLayout.targetContentOffset).
        var adjustment: CGFloat = 0
        var landedAnchor: Anchor?
        // Computed for EVERY reader, including one at the newest message: a page of history landing
        // above them moves their rows too, and the delta is what holds them still. (In the inverted
        // list this was skipped at the newest message because an append could not move anyone; an
        // append still cannot, the anchor row does not move, so the delta comes out zero on its own.)
        if let landed = continuityDelta(anchors, before: beforeY, after: afterY) {
            adjustment = landed.delta
            landedAnchor = landed.anchor
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, self.sendAnimating else { return }
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
        let anchors = continuityAnchors()
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
    // everything, so it moved whenever a measurement landed. The newest message is at the origin, so there
    // is one landing and it is exact.
    private func performFirstLandIfReady() {
        guard !didFirstLand,
              collectionView.bounds.width > 0, collectionView.bounds.height > 0,
              !currentIds.isEmpty else { return }
        // The landing offset depends on contentSize and both insets, so the insets must be current and
        // the layout settled BEFORE we land; the composer height and safe area can arrive after the
        // first apply.
        updateInsets()
        measureMissing(currentIds, width: collectionView.bounds.width)
        layout.generation += 1
        layout.invalidateLayout()
        collectionView.layoutIfNeeded()
        didFirstLand = true
        perform(.initialPosition)
        recordDistanceFromBottom()
        lastBottomClearance = bottomClearance
        lastTopClearance = collectionView.contentInset.top
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
        return max(0, room - collectionView.contentSize.height)
    }

    private var minContentOffsetY: CGFloat { -collectionView.adjustedContentInset.top }
    private var maxContentOffsetY: CGFloat {
        max(minContentOffsetY,
            collectionView.contentSize.height + collectionView.adjustedContentInset.bottom - collectionView.bounds.height)
    }
    private func clampOffset(_ y: CGFloat) -> CGFloat { min(max(minContentOffsetY, y), maxContentOffsetY) }

    // AT THE NEWEST MESSAGE: within 5pt of the bottom of the content (the reference app's tolerance).
    // This reads contentSize, so it is only asked with the layout settled; see the file comment.
    private var isAtNewest: Bool { collectionView.contentOffset.y >= maxContentOffsetY - 5 }

    /// AT REST, THE READER CAN NEVER BE BEYOND THE NEWEST MESSAGE. The keyboard leaving shrinks the
    /// bottom inset, which shrinks `maxContentOffsetY`; a reader parked at the old maximum is then in the
    /// bottom bounce region with the last bubble under the composer, and nothing pulls them back on its
    /// own because no finger is there to end a drag. Being beyond the bound at rest is never legitimate,
    /// so it is enforced wherever the list comes to rest rather than patched per timing.
    ///
    /// ⚠️ HARMLESS WHILE THE KEYBOARD MOVES, by construction rather than by a flag. The guide changes
    /// the bound ONCE, inside the keyboard's animation block, and `updateInsets` writes the final
    /// offset in that same pass; the model offset is therefore already at the bound while the
    /// presentation animates, and this finds nothing beyond it. The old keyboard clock that used to
    /// gate this went with the rest of the notification machinery (see `updateInsets`).
    private func clampToNewestIfBeyond() {
        guard didFirstLand, !isDisappearing,
              !collectionView.isTracking, !collectionView.isDragging, !collectionView.isDecelerating,
              !sendAnimating, !programmaticScrollAnimating else { return }
        let bound = maxContentOffsetY
        guard collectionView.contentOffset.y > bound + 0.5 else { return }
        UIView.performWithoutAnimation {
            collectionView.setContentOffset(CGPoint(x: 0, y: bound), animated: false)
        }
    }

    /// Set the moment a finger first moves the list; never reset while the chat is open.
    private var readerHasScrolled = false

    /// ⛔ THE FIRST-OPEN NET — owner, 2026-08-25, build 681, twice ("when open first time chat,
    /// messages is entering under composer… need scroll", then again opening from the chat list).
    ///
    /// The clearance under the last bubble is assembled from parts that arrive a beat apart on a
    /// cold open: the composer's height is measured by SwiftUI and reported a pass later, the
    /// keyboard guide resolves on its own first layout, image rows re-measure. A reader pinned to
    /// the newest bound BEFORE a late part lands is left exactly that part short — visibly under the
    /// bar, healing only when a scroll recomputes everything. WHICH pass completes the clearance
    /// cannot be named in advance (his two OSes have already disagreed over exactly such orderings),
    /// so the net is positional rather than causal: until the reader scrolls for the first time, a
    /// reader whose RECORDED place is the newest message is kept at the newest bound on every layout
    /// pass. One comparison when nothing changed; dies at the first real scroll.
    ///
    /// The RECORDED distance, deliberately: a first-unread landing records its real distance, and
    /// every programmatic jump records where it put the reader, so none of them are touched.
    private func keepNewestUntilFirstScroll() {
        guard didFirstLand, !isDisappearing, !readerHasScrolled,
              lastKnownDistanceFromBottom <= 5,
              !collectionView.isTracking, !collectionView.isDragging, !collectionView.isDecelerating,
              !sendAnimating, !programmaticScrollAnimating else { return }
        let bound = maxContentOffsetY
        guard abs(collectionView.contentOffset.y - bound) > 0.5 else { return }
        collectionView.setContentOffset(CGPoint(x: 0, y: bound), animated: false)
        lastStableOffset = bound
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
    // ⚠️ "WAS AT THE BOTTOM" IS ASKED AGAINST THE CLEARANCE LAST ESTABLISHED, not the live adjusted
    // inset. If SwiftUI's safe area moves before the guide does, the live bound has already moved and
    // a reader who was at the newest message no longer looks it. Theirs can use the live test because
    // their safe area never carries the keyboard; ours cannot, so the question is asked against the
    // geometry this method last left behind.
    /// The keyboard band the NOTIFICATION most recently announced; nil at rest.
    ///
    /// ⛔ THE GUIDE ALONE WAS NOT ENOUGH ON HIS PHONE — owner, 2026-08-25, build 682, iOS 26: typing
    /// left the bubbles BEHIND the keys, and the open "feels small… bubbles under keyboard". The
    /// layout guide never moved inside this hosted controller on that device, and with the
    /// safe-area route deliberately severed (see `nativeList` in ThreadView) the keyboard had no way
    /// into the list at all; the rest fallback in `keyboardBand` masked it whenever the keyboard was
    /// down, which is why everything at rest looked fixed. At-rest truth still comes from the guide
    /// or the safe area; a MOVING keyboard announces itself here, and the announcement carries its
    /// own duration and curve, so `rideKeyboard` wraps the inset work in exactly that animation —
    /// the reference app's own shipped mechanism from before the guide existed, and the one route
    /// that cannot depend on how a hosted view controller is plumbed. Where the guide does work, the
    /// two agree and every write is idempotent.
    private var notifiedKeyboardBand: CGFloat?

    @objc private func keyboardWillChangeFrame(_ note: Notification) { rideKeyboard(note, hiding: false) }
    @objc private func keyboardWillHideNote(_ note: Notification) { rideKeyboard(note, hiding: true) }

    private func rideKeyboard(_ note: Notification, hiding: Bool) {
        guard isViewLoaded, view.window != nil, !isDisappearing,
              let info = note.userInfo,
              let end = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        // The end frame is in screen coordinates; its overlap with THIS view is the band. A hide's
        // end frame is off the bottom, so its overlap never exceeds the resting safe area.
        let local = view.convert(end, from: nil)
        let overlap = max(0, view.bounds.maxY - local.minY)
        notifiedKeyboardBand = (hiding || overlap <= view.safeAreaInsets.bottom + 0.5) ? nil : overlap
        let d = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0
        let curve = (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 7
        if d > 0 {
            // The keyboard's own duration and curve (7, its private one, handed to UIKit as
            // `rawValue << 16`): the offset write inside rides the keys on every OS, whether or not
            // the guide also fires.
            UIView.animate(withDuration: d, delay: 0,
                           options: [UIView.AnimationOptions(rawValue: curve << 16),
                                     .beginFromCurrentState, .allowUserInteraction],
                           animations: { self.updateInsets(); self.view.layoutIfNeeded() })
        } else {
            // An interactive drag reports no duration: the finger owns the motion.
            updateInsets()
        }
    }

    private var keyboardBand: CGFloat {
        // A present keyboard is whatever the notification said — see `notifiedKeyboardBand`.
        if let band = notifiedKeyboardBand { return band }
        let frame = view.keyboardLayoutGuide.layoutFrame
        // The guide's frame is a zero RECT until UIKit first resolves it (distinct from the resolved
        // zero-HEIGHT frame a home-button phone reports at rest, whose minY is the view's bottom).
        // Unresolved means "no keyboard": the band is the safe-area bottom, which is exactly what
        // the guide itself answers once resolved at rest.
        guard frame.height > 0 || frame.minY > 0 else { return view.safeAreaInsets.bottom }
        return max(0, view.bounds.maxY - frame.minY)
    }
    private var bottomClearance: CGFloat { keyboardBand + composerBarH + 12 }

    /// The at-rest bottom bound the list had under a given bottom clearance.
    private func boundForClearance(_ bottomClearance: CGFloat) -> CGFloat {
        max(minContentOffsetY, collectionView.contentSize.height + bottomClearance - collectionView.bounds.height)
    }

    private func updateInsets() {
        guard isViewLoaded, !isDisappearing else { return }
        // Theirs: not during an interactive pop.
        if let pop = navigationController?.interactivePopGestureRecognizer {
            switch pop.state { case .possible, .failed: break; default: return }
        }
        view.layoutIfNeeded()   // theirs: the guide's frame is current before it is read

        let bottom = bottomClearance
        let top = topOverlayHeight + bottomAlignShortfall(bottomClearance: bottom)
        let safe = collectionView.safeAreaInsets
        let oldInsets = collectionView.contentInset
        var newInsets = oldInsets
        newInsets.bottom = bottom - safe.bottom
        newInsets.top = top

        // Step 1: pre-change geometry.
        let previousBottom = lastBottomClearance
        let oldYOffset = collectionView.contentOffset.y
        let wasScrolledToBottom = oldYOffset >= boundForClearance(previousBottom) - 5

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

        let clearanceChanged = abs(bottom - previousBottom) > 0.5 || abs(top - lastTopClearance) > 0.5
        guard didChangeInsets || clearanceChanged else { return }
        lastBottomClearance = bottom
        lastTopClearance = top

        // Step 3. Theirs: the finger owns the offset while it drags the keyboard down.
        guard !collectionView.isDragging else { return }
        // Ours additionally: a send glide or a jump is a programmatic animated scroll that already
        // knows where it is going, and `scrollViewDidEndScrollingAnimation` lands it.
        guard didFirstLand, !collectionView.isDecelerating,
              !sendAnimating, !programmaticScrollAnimating else { return }
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
        if wasScrolledToBottom {
            // Theirs, verbatim: "If we were scrolled to the bottom, don't do any fancy math. Just
            // stay at the bottom."
            let bound = maxContentOffsetY
            if abs(collectionView.contentOffset.y - bound) > 0.5 {
                collectionView.setContentOffset(CGPoint(x: 0, y: bound), animated: false)
            }
        } else {
            // Theirs: "shift the content in lockstep with the keyboard, up to the limits of the
            // content bounds." The delta is the clearance's, which is where the keyboard lands for us.
            let insetChange = bottom - previousBottom
            if abs(insetChange) > 0.5 {
                let want = clampOffset(oldYOffset + insetChange)
                if abs(collectionView.contentOffset.y - want) > 0.5 {
                    collectionView.setContentOffset(CGPoint(x: 0, y: want), animated: false)
                }
            }
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
    // MARK: - Lifecycle

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isDisappearing = true
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
        collectionView.isPrefetchingEnabled = true     // re-enable after the jank-sensitive first presentation
        updateInsets()
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
        let anchors = wasAtNewest ? [] : continuityAnchors()
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
        safeAreaInsetsWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.updateInsets() }
        safeAreaInsetsWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: work)
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
        // `updateContentInsets()` synchronously and that is their entire keyboard handling: when the
        // keyboard moves, UIKit changes `keyboardLayoutGuide` inside its own animation block, the
        // constraint on `keyboardTracker` dirties this view's layout, and this pass therefore runs
        // INSIDE that block — so the one unanimated offset write in `updateInsets` inherits the keys'
        // real duration and curve. Not forced, not clocked, never deferred: a deferred write lands
        // outside the block and hard-jumps, which is why theirs debounces the safe-area path and not
        // this one. Cheap otherwise: it returns as soon as nothing has moved.
        updateInsets()
        // The invariant net, independent of any keyboard bookkeeping: at rest, never beyond the newest
        // bound. Catches the tail of an interactive keyboard dismissal, where `updateInsets` correctly
        // stands down because a finger owns the list while the clearance shrinks.
        clampToNewestIfBeyond()
        keepNewestUntilFirstScroll()
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
            // 1:1 with the finger to the threshold, then RUBBER-BAND (drag past -70 moves at quarter speed,
            // capped) â€” attached to the finger up close, physical resistance past the commit point.
            let t = min(0, g.translation(in: collectionView).x)
            let tx = t > -70 ? t : -70 + max(-30, (t + 70) * 0.25)
            // Move the BUBBLE VIEW inside the cell, NOT the cell: the cell's frame never changes, so the
            // collection view has nothing to react to and the neighbours stay frozen.
            (cell as? MessageRowCell)?.previewBubble.transform = CGAffineTransform(translationX: tx, y: 0)
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
    private func bubbleSource(at indexPath: IndexPath, id: String)
        -> (source: UIView, snapshot: UIView, frame: CGRect)? {
        guard let cell = collectionView.cellForItem(at: indexPath) else { return nil }
        if let native = cell as? MessageRowCell {
            // The lift has to include the reaction badges: they hang 13pt off the bubble's bottom
            // corner, and a snapshot of the bubble's own bounds slices them in half. `liftFrameInWindow`
            // is the bubble unioned with its badges, which is what the SwiftUI path expressed as
            // `bottomOverhang: 13` on its published rect.
            let frame = native.liftFrameInWindow
            let inBubble = native.previewBubble.convert(frame, from: nil)
            guard let snap = native.previewBubble.resizableSnapshotView(from: inBubble,
                                                                       afterScreenUpdates: false,
                                                                       withCapInsets: .zero) else { return nil }
            return (native.previewBubble, snap, frame)
        }
        // Hosted (SwiftUI) row: crop the row snapshot to the published bubble rect. The bubble draws
        // its own rounded corners over a clear row background, so the crop needs no masking. When no
        // rect was published yet, fall back to the whole row content.
        if let rect = CMBubbleRects.rect(id) {
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

        let keyboardWasUp = onMenuCloseKeyboard()
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
        if menu.keyboardWasUp { onMenuRestoreKeyboard() }
        activeMenu = nil
        contextMenuVisible = false
        contextMenuSourceId = nil
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
        if !decelerate { clampToNewestIfBeyond(); recordDistanceFromBottom(); settleFlush() }
        // The lift is the moment a jump asked for mid-drag becomes allowed. It runs whether the list
        // is about to coast or not: perform() kills the coast on its way past.
        if let animated = pendingNewestJump {
            pendingNewestJump = nil
            perform(.newest(animated: animated))
        }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard !ignoringScrollEvents else { return }   // our own stop, not the reader's — see stopScrolling
        clampToNewestIfBeyond(); recordDistanceFromBottom(); settleFlush()
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
        if scrollView.isDragging || scrollView.isTracking || scrollView.isDecelerating {
            readerHasScrolled = true     // the first-open net stands down for good — see it for why
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
            snapBack()
            self?.collectionView.keyboardDismissMode = .interactive
            self?.settleFlush()
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
    private var voiceControlInset: CGFloat = 20

    func setVoiceControl(_ kind: Int, inset: CGFloat) {
        voiceControlInset = inset
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

    /// The send button's column (the composer's side inset), 16 above the composer bar's top edge.
    ///
    /// ⛔ THE BAND IS PART OF THE HEIGHT IT SITS ABOVE — owner, 2026-08-25, build 683: the pause and
    /// the send button "are overlapping", his screenshot showing the pause resting on the send.
    /// `composerBarH` is the bar's own height and nothing else; the bar sits on top of the
    /// home-indicator band (or the keyboard), so measuring only the bar from the physical bottom
    /// put this button a whole band too low — straight onto the send button in the same column.
    /// `keyboardBand + composerBarH` is exactly the bar's top edge, which is what the old SwiftUI
    /// overlay measured against too (a bottom padding there starts at the safe area, not the
    /// physical edge). It rides the keyboard for free: the band grows, this rises with it.
    private func positionVoiceControl() {
        guard let b = voiceControlButton else { return }
        b.frame = CGRect(x: view.bounds.maxX - voiceControlInset - 40,
                         y: view.bounds.maxY - keyboardBand - composerBarH - 16 - 40,
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

