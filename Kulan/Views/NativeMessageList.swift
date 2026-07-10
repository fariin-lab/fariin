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
    private var pendingBottomScroll = false   // deferred to viewDidLayoutSubviews so the first frame (0 bounds) still lands at bottom
    private var inTopZone = false             // debounces the load-older callback to one fire per entry
    private var stickBottomThroughLayout = false   // keep the bottom pinned across keyboard/composer resizes

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
        let layout = UICollectionViewCompositionalLayout(section: section)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
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
    }

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
            // Same rows, but SwiftUI state changed (reaction/edit/read tick): cheaply refresh only the
            // on-screen cells. Off-screen cells rebuild from the latest `row` closure when they scroll in.
            let visible = collectionView.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) }
            guard !visible.isEmpty else { return }
            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems(visible)
            dataSource.apply(snapshot, animatingDifferences: false)
            return
        }

        let wasAtBottom = computeAtBottom()
        let isFirst = currentIds.isEmpty
        // A top-prepend (load older) = the new list ENDS WITH the entire old list. For that we anchor an
        // on-screen row and restore its position after the insert, so nothing lurches.
        let isPrepend = !currentIds.isEmpty && ids.count > currentIds.count
            && Array(ids.suffix(currentIds.count)) == currentIds
        let anchor: (id: String, distanceFromTop: CGFloat)? = isPrepend ? captureTopAnchor() : nil

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids, toSection: 0)
        let overlap = ids.filter { currentIds.contains($0) }
        if !overlap.isEmpty { snapshot.reconfigureItems(overlap) }
        currentIds = ids

        let shouldStick = isFirst || !didInitialScroll || (wasAtBottom && !isPrepend)
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self else { return }
            if let anchor {
                self.restore(anchor)          // load-older: keep the reader's place
            } else if shouldStick {
                self.pendingBottomScroll = true
                self.maybeScrollToBottom()    // first load / my send / at-bottom receive: land at bottom
            }
        }
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
        stickBottomThroughLayout = didInitialScroll && !pendingBottomScroll && computeAtBottom()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if pendingBottomScroll { maybeScrollToBottom(); return }
        if stickBottomThroughLayout { scrollToBottom() }   // keyboard opened while at bottom -> stay pinned
    }

    private func maybeScrollToBottom() {
        guard pendingBottomScroll, collectionView.bounds.height > 0 else { return }
        scrollToBottom()
        pendingBottomScroll = false
        didInitialScroll = true
    }

    private func scrollToBottom() {
        collectionView.layoutIfNeeded()   // force real sizes of the near-bottom cells before offsetting
        let target = collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom
        let minY = -collectionView.adjustedContentInset.top
        collectionView.setContentOffset(CGPoint(x: 0, y: max(minY, target)), animated: false)
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
