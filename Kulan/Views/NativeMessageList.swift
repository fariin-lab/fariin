import SwiftUI
import UIKit

// UIKit-backed message list that reproduces the reference conversation open + scroll behaviour (our own
// code). A UICollectionView hosts our existing SwiftUI rows (MessageBubble etc.) via
// UIHostingConfiguration, so no bubble feature is lost — only the scroll container differs.
//
// ROOT-CAUSE FIX (the "shake / jump / flicker on open"): we do NOT self-size cells. Self-sizing means
// the collection view lays out with an ESTIMATED height, scrolls to the bottom using the wrong total,
// then measures each SwiftUI cell and CORRECTS — and that correction is the visible shake. The reference
// never self-sizes: its layout pre-measures every cell and lays out EXACT frames, so the very
// first frame is already final and scroll-to-bottom lands perfectly.
//
// We copy that exactly:
//   1. Each row's height is measured up-front (UIHostingController.sizeThatFits at the real width,
//      cached by row id) and fed to a custom layout that stacks exact frames. Our bubbles reserve their
//      true height synchronously from stored image/video dimensions, so a photo decoding later never
//      changes a row height — the pre-measure is correct on the first pass.
//   2. Genuine late height changes (only link-preview cards, which fetch Open-Graph data async) are
//      reconciled ONCE via a GeometryReader height report, with scroll position preserved — the same way
//      the reference re-lays-out when media sizes land late. Gated until after the first reveal so it can never
//      affect the open.
struct NativeMessageList: UIViewControllerRepresentable {
    var rowIds: [String]                       // stable ids in order (Message.rowId)
    var rowSignatures: [String: String] = [:]  // per-row CONTENT signature → same-ids apply reconfigures ONLY changed rows
    var row: (String) -> AnyView               // ThreadView builds the full row (date/divider/bubble) for an id
    // UIKit bubble migration: messages the native path fully supports (plain 1:1 delivered text) render
    // as UIKit cells — no SwiftUI, no per-cell animation/re-measure during scroll. The models arrive as a
    // SNAPSHOT DICTIONARY resolved once per body run (not a live closure): measure() and the cell
    // provider read the same frozen routing, so a state flip can never route a row differently between
    // its measurement and its render (the mismatch that stranded the layout when this path first ran).
    var uikitModels: [String: UIKitBubbleModel] = [:]
    var uikitMenu: (String) -> UIMenu? = { _ in nil }        // long-press menu for UIKit-routed rows
    var onUikitDoubleTap: (String) -> Void = { _ in }        // double-tap quick reaction (heart)
    var onReachedTop: () -> Void               // near-top -> page older
    var selecting: Bool = false                // selection mode — drives the selection-animation land gate
    // The reference's initial scroll position: when the conversation has unread messages, the FIRST open
    // lands with the first-unread row (its unread divider) near the top — not at the bottom. Consumed
    // exactly once at first open; nil (or an id outside the loaded window) falls back to the bottom.
    var initialScrollId: String? = nil
    var canSwipeReply: (String) -> Bool = { _ in false }   // is this rowId reply-eligible (on the server)?
    var onSwipeReply: (String) -> Void = { _ in }          // swipe past threshold released → reply to this rowId
    var loadingOlder: Bool = false             // show the top spinner while older messages page in
    // Composer bar height (SwiftUI-measured). Extra bottom clearance so the newest message clears the bar:
    // the list is full-bleed UNDER the composer, so the composer's own safe-area inset is NOT folded by
    // .always (only the keyboard is). Keyboard stays native; this just adds the static bar height.
    var composerBarHeight: CGFloat = 0
    // Height of the top overlay (pinned-message bar) the list runs UNDER. The floating date pill drops below
    // it so it isn't hidden behind the pin (Signal behavior). 0 → pill sits at its normal top position.
    var topOverlayHeight: CGFloat = 0
    var onTopInset: (CGFloat) -> Void = { _ in }   // reports the GEOMETRIC nav-bar overlap (UIKit safe area — reliable)
    @Binding var isAtBottom: Bool
    @Binding var scrollTarget: String?         // set to a rowId to scroll it into view (reply/search jump), then cleared
    // Day label for the floating date pill, resolved from a rowId. Called from scrollViewDidScroll and
    // rendered by a UIKit pill INSIDE the controller — so scrolling no longer writes SwiftUI state (a
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
        vc.onUikitDoubleTap = onUikitDoubleTap
        vc.setComposerBarHeight(composerBarHeight)
        vc.setTopOverlayHeight(topOverlayHeight)
        vc.setSelecting(selecting)
        vc.initialScrollId = initialScrollId
        vc.canSwipeReply = canSwipeReply
        vc.onSwipeReply = onSwipeReply
        vc.dayLabelFor = dayLabelFor
        vc.onTopInset = onTopInset
        vc.setLoadingOlder(loadingOlder)
        vc.rowSignatures = rowSignatures
        // The scroll target RIDES the apply (the reference model: a jump is a scroll ACTION attached to the
        // load, landed atomically with it). Calling scrollTo after apply was a race: for a jump into older
        // history (ensureLoaded → prepend), apply's async completion restored the pre-load offset AFTER the
        // scroll had already run — stomping the jump ("reply/search jump doesn't work").
        vc.apply(rowIds: rowIds, scrollTarget: scrollTarget)
        // Belt-and-braces from the 325 field failure: push geometry-neutral model changes (read ticks)
        // STRAIGHT onto the visible uikit cells — even if the reconfigure chain misses, ticks repaint.
        vc.repaintUikitCells()
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

// Hardened collection view (the reference's ConversationCollectionView protections):
// - Auto Layout transiently zeroes frames during presentation; accepting a zero size destroys the
//   contentOffset/scroll state. Reject those values.
// - UIScrollView's internal _adjustContentOffsetIfNecessary resets the offset to zero BEFORE the content
//   size is established — snapping the view to the top. Reject offset resets while content is empty.
final class HardenedCollectionView: UICollectionView {
    override var frame: CGRect {
        get { super.frame }
        set { if newValue.width > 0, newValue.height > 0 { super.frame = newValue } }
    }
    override var bounds: CGRect {
        get { super.bounds }
        set { if newValue.width > 0, newValue.height > 0 { super.bounds = newValue } }
    }
    override var contentOffset: CGPoint {
        get { super.contentOffset }
        set {
            if contentSize.height < 1, newValue.y <= 0 { return }   // defeat pre-content zero-resets
            super.contentOffset = newValue
        }
    }
}

final class MessageListController: UIViewController, UICollectionViewDelegate, UIGestureRecognizerDelegate {
    var coordinator: NativeMessageList.Coordinator!
    private var collectionView: UICollectionView!
    private var layout: ExactHeightLayout!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var reg: UICollectionView.CellRegistration<UICollectionViewCell, String>!

    private var currentIds: [String] = []
    private var heights: [String: CGFloat] = [:]   // rowId -> exact measured height (cell-size cache)
    private var measuredWidth: CGFloat = 0
    private var hostWidth: CGFloat = 0             // final cell width, pinned into each hosted row's first layout

    // Off-screen SwiftUI sizer: hosts a row and returns its exact height for a given width (no display).
    // A child VC so it inherits our trait collection (Dynamic Type), matching the on-screen render.
    private let sizer = UIHostingController(rootView: AnyView(Color.clear))

    // Load-older indicator: a small spinner pinned at the top of the list while older messages
    // page in. Kept as a fixed overlay (not a scrolling cell / content inset) so it can't disturb the
    // exact-frame layout or the prepend anchor math.
    private let topSpinner = UIActivityIndicatorView(style: .medium)

    private var didInitialScroll = false      // the first open has landed at the bottom
    private var didReveal = false             // hidden until the first frame is final (first-load applied)
    private var scheduledEmptyReveal = false  // one-shot fallback for a genuinely-empty / slow-decrypt chat
    private var pendingBottomOnOpen = false   // brief open window: keep pinned to bottom
    private var stickBottom = false           // keep the bottom pinned across keyboard / composer resizes
    private var sendAnimating = false         // an animated send/receive glide is in flight — do NOT snap over it
    private var needsRefreshOnSettle = false  // a content refresh arrived mid-motion → coalesced, lands on settle
    private var needsPinOnSettle = false      // a bottom-append landed mid-scroll → pin at settle, never mid-drag
    private var needsReconcileOnSettle = false // a reconcile deferred mid-motion whose heights were pre-adopted
    var initialScrollId: String?              // first-unread rowId → the FIRST open lands here (reference)

    // Branch marker — compiles to a no-op outside DEBUG.
    private func dbg(_ s: String) {
        #if DEBUG
        dbgBranch = s
        debugKB("UBI")
        #endif
    }

    #if DEBUG
    // TEMPORARY keyboard-pipeline telemetry (Debug/preview builds only, never TestFlight/Release): a tiny
    // on-screen readout of the inset/offset state at each keyboard stage, so a preview screenshot of the
    // "keyboard opens but the chat doesn't scroll" bug carries the exact numbers. Remove once diagnosed.
    private let kbDebugLabel = UILabel()
    private var dbgBranch = "-"
    private func debugKB(_ stage: String) {
        kbDebugLabel.isHidden = false
        kbDebugLabel.text = String(
            format: " %@ | %@ \n ovl=%.0f safeB=%.0f barH=%.0f \n inset=%.0f off=%.1f max=%.1f \n dist=%.1f atB=%@ cap=%@ anim=%@ ",
            stage, dbgBranch, keyboardOverlap, view.safeAreaInsets.bottom, composerBarH,
            collectionView.contentInset.bottom, collectionView.contentOffset.y, maxContentOffsetY,
            safeDistanceFromBottom, computeAtBottom() ? "Y" : "N",
            atBottomForKeyboard.map { $0 ? "Y" : "N" } ?? "-", keyboardAnimating ? "Y" : "N")
    }
    private func setupKBDebug() {
        kbDebugLabel.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        kbDebugLabel.textColor = .white
        kbDebugLabel.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        kbDebugLabel.numberOfLines = 0
        kbDebugLabel.isHidden = true
        kbDebugLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(kbDebugLabel)
        NSLayoutConstraint.activate([
            kbDebugLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            kbDebugLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 52),
        ])
    }
    #endif
    private var pendingSettleHeights: Set<String> = []   // rows whose rendered height changed mid-motion
    private var captureFreezeUntil = Date.distantPast    // system screenshot capture owns the scroll until then
    private var popGestureHooked = false                 // interactive-pop target attached once
    private var lastKnownDistanceFromBottom: CGFloat = 0 // continuity scalar, tracked on every scroll (reference)
    private var scrollWorkTimer: Timer?                  // 0.1s debounce for pagination + isAtBottom writes
    private var userScrolledSinceTimer = false           // the debounced work only pages on USER scrolls
    // EVERY programmatic animated scroll is tracked (the reference registers them centrally): while one is
    // in flight, no land may invalidate the layout under it. A 5s watchdog force-clears the flag if UIKit
    // cancels the animation without a completion callback — a wedged flag would block lands forever.
    private var programmaticScrollAnimating = false
    private var scrollAnimationWatchdog: Timer?
    private var lastLoadOlderAt = Date.distantPast       // pagination throttle (2s window, reference)
    private var shouldAnimateKeyboardChanges = false     // true only between viewDidAppear and viewWillDisappear
    private var keyboardSessionWasAtBottom = false       // the show→hide session began at the bottom → end pinned
    private var geoSettleWork: DispatchWorkItem?         // trailing settle after the geometric signal goes quiet
    private var geoRiding = false                        // geometric keyboard ride in flight → layout passes stand off
    // Selection-mode animation coordination (the reference's selectionAnimationState): the land that
    // CARRIES the checkbox change passes (even mid-motion), then further lands defer until the slide
    // animation window closes — a reconfigure mid-slide clobbered the checkbox animation.
    private enum SelectionAnimationState { case idle, willAnimate, animating }
    private var selectionAnimationState: SelectionAnimationState = .idle
    private var isSelecting = false

    func setSelecting(_ s: Bool) {
        guard s != isSelecting else { return }
        isSelecting = s
        selectionAnimationState = .willAnimate   // the next land carries the checkboxes — let it through
    }
    var rowSignatures: [String: String] = [:] // set before each apply — per-row content signature
    private var lastRowSigs: [String: String] = [:]  // signatures at the last apply → diff to find changed rows
    private var lastStableOffset: CGFloat = 0 // last user/our-pin offset → screenshot-capture recovery
    private var isDisappearing = false        // swipe-back / pop in progress → freeze all content-offset reflow

    // Swipe-to-reply (the reference model): ONE pan gesture on the collection view drags the touched
    // cell's content left and reveals a reply arrow, instead of a SwiftUI drag gesture per bubble (which
    // fought the scroll pan and jittered). Callbacks are fed from SwiftUI.
    var canSwipeReply: (String) -> Bool = { _ in false }
    var onSwipeReply: (String) -> Void = { _ in }
    var uikitModels: [String: UIKitBubbleModel] = [:]   // frozen routing snapshot (set before every apply)
    var uikitMenu: (String) -> UIMenu? = { _ in nil }
    var onUikitDoubleTap: (String) -> Void = { _ in }
    // Route each id was last CONFIGURED with (uikit vs SwiftUI cell). A content change that flips the
    // route needs reloadItems (re-dequeue the other cell class) — reconfigureItems reuses the same cell
    // instance, which can't switch renderers.
    private var configuredRoutes: [String: Bool] = [:]
    private var doubleTapGesture: UITapGestureRecognizer!
    private var holdPress: UILongPressGestureRecognizer!     // passive: marks the context-menu lift window
    private var interactionHoldUntil = Date.distantPast      // lands defer while a long-press is in flight
    private var uikitReg: UICollectionView.CellRegistration<UIKitBubbleCell, String>!
    private var swipePan: UIPanGestureRecognizer!
    private weak var swipingCell: UICollectionViewCell?
    private var swipingId: String?
    private var swipeArrow: UIImageView?
    private var swipeTriggered = false         // crossed the reply threshold this drag (haptic + fire on release)

    // Floating date pill (the sticky day header), rendered in UIKit and updated directly from
    // scrollViewDidScroll — NOT via a SwiftUI binding. Shows the topmost visible row's day while scrolling,
    // fades ~1.2s after scrolling stops. This is what removes the per-scroll SwiftUI round-trip.
    var dayLabelFor: (String) -> String? = { _ in nil }
    private let datePill = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    private var datePillTop: NSLayoutConstraint!   // top constant grows by the pinned-bar height when pinned
    private var topOverlayHeight: CGFloat = 0
    private let dateLabel = UILabel()
    private var dateFadeWork: DispatchWorkItem?
    private var lastDateId: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        layout = ExactHeightLayout()
        layout.heightForItem = { [weak self] index in
            guard let self, index < self.currentIds.count else { return 44 }
            return self.heights[self.currentIds[index]] ?? 44
        }
        collectionView = HardenedCollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.isPrefetchingEnabled = false   // off until first appearance (reference: faster, jank-free open)
        collectionView.backgroundColor = .clear
        collectionView.alpha = 0   // invisible until the first render is final — never shows a mid-measure frame
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .interactive
        // .always so SwiftUI's safe-area insets (nav bar on top, floating composer on the bottom) become
        // the collection view's adjustedContentInset — the last message clears the composer and the
        // bottom-scroll lands exactly above it.
        // GEOMETRIC insets (.always): the view is full-bleed under the nav bar + home area (ThreadView
        // applies .ignoresSafeArea), and UIKit derives the top/home overlap from real geometry — a value
        // that can NOT desync (this is what made the top rock-solid in 299-301). The parts UIKit can't
        // know — the SwiftUI composer bar's height and the keyboard — are added as contentInset.bottom by
        // updateBottomInset() (bar height fed from SwiftUI; keyboard observed directly, our model).
        // The earlier fully-manual .never + SwiftUI GeometryReader insets desynced during keyboard
        // transitions (readers reporting late/0 → top inset 0 → bubbles under the header).
        collectionView.contentInsetAdjustmentBehavior = .always
        // BOTTOM edge-effect OFF: the user wants the messages fully CLEAR/raw under the composer (no frost,
        // no dimming). Hiding it removes the native soft fade so content stays sharp right up to the pills.
        if #available(iOS 26.0, *) {
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

        // Single swipe-to-reply pan (reference model). Its delegate gates it to horizontal-left drags so
        // vertical scrolling is never hijacked, and it coexists with the scroll pan.
        swipePan = UIPanGestureRecognizer(target: self, action: #selector(handleSwipePan(_:)))
        swipePan.delegate = self
        collectionView.addGestureRecognizer(swipePan)

        // Double-tap quick-react for UIKit-routed rows (the SwiftUI rows carry their own gesture).
        // Gated in gestureRecognizerShouldBegin to uikit cells only, so SwiftUI cells never see it.
        doubleTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTapGesture.numberOfTapsRequired = 2
        doubleTapGesture.delegate = self
        collectionView.addGestureRecognizer(doubleTapGesture)

        // PASSIVE long-press observer (never consumes touches, recognizes alongside everything): marks
        // the context-menu lift window so isInMotion defers content lands during it — a reconfigure
        // landing mid-lift replaced the menu's source view (flickering / vanishing long-press menu).
        holdPress = UILongPressGestureRecognizer(target: self, action: #selector(handleHoldWindow(_:)))
        holdPress.minimumPressDuration = 0.25
        holdPress.cancelsTouchesInView = false
        holdPress.delegate = self
        collectionView.addGestureRecognizer(holdPress)

        // Off-screen sizer, in the hierarchy (0-alpha) so it inherits traits for accurate measurement.
        // CRITICAL: it must NOT reserve safe area. It's a child of this controller, and once the list runs
        // under the nav bar (ThreadView's .ignoresSafeArea(.top)), this controller's view gains a top
        // safe-area inset — a plain UIHostingController would ADD that inset to every measured row height,
        // inflating the gap under every bubble. safeAreaRegions = [] measures the row content ONLY.
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
        // Stored so the pill can drop BELOW the pinned-message bar when one appears (setTopOverlayHeight).
        datePillTop = datePill.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6)
        NSLayoutConstraint.activate([
            datePill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            datePillTop,
            datePill.heightAnchor.constraint(equalToConstant: 30),
            dateLabel.centerYAnchor.constraint(equalTo: datePill.contentView.centerYAnchor),
            dateLabel.leadingAnchor.constraint(equalTo: datePill.contentView.leadingAnchor, constant: 14),
            dateLabel.trailingAnchor.constraint(equalTo: datePill.contentView.trailingAnchor, constant: -14),
        ])

        // Keyboard is handled NATIVELY (safeAreaBar + .always fold; see updateBottomInset) — no keyboard
        // FRAME observers (those double-counted the keyboard). The one exception is the DID-HIDE settle:
        // it fires AFTER the hide animation, so it can't fight the ride, and it's the definitive "end the
        // close pinned" pass. Without it (the observer was dropped in the native-model revert while its
        // handler stayed behind, unregistered) a close could rest with the last messages half under the
        // composer — the build-325 report.
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardDidHide),
                                               name: UIResponder.keyboardDidHideNotification, object: nil)
        // Screenshot recovery: iOS 26's full-page capture scrolls the list; snap back afterwards.
        NotificationCenter.default.addObserver(self, selector: #selector(screenshotTaken),
                                               name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        // Background: only RECORD that the keyboard is gone (no reflow while offscreen — that's what made
        // the chat visibly shift/flash on return). The correction lands on foreground.
        NotificationCenter.default.addObserver(self, selector: #selector(appBackgrounded),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appForegrounded),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)

        buildDataSource()
        #if DEBUG
        setupKBDebug()
        #endif
    }

    func setLoadingOlder(_ loading: Bool) {
        if loading { topSpinner.startAnimating() } else { topSpinner.stopAnimating() }
    }

    private func buildDataSource() {
        reg = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, id in
            let content = self?.coordinator.parent.row(id) ?? AnyView(EmptyView())
            // PIN the row to the FINAL cell width on its very first layout pass. A freshly configured
            // UIHostingConfiguration lays its SwiftUI out before the cell has its final frame, so Text
            // computed line breaks at a transient narrower width and never re-wrapped — the "newest
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
            // Safety net: UIKit cells never report a rendered height (they can't drift on their own),
            // but an OFFSCREEN content change can leave a stale cached height. Verify at dequeue —
            // one cheap text measure — and reconcile if the cache drifted.
            if let cached = self.heights[id], self.collectionView.bounds.width > 0 {
                let h = UIKitBubbleView.sizes(m, width: self.collectionView.bounds.width).cell.height
                if abs(cached - h) > 2 {
                    self.heights[id] = h
                    DispatchQueue.main.async { [weak self] in self?.reconcile() }
                }
            }
        }
        dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) { [weak self] cv, ip, id in
            guard let self else { return UICollectionViewCell() }
            // ROUTER: native UIKit cell when the message is supported (plain 1:1 delivered text), else the
            // SwiftUI hosting cell — so scrolling the common case is a rigid UIKit surface and no feature is lost.
            // Routing reads the FROZEN snapshot dict (same source measure() used), never live view state.
            let isUikit = self.uikitModels[id] != nil
            self.configuredRoutes[id] = isUikit
            if isUikit {
                return cv.dequeueConfiguredReusableCell(using: self.uikitReg, for: ip, item: id)
            }
            return cv.dequeueConfiguredReusableCell(using: self.reg, for: ip, item: id)
        }
        // Install section 0 IMMEDIATELY (empty) so the very first layout pass never sees a section-less
        // data source — an empty new chat previously reached prepare() with zero sections and crashed.
        var initial = NSDiffableDataSourceSnapshot<Int, String>()
        initial.appendSections([0])
        dataSource.apply(initial, animatingDifferences: false)
    }

    // MARK: - Measurement (pre-measured cell size)

    // Exact height of a row for the given width, measured off-screen. Deterministic for every bubble type
    // (heights come from stored dimensions / fixed frames), so this equals the on-screen render.
    private func measure(_ id: String, width: CGFloat) -> CGFloat {
        // Native UIKit bubble: deterministic UIKit measurement (matches the cell's own layout exactly —
        // same sizes() function, same frozen model the cell provider will configure with).
        if let m = uikitModels[id], width > 0 {
            return UIKitBubbleView.sizes(m, width: width).cell.height
        }
        // Measure EXACTLY as the cell renders: the cell wraps its content in `.frame(width: hostWidth)`,
        // so the sizer must apply the SAME explicit width frame — not just a sizeThatFits width proposal.
        // The two constraint mechanisms wrap Text differently in edge cases, and any disagreement made
        // the layout frame (from the sizer) not match the rendered cell → overlap, and a permanent
        // rendered-vs-measured mismatch that fired reconcile forever → flashing/jumping. Framing the
        // sizer identically makes the measured height == the rendered height, exactly like the reference.
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

    // Frame minY per row for an id order — exactly what ExactHeightLayout will produce (y-accumulated
    // heights). Used to build the before/after maps of the scroll-continuity token.
    private func frameMinY(for ids: [String]) -> [String: CGFloat] {
        var out = [String: CGFloat](minimumCapacity: ids.count)
        var y: CGFloat = 0
        for id in ids {
            out[id] = y
            y += heights[id] ?? 44
        }
        return out
    }

    // Late rendered-height report from a cell. During open we trust the synchronous pre-measure; after
    // reveal, a genuine change (a link-preview card fetching Open-Graph data) re-lays-out ONCE with the
    // reader's position preserved — nothing else can change a row height, so this fires rarely.
    private func reportHeight(_ h: CGFloat, for id: String) {
        let hh = ceil(h)
        guard hh > 0 else { return }
        if let old = heights[id] {
            guard abs(old - hh) > 2 else { return }   // ignore sub-pixel noise
        } else {
            heights[id] = hh
            return
        }
        guard didReveal else { return }   // never reconcile during the open — the pre-measure owns it
        // Land-when-safe: a rendered-height signal that arrives mid-scroll/animation is coalesced and
        // handled on settle — reconciling now would invalidate the layout under a live scroll (overlap).
        // Remember WHICH row changed so the settle flush re-measures just it (not every visible cell).
        if isInMotion { needsRefreshOnSettle = true; pendingSettleHeights.insert(id); return }
        // The rendered report is only a SIGNAL that something changed — the SIZER is the single height
        // authority. (Adopting the rendered value here while the same-ids path adopts the sizer value
        // made two authorities fight: any row where they disagreed >2pt reconciled back and forth
        // forever, invalidating the layout mid-scroll = overlapping bubbles.) Re-measure with the sizer;
        // adopt only a real change.
        let w = collectionView.bounds.width
        guard w > 0 else { return }
        let sized = measure(id, width: w)
        guard let cached = heights[id], abs(cached - sized) > 2 else { return }
        heights[id] = sized
        DispatchQueue.main.async { [weak self] in self?.reconcile() }
    }

    // Re-lay-out after a late height change, keeping the viewport stable (the late-media re-layout).
    private func reconcile() {
        guard collectionView.bounds.height > 0 else { return }
        // Never invalidate the layout under a live scroll (this runs a runloop after its trigger, so the
        // user may have STARTED dragging since the motion check) — defer to settle like everything else.
        // needsReconcileOnSettle specifically: the heights cache may ALREADY hold the new value, so the
        // settle signature/height diff can come up empty — without this flag the relayout was dropped and
        // the cache and on-screen frames diverged permanently (overlap + a wrong continuity delta later).
        if isInMotion { needsRefreshOnSettle = true; needsReconcileOnSettle = true; return }
        let wasBottom = computeAtBottom()
        let anchor = captureTopAnchor()
        layout.generation += 1
        layout.invalidateLayout()
        collectionView.layoutIfNeeded()
        if wasBottom { pinBottom() }
        else if let anchor { restore(anchor) }
    }

    // MARK: - Land-when-safe (the land-when-safe gate)

    // The list is "in motion" while the user scrolls or an insert animation runs — content updates must
    // never land during this (they invalidate the layout mid-scroll → overlap/jumps). The system's
    // full-page screenshot capture also counts: it scrolls the list PROGRAMMATICALLY (no drag flags), so
    // without the freeze window every gate would be open while the capture flies through the list —
    // landings mid-capture mixed two layout generations = the overlapping-elements-on-screenshot bug.
    private var isInMotion: Bool {
        collectionView.isDragging || collectionView.isTracking || collectionView.isDecelerating
            || sendAnimating || swipingCell != nil || keyboardAnimating || programmaticScrollAnimating
            || selectionAnimationState == .animating || Date() < captureFreezeUntil
            || Date() < interactionHoldUntil
        // interactionHoldUntil: a finger is (or just was) held down long on a row — the context-menu
        // lift window. A reconfigure landing mid-lift replaced the menu's source view under it
        // (flicker / dismissed menu). Passive hold recognizer below; lands defer to settle like
        // every other motion.
        // keyboardAnimating: the reference's canLandLoad blocks lands during the keyboard animation —
        // a reconfigure landing mid-keyboard fights the animated inset track (visible fight/jump).
        // programmaticScrollAnimating: same rule for OUR animated scrolls (jumps, pin-to-bottom glides).
    }

    // Register a programmatic animated scroll (the reference's collectionViewWillAnimate): lands defer
    // until scrollViewDidEndScrollingAnimation, with a 5s watchdog against cancelled animations.
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
        settleFlush()            // land whatever coalesced during the animation (no-op when nothing pending)
        autoLoadMoreIfNeeded()   // reference: autoLoadMoreIfNecessary on animation complete — a programmatic
                                 // scroll (status-bar tap, jump) can land near the top and still needs paging
    }

    // Flush the coalesced work once the list settles — landing ONLY what actually changed while in
    // motion. The old flush reconfigured EVERY visible cell unconditionally, re-rendering all bubbles
    // the instant scrolling stopped = the flash/flicker at scroll end.
    private func settleFlush() {
        guard !isInMotion else { return }
        // A load that arrived mid-motion lands FIRST, now that the list is at rest (Signal's model:
        // loads land only when scrolling settles, so continuity math always runs against a resting
        // list). Its own completion handles pinning/continuity; the flush work below then proceeds.
        if let pending = pendingIdsApply {
            pendingIdsApply = nil
            apply(rowIds: pending, scrollTarget: nil)
            // The land may have STARTED an animation (send glide) — continuing into the reconfigure
            // work below would land content mid-animation, the exact violation the gate exists to
            // prevent (audit S3). The pending flags survive; the animation's completion re-settles.
            guard !isInMotion else { return }
        }
        // A message arrived at the bottom mid-scroll: pin now (only if the reader is still at the bottom).
        if needsPinOnSettle {
            needsPinOnSettle = false
            if computeAtBottom() { pinBottom() }
        }
        guard needsRefreshOnSettle else { return }
        needsRefreshOnSettle = false
        let visible = collectionView.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) }
        let changed = visible.filter { rowSignatures[$0] != lastRowSigs[$0] }   // content changes (signature diff)
        lastRowSigs = rowSignatures
        let heightIds = pendingSettleHeights                                    // late height reports (link preview)
        pendingSettleHeights.removeAll()
        let target = Array(Set(changed).union(heightIds))
        guard !target.isEmpty else {
            // Nothing to reconfigure, but a deferred reconcile may still be owed (heights already adopted
            // before the defer — the diff can't see it). Run it now or the layout stays diverged.
            if needsReconcileOnSettle { needsReconcileOnSettle = false; reconcile() }
            return
        }
        // An owed reconcile may cover a DIFFERENT row than the refresh target (audit M11: a uikit
        // dequeue adopted a corrected height for row X while a reaction changed row A — refreshing A
        // never relaid-out X, so cached heights and frames diverged permanently). Honor it explicitly.
        let owedReconcile = needsReconcileOnSettle
        needsReconcileOnSettle = false
        refreshVisible(target)
        if owedReconcile { DispatchQueue.main.async { [weak self] in self?.reconcile() } }
    }

    // Split ids into (reconfigure, reload): a row whose RENDER ROUTE flipped since it was last configured
    // (uikit ↔ SwiftUI — e.g. a plain text message gained a reaction) must be RELOADED so the other cell
    // class is dequeued; reconfigureItems reuses the same cell instance, which can't switch renderers.
    private func splitByRouteFlip(_ ids: [String]) -> (reconfigure: [String], reload: [String]) {
        var reconf: [String] = [], reload: [String] = []
        for id in ids {
            let newRoute = uikitModels[id] != nil
            if let old = configuredRoutes[id], old != newRoute { reload.append(id) } else { reconf.append(id) }
        }
        return (reconf, reload)
    }

    // Re-measure + reconfigure the on-screen rows (single sizer authority, >2pt tolerance), then relayout
    // once if any height actually changed — position preserved (pin bottom / top anchor).
    private func refreshVisible(_ subset: [String]? = nil) {
        let width = collectionView.bounds.width
        let visible = collectionView.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) }
        // Reconfigure the requested subset (rows whose content changed) intersected with what's on screen;
        // default (settle flush) = all visible.
        let target = (subset.map { s in s.filter(Set(visible).contains) }) ?? visible
        guard !target.isEmpty else { return }
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
        let split = splitByRouteFlip(target)
        if !split.reconfigure.isEmpty { snapshot.reconfigureItems(split.reconfigure) }
        if !split.reload.isEmpty { snapshot.reloadItems(split.reload) }
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            if heightChanged { self?.reconcile() }
        }
    }

    // MARK: - Apply

    // Signal's land gate applies to LOADS too (their loads build async and land only when scrolling
    // settles): an ids-change landing mid-drag/mid-fling is the worst moment — the continuity
    // compensation runs against a moving list and any miss fights the finger. Deferred lands coalesce
    // (.lastOnly) and flush from settleFlush. Jumps (scrollTarget) are exempt: they TAKE OVER the scroll.
    private var pendingIdsApply: [String]?

    func apply(rowIds ids: [String], scrollTarget: String? = nil) {
        let width = collectionView.bounds.width

        if didInitialScroll, ids != currentIds, scrollTarget == nil, isInMotion {
            pendingIdsApply = ids   // latest wins; flushed on settle
            return
        }
        pendingIdsApply = nil       // an immediate land supersedes anything deferred (ids are the latest)

        guard ids != currentIds else {
            // A jump with no data change (target already in the loaded window): scroll now. scrollToItem
            // is safe mid-deceleration (it takes over the scroll), so this lands even in motion.
            if let target = scrollTarget { scrollTo(id: target) }
            // Selection land (reference exception): the update that carries the checkbox change passes
            // even mid-motion, then opens the animation window that defers everything else.
            if selectionAnimationState == .willAnimate {
                selectionAnimationState = .animating
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    self?.selectionAnimationState = .idle
                    self?.settleFlush()
                }
                let visible = collectionView.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) }
                let changed = visible.filter { rowSignatures[$0] != lastRowSigs[$0] }
                lastRowSigs = rowSignatures
                if !changed.isEmpty { refreshVisible(changed) }
                return
            }
            // Same rows, SwiftUI state changed (reaction added/removed, edit, media loaded, read tick).
            // SIGNAL'S "LAND WHEN SAFE" GATE (CVLoadCoordinator.canLandLoad): NOTHING lands while the list
            // is in motion — no reconfigure, no re-measure, no relayout during dragging/deceleration or the
            // send animation. Landing an update mid-motion positions cells from two layout generations =
            // the overlapping-bubbles-while-scrolling bug. The request is coalesced (.lastOnly — the ids
            // are unchanged, only content) and flushed once the list settles (scroll end / animation end).
            if isInMotion {
                needsRefreshOnSettle = true
                return
            }
            // Reconfigure ONLY the visible rows whose CONTENT signature changed since the last apply —
            // NOT every visible cell on every SwiftUI re-render. ThreadView's body re-runs constantly on
            // presence/typing/read/topVisibleId churn with the SAME row content; reconfiguring all visible
            // cells each time re-rendered every bubble = the flashing. If nothing changed, do nothing.
            let visible = collectionView.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) }
            let changed = visible.filter { rowSignatures[$0] != lastRowSigs[$0] }
            lastRowSigs = rowSignatures
            guard !changed.isEmpty else { return }
            refreshVisible(changed)
            return
        }
        // At-bottom INTENT from the latch, not just live geometry (Signal reads its latched
        // lastKnownDistanceFromBottom): a land during the keyboard's native ride reads mid-flight
        // geometry and answered "not at bottom" — the own-send glide then silently skipped ("sometimes
        // sending doesn't scroll"). The latch is refreshed on every scroll tick, so a reader in history
        // can't false-positive. stickBottom was REMOVED from this union (audit S1): it refreshes only on
        // layout passes, which don't happen during quiet reading — a stale TRUE from minutes ago made a
        // deferred arrival glide the reader to the bottom at settle (the reading-yank, via a new door).
        let wasAtBottom = computeAtBottom() || lastKnownDistanceFromBottom <= 44
        // A bottom-append (send / receive) = the new list STARTS WITH the entire old list.
        let isAppend = !currentIds.isEmpty && ids.count > currentIds.count
            && Array(ids.prefix(currentIds.count)) == currentIds
        let isPrepend = !currentIds.isEmpty && ids.count > currentIds.count
            && Array(ids.suffix(currentIds.count)) == currentIds
        let appendedCount = ids.count - currentIds.count
        let appendedIds = isAppend ? Array(ids.suffix(max(0, appendedCount))) : []

        // SCROLL-CONTINUITY TOKEN (the reference model): before the update, snapshot every current row's
        // frame-minY (frames are exactly y-accumulated heights) plus the visible ids. After the new
        // heights are known, the anchor row's frame DELTA becomes a contentOffset adjustment that UIKit
        // applies ATOMICALLY inside the batch update (targetContentOffset override on the layout) — one
        // mechanism for prepend, top-trim, delete, and any mixed change; no post-completion offset fixing,
        // so no frame ever renders at the stale offset.
        let beforeY = frameMinY(for: currentIds)
        // Anchor candidates come from the TRUE viewport (not the pre-rendered overflow): the continuity
        // adjustment keeps the anchor row visually still, so the anchor must be a row the user can see.
        let visibleBefore = viewportIndexPaths().compactMap { dataSource.itemIdentifier(for: $0) }
        // CONTINUITY INVARIANT (the auto-scroll-while-reading fix): capture the top viewport rows and
        // exactly where they sit on screen. After the land, the first survivor is VERIFIED — if any
        // mechanism moved it (a dropped contentOffsetAdjustment, a trim, anything), the offset is
        // corrected in the same breath. Signal treats reading position as an invariant to enforce,
        // not an adjustment to hope for; several anchors so a trimmed/deleted top row falls through
        // to the next one instead of giving up.
        let continuityAnchors: [(id: String, distanceFromTop: CGFloat)] = visibleBefore.prefix(6).compactMap { id in
            guard let ip = dataSource.indexPath(for: id),
                  let attr = collectionView.layoutAttributesForItem(at: ip) else { return nil }
            return (id, attr.frame.minY - collectionView.contentOffset.y)
        }
        // Radar 28167779: settle any dirty layout against the OLD data BEFORE mutating heights/ids —
        // a dirty layout preparing after the mutation would mix old counts with new heights (garbage
        // before-state under the batch update, corrupting the continuity adjustment).
        collectionView.layoutIfNeeded()

        // Content changes that BATCH with an ids change (a reaction/read-tick arriving in the same repo
        // emission as a new message — constant with Firestore listener batches) must still reconfigure:
        // diffable apply does NOT touch rows present in both snapshots, and the old reseed silently
        // dropped them (stale bubbles until cell recycle). Checked across ALL live cells (including the
        // overdrawn pre-rendered ones) so no configured cell is ever left stale — the viewport-only
        // visibleBefore list above is for the scroll ANCHOR, not for content coverage.
        let liveIds = collectionView.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) }
        let contentChanged = liveIds.filter { ids.contains($0) && rowSignatures[$0] != lastRowSigs[$0] }
        // Reseed AFTER the diff above (audit S2): the reseed used to run at the TOP of this path, so
        // contentChanged compared the new signatures against themselves and was empty by construction —
        // a read-tick/reaction arriving IN THE SAME Firestore batch as a new message (the normal case in
        // an active chat) never repainted. This mechanism was born dead; the diff now sees real changes.
        lastRowSigs = rowSignatures

        measureMissing(ids, width: width)   // exact heights BEFORE the layout prepares (no self-size correction)
        for id in contentChanged { heights[id] = measure(id, width: width) }   // changed content → fresh height
        if ids.count < currentIds.count {   // rows left (trim/delete): drop their cached heights too
            let keep = Set(ids)
            heights = heights.filter { keep.contains($0.key) }
            configuredRoutes = configuredRoutes.filter { keep.contains($0.key) }
        }
        let afterY = frameMinY(for: ids)

        // Selection flip riding an ids change: advance the state machine here too (it was only consumed
        // on the same-ids path — a message arriving in the same render as long-press-select lost the
        // checkbox land AND leaked .willAnimate into a later spurious block window).
        if selectionAnimationState == .willAnimate {
            selectionAnimationState = .animating
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.selectionAnimationState = .idle
                self?.settleFlush()
            }
        }

        // Anchor cascade (the reference order): visible rows first — bottom-most first when the reader is
        // at the bottom, top-most first otherwise — then any row present in both windows.
        var adjustment: CGFloat = 0
        let candidates = (wasAtBottom ? visibleBefore.reversed() : visibleBefore) + ids
        for id in candidates {
            if let b = beforeY[id], let a = afterY[id] { adjustment = a - b; break }
        }

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids, toSection: 0)
        if !contentChanged.isEmpty {   // C2: batched content lands too (route flips re-dequeue)
            let split = splitByRouteFlip(contentChanged)
            if !split.reconfigure.isEmpty { snapshot.reconfigureItems(split.reconfigure) }
            if !split.reload.isEmpty { snapshot.reloadItems(split.reload) }
        }
        currentIds = ids
        layout.generation += 1   // ids/heights changed → next prepare() rebuilds frames (O(1) check otherwise)

        // First content: apply, then land at the exact bottom and reveal. (If width isn't ready yet the
        // list applies invisibly and viewDidLayoutSubviews performs the open once it is.)
        if !didInitialScroll {
            dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
                self?.performFirstOpenIfReady()
            }
            return
        }

        // Send / receive at the bottom = the reference behavior: insert the new row at its FINAL frame
        // (no per-cell entrance transform, no scale, no fade), then an ANIMATED scroll to the bottom so
        // the list glides up to reveal the new bubble. The bubble itself never animates — only the scroll
        // does. Only a single genuine new row animates the scroll; multi-row chunk loads and prepends do not.
        // scrollTarget == nil: a jump riding this load must never be swallowed by the glide branch
        // (audit M9: a reply-quote jump landing with a fresh append glided to the bottom instead, and
        // the one-shot target was already cleared — the jump was gone for good).
        let animate = isAppend && wasAtBottom && appendedCount == 1 && scrollTarget == nil
        if animate {
            sendAnimating = true   // land-when-safe: no content refresh lands during the scroll animation
            dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
                guard let self, self.collectionView.bounds.height > 0 else { self?.sendAnimating = false; return }
                self.collectionView.layoutIfNeeded()   // exact frames for the appended row
                self.pinBottom(animated: true)         // animated scroll to bottom reveals the new bubble
            }
            // If the animated scroll produces no end-callback (list was already exactly at the bottom),
            // clear the gate so coalesced refreshes still flush.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, self.sendAnimating else { return }
                self.sendAnimating = false
                self.settleFlush()
            }
        } else {
            // Land the load with ATOMIC continuity via the layout's targetContentOffset override: UIKit
            // consults it DURING the batch update this apply performs, and answers proposed + delta —
            // the offset shift lands in the same transaction as the content change, so no frame ever
            // renders at the stale offset. This channel existed since the continuity rebuild but was
            // NEVER FED (only zeroed and read — dead code): the only live mechanism was a pre-apply
            // invalidation-context adjustment whose timing Signal's own source calls "delicate… must be
            // done just before performBatchUpdates" — in our diffable setup a SwiftUI layout pass could
            // run between the invalidation and the update and consume/misapply it. That dropped
            // compensation shoved a history reader a full page toward the newest messages on EVERY
            // page-in (the auto-scroll-while-reading bug). finalizeCollectionViewUpdates resets it
            // one-shot; the post-land verification below remains as the last-resort net.
            if adjustment != 0 {
                layout.pendingContentOffsetAdjustment = adjustment
            }
            dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
                guard let self else { return }
                self.layout.pendingContentOffsetAdjustment = 0   // fallback channel — never goes stale
                self.lastStableOffset = self.collectionView.contentOffset.y
                self.lastKnownDistanceFromBottom = self.safeDistanceFromBottom   // refresh after every land (reference)
                if let target = scrollTarget, target != "BOTTOM",
                   let ip = self.dataSource.indexPath(for: target) {
                    // A jump RODE this load (reply/search into older history): land it POSITIONED on the
                    // target — the scroll action is part of the load, nothing can stomp it.
                    self.collectionView.layoutIfNeeded()
                    self.collectionView.scrollToItem(at: ip, at: .centeredVertically, animated: false)
                    self.lastStableOffset = self.collectionView.contentOffset.y
                } else if wasAtBottom && !isPrepend {
                    // Stay pinned — but NEVER yank while the user is actively scrolling (a message arriving
                    // while the finger is down within the bottom zone used to snap the list = the random
                    // mid-scroll jump). Defer the pin to settle; if they've scrolled away by then, no pin.
                    let userScrolling = self.collectionView.isDragging || self.collectionView.isTracking
                        || self.collectionView.isDecelerating
                    if userScrolling { self.needsPinOnSettle = true }
                    else { self.pinBottom() }
                    if let target = scrollTarget, target == "BOTTOM" { self.pinBottom(animated: true) }
                } else if let target = scrollTarget {
                    self.scrollTo(id: target)
                } else if !wasAtBottom, !continuityAnchors.isEmpty, !self.collectionView.isTracking {
                    // ENFORCE the continuity invariant: the reader's top row must sit exactly where it
                    // sat before the land. The atomic contentOffsetAdjustment above is the primary
                    // mechanism; this catches ANY case it missed (dropped adjustment on a prepend →
                    // every page-in of history knocked the reader a full page toward the newest =
                    // "the conversation scrolls back while I read"; a window-trim deleting the anchor;
                    // any future mechanism failure). First surviving anchor wins; correction is exact
                    // and non-animated, in the same runloop as the land. NOT while the finger is down:
                    // the live pan re-derives the offset from its own baseline every tick and would
                    // overwrite the correction — the two would visibly fight. (Deceleration is fine.)
                    self.collectionView.layoutIfNeeded()
                    for a in continuityAnchors {
                        guard let ip = self.dataSource.indexPath(for: a.id),
                              let attr = self.layout.layoutAttributesForItem(at: ip) else { continue }
                        let expected = attr.frame.minY - a.distanceFromTop
                        let clamped = min(max(self.minContentOffsetY, expected), self.maxContentOffsetY)
                        if abs(self.collectionView.contentOffset.y - clamped) > 2 {
                            self.collectionView.setContentOffset(CGPoint(x: 0, y: clamped), animated: false)
                            self.lastStableOffset = clamped
                            self.lastKnownDistanceFromBottom = self.safeDistanceFromBottom
                        }
                        break
                    }
                }
                // Post-land auto-load re-check (reference: autoLoadMoreIfNecessary after the land settles,
                // async so it's never re-entrant inside the land): a short prepend can leave the reader
                // still within the load threshold — continue the chain instead of stalling until the next
                // manual scroll. The 2s throttle paces it.
                DispatchQueue.main.async { [weak self] in self?.autoLoadMoreIfNeeded() }
            }
        }

        // Re-flow the just-appended bubble(s) at their FINAL cell width. UIHostingConfiguration lays a
        // freshly inserted cell's SwiftUI text out at the pre-final width and does NOT re-flow it until a
        // later update — that's the "newest bubble wraps narrow until the next message" bug. Reconfiguring
        // the appended rows one runloop later (after the exact frame is applied) forces the correct wrap
        // now, without waiting for another message. Same-text → same height, so layout isn't disturbed.
        if !appendedIds.isEmpty {
            DispatchQueue.main.async { [weak self] in self?.reflowAppended(appendedIds) }
        }
    }

    private func reflowAppended(_ ids: [String]) {
        // Dispatched one runloop after apply — squarely inside the send glide (audit M10): a reconfigure
        // + heights mutation mid-animation renders new-height content in old frames. Defer to settle;
        // pendingSettleHeights re-measures exactly these rows there.
        if isInMotion {
            ids.forEach { pendingSettleHeights.insert($0) }
            needsRefreshOnSettle = true
            return
        }
        var snap = dataSource.snapshot()
        let present = ids.filter { snap.itemIdentifiers.contains($0) }
        guard !present.isEmpty else { return }
        // Re-measure: a freshly sent image/video/album can land before its exact box height is settled —
        // re-measure at the final width and relayout if it changed, otherwise the next bubble overlaps
        // the media. ONE-SHEET RULE: reconfigure ONLY the rows whose height actually changed. Plain text
        // lands at its final wrap already (the hostWidth pin makes the first wrap the final wrap), so
        // reconfiguring it here just re-rendered the new bubble alone one beat after it appeared — the
        // one visible "independent element" moment left on every send.
        var changed: [String] = []
        if collectionView.bounds.width > 0 {
            for id in present {
                let h = measure(id, width: collectionView.bounds.width)
                if let old = heights[id], abs(old - h) <= 2 { continue }   // same tolerance as everywhere
                heights[id] = h
                changed.append(id)
            }
        }
        guard !changed.isEmpty else { return }
        snap.reconfigureItems(changed)
        dataSource.apply(snap, animatingDifferences: false) { [weak self] in
            self?.reconcile()
        }
    }

    // The first open: measure everything at the real width, place exact frames, land at the initial
    // position, reveal. Everything the user sees is already final — no estimate → measure correction, so
    // no shake. INITIAL POSITION (the reference's initialPosition): the first-unread row near the top
    // when the conversation has unread messages; otherwise the exact bottom.
    private func performFirstOpenIfReady() {
        guard !didInitialScroll,
              collectionView.bounds.width > 0, collectionView.bounds.height > 0,
              !currentIds.isEmpty else { return }
        measureMissing(currentIds, width: collectionView.bounds.width)
        layout.generation += 1
        layout.invalidateLayout()
        collectionView.layoutIfNeeded()
        didInitialScroll = true
        landAtInitialPosition()
        // Re-assert for one runloop as a belt-and-suspenders guard, then release to free scrolling.
        pendingBottomOnOpen = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.landAtInitialPosition()
            self.reveal()
            self.pendingBottomOnOpen = false
        }
    }

    // First-unread near the top (12pt breathing room under the nav bar), clamped to the valid range;
    // no unread target (or target outside the loaded window) → the exact bottom.
    private func landAtInitialPosition() {
        if let target = initialScrollId, let ip = dataSource.indexPath(for: target),
           let attr = layout.layoutAttributesForItem(at: ip) {
            let minY = -collectionView.adjustedContentInset.top
            let y = min(max(minY, attr.frame.minY - collectionView.adjustedContentInset.top - 12), maxContentOffsetY)
            collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
            lastStableOffset = y
            lastKnownDistanceFromBottom = safeDistanceFromBottom
        } else {
            pinBottom()
        }
    }

    private func reveal() {
        guard !didReveal, collectionView.bounds.height > 0 else { return }
        didReveal = true
        collectionView.alpha = 1
        // First frame is on screen — from here on, keep an extra viewport of rows rendered on each side
        // so scrolling always reveals already-rendered bubbles (the connected-sheet feel). The neighbor
        // rows render right now, during the post-open idle, not later mid-scroll.
        layout.overdrawEnabled = true
        DispatchQueue.main.async { [weak self] in self?.layout.invalidateLayout() }
    }

    // Empty on first layout (cold decrypt in flight): reveal WITH content if it lands within ~0.6s (via the
    // normal open path), else reveal the empty state so the composer still shows.
    private func scheduleEmptyReveal() {
        guard !scheduledEmptyReveal else { return }
        scheduledEmptyReveal = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, !self.didReveal else { return }
            self.reveal()
        }
    }

    // MARK: - Scroll continuity (anchor / restore) — the anti-jump idea, our implementation

    // Index paths of cells actually INSIDE the viewport. The layout keeps an extra viewport of cells
    // alive above and below for the connected-sheet pre-render, so indexPathsForVisibleItems includes
    // off-screen rows — anchors and the date pill must never pick one of those.
    private func viewportIndexPaths() -> [IndexPath] {
        collectionView.indexPathsForVisibleItems
            .filter { ip in
                guard let f = collectionView.layoutAttributesForItem(at: ip)?.frame else { return false }
                return f.maxY > collectionView.bounds.minY && f.minY < collectionView.bounds.maxY
            }
            .sorted()
    }

    private func captureTopAnchor() -> (id: String, distanceFromTop: CGFloat)? {
        guard let ip = viewportIndexPaths().first,
              let id = dataSource.itemIdentifier(for: ip),
              let attr = collectionView.layoutAttributesForItem(at: ip) else { return nil }
        return (id, attr.frame.minY - collectionView.contentOffset.y)
    }

    private func restore(_ anchor: (id: String, distanceFromTop: CGFloat)) {
        collectionView.layoutIfNeeded()
        guard let ip = dataSource.indexPath(for: anchor.id),
              let attr = collectionView.layoutAttributesForItem(at: ip) else { return }
        let y = attr.frame.minY - anchor.distanceFromTop
        lastStableOffset = y   // our intentional position → screenshot recovery target
        collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
    }

    // MARK: - Bottom pinning

    // Swipe-back dismisses the keyboard mid-transition; reacting to that keyboard-frame change (shrinking
    // the inset + re-pinning) shifted the conversation during the pop. Freeze all content-offset reflow
    // while the view is disappearing; re-validate when it (re)appears (a cancelled pop returns here).
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isDisappearing = true
        shouldAnimateKeyboardChanges = false   // off-screen keyboard changes apply silently (reference)
    }

    // Rotation / size change (the reference's setScrollActionForSizeTransition): capture the position
    // BEFORE the transition — bottom-pinned (within 50pt) restores the pin; mid-history restores the
    // topmost visible row — and re-assert it after the width-change re-measure has run.
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        guard didInitialScroll else { return }
        let wasBottom = computeAtBottom() || lastKnownDistanceFromBottom < 50
        let anchor = wasBottom ? nil : captureTopAnchor()
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self else { return }
            self.collectionView.layoutIfNeeded()   // the width-change re-measure ran in viewWillLayoutSubviews
            if wasBottom { self.pinBottom() }
            else if let anchor { self.restore(anchor) }
        }
    }

    // Safe-area churn (in-call status banner, dynamic island, rotation) re-derives the inset directly —
    // the reference hooks viewSafeAreaInsetsDidChange into its inset/load pipeline the same way.
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updateBottomInset()
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isDisappearing = false
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isDisappearing = false
        shouldAnimateKeyboardChanges = true            // keyboard tracking animates only once fully on screen (reference)
        collectionView.isPrefetchingEnabled = true     // re-enable after the jank-sensitive first presentation
        updateBottomInset()   // correct the inset if a cancelled pop / return changed the keyboard state
        // Swiping back with the KEYBOARD UP: dismiss the keyboard the moment the pop gesture begins
        // (the reference behavior) — the transition then runs against a settled layout instead of
        // fighting a live keyboard teardown (that fight was the swipe-back chaos: mixed-up bars,
        // misplaced messages mid-transition). Position is preserved: inset updates are blocked while
        // the gesture is active and re-validated only when it resolves.
        if !popGestureHooked, let pop = navigationController?.interactivePopGestureRecognizer {
            pop.addTarget(self, action: #selector(popGestureChanged(_:)))
            popGestureHooked = true
        }
    }

    @objc private func popGestureChanged(_ g: UIGestureRecognizer) {
        switch g.state {
        case .began:
            if keyboardOverlap > 0 { view.window?.endEditing(true) }   // keyboard down FIRST, then the swipe
        case .ended, .cancelled, .failed:
            // Gesture resolved (pop completed or cancelled): re-validate the inset once, silently. On a
            // completed pop the view is disappearing and the guard no-ops; on a cancel this restores truth.
            UIView.performWithoutAnimation { updateBottomInset() }
        default:
            break
        }
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // Remember (before a keyboard/composer resize) whether we were at the bottom, so we can stay there.
        stickBottom = didInitialScroll && !pendingBottomOnOpen && !sendAnimating
            && !programmaticScrollAnimating && computeAtBottom()   // never re-pin under an in-flight jump
        // Keep the registration's width pin fresh: cells configured during this pass read hostWidth.
        if collectionView.bounds.width > 0 { hostWidth = collectionView.bounds.width }
        // Width change (rotation / split view): every measured height is width-dependent — drop + re-measure,
        // and RECONFIGURE the on-screen cells so their hard width pin (.frame(width: hostWidth)) updates.
        let w = collectionView.bounds.width
        if w > 0, measuredWidth > 0, w != measuredWidth {
            heights.removeAll(keepingCapacity: true)
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
        // During a keyboard-synced animation the inset is owned by that UIView.animate — re-asserting it
        // instantly here snapped the content to its final spot while the keyboard was still sliding (the jump).
        if !keyboardAnimating, !geoRiding { updateBottomInset() }   // safe-area valid here; not during the keyboard ride
        // Report the GEOMETRIC nav-bar overlap (view.safeAreaInsets.top — the same reliable source the
        // insets use; the SwiftUI readers reported 0 during transitions, which put the floating date
        // pill in the status bar). Async so the SwiftUI state write never lands mid-layout.
        let top = view.safeAreaInsets.top
        if abs(top - lastReportedTop) > 0.5 {
            lastReportedTop = top
            DispatchQueue.main.async { [weak self] in self?.onTopInset?(top) }
        }
        // Keep the bottom edge-effect OFF (UIKit can reset it) — content stays fully clear/raw under the composer.
        if #available(iOS 26.0, *), !collectionView.bottomEdgeEffect.isHidden {
            collectionView.bottomEdgeEffect.isHidden = true
        }
        if !didInitialScroll {
            if !currentIds.isEmpty { performFirstOpenIfReady() }   // width just became valid → open now
            else { scheduleEmptyReveal() }
            return
        }
        // Never re-pin during: the send animation, the open window, a keyboard animation, the geometric
        // keyboard ride, or while the USER is actively scrolling. geoRiding is the key one for the
        // keyboard-jump-on-open bug: without it, a layout pass mid-ride ran the OLD updateBottomInset with
        // computeAtBottom()==false (offset hadn't followed the grown inset yet) → stickBottom false →
        // clampOffsetIfBeyondContent left the content stranded at the top with the reserved gap below.
        let userScrolling = collectionView.isDragging || collectionView.isTracking || collectionView.isDecelerating
        guard !sendAnimating, !pendingBottomOnOpen, !keyboardAnimating, !programmaticScrollAnimating,
              !geoRiding, !userScrolling else { return }
        if stickBottom {
            // Keyboard/composer resize → stay pinned. When this layout pass runs INSIDE the keyboard's
            // own animation transaction (safe-area growth animates with the keyboard slide), let the pin
            // INHERIT it: the offset then rides the keyboard with Apple's exact curve, in lockstep — the
            // suppressed pin snapped the messages to their final spot in one frame while the keyboard was
            // still sliding (the "jump on keyboard open"). Outside an animation (cold passes), the
            // suppression stays: an animated pin there would drift visibly for no reason.
            if UIView.inheritedAnimationDuration > 0 { pinBottom() }
            else { UIView.performWithoutAnimation { pinBottom() } }
        }
        else { clampOffsetIfBeyondContent() }
    }

    // The two insets UIKit's geometric .always adjustment can't know: the SwiftUI composer bar's height
    // (fed once from a reader ON the bar itself) and the live keyboard overlap (observed directly —
    // our model). Everything else (nav-bar top, home indicator) comes from real geometry via the
    // safe area, so it can never desync. Keeps the newest message pinned when the bottom inset grows.
    var onTopInset: ((CGFloat) -> Void)?      // ThreadView positions the date pill / pinned bar with this
    private var lastReportedTop: CGFloat = -1
    private var composerBarH: CGFloat = 0
    private var keyboardOverlap: CGFloat = 0
    private var keyboardAnimating = false     // a keyboard-synced inset animation is in flight — layout passes
                                              // must NOT re-assert the inset/pin instantly and override it
    // At-bottom truth CAPTURED when the keyboard animation starts. Mid-animation inset updates (the reply
    // banner growing the composer bar) can't trust computeAtBottom() — the offset is mid-flight — so they
    // reuse this instead. Cleared when the keyboard animation completes.
    private var atBottomForKeyboard: Bool?
    // The floating date pill normally sits just under the nav bar (safe-area top + 6). When a pinned-message
    // bar is showing, the list runs UNDER it, so the pill would hide behind the pin — drop it below the bar.
    func setTopOverlayHeight(_ h: CGFloat) {
        guard abs(h - topOverlayHeight) > 0.5, datePillTop != nil else { return }
        topOverlayHeight = h
        datePillTop.constant = 6 + h
    }

    func setComposerBarHeight(_ h: CGFloat) {
        // Reject implausible reports: the composer bar is never under ~40pt — a transient 0/near-0 from
        // the SwiftUI reader mid-transition would zero the bottom inset and drop the last messages
        // straight under the input field.
        guard h > 30, abs(h - composerBarH) > 0.5 else { return }
        composerBarH = h
        updateBottomInset()
    }

    // GEOMETRIC keyboard signal v2 (telemetry root-cause fix). The old signal measured the bar against the
    // SCREEN bottom, which over-counted the keyboard when the list frame ALSO shrinks with the keyboard —
    // the keyboard got subtracted twice and the content rested a keyboard-height too high (a big gap under
    // the last message). Instead, measure how much the composer bar (which rides the keyboard) COVERS the
    // collection view — coverage = list-bottom − bar-top — and derive the keyboard portion from that. If the
    // frame shrinks, the list bottom sits at the keyboard top so coverage collapses to just the composer and
    // the keyboard portion is 0 (the frame-shrink already made the room). If it doesn't shrink, coverage is
    // composer+keyboard and the portion is the full keyboard. Either way, no double count.
    func setComposerTop(_ topY: CGFloat) {
        guard view.window != nil, topY > 0 else { return }
        let cvMaxY = collectionView.convert(collectionView.bounds, to: nil).maxY
        let coverage = max(0, cvMaxY - topY)                 // composer (+ keyboard, if the frame didn't shrink)
        let keyboardPortion = max(0, coverage - composerBarH)  // just the keyboard's contribution
        setKeyboardOverlapInternal(keyboardPortion)
    }

    // Fed the keyboard portion per animation frame while the bar rides the keyboard: each step re-derives the
    // inset and the at-bottom pin instantly, so the content tracks the keyboard in lockstep with the user.
    func setKeyboardOverlapInternal(_ raw: CGFloat) {
        guard abs(raw - keyboardOverlap) > 0.5 else { return }
        geoRiding = true   // the ride owns the inset+offset until the trailing settle; layout passes stand off
        // Session bookkeeping (was previously set from the dead notification path): the keyboard session
        // "starts at the bottom" when the overlap first grows beyond the home area while at the bottom.
        if raw > view.safeAreaInsets.bottom + 10, keyboardOverlap <= view.safeAreaInsets.bottom + 10,
           didInitialScroll, computeAtBottom() {
            keyboardSessionWasAtBottom = true
        }
        keyboardOverlap = raw
        updateBottomInset()
        // Keyboard fully down (bar back at the home area): run the definitive settle the didHide
        // notification used to own — with notifications dead, this is the authoritative end-of-session.
        if raw <= view.safeAreaInsets.bottom + 10, keyboardSessionWasAtBottom {
            keyboardSessionWasAtBottom = false
            let userScrolling = collectionView.isDragging || collectionView.isTracking || collectionView.isDecelerating
            if !userScrolling, !programmaticScrollAnimating, !isDisappearing, didInitialScroll {
                UIView.performWithoutAnimation { pinBottom() }
            }
        }
        // TRAILING SETTLE (telemetry-driven: off=438 vs max=554 at rest — SwiftUI coalesces onChange and
        // can DROP the ride's final geometry values, so the last pin ran against a mid-ride inset and the
        // list rested ~116pt short of the bottom). Re-armed on every update; fires 0.15s after the signal
        // goes quiet and lands the exact end state from the CURRENT bar value — whatever got dropped.
        geoSettleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.geoRiding = false   // ride over — layout passes may re-assert again
            guard !self.isDisappearing, self.didInitialScroll else { return }
            let userScrolling = self.collectionView.isDragging || self.collectionView.isTracking
                || self.collectionView.isDecelerating
            guard !userScrolling, !self.programmaticScrollAnimating else { return }
            self.updateBottomInset()
            if self.keyboardSessionWasAtBottom {
                UIView.performWithoutAnimation { self.pinBottom() }
            }
            #if DEBUG
            self.debugKB("GEO-SETTLE")
            #endif
        }
        geoSettleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        #if DEBUG
        debugKB("GEO")
        #endif
    }

    @objc private func keyboardFrameWillChange(_ note: Notification) {
        guard let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
              let window = view.window else { return }
        let kbInView = view.convert(end, from: window.coordinateSpace)
        keyboardOverlap = max(0, view.bounds.maxY - kbInView.minY)   // 0 when hidden (frame moves offscreen)
        #if DEBUG
        debugKB("WC")
        #endif
        // During an interactive pop the transition owns the geometry: record the overlap (done above) but
        // run NO inset animation — updateBottomInset is blocked during the pop and re-validated on
        // viewDidAppear / gesture end. Animating layout mid-transition was part of the swipe-back chaos.
        if let pop = navigationController?.interactivePopGestureRecognizer {
            switch pop.state {
            case .possible, .failed: break
            default: return
            }
        }
        // Off-screen / not-yet-appeared: apply the inset change SILENTLY (the reference's
        // shouldAnimateKeyboardChanges — animating layout on a view that isn't fully on screen leaves
        // visible artifacts when it appears).
        guard shouldAnimateKeyboardChanges else { updateBottomInset(); return }
        // Capture the at-bottom truth for this animation window. CRITICAL: honor the SESSION flag first —
        // when the geometric bar signal has already started the ride (it fires per frame, often BEFORE
        // this notification), a live computeAtBottom() here reads a mid-flight offset, captures FALSE, and
        // this path then takes the lockstep branch with stale values → the ride ends SHORT of the bottom
        // (the observed ~116pt gap above the composer). The session flag holds the pre-ride truth.
        atBottomForKeyboard = didInitialScroll && (keyboardSessionWasAtBottom || computeAtBottom())
        if keyboardOverlap > 0, atBottomForKeyboard == true { keyboardSessionWasAtBottom = true }
        // Animate the inset/offset change IN LOCKSTEP with the keyboard's OWN animation (duration + curve
        // straight from the notification), the way the reference does — so the messages track the keyboard
        // as it slides instead of snapping to the final position while the keyboard is still moving (the jump).
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0
        guard duration > 0 else {
            updateBottomInset()          // uses the truth captured just above…
            atBottomForKeyboard = nil    // …then clears it — no completion will (duration-0 changes:
            return                       // hardware keyboard / input-mode switches) and a stale TRUE
        }                                // later yanked a history reader to the bottom on a banner grow
        let curveRaw = (note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int)
            ?? Int(UIView.AnimationCurve.easeInOut.rawValue)
        let options = UIView.AnimationOptions(rawValue: UInt(curveRaw) << 16)
        // Guard: while this runs, a layout pass (SwiftUI re-renders the composer bar mid-keyboard) must NOT
        // instantly re-assert the inset/pin in viewDidLayoutSubviews — that instant override was defeating
        // the animated track and leaving the keyboard jump in place.
        keyboardAnimating = true
        UIView.animate(withDuration: duration, delay: 0, options: [options, .beginFromCurrentState]) {
            self.updateBottomInset(animated: true)
            self.collectionView.layoutIfNeeded()
        } completion: { _ in
            self.keyboardAnimating = false
            self.atBottomForKeyboard = nil
            self.settleFlush()   // land anything that coalesced while the keyboard was animating
            #if DEBUG
            self.debugKB("DONE")
            #endif
        }
    }

    // Keyboard fully gone — the AUTHORITATIVE end of the session (fires after the hide animation, the
    // interactive drag-dismiss, or a cancelled animation alike). The animated hide path can be raced
    // mid-flight (drag-dismiss skips offset work per the hands-off rule; a composer re-render mid-
    // animation; a cancelled animation) — when that happened, nothing re-asserted the pin and the last
    // bubbles rested UNDER the input field. This is the definitive settle: zero the overlap, re-derive
    // the inset, and if the keyboard session STARTED at the bottom, end it pinned at the bottom.
    @objc private func keyboardDidHide() {
        keyboardSessionWasAtBottom = false
        atBottomForKeyboard = nil   // session over — never let a stale capture drive later inset updates
        if keyboardOverlap != 0 {
            keyboardOverlap = 0
            updateBottomInset()
        }
        let userScrolling = collectionView.isDragging || collectionView.isTracking || collectionView.isDecelerating
        // Also hands-off while a programmatic jump animates (tapping a reply quote dismisses the keyboard
        // AND starts a jump — the definitive pin was cancelling the jump and wedging its animation flag).
        // Gate on the LIVE at-bottom truth, not the old session flag: the frame-notification path that
        // used to maintain that flag is gone (native model), so the flag was permanently false and this
        // settle never ran — the close could rest with the last bubble half under the composer. If the
        // reader is near the bottom (≤44pt — exactly the "partially hidden" case) end the close pinned;
        // a reader deep in history is untouched.
        if !userScrolling, !programmaticScrollAnimating, !isDisappearing, didInitialScroll, computeAtBottom() {
            UIView.performWithoutAnimation { pinBottom() }
        }
    }

    // Backgrounding force-dismisses the keyboard WITHOUT a frame notification. Record overlap = 0 so the
    // inset isn't left stale (the "no-limit scroll" bug), but do NOT reflow the offset while offscreen —
    // reflowing here is what made the conversation visibly jump/blank on return.
    @objc private func appBackgrounded() { keyboardOverlap = 0 }
    // On return, re-validate the inset once (the keyboard is genuinely down now) with no animation, so
    // the content is correct without a visible shift.
    @objc private func appForegrounded() {
        UIView.performWithoutAnimation { updateBottomInset() }
    }

    // `animated`: when called from inside the keyboard's UIView.animate block, the inset + offset changes
    // are applied WITHOUT performWithoutAnimation, so they ride the keyboard's animation. Every other
    // caller (layout passes, composer resize, foreground) passes false = the original instant behavior.
    //
    // The BODY is the reference's exact updateContentInsets algorithm (its comments quoted where load-bearing):
    //  1. Blocked entirely while an interactive pop gesture is active — checked via the GESTURE state, not
    //     appearance callbacks. "When performing an interactive dismiss, safe area updates rapidly in quick
    //     succession, which causes this method to go haywire, recomputing insets a few times and incorrectly
    //     determining that it needs to scroll as a result." (= our swipe-back-return shift bug.)
    //  2. Stash + restore contentOffset around the inset write — "Changing the contentInset can change the
    //     contentOffset" (UIKit moves it on its own; uncompensated, content moves 'by itself').
    //  3. While the user is dragging (interactive keyboard dismiss), touch NOTHING — "UIKit updates
    //     collection view's scroll position when user drags with the keyboard."
    //  4. At bottom → stay at bottom ("don't do any fancy math"); scrolled away → shift content in LOCKSTEP
    //     with the inset delta, clamped to the content bounds.
    // NATIVE keyboard model (build-292, Apple-native): the bottom inset is STATIC. The composer is an iOS 26
    // `safeAreaBar` (floatingBottomBar) — it grows the collection view's bottom SAFE AREA, and when the
    // keyboard opens it rides the keyboard so the safe area becomes composer+keyboard. With
    // `contentInsetAdjustmentBehavior = .always`, UIKit folds that safe area into adjustedContentInset for
    // us — no manual keyboard math, no notifications, no geometric signal (all of which double-counted the
    // keyboard and stranded the content high). This +12 is just Signal's small gap so the last bubble and
    // its reaction badge clear the composer. Staying pinned across the keyboard resize is done in
    // viewDidLayoutSubviews via `stickBottom` (captured in viewWillLayoutSubviews, BEFORE the resize).
    private func updateBottomInset(animated: Bool = false) {
        guard isViewLoaded, !isDisappearing else { return }
        if let pop = navigationController?.interactivePopGestureRecognizer {
            switch pop.state { case .possible, .failed: break; default: return }
        }
        // Composer bar height + Signal's small gap. The bar height must be added HERE because the list runs
        // full-bleed under the composer, so .always does NOT fold the composer's safe-area inset (it only
        // folds the keyboard, which is un-ignored). Without the bar height the newest message slides under
        // the input. The keyboard clearance still rides on top of this via .always — no double count.
        let newBottom: CGFloat = composerBarH + 12
        guard abs(collectionView.contentInset.bottom - newBottom) > 0.5 else { return }
        UIView.performWithoutAnimation {
            let stash = collectionView.contentOffset
            collectionView.contentInset.bottom = newBottom   // never moves content: stash + restore the offset
            collectionView.setContentOffset(stash, animated: false)
        }
    }

    private func pinBottom(animated: Bool = false) {
        guard collectionView.bounds.height > 0 else { return }
        let target = collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom
        let y = max(-collectionView.adjustedContentInset.top, target)
        lastStableOffset = y   // our intentional position → screenshot recovery target
        if animated {
            // ALREADY at the target: an animated no-op scroll never fires scrollViewDidEndScrollingAnimation,
            // which would wedge programmaticScrollAnimating for the full 5s watchdog and freeze every
            // content land in that window (fired on essentially every keyboard-open at the bottom).
            guard abs(collectionView.contentOffset.y - y) > 0.5 else { return }
            scrollingAnimationDidStart()   // lands defer until the glide completes (reference)
            collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: true)
        } else if abs(collectionView.contentOffset.y - y) > 0.5 {
            collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        }
        lastKnownDistanceFromBottom = 0   // pinned = at the bottom; keep the continuity scalar fresh (reference)
    }

    // Never leave the view scrolled PAST the content: clamp the offset back onto the real content.
    private func clampOffsetIfBeyondContent() {
        guard collectionView.bounds.height > 0 else { return }
        let maxY = max(-collectionView.adjustedContentInset.top,
                       collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
        if collectionView.contentOffset.y > maxY + 0.5 {
            collectionView.setContentOffset(CGPoint(x: 0, y: maxY), animated: false)
        }
    }

    // MARK: - Jump to a message (reply / search)

    // Center-if-not-entirely-on-screen (the search/jump alignment): when the target row is already
    // fully visible, don't move at all — repeated next/prev taps between two on-screen results then feel
    // stable instead of re-centering the list on every tap.
    func scrollTo(id: String) {
        // Sentinel: the scroll-to-latest button + own-send-while-scrolled-up route here — a smooth
        // animated glide to the exact bottom (the old ScrollViewProxy path was a no-op on this list).
        if id == "BOTTOM" { pinBottom(animated: true); return }
        guard let ip = dataSource.indexPath(for: id) else { return }
        guard let attr = collectionView.layoutAttributesForItem(at: ip) else { return }
        let visible = CGRect(x: 0,
                             y: collectionView.contentOffset.y + collectionView.adjustedContentInset.top,
                             width: collectionView.bounds.width,
                             height: collectionView.bounds.height
                                - collectionView.adjustedContentInset.top
                                - collectionView.adjustedContentInset.bottom)
        if visible.contains(attr.frame) { return }   // already entirely on screen → no scroll
        // Compute the clamped centered target OURSELVES (frames are exact): scrollToItem clamps
        // internally, and a clamp that lands on the current offset animates nothing — no end callback,
        // 5s wedge of the programmatic-scroll flag freezing every land (audit S4).
        let centered = attr.frame.midY - collectionView.bounds.height / 2
        let targetY = min(max(minContentOffsetY, centered), maxContentOffsetY)
        guard abs(targetY - collectionView.contentOffset.y) > 0.5 else { return }
        scrollingAnimationDidStart()   // lands defer until the jump animation completes (reference)
        collectionView.setContentOffset(CGPoint(x: 0, y: targetY), animated: true)
    }

    // MARK: - Swipe to reply (single pan; the reference model)

    // Begin ONLY for a horizontal-left drag over a reply-eligible row, so vertical scrolling is untouched
    // and a right-swipe (interactive pop) is untouched. This is what makes one pan safe where N SwiftUI
    // drags were not: the scroll gesture keeps every vertical drag.
    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === doubleTapGesture {
            let loc = g.location(in: collectionView)
            guard let ip = collectionView.indexPathForItem(at: loc),
                  let id = dataSource.itemIdentifier(for: ip), uikitModels[id] != nil else { return false }
            // The BUBBLE only, not the full-width row (audit: double-tapping the empty area beside a
            // uikit bubble hearted it; SwiftUI rows react on the bubble content only).
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
        return true
    }

    // Coexist with the collection view's own scroll pan (the list scrolls vertically, we translate a cell
    // horizontally — different axes, no conflict). shouldBegin already gates us to horizontal-left.
    // holdPress is a PASSIVE observer — it must never block the SwiftUI context-menu press or anything else.
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g === swipePan || g === holdPress
    }

    @objc private func handleHoldWindow(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            interactionHoldUntil = .distantFuture
        case .ended, .cancelled, .failed:
            // Keep the gate up briefly past the lift-off: the menu presentation is still settling.
            interactionHoldUntil = Date().addingTimeInterval(1.0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) { [weak self] in self?.settleFlush() }
        default: break
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
            // LOCK vertical scrolling for the duration of the reply-swipe (user request): the swipe owns the
            // touch, the conversation must not scroll up/down at the same time. Disabling the collection
            // view's own scroll cancels any in-flight vertical pan; our swipePan is a separate recognizer so
            // it keeps tracking. Restored on end/cancel.
            collectionView.isScrollEnabled = false
            addSwipeArrow(for: cell)
        case .changed:
            guard let cell = swipingCell else { return }
            if VoiceScrubState.active { resetSwipe(animated: false); return }   // waveform took over mid-drag
            // 1:1 with the finger to the threshold, then RUBBER-BAND (drag past -70 moves at 1/4 speed,
            // capped) — attached-to-the-finger up close, physical resistance past the commit point.
            let t = min(0, g.translation(in: collectionView).x)
            let tx = t > -70 ? t : -70 + max(-30, (t + 70) * 0.25)
            // Transform the CELL itself — the proven path (the send animation moved cells this way).
            // Transforming the hosted contentView had its transform fought by the SwiftUI hosting layout,
            // which is why the bubble barely moved ("stays fixed, no feedback").
            cell.transform = CGAffineTransform(translationX: tx, y: 0)
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
            collectionView.isScrollEnabled = true   // swipe over → vertical scrolling allowed again
            let fire = swipeTriggered ? swipingId : nil
            resetSwipe(animated: true, velocity: g.velocity(in: collectionView).x)
            if let id = fire { onSwipeReply(id) }
            settleFlush()   // land anything that was deferred while the swipe owned the cell
        default:
            break
        }
    }

    // The reply arrow sits in the space the bubble vacates — added to the COLLECTION VIEW at the cell's
    // frame (the cell itself translates, the arrow must not move with it).
    private func addSwipeArrow(for cell: UICollectionViewCell) {
        swipeArrow?.removeFromSuperview()
        let img = UIImageView(image: UIImage(systemName: "arrowshape.turn.up.left.fill"))
        img.tintColor = .secondaryLabel
        img.contentMode = .scaleAspectFit
        img.alpha = 0
        img.frame = CGRect(x: cell.frame.maxX - 36, y: cell.frame.midY - 9, width: 20, height: 18)
        collectionView.addSubview(img)
        swipeArrow = img
    }

    // Direct repaint of visible uikit cells from the frozen model dict (geometry-neutral changes only —
    // the cell itself gates on that). Runs on every SwiftUI update; a no-op when nothing changed.
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

    // MARK: - Context menu (UIKit-routed rows — identical native lift/menu as the SwiftUI .contextMenu)

    // MODERN API (iOS 16+): UIKit calls the PLURAL method on current SDKs — implementing only the
    // deprecated single-item variant meant uikit-routed rows never showed a menu at all (the "long-press
    // on my message not working" report; SwiftUI rows kept working via their own .contextMenu).
    func collectionView(_ collectionView: UICollectionView,
                        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard let ip = indexPaths.first else { return nil }
        return contextMenuConfig(at: ip)
    }

    // Deprecated single-item variant kept as a belt-and-braces fallback for any path that still asks it.
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

    // Lift ONLY the bubble (rounded to its exact corner path) — the default would lift the whole
    // full-width transparent cell.
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

    // The swiped cell scrolled off and is being RECYCLED for another row: kill the swipe immediately —
    // keeping the transform would slide the WRONG row left when the cell is reused.
    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        guard cell === swipingCell else { return }
        resetSwipe(animated: false)
        swipePan.isEnabled = false; swipePan.isEnabled = true   // cancel the in-flight pan
    }

    private func resetSwipe(animated: Bool, velocity: CGFloat = 0) {
        let cell = swipingCell
        let arrow = swipeArrow
        swipingCell = nil; swipingId = nil; swipeArrow = nil; swipeTriggered = false
        let reset = { cell?.transform = .identity; arrow?.alpha = 0 }
        if animated {
            // Seed the spring with the release velocity so a fast flick snaps back livelier than a slow let-go.
            let distance = abs(cell?.transform.tx ?? 0)
            let v = distance > 0 ? min(3, abs(velocity) / max(1, distance)) : 0.4
            UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: v,
                           options: [.allowUserInteraction], animations: reset) { _ in arrow?.removeFromSuperview() }
        } else {
            reset(); arrow?.removeFromSuperview()
        }
    }

    // MARK: - Scroll observation

    // The reference at-rest math: "is the scroll view scrolled down as far as it can, at rest" — measured
    // against the at-rest MAXIMUM offset, not against the content's bottom edge (their comment: the edge
    // check is wrong when the content doesn't fill the viewport, e.g. a short chat with the keyboard down).
    private var minContentOffsetY: CGFloat { -collectionView.adjustedContentInset.top }
    private var maxContentOffsetY: CGFloat {
        max(minContentOffsetY,
            collectionView.contentSize.height + collectionView.adjustedContentInset.bottom - collectionView.bounds.height)
    }
    private var safeDistanceFromBottom: CGFloat { maxContentOffsetY - collectionView.contentOffset.y }

    private func computeAtBottom() -> Bool {
        guard collectionView.contentSize.height > 0 else { return true }
        return safeDistanceFromBottom <= 44
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        sendAnimating = false
        scrollingAnimationDidComplete()   // also runs settleFlush
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settleFlush() }   // finger up, no fling → settled now
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settleFlush() }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // During the screenshot-capture freeze the SYSTEM owns the offset: write no SwiftUI state (the
        // isAtBottom flips would re-run the tree and land reconfigures mid-capture = overlap), fire nothing.
        if Date() < captureFreezeUntil { return }
        // Constantly track the distance from the at-rest bottom (the reference continuity scalar).
        if didReveal { lastKnownDistanceFromBottom = safeDistanceFromBottom }
        let userDriven = scrollView.isDragging || scrollView.isTracking || scrollView.isDecelerating
        // Remember the last USER-intended offset (also kept fresh by pinBottom/restore). The iOS 26
        // full-page screenshot capture scrolls the list programmatically — this is what we snap back to.
        if userDriven {
            lastStableOffset = scrollView.contentOffset.y
            userScrolledSinceTimer = true
            // Scrolled away from the bottom mid-keyboard-session → the definitive settle at keyboardDidHide
            // must NOT yank the reader back down (they left the bottom deliberately, keyboard up).
            if keyboardSessionWasAtBottom, safeDistanceFromBottom > 44 { keyboardSessionWasAtBottom = false }
            // stickBottom is otherwise only recomputed on LAYOUT passes, which don't run during quiet
            // reading — invalidate it the moment the user scrolls away so no stale TRUE survives (S1).
            if stickBottom, safeDistanceFromBottom > 44 { stickBottom = false }
        }
        // Heavier per-scroll work (pagination trigger, the isAtBottom SwiftUI write) is DEBOUNCED onto a
        // 0.1s one-shot timer on the COMMON runloop mode (fires during scrolling) — the reference model:
        // scrollViewDidScroll itself stays cheap and never mutates state that re-enters layout inline.
        scheduleScrollWorkTimer()
        // Topmost visible row → the floating date pill (UIKit, updated in place — NO SwiftUI write).
        // Only on real user scrolls, so the programmatic open/pin never flashes the pill.
        if userDriven {
            let top = viewportIndexPaths().first.flatMap { dataSource.itemIdentifier(for: $0) }
            updateDatePill(topId: top)
        }
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
        // isAtBottom SwiftUI write, coalesced to ≤10/s: the composer's jump-button reacts promptly but the
        // conversation tree no longer re-runs on every scroll tick near the bottom threshold.
        let atBottom = computeAtBottom()
        if coordinator.parent.isAtBottom != atBottom { coordinator.parent.isAtBottom = atBottom }
        // Pagination — USER scrolls only (a programmatic/system scroll must never page history in).
        if userScrolledSinceTimer { autoLoadMoreIfNeeded() }
        userScrolledSinceTimer = false
    }

    // The reference's auto-load placement: fire when within THREE screen-heights of the top (pagination
    // feels seamless — history is there before the user ever sees the edge), throttled to one load per 2s
    // (their didLoadOlderRecently window). No zone-entry debounce: a short prepend leaves the reader still
    // inside the zone, and the time throttle alone lets the chain continue until content outruns the
    // threshold (the old once-per-entry rule stalled exactly there). The repo's own loading flag prevents
    // concurrent loads.
    private func autoLoadMoreIfNeeded() {
        guard didReveal, Date() >= captureFreezeUntil else { return }
        let threshold = max(72, collectionView.bounds.height * 3)
        guard collectionView.contentOffset.y <= threshold,
              Date().timeIntervalSince(lastLoadOlderAt) > 2 else { return }
        lastLoadOlderAt = Date()
        coordinator.parent.onReachedTop()
    }

    // Status-bar tap: the default scroll-to-top animation swings PAST the top then bounces back — that
    // overshoot can land a load-older prepend mid-animation, and the animation then overwrites the
    // adjusted offset (continuity break + possible load loop — the reference documents exactly this).
    // A plain animated setContentOffset has no overshoot.
    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        // Already at the top → an animated no-op scroll never fires its end callback, wedging the
        // programmatic-scroll flag for the full 5s watchdog and freezing every land (audit S4).
        guard abs(collectionView.contentOffset.y - minContentOffsetY) > 0.5 else { return false }
        scrollingAnimationDidStart()
        collectionView.setContentOffset(CGPoint(x: 0, y: minContentOffsetY), animated: true)
        return false
    }

    // Show the day of the topmost visible row while scrolling; fade ~1.2s after it stops. Runs entirely in
    // UIKit — no binding write, so scrolling never re-runs the SwiftUI conversation tree.
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
    // notification to capture every page. Two defenses:
    //  1. FREEZE all landings for the capture window (captureFreezeUntil folds into isInMotion) and mute
    //     scrollViewDidScroll side-effects — landings mid-capture mixed layout generations = overlap.
    //  2. Snap back to the last stable offset AFTER the capture has finished (the old immediate snap-back
    //     ran BEFORE the capture scroll and restored nothing).
    @objc func screenshotTaken() {
        guard didInitialScroll, !isDisappearing,
              !collectionView.isDragging, !collectionView.isTracking,
              !collectionView.isDecelerating else { return }   // never rewind a legitimate fling to a stale offset
        captureFreezeUntil = Date().addingTimeInterval(1.5)
        let snapBack: () -> Void = { [weak self] in
            guard let self else { return }
            let target = self.lastStableOffset
            if abs(self.collectionView.contentOffset.y - target) > 4 {
                let maxY = max(-self.collectionView.adjustedContentInset.top,
                               self.collectionView.contentSize.height - self.collectionView.bounds.height
                                   + self.collectionView.adjustedContentInset.bottom)
                let y = min(max(-self.collectionView.adjustedContentInset.top, target), maxY)
                self.collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
            }
        }
        // Snap once right away (plain screenshot: no capture scroll happens) and once after the freeze
        // (full-page capture: the system has finished flying through the list by then), then flush
        // whatever coalesced during the freeze.
        DispatchQueue.main.async(execute: snapBack)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.55) { [weak self] in
            snapBack()
            self?.settleFlush()
        }
    }
}

// Pre-measured layout: cell heights are known before layout (never self-sized), so every
// frame is exact on the first pass. `heightForItem` reads the controller's measured-height cache; prepare
// stacks the rows into exact frames and an exact content height. This is the whole anti-shake mechanism —
// with no estimate → measure step, there is nothing to correct and nothing to hide.
final class ExactHeightLayout: UICollectionViewLayout {
    var heightForItem: ((Int) -> CGFloat)?
    // A render-state id: an O(1) identity check instead of re-stacking frames on every prepare().
    // The controller bumps this whenever ids/heights change; unchanged generation + width + count →
    // the cached frames are reused untouched (prepare() is called constantly during scrolling).
    var generation = 0

    private var frames: [CGRect] = []
    private var contentHeight: CGFloat = 0
    private(set) var layoutWidth: CGFloat = 0
    private var builtGeneration = -1
    private var builtCount = -1

    override func prepare() {
        super.prepare()
        guard let cv = collectionView else { return }
        // CRASH GUARD (build 283 SIGABRT): before the FIRST snapshot lands, the diffable data source
        // reports ZERO sections — asking numberOfItems(inSection: 0) then trips UIKit's internal
        // assertion and aborts. An empty brand-new chat hit exactly this (its first apply() returned
        // through the same-ids guard without ever installing a section).
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

    // ONE-CONNECTED-SHEET (the Telegram model): keep a full viewport of rows rendered ABOVE and BELOW
    // the visible rect, so every bubble is already fully rendered before it scrolls on screen. Without
    // this, each hosted bubble builds its SwiftUI at the moment it enters the viewport — bubbles pop in
    // one at a time behind the moving sheet, which reads as independent elements instead of one surface.
    // Gated until after the first reveal so the carefully-tuned instant open never pays the extra cells.
    var overdrawEnabled = false

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        let overdraw = overdrawEnabled ? (collectionView?.bounds.height ?? 0) : 0
        let expanded = rect.insetBy(dx: 0, dy: -overdraw)
        var result: [UICollectionViewLayoutAttributes] = []
        for i in frames.indices where frames[i].intersects(expanded) {
            let a = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: i, section: 0))
            a.frame = frames[i]
            result.append(a)
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.item < frames.count else { return nil }
        let a = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        a.frame = frames[indexPath.item]
        return a
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != layoutWidth
    }

    // ===== Scroll continuity (the reference model) =====
    // When a load lands, the controller computes the anchor row's frame delta (before vs after the
    // update) and parks it here. UIKit consults targetContentOffset(forProposedContentOffset:) DURING
    // the batch update — answering with proposed + delta shifts the offset ATOMICALLY with the layout
    // change, so no frame ever renders at the stale offset. (The old model corrected the offset in the
    // apply COMPLETION — one frame late, which is a visible jump on every prepend/trim/delete.)
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
