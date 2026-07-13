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
    var onReachedTop: () -> Void               // near-top -> page older
    var loadingOlder: Bool = false             // show the top spinner while older messages page in
    var composerBarHeight: CGFloat = 0         // the floating composer bar's height (the ONLY SwiftUI-fed inset)
    var onTopInset: (CGFloat) -> Void = { _ in }   // reports the GEOMETRIC nav-bar overlap (UIKit safe area — reliable)
    @Binding var isAtBottom: Bool
    @Binding var scrollTarget: String?         // set to a rowId to scroll it into view (reply/search jump), then cleared
    @Binding var topVisibleId: String?         // rowId of the topmost visible row → drives the floating date header

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
        vc.setComposerBarHeight(composerBarHeight)
        vc.onTopInset = onTopInset
        vc.setLoadingOlder(loadingOlder)
        vc.rowSignatures = rowSignatures
        vc.apply(rowIds: rowIds)
        if let target = scrollTarget {
            vc.scrollTo(id: target)
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

final class MessageListController: UIViewController, UICollectionViewDelegate {
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
    var rowSignatures: [String: String] = [:] // set before each apply — per-row content signature
    private var lastRowSigs: [String: String] = [:]  // signatures at the last apply → diff to find changed rows
    private var inTopZone = false             // debounces the load-older callback to one fire per entry
    private var lastStableOffset: CGFloat = 0 // last user/our-pin offset → screenshot-capture recovery

    override func viewDidLoad() {
        super.viewDidLoad()
        layout = ExactHeightLayout()
        layout.heightForItem = { [weak self] index in
            guard let self, index < self.currentIds.count else { return 44 }
            return self.heights[self.currentIds[index]] ?? 44
        }
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
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
        // TOP edge-effect: iOS 26 native default (soft fade under the system nav bar — correct there).
        // BOTTOM edge-effect: OFF — its progressive blur spans a TALL gradient region tied to the big
        // bottom inset, bleeding way up into the conversation (blurred bubbles far above the composer).
        // The composer's frost is the bar's own bounded native material instead (ThreadView).
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

        // Keyboard handled HERE, UIKit-native (the view's frame never changes — ThreadView ignores the
        // keyboard safe area): observe the real keyboard frame and fold its overlap into the bottom inset.
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardFrameWillChange(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        // Screenshot recovery: iOS 26's full-page capture scrolls the list; snap back afterwards.
        NotificationCenter.default.addObserver(self, selector: #selector(screenshotTaken),
                                               name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        // STALE-KEYBOARD-INSET guards: leaving the chat/app with the keyboard up can tear the keyboard
        // down WITHOUT a frame-change notification reaching us — keyboardOverlap then stays ~340pt, the
        // bottom inset stays inflated, and the user can scroll the conversation way past its end and it
        // RESTS there ("no limit scroll", messages stuck at the top). Reset the overlap explicitly.
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardDidHide),
                                               name: UIResponder.keyboardDidHideNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardDidHide),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)

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
        dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) { [weak self] cv, ip, id in
            cv.dequeueConfiguredReusableCell(using: self!.reg, for: ip, item: id)
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
        if isInMotion { needsRefreshOnSettle = true; return }
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
    // never land during this (they invalidate the layout mid-scroll → overlap/jumps).
    private var isInMotion: Bool {
        collectionView.isDragging || collectionView.isTracking || collectionView.isDecelerating || sendAnimating
    }

    // Flush the coalesced refresh once the list settles.
    private func settleFlush() {
        guard needsRefreshOnSettle, !isInMotion else { return }
        needsRefreshOnSettle = false
        refreshVisible()
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
        snapshot.reconfigureItems(target)
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            if heightChanged { self?.reconcile() }
        }
    }

    // MARK: - Apply

    func apply(rowIds ids: [String]) {
        let width = collectionView.bounds.width

        guard ids != currentIds else {
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
        lastRowSigs = rowSignatures   // ids changed (append/prepend/trim): reseed signatures for the new set

        let wasAtBottom = computeAtBottom()
        // A top-prepend (load older) = the new list ENDS WITH the entire old list. Anchor an on-screen row
        // and restore its position after the insert, so nothing lurches.
        let isPrepend = !currentIds.isEmpty && ids.count > currentIds.count
            && Array(ids.suffix(currentIds.count)) == currentIds
        // A bottom-append (send / receive) = the new list STARTS WITH the entire old list.
        let isAppend = !currentIds.isEmpty && ids.count > currentIds.count
            && Array(ids.prefix(currentIds.count)) == currentIds
        // A top-TRIM (the repo LRU-dropped the oldest window overflow) = the new list is a SUFFIX of the
        // old. Anchor a visible row and restore it so the trim is invisible to the reader.
        let isTopTrim = !currentIds.isEmpty && ids.count < currentIds.count
            && Array(currentIds.suffix(ids.count)) == ids
        let trimAnchor: (id: String, distanceFromTop: CGFloat)? = isTopTrim ? captureTopAnchor() : nil
        let appendedCount = ids.count - currentIds.count
        let appendedIds = isAppend ? Array(ids.suffix(max(0, appendedCount))) : []
        // Prepend (load older): capture the content height + offset so we can keep the visible content
        // EXACTLY stable — after the older messages lay out, add their total height to the offset. The
        // reader never jumps and is never auto-scrolled; the new older messages simply sit above.
        let prepend: (oldHeight: CGFloat, oldOffset: CGFloat)? = isPrepend
            ? (collectionView.contentSize.height, collectionView.contentOffset.y) : nil

        measureMissing(ids, width: width)   // exact heights BEFORE the layout prepares (no self-size correction)
        if ids.count < currentIds.count {   // rows left (trim/delete): drop their cached heights too
            let keep = Set(ids)
            heights = heights.filter { keep.contains($0.key) }
        }

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids, toSection: 0)
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

        // Send / receive at the bottom ANIMATES (the recipe: animated batch insert + animated scroll
        // to bottom). Only a single genuine new row animates; multi-row chunk loads and prepends do not.
        let animate = isAppend && wasAtBottom && appendedCount == 1
        if animate {
            // Premium send: insert the new cell instantly, land at the bottom so it's in
            // view just above the composer, then the BUBBLE flies up out of the composer — it starts pushed
            // down near the input field (slightly smaller) and springs to its resting position. Natural
            // spring physics, no fade/pop.
            sendAnimating = true
            dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
                guard let self, self.collectionView.bounds.height > 0 else { self?.sendAnimating = false; return }
                self.collectionView.layoutIfNeeded()   // exact frames for the appended row
                let target = self.collectionView.contentSize.height - self.collectionView.bounds.height + self.collectionView.adjustedContentInset.bottom
                let y = max(-self.collectionView.adjustedContentInset.top, target)
                self.collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
                self.collectionView.layoutIfNeeded()
                let ip = IndexPath(item: self.currentIds.count - 1, section: 0)
                guard let cell = self.collectionView.cellForItem(at: ip) else { self.sendAnimating = false; return }
                // Start it down at the composer (its own height + the composer inset below), a touch smaller.
                let startDy = cell.bounds.height + self.collectionView.adjustedContentInset.bottom
                cell.transform = CGAffineTransform(translationX: 0, y: startDy).scaledBy(x: 0.9, y: 0.9)
                UIView.animate(withDuration: 0.55, delay: 0, usingSpringWithDamping: 0.72, initialSpringVelocity: 0.6,
                               options: [.allowUserInteraction]) {
                    cell.transform = .identity
                } completion: { _ in self.sendAnimating = false; self.settleFlush() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.sendAnimating = false
                self?.settleFlush()
            }
        } else {
            dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
                guard let self else { return }
                if let p = prepend {
                    // Keep the reader's EXACT position: shift the offset down by the height the prepended
                    // older messages added, so nothing on screen moves. No jump, no auto-scroll-down.
                    self.collectionView.layoutIfNeeded()
                    let delta = self.collectionView.contentSize.height - p.oldHeight
                    self.collectionView.setContentOffset(CGPoint(x: 0, y: p.oldOffset + delta), animated: false)
                } else if let anchor = trimAnchor {
                    self.restore(anchor)                             // top-trim: keep the reader's place
                } else if wasAtBottom && !isPrepend {
                    self.pinBottom()                                 // was at bottom: stay pinned
                }
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
        var snap = dataSource.snapshot()
        let present = ids.filter { snap.itemIdentifiers.contains($0) }
        guard !present.isEmpty else { return }
        // Re-measure too (not just re-flow text): a freshly sent image/video/album can land before its
        // exact box height is settled, so re-measure at the final width and relayout if it changed —
        // otherwise the next bubble overlaps the media.
        var heightChanged = false
        if collectionView.bounds.width > 0 {
            for id in present {
                let h = measure(id, width: collectionView.bounds.width)
                if let old = heights[id], abs(old - h) <= 2 { continue }   // same tolerance as everywhere
                heights[id] = h
                heightChanged = true
            }
        }
        snap.reconfigureItems(present)
        dataSource.apply(snap, animatingDifferences: false) { [weak self] in
            if heightChanged { self?.reconcile() }
        }
    }

    // The first open: measure everything at the real width, place exact frames, land at the bottom, reveal.
    // Everything the user sees is already final — no estimate → measure correction, so no shake.
    private func performFirstOpenIfReady() {
        guard !didInitialScroll,
              collectionView.bounds.width > 0, collectionView.bounds.height > 0,
              !currentIds.isEmpty else { return }
        measureMissing(currentIds, width: collectionView.bounds.width)
        layout.generation += 1
        layout.invalidateLayout()
        collectionView.layoutIfNeeded()
        didInitialScroll = true
        pinBottom()
        // Keep pinned for one runloop as a belt-and-suspenders guard, then release to free scrolling.
        pendingBottomOnOpen = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pinBottom()
            self.reveal()
            self.pendingBottomOnOpen = false
        }
    }

    private func reveal() {
        guard !didReveal, collectionView.bounds.height > 0 else { return }
        didReveal = true
        collectionView.alpha = 1
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

    private func captureTopAnchor() -> (id: String, distanceFromTop: CGFloat)? {
        guard let ip = collectionView.indexPathsForVisibleItems.min(),
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

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // Remember (before a keyboard/composer resize) whether we were at the bottom, so we can stay there.
        stickBottom = didInitialScroll && !pendingBottomOnOpen && !sendAnimating && computeAtBottom()
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
        updateBottomInset()   // safe-area values are valid here — keeps the bottom inset exact
        // Report the GEOMETRIC nav-bar overlap (view.safeAreaInsets.top — the same reliable source the
        // insets use; the SwiftUI readers reported 0 during transitions, which put the floating date
        // pill in the status bar). Async so the SwiftUI state write never lands mid-layout.
        let top = view.safeAreaInsets.top
        if abs(top - lastReportedTop) > 0.5 {
            lastReportedTop = top
            DispatchQueue.main.async { [weak self] in self?.onTopInset?(top) }
        }
        // Keep the bottom edge-effect off (UIKit can reset it) — its tall gradient bled into the chat.
        if #available(iOS 26.0, *), !collectionView.bottomEdgeEffect.isHidden {
            collectionView.bottomEdgeEffect.isHidden = true
        }
        if !didInitialScroll {
            if !currentIds.isEmpty { performFirstOpenIfReady() }   // width just became valid → open now
            else { scheduleEmptyReveal() }
            return
        }
        guard !sendAnimating, !pendingBottomOnOpen else { return }
        if stickBottom { UIView.performWithoutAnimation { pinBottom() } }   // keyboard/composer resize → stay pinned
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
    func setComposerBarHeight(_ h: CGFloat) {
        guard abs(h - composerBarH) > 0.5 else { return }
        composerBarH = h
        updateBottomInset()
    }

    @objc private func keyboardFrameWillChange(_ note: Notification) {
        guard let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
              let window = view.window else { return }
        let kbInView = view.convert(end, from: window.coordinateSpace)
        keyboardOverlap = max(0, view.bounds.maxY - kbInView.minY)   // 0 when hidden (frame moves offscreen)
        updateBottomInset()
    }

    // Keyboard fully gone (or the app backgrounded, which force-dismisses it): the overlap is 0 no
    // matter what the last frame notification said.
    @objc private func keyboardDidHide() {
        guard keyboardOverlap != 0 else { return }
        keyboardOverlap = 0
        updateBottomInset()
    }

    private func updateBottomInset() {
        guard isViewLoaded else { return }
        // .always already adds the geometric home-indicator overlap; the keyboard replaces it when up.
        let keyboardExtra = max(0, keyboardOverlap - view.safeAreaInsets.bottom)
        let newBottom = composerBarH + keyboardExtra + 12   // +12: last bubble + reaction badge clear the bar
        let old = collectionView.contentInset.bottom
        guard abs(old - newBottom) > 0.5 else { return }
        let stayAtBottom = didInitialScroll && computeAtBottom()
        collectionView.contentInset.bottom = newBottom
        collectionView.verticalScrollIndicatorInsets.bottom = composerBarH + keyboardExtra
        if stayAtBottom { UIView.performWithoutAnimation { pinBottom() } }
        else if newBottom < old { clampOffsetIfBeyondContent() }   // inset SHRANK → never rest past the end
    }

    private func pinBottom(animated: Bool = false) {
        guard collectionView.bounds.height > 0 else { return }
        let target = collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom
        let y = max(-collectionView.adjustedContentInset.top, target)
        lastStableOffset = y   // our intentional position → screenshot recovery target
        if animated {
            collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: true)
        } else if abs(collectionView.contentOffset.y - y) > 0.5 {
            collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        }
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
        if let attr = collectionView.layoutAttributesForItem(at: ip) {
            let visible = CGRect(x: 0,
                                 y: collectionView.contentOffset.y + collectionView.adjustedContentInset.top,
                                 width: collectionView.bounds.width,
                                 height: collectionView.bounds.height
                                    - collectionView.adjustedContentInset.top
                                    - collectionView.adjustedContentInset.bottom)
            if visible.contains(attr.frame) { return }   // already entirely on screen → no scroll
        }
        collectionView.scrollToItem(at: ip, at: .centeredVertically, animated: true)
    }

    // MARK: - Scroll observation

    private func computeAtBottom() -> Bool {
        guard collectionView.contentSize.height > 0 else { return true }
        let bottomEdge = collectionView.contentOffset.y + collectionView.bounds.height - collectionView.adjustedContentInset.bottom
        return bottomEdge >= collectionView.contentSize.height - 44
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { sendAnimating = false; settleFlush() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settleFlush() }   // finger up, no fling → settled now
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settleFlush() }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let atBottom = computeAtBottom()
        if coordinator.parent.isAtBottom != atBottom { coordinator.parent.isAtBottom = atBottom }
        let userDriven = scrollView.isDragging || scrollView.isTracking || scrollView.isDecelerating
        // Remember the last USER-intended offset (also kept fresh by pinBottom/restore). The iOS 26
        // full-page screenshot capture scrolls the list programmatically — this is what we snap back to.
        if userDriven { lastStableOffset = scrollView.contentOffset.y }
        // Fire load-older once when we cross into the top zone — USER scrolls only. The system's
        // full-page screenshot capture scrolls the list programmatically to the top, which used to
        // page older messages in (prepend → content shift) and leave the chat "gone up" after the
        // screenshot. A programmatic system scroll must never trigger paging.
        let nearTop = scrollView.contentOffset.y <= 72
        if nearTop && !inTopZone && userDriven { coordinator.parent.onReachedTop() }
        inTopZone = nearTop
        // Topmost visible row → the floating date header (the sticky date).
        let top = collectionView.indexPathsForVisibleItems.min().flatMap { dataSource.itemIdentifier(for: $0) }
        if coordinator.parent.topVisibleId != top { coordinator.parent.topVisibleId = top }
    }

    // MARK: - Screenshot recovery

    // iOS 26 full-page screenshots scroll the view programmatically to capture pages; if its own restore
    // lands wrong (or our layout shifted meanwhile), the chat is left scrolled away. When the screenshot
    // notification fires, snap back to the last position the USER (or our own pinning) put the list at.
    @objc func screenshotTaken() {
        guard didInitialScroll, !collectionView.isDragging, !collectionView.isTracking else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let target = self.lastStableOffset
            guard abs(self.collectionView.contentOffset.y - target) > 4 else { return }
            let maxY = max(-self.collectionView.adjustedContentInset.top,
                           self.collectionView.contentSize.height - self.collectionView.bounds.height
                               + self.collectionView.adjustedContentInset.bottom)
            let y = min(max(-self.collectionView.adjustedContentInset.top, target), maxY)
            self.collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        }
    }
}

// Pre-measured layout: cell heights are known before layout (never self-sized), so every
// frame is exact on the first pass. `heightForItem` reads the controller's measured-height cache; prepare
// stacks the rows into exact frames and an exact content height. This is the whole anti-shake mechanism —
// with no estimate → measure step, there is nothing to correct and nothing to hide.
final class ExactHeightLayout: UICollectionViewLayout {
    var heightForItem: ((Int) -> CGFloat)?
    var animateInserts = false            // a fade-in for a freshly inserted (sent/received) bottom cell
    // A render-state id: an O(1) identity check instead of re-stacking frames on every prepare().
    // The controller bumps this whenever ids/heights change; unchanged generation + width + count →
    // the cached frames are reused untouched (prepare() is called constantly during scrolling).
    var generation = 0

    private var frames: [CGRect] = []
    private var contentHeight: CGFloat = 0
    private(set) var layoutWidth: CGFloat = 0
    private var inserted: Set<IndexPath> = []
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

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        var result: [UICollectionViewLayoutAttributes] = []
        for i in frames.indices where frames[i].intersects(rect) {
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

    // Fade a freshly inserted bottom cell in (the sent/received bubble), so an animated send glides the
    // list up while the new bubble fades — the native UIKit behaviour, no custom per-cell transforms.
    override func prepare(forCollectionViewUpdates updateItems: [UICollectionViewUpdateItem]) {
        super.prepare(forCollectionViewUpdates: updateItems)
        inserted = Set(updateItems.compactMap { $0.updateAction == .insert ? $0.indexPathAfterUpdate : nil })
    }
    override func finalizeCollectionViewUpdates() { super.finalizeCollectionViewUpdates(); inserted = [] }
    override func initialLayoutAttributesForAppearingItem(at ip: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard animateInserts, inserted.contains(ip), let final = layoutAttributesForItem(at: ip) else {
            return super.initialLayoutAttributesForAppearingItem(at: ip)
        }
        let a = final.copy() as! UICollectionViewLayoutAttributes
        a.alpha = 0
        return a
    }
}
