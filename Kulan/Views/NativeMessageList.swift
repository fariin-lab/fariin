import SwiftUI
import UIKit

// ISOLATED UIKit-backed message list — Signal's architecture, our own code. A UICollectionView with a
// diffable data source hosts our EXISTING SwiftUI rows (MessageBubble etc.) in each cell via
// UIHostingConfiguration, so no feature is lost. Unlike a SwiftUI LazyVStack, the collection view lets
// us control the content offset directly, so the chat opens at the EXACT bottom with no jump and stays
// stable when a message is sent/received. Wired behind a flag in ThreadView so it can be A/B tested and
// only kept if it's solid on-device.
//
// Stage 1: display rows + open-at-bottom + send/receive stability + reach-top callback for pagination.
struct NativeMessageList: UIViewControllerRepresentable {
    var rowIds: [String]                       // stable ids in order (Message.rowId)
    var row: (String) -> AnyView               // ThreadView builds the full row (date/divider/bubble) for an id
    var onReachedTop: () -> Void               // near-top -> page older
    @Binding var isAtBottom: Bool

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

    override func viewDidLoad() {
        super.viewDidLoad()
        var config = UICollectionLayoutListConfiguration(appearance: .plain)
        config.showsSeparators = false
        config.backgroundColor = .clear
        let layout = UICollectionViewCompositionalLayout.list(using: config)
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
        let idsChanged = ids != currentIds
        let wasAtBottom = computeAtBottom()
        let isFirst = currentIds.isEmpty

        if idsChanged {
            // Identity change (insert/delete) -> rebuild the snapshot; reconfigure the overlap so any
            // in-place content change (reaction/edit/read tick) on a surviving row also refreshes.
            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            snapshot.appendSections([0])
            snapshot.appendItems(ids, toSection: 0)
            let overlap = ids.filter { currentIds.contains($0) }
            if !overlap.isEmpty { snapshot.reconfigureItems(overlap) }
            currentIds = ids
            let shouldStickToBottom = isFirst || !didInitialScroll || wasAtBottom
            dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
                guard let self else { return }
                if shouldStickToBottom {
                    self.pendingBottomScroll = true
                    self.maybeScrollToBottom()
                }
            }
        } else {
            // Same rows, but SwiftUI state changed (reaction/edit/read tick): cheaply refresh only the
            // on-screen cells. Off-screen cells rebuild from the latest `row` closure when they scroll in.
            let visible = collectionView.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) }
            guard !visible.isEmpty else { return }
            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems(visible)
            dataSource.apply(snapshot, animatingDifferences: false)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        maybeScrollToBottom()   // first real layout (or a size change) -> land at the exact bottom
    }

    private func maybeScrollToBottom() {
        guard pendingBottomScroll, collectionView.bounds.height > 0 else { return }
        collectionView.layoutIfNeeded()   // force real sizes of the near-bottom cells before offsetting
        let target = collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom
        let minY = -collectionView.adjustedContentInset.top
        collectionView.setContentOffset(CGPoint(x: 0, y: max(minY, target)), animated: false)
        pendingBottomScroll = false
        didInitialScroll = true
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
