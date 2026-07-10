import SwiftUI
import UIKit

// UIKit-backed message list that reproduces Signal's conversation SCROLL BEHAVIOUR (our own code). A
// UICollectionView hosts our existing SwiftUI rows (MessageBubble etc.) via UIHostingConfiguration, so
// no bubble feature is lost — only the scroll container differs from the SwiftUI list. Because the
// collection view controls its own contentOffset, we can reproduce the three behaviours a SwiftUI
// LazyVStack structurally cannot:
//   1. Open at the EXACT bottom on the first frame (no estimate-then-correct jump / blink).
//   2. Scroll CONTINUITY when older messages load at the top — an on-screen message is anchored and its
//      position restored after the insert, so the view never lurches (Signal's key anti-jump idea).
//   3. Stay pinned to the bottom across keyboard / composer height changes when already at the bottom.
struct NativeMessageList: UIViewControllerRepresentable {
    var rowIds: [String]                       // stable ids in order (Message.rowId)
    var row: (String) -> AnyView               // ThreadView builds the full row (date/divider/bubble) for an id
    var onReachedTop: () -> Void               // near-top -> page older
    @Binding var isAtBottom: Bool
    @Binding var scrollTarget: String?         // set to a rowId to scroll it into view (reply/search jump), then cleared

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

final class MessageListController: UIViewController, UICollectionViewDelegate {
    var coordinator: NativeMessageList.Coordinator!
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var reg: UICollectionView.CellRegistration<UICollectionViewCell, String>!
    private var currentIds: [String] = []
    private var didInitialScroll = false
    private var pendingBottomScroll = false   // open/at-bottom settle window: keep re-pinning to the bottom
    private var inTopZone = false             // debounces the load-older callback to one fire per entry
    private var stickBottomThroughLayout = false   // keep the bottom pinned across keyboard/composer resizes
    private var contentSizeObs: NSKeyValueObservation?   // re-pin to bottom while self-sizing cells settle
    private var settleWork: DispatchWorkItem?
    private var sendAnimating = false   // an animated send/receive glide is in flight — do NOT snap-pin over it
    private var didReveal = false       // hidden until the first load is fully settled (Signal's hasAppliedFirstLoad)

    override func viewDidLoad() {
        super.viewDidLoad()
        // A PLAIN self-sizing vertical layout — NOT UICollectionLayoutListConfiguration, whose "list"
        // styling drew separators / inset cell backgrounds (the boxes/borders around bubbles). Here each
        // cell is full-width, self-sizes to its SwiftUI content, and has no chrome of its own.
        let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                              heightDimension: .estimated(60))
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let group = NSCollectionLayoutGroup.vertical(layoutSize: itemSize, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        let layout = ComposerEmergeLayout(section: section)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        // Invisible until the first load settles (Signal shows the conversation only once the first
        // render state has landed) — the bubbles appear fully formed, never mid-measure.
        collectionView.alpha = 0
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .interactive
        // .always so SwiftUI's safe-area insets (nav bar on top, the floating composer on the bottom)
        // become the collection view's adjustedContentInset — the last message clears the composer and
        // scrollToBottom lands exactly above it.
        collectionView.contentInsetAdjustmentBehavior = .always
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        buildDataSource()   // collectionView now exists — safe to wire the diffable data source
        // ROOT CAUSE of the open-jump: cells self-size (estimated height → measured), so contentSize
        // changes AFTER the initial scroll-to-bottom and the visible messages shift. Keep the bottom
        // anchored by re-pinning whenever contentSize changes during the open / at-bottom window; the
        // size corrections then land on off-screen content above, invisibly.
        contentSizeObs = collectionView.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
            guard let self, !self.sendAnimating else { return }   // never stomp an in-flight send glide
            if self.pendingBottomScroll || self.stickBottomThroughLayout {
                // Corrections must be INSTANT — UICollectionView animates self-sizing invalidations by
                // default, which rendered the settle as visible bubble motion (the "jump animation").
                UIView.performWithoutAnimation { self.pinBottom() }
            }
        }
    }

    deinit { contentSizeObs?.invalidate(); settleWork?.cancel() }

    private func buildDataSource() {
        reg = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, id in
            guard let self else { return }
            cell.contentConfiguration = UIHostingConfiguration { self.coordinator.parent.row(id) }
                .margins(.all, 0)
            cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
        }
        dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) { [weak self] cv, ip, id in
            cv.dequeueConfiguredReusableCell(using: self!.reg, for: ip, item: id)
        }
    }

    func apply(rowIds ids: [String]) {
        guard ids != currentIds else {
            // Same rows, but SwiftUI state changed (reaction/edit/read tick): refresh only the on-screen
            // cells. THROTTLED: reconfiguring on every parent re-render (each keystroke, typing dots)
            // churned layout and left STALE, OVERLAPPING cell frames — the invisible overlapped cells
            // then swallowed long-press/swipe on the rows beneath (couldn't reply/react on GIFs/calls).
            let visible = collectionView.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) }
            guard !visible.isEmpty else { return }
            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems(visible)
            dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
                // Re-measure + re-place after the reconfigure so no cell keeps a stale frame.
                self?.collectionView.collectionViewLayout.invalidateLayout()
            }
            return
        }

        let wasAtBottom = computeAtBottom()
        let isFirst = currentIds.isEmpty
        // A top-prepend (load older) = the new list ENDS WITH the entire old list. For that we anchor an
        // on-screen row and restore its position after the insert, so nothing lurches.
        let isPrepend = !currentIds.isEmpty && ids.count > currentIds.count
            && Array(ids.suffix(currentIds.count)) == currentIds
        // A bottom-append (send / receive) = the new list STARTS WITH the entire old list.
        let isAppend = !currentIds.isEmpty && ids.count > currentIds.count
            && Array(ids.prefix(currentIds.count)) == currentIds
        let anchor: (id: String, distanceFromTop: CGFloat)? = isPrepend ? captureTopAnchor() : nil

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids, toSection: 0)
        let overlap = ids.filter { currentIds.contains($0) }
        if !overlap.isEmpty { snapshot.reconfigureItems(overlap) }
        currentIds = ids

        let shouldStick = isFirst || !didInitialScroll || (wasAtBottom && !isPrepend)
        // Send/receive at the bottom ANIMATES — Signal's exact recipe (ConversationViewController+CVC):
        // an animated performBatchUpdates insert + scrollAction .bottomForNewMessage(isAnimated: true).
        // First load and prepends stay non-animated (Signal wraps those in zero-duration animations).
        let animate = isAppend && didInitialScroll && wasAtBottom
        if animate {
            // iMessage-style send: the new bubble EMERGES FROM THE COMPOSER (the layout's
            // initialLayoutAttributesForAppearingItem starts it at the screen bottom) and one native
            // UIKit SPRING drives both the batch-update insert and the scroll — the diffable apply is
            // synchronous on main, so wrapping it in UIView.animate makes the whole update (insert +
            // contentOffset) share the same spring curve: bubble and scroll move as one.
            sendAnimating = true
            (collectionView.collectionViewLayout as? ComposerEmergeLayout)?.emergeFromComposer = true
            UIView.animate(withDuration: 0.55, delay: 0, usingSpringWithDamping: 0.82,
                           initialSpringVelocity: 0.4, options: [.allowUserInteraction]) {
                self.dataSource.apply(snapshot, animatingDifferences: true)
                let target = self.collectionView.collectionViewLayout.collectionViewContentSize.height
                    - self.collectionView.bounds.height + self.collectionView.adjustedContentInset.bottom
                let y = max(-self.collectionView.adjustedContentInset.top, target)
                self.collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: false)   // inherits the spring
            } completion: { [weak self] _ in
                self?.sendAnimating = false
                (self?.collectionView.collectionViewLayout as? ComposerEmergeLayout)?.emergeFromComposer = false
            }
            // Safety: release even if the completion is dropped mid-transition.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.sendAnimating = false }
        } else {
            dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
                guard let self else { return }
                if let anchor {
                    self.restore(anchor)          // load-older: keep the reader's place
                } else if shouldStick {
                    self.beginBottomSettle()      // open: land + stay at bottom, no motion
                }
            }
        }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        sendAnimating = false
    }

    // MARK: - Scroll continuity (Signal's anti-jump idea, our implementation)

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
        collectionView.setContentOffset(CGPoint(x: 0, y: attr.frame.minY - anchor.distanceFromTop), animated: false)
    }

    // MARK: - Bottom pinning

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // Remember (before a keyboard/composer resize) whether we were at the bottom, so we can stay there.
        stickBottomThroughLayout = didInitialScroll && !pendingBottomScroll && !sendAnimating && computeAtBottom()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !didReveal { revealAfterSettle() }   // safety: empty chats settle nothing but must still show
        guard !sendAnimating else { return }   // never snap over an in-flight send glide
        if pendingBottomScroll { settleNow() }                                          // first real layout → full synchronous settle
        else if stickBottomThroughLayout { UIView.performWithoutAnimation { pinBottom() } }
        else { clampOffsetIfBeyondContent() }
    }

    // Open / at-bottom send-receive: settle the self-sizing cells SYNCHRONOUSLY, before the frame is
    // drawn. Each layoutIfNeeded pass resolves estimated→measured heights for the cells now on screen;
    // pinning the bottom then exposes the next batch, so a few passes converge — all inside one
    // CATransaction and without implicit animations, so the user NEVER sees intermediate positions.
    // (Async re-pins across frames were the visible "jump animation": UIKit animates self-sizing
    // corrections by default.)
    private func beginBottomSettle() {
        didInitialScroll = true
        pendingBottomScroll = true
        settleNow()
        settleWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            self?.pendingBottomScroll = false
            self?.clampOffsetIfBeyondContent()
        }
        settleWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    private func settleNow() {
        guard collectionView.bounds.height > 0 else { return }   // pre-layout: viewDidLayoutSubviews will settle
        UIView.performWithoutAnimation {
            for _ in 0..<4 {
                collectionView.layoutIfNeeded()
                pinBottom()
            }
        }
        revealAfterSettle()
    }

    // First open: some hosted-SwiftUI cell heights resolve one runloop AFTER the synchronous passes, so
    // reveal on the NEXT runloop turn — after one more settle — while still invisible. The user only
    // ever sees the final, fully-formed layout (no pop/bounce during the push transition).
    private func revealAfterSettle() {
        guard !didReveal else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.didReveal, self.collectionView.bounds.height > 0 else { return }
            UIView.performWithoutAnimation {
                for _ in 0..<2 {
                    self.collectionView.layoutIfNeeded()
                    self.pinBottom()
                }
                self.didReveal = true
                self.collectionView.alpha = 1
            }
        }
    }

    private func pinBottom() {
        guard collectionView.bounds.height > 0 else { return }
        let target = collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom
        let y = max(-collectionView.adjustedContentInset.top, target)
        if abs(collectionView.contentOffset.y - y) > 0.5 {
            collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        }
    }

    // Never leave the view scrolled PAST the content (the "sometimes empty chat" bug): when the content
    // shrinks (estimated → measured heights), clamp the offset back onto the real content.
    private func clampOffsetIfBeyondContent() {
        guard collectionView.bounds.height > 0 else { return }
        let maxY = max(-collectionView.adjustedContentInset.top,
                       collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
        if collectionView.contentOffset.y > maxY + 0.5 {
            collectionView.setContentOffset(CGPoint(x: 0, y: maxY), animated: false)
        }
    }

    // MARK: - Jump to a message (reply / search)

    func scrollTo(id: String) {
        guard let ip = dataSource.indexPath(for: id) else { return }
        collectionView.scrollToItem(at: ip, at: .centeredVertically, animated: true)
    }

    private func computeAtBottom() -> Bool {
        guard collectionView.contentSize.height > 0 else { return true }
        let bottomEdge = collectionView.contentOffset.y + collectionView.bounds.height - collectionView.adjustedContentInset.bottom
        return bottomEdge >= collectionView.contentSize.height - 44
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let atBottom = computeAtBottom()
        if coordinator.parent.isAtBottom != atBottom { coordinator.parent.isAtBottom = atBottom }
        // Fire load-older once when we cross into the top zone, not on every frame we sit there.
        let nearTop = scrollView.contentOffset.y <= 72
        if nearTop && !inTopZone { coordinator.parent.onReachedTop() }
        inTopZone = nearTop
    }
}

// Compositional layout whose APPEARING cells emerge from the composer (Apple's native insert-animation
// hook, initialLayoutAttributesForAppearingItem): a freshly inserted bottom cell starts translated down
// at the input-field position with a slight scale, and UIKit's surrounding spring animates it up into
// place — the iMessage send feel, built entirely from native animation APIs.
final class ComposerEmergeLayout: UICollectionViewCompositionalLayout {
    var emergeFromComposer = false
    private var inserted: Set<IndexPath> = []

    override func prepare(forCollectionViewUpdates updateItems: [UICollectionViewUpdateItem]) {
        super.prepare(forCollectionViewUpdates: updateItems)
        inserted = Set(updateItems.compactMap { $0.updateAction == .insert ? $0.indexPathAfterUpdate : nil })
    }

    override func finalizeCollectionViewUpdates() {
        super.finalizeCollectionViewUpdates()
        inserted = []
    }

    override func initialLayoutAttributesForAppearingItem(at itemIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        let attr = super.initialLayoutAttributesForAppearingItem(at: itemIndexPath)
        guard emergeFromComposer, inserted.contains(itemIndexPath),
              let final = layoutAttributesForItem(at: itemIndexPath),
              let cv = collectionView else { return attr }
        let a = final.copy() as! UICollectionViewLayoutAttributes
        // Start at the composer: the visible bottom edge of the viewport, slightly scaled down.
        let viewportBottom = cv.contentOffset.y + cv.bounds.height - cv.adjustedContentInset.bottom
        let dy = max(0, viewportBottom - final.frame.minY)
        a.transform = CGAffineTransform(translationX: 0, y: dy).scaledBy(x: 0.92, y: 0.92)
        a.alpha = 1   // no fade — it slides, like iMessage
        return a
    }
}
