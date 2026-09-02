import SwiftUI
import UIKit

/// THE CHAT LIST AS A `UITableView`, because a row has to physically travel between sections.
///
/// ⛔ HIS INSTRUCTION, 2026-09-02, after three reports on the pin animation: "go start now, chat
/// list → UITableView". The last of those reports is what makes it necessary rather than tidy.
///
/// ⚠️ WHY SwiftUI COULD NOT FINISH THE JOB, stated once so nobody reverses this later. A row leaving
/// one `ForEach` for another is a DELETE and an INSERT to SwiftUI's diff — there is no spelling of
/// "this row moved to that section". So pinning crossfaded a row out of Chats and into Pinned, where
/// the reference app calls `moveRow(at:to:)` and the row flies. Everything else about their chat
/// list we matched in SwiftUI; this one thing has no SwiftUI equivalent at all.
///
/// ⚠️ THEIR STRUCTURE, READ FROM SOURCE (`CLVTableDataSource`, `ChatListViewController+Loading`) and
/// not from memory, which is what he asked for:
///   • `UITableView(frame: .zero, style: .grouped)` — grouped so headers scroll instead of floating.
///   • `separatorStyle = .none`.
///   • A header is a plain `UIView` with layout margins 14/16/8/16 and a `dynamicTypeHeadline`
///     label in `.label`; a titleless section returns `.leastNormalMagnitude`, and so does every
///     footer, "because we do not want that spacing".
///   • Changes are applied inside `beginUpdates()` / `endUpdates()`; sections are inserted and
///     deleted as sections, and a row that changes section is a `moveRow`, explicitly NOT a
///     delete-plus-insert, because that "results in a weird animation".
///
/// ⚠️ BUILT BESIDE THE SwiftUI LIST, NOT IN PLACE OF IT YET. This file is the table and its data
/// source and nothing else; the swipe actions, the context menu, multi-select and the story-ring tap
/// all still live on the SwiftUI rows and have to be carried over one at a time, each verified on
/// his phone. Swapping the whole screen in one commit is how this file's own history says the chat
/// list gets broken.
enum ChatListSection: Int, CaseIterable {
    case pinned, unpinned

    /// Nil means the header draws nothing and collapses — their rule for a section with no title,
    /// which is what a list with nothing pinned needs.
    func title(pinnedCount: Int, unpinnedCount: Int) -> String? {
        // Both headings appear only when both sections exist. A lone "Chats" over every chat in the
        // app is a label with nothing to contrast against — the same rule the SwiftUI list follows.
        guard pinnedCount > 0, unpinnedCount > 0 else { return nil }
        return self == .pinned ? "Pinned" : "Chats"
    }
}

/// One frozen answer to "what does the list look like right now".
///
/// ⚠️ A VALUE, AND THAT IS THE POINT. The diff below compares the previous render state with the new
/// one; if either could change under it the index paths it produces would describe a list that no
/// longer exists, which is the classic "attempt to delete row that no longer exists" crash.
struct ChatListRenderState: Equatable {
    var pinned: [String] = []
    var unpinned: [String] = []

    func ids(in section: ChatListSection) -> [String] {
        section == .pinned ? pinned : unpinned
    }

    var isEmpty: Bool { pinned.isEmpty && unpinned.isEmpty }

    func indexPath(of id: String) -> IndexPath? {
        if let r = pinned.firstIndex(of: id) {
            return IndexPath(row: r, section: ChatListSection.pinned.rawValue)
        }
        if let r = unpinned.firstIndex(of: id) {
            return IndexPath(row: r, section: ChatListSection.unpinned.rawValue)
        }
        return nil
    }

    /// Which sections currently carry a heading. Used to decide whether a header has to be reloaded
    /// when the pinned set empties or fills.
    func titledSections() -> Set<Int> {
        var out: Set<Int> = []
        for s in ChatListSection.allCases where s.title(pinnedCount: pinned.count,
                                                        unpinnedCount: unpinned.count) != nil {
            out.insert(s.rawValue)
        }
        return out
    }
}

/// The one operation the whole rewrite exists for.
///
/// Their `applyRowChanges` walks a diff and emits deletes, inserts and moves. This is the same shape
/// reduced to what our list can produce: our two sections always both exist as far as the table is
/// concerned (an empty one draws no header and no rows), so there are no section inserts or deletes
/// to make — only row deletes, inserts and, crucially, moves ACROSS sections.
struct ChatListRowChanges {
    var deletes: [IndexPath] = []
    var inserts: [IndexPath] = []
    var moves: [(from: IndexPath, to: IndexPath)] = []

    var isEmpty: Bool { deletes.isEmpty && inserts.isEmpty && moves.isEmpty }

    /// ⚠️ MOVES ARE EXPRESSED AGAINST THE OLD LIST FOR `from` AND THE NEW LIST FOR `to`, which is
    /// exactly what `moveRow(at:to:)` wants and is the single easiest thing to get wrong here. A
    /// delete's index path is the OLD list's; an insert's is the NEW list's. UIKit applies deletes
    /// first, then inserts, then moves, all against that split — so nothing here may be renumbered.
    static func between(_ old: ChatListRenderState, _ new: ChatListRenderState) -> ChatListRowChanges {
        var out = ChatListRowChanges()
        let oldIds = Set(old.pinned + old.unpinned)
        let newIds = Set(new.pinned + new.unpinned)

        for id in oldIds.subtracting(newIds) {
            if let p = old.indexPath(of: id) { out.deletes.append(p) }
        }
        for id in newIds.subtracting(oldIds) {
            if let p = new.indexPath(of: id) { out.inserts.append(p) }
        }
        // Survivors: a move is reported only when the row actually lands somewhere else. Reporting
        // a move to the same place is legal and wasteful, and on a list that re-sorts on every
        // message it would be most of the list every time.
        for id in oldIds.intersection(newIds) {
            guard let from = old.indexPath(of: id), let to = new.indexPath(of: id), from != to else { continue }
            out.moves.append((from: from, to: to))
        }
        return out
    }
}

/// The table itself.
///
/// ⚠️ `UIViewControllerRepresentable`, not `UIViewRepresentable`. A bare view has nowhere to put the
/// swipe actions' owning controller or the context-menu previews that still have to be carried over,
/// and a controller is also what lets the table participate in the navigation stack's safe area the
/// way the SwiftUI list does.
struct ChatListTable: UIViewControllerRepresentable {
    /// Rows to draw, already filtered and sorted by the caller — this view decides nothing about
    /// which chats are here or in what order, only how the change from the last set is animated.
    var pinned: [Conversation]
    var unpinned: [Conversation]
    var me: String
    var dark: Bool
    var onOpen: (Conversation) -> Void
    var onStoryTap: (Conversation) -> Void
    var storySeen: (Conversation) -> [Bool]

    /// ⛔ THEIR SWIPE SET, IN THEIR ORDER — `ThreadContextualActionProvider`, read from source:
    /// leading is read-state then pin-state, trailing is archive, delete, mute. Ours had pin alone
    /// on the leading edge and archive/mute/delete trailing, so two of the three were in a different
    /// place and one was missing entirely.
    var onToggleRead: (Conversation) -> Void
    var onTogglePin: (Conversation) -> Void
    var onArchive: (Conversation) -> Void
    var onDelete: (Conversation) -> Void
    var onMute: (Conversation) -> Void
    /// The long-press menu's rows, as the SwiftUI screen already builds them, plus the peek it shows
    /// above them. Handed over as makers rather than as views so the table can build a real
    /// `UIContextMenuConfiguration` — which is what gives the peek its lift and its own dismissal.
    var menuActions: (Conversation) -> [UIAction]
    var peek: (Conversation) -> UIViewController

    func makeUIViewController(context: Context) -> ChatListTableController {
        let vc = ChatListTableController()
        vc.host = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: ChatListTableController, context: Context) {
        context.coordinator.parent = self
        vc.apply(state: ChatListRenderState(pinned: pinned.map(\.id), unpinned: unpinned.map(\.id)),
                 animated: true)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator {
        var parent: ChatListTable
        init(_ parent: ChatListTable) { self.parent = parent }

        /// Rows by id, so the data source can hand a cell its conversation without searching two
        /// arrays for every visible row on every pass.
        func conversation(_ id: String) -> Conversation? {
            parent.pinned.first { $0.id == id } ?? parent.unpinned.first { $0.id == id }
        }
    }
}

/// The controller that owns the table. Deliberately thin: it holds the render state, applies a diff
/// to it, and vends cells.
final class ChatListTableController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    var host: ChatListTable.Coordinator?
    private(set) var state = ChatListRenderState()

    /// Their table, their style. See the file header for why `.grouped` rather than `.plain`.
    private lazy var tableView: UITableView = {
        let t = UITableView(frame: .zero, style: .grouped)
        t.separatorStyle = .none
        t.backgroundColor = .clear
        t.rowHeight = UITableView.automaticDimension
        t.estimatedRowHeight = 80          // our row: 56pt avatar + 12 above and below
        t.dataSource = self
        t.delegate = self
        t.register(ChatListCell.self, forCellReuseIdentifier: ChatListCell.reuseId)
        return t
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(tableView)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// ⛔ THEIR TRANSACTION, AND THE REASON THIS FILE EXISTS. One `beginUpdates`/`endUpdates` block
    /// holding deletes, inserts and — the whole point — `moveRow` for a row that changed section.
    ///
    /// ⚠️ THE FIRST APPLY IS NOT ANIMATED. There is nothing to animate from: every row would fly in
    /// from nowhere, which is the "everything slides on launch" that a diffing list gets wrong once
    /// and is then rewritten to avoid.
    func apply(state new: ChatListRenderState, animated: Bool) {
        let old = state
        state = new

        guard animated, !old.isEmpty else {
            tableView.reloadData()
            return
        }

        let changes = ChatListRowChanges.between(old, new)
        // A heading appears or disappears when the pinned section fills or empties, and that is a
        // header change rather than a row change — the table has to be told separately.
        let headerChanged = old.titledSections() != new.titledSections()

        guard !changes.isEmpty || headerChanged else { return }

        tableView.beginUpdates()
        if !changes.deletes.isEmpty { tableView.deleteRows(at: changes.deletes, with: .automatic) }
        if !changes.inserts.isEmpty { tableView.insertRows(at: changes.inserts, with: .automatic) }
        for m in changes.moves { tableView.moveRow(at: m.from, to: m.to) }
        tableView.endUpdates()

        // ⚠️ AFTER the transaction, never inside it. Reloading a section inside the same block that
        // moves rows out of it is UIKit's own definition of an inconsistent update.
        if headerChanged {
            UIView.performWithoutAnimation {
                tableView.reloadSections(IndexSet(ChatListSection.allCases.map(\.rawValue)),
                                         with: .none)
            }
        }
    }

    // MARK: - Data source

    func numberOfSections(in tableView: UITableView) -> Int { ChatListSection.allCases.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let s = ChatListSection(rawValue: section) else { return 0 }
        return state.ids(in: s).count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: ChatListCell.reuseId, for: indexPath)
        guard let c = cell as? ChatListCell,
              let s = ChatListSection(rawValue: indexPath.section),
              let id = state.ids(in: s)[safe: indexPath.row],
              let host, let conv = host.conversation(id)
        else { return cell }

        let p = host.parent
        // ⚠️ `UIHostingConfiguration`, so the ROW ITSELF is still the SwiftUI `ChatRow` we already
        // have. Nothing about how a row looks moves to UIKit here — only how rows are arranged and
        // animated. Rewriting the row's drawing as well would be two rewrites at once, and the
        // second one has no reason to happen.
        c.contentConfiguration = UIHostingConfiguration {
            ChatRow(conv: conv, me: p.me, dark: p.dark,
                    storySeen: p.storySeen(conv),
                    onStoryTap: { p.onStoryTap(conv) })
        }
        .margins(.all, 0)
        c.backgroundColor = .clear
        c.selectionStyle = .default
        return c
    }

    // MARK: - Swipes

    /// ⛔ THEIR ORDER, READ FROM `ThreadContextualActionProvider`: leading is READ-STATE then
    /// PIN-STATE; trailing is ARCHIVE, DELETE, MUTE. Ours was pin alone on the left and
    /// archive/mute/delete on the right — so mark-unread did not exist, and delete and mute were
    /// swapped against theirs.
    ///
    /// ⚠️ A `UISwipeActionsConfiguration`'s array reads OUTWARDS FROM THE EDGE, which is why their
    /// list looks reversed on screen: the first element is the one nearest the edge you dragged
    /// from. Writing them in their order and letting UIKit place them is what keeps the two apps'
    /// muscle memory the same.
    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool { true }

    func tableView(_ tableView: UITableView,
                   leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let c = conversation(at: indexPath), let p = host?.parent else { return nil }
        let read = UIContextualAction(style: .normal, title: c.hasUnreadMark(p.me) ? "Read" : "Unread") { _, _, done in
            p.onToggleRead(c); done(true)
        }
        read.image = UIImage(systemName: c.hasUnreadMark(p.me) ? "envelope.open.fill" : "envelope.badge.fill")
        read.backgroundColor = .systemBlue

        let pinned = c.isPinned(p.me)
        let pin = UIContextualAction(style: .normal, title: pinned ? "Unpin" : "Pin") { _, _, done in
            p.onTogglePin(c); done(true)
        }
        pin.image = UIImage(systemName: pinned ? "pin.slash.fill" : "pin.fill")
        pin.backgroundColor = .systemOrange

        return UISwipeActionsConfiguration(actions: [read, pin])
    }

    func tableView(_ tableView: UITableView,
                   trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let c = conversation(at: indexPath), let p = host?.parent else { return nil }
        let archive = UIContextualAction(style: .normal, title: "Archive") { _, _, done in
            p.onArchive(c); done(true)
        }
        archive.image = UIImage(systemName: "archivebox.fill")
        archive.backgroundColor = .systemGray

        // ⚠️ `.destructive` ON DELETE, AND IT IS NOT ONLY THE COLOUR. A destructive contextual
        // action is the one a FULL swipe performs, and it is the one UIKit animates the row out on.
        // Ours was destructive too; the difference is that it now sits where theirs does.
        let del = UIContextualAction(style: .destructive, title: "Delete") { _, _, done in
            p.onDelete(c); done(true)
        }
        del.image = UIImage(systemName: "trash.fill")

        let mute = UIContextualAction(style: .normal, title: "Mute") { _, _, done in
            p.onMute(c); done(true)
        }
        mute.image = UIImage(systemName: "bell.slash.fill")
        mute.backgroundColor = .systemIndigo

        let cfg = UISwipeActionsConfiguration(actions: [archive, del, mute])
        // ⛔ NO FULL-SWIPE DELETE. Theirs leaves `performsFirstActionWithFullSwipe` at its default,
        // where the first trailing action is ARCHIVE — a full swipe archives, which is undoable.
        // Ours must not let a long drag delete a conversation with no confirmation; `onDelete`
        // raises the app's own alert, so the guard is really in the closure, and this line says the
        // gesture is deliberate rather than inherited.
        cfg.performsFirstActionWithFullSwipe = true
        return cfg
    }

    // MARK: - Long press

    /// ⛔ A REAL `UIContextMenuConfiguration`, WITH THE PEEK AS ITS PREVIEW — the same shape theirs
    /// uses (`contextMenuConfigurationForRowAt` with a `previewProvider` and an `actionProvider`).
    ///
    /// ⚠️ THE IDENTIFIER IS THE CHAT'S ID, deliberately, and theirs is too. UIKit hands the identifier
    /// back when the menu is dismissed, and a menu whose row has moved underneath it — which this
    /// list does on every new message — can only find its way home if it can say WHICH chat it was.
    func tableView(_ tableView: UITableView,
                   contextMenuConfigurationForRowAt indexPath: IndexPath,
                   point: CGPoint) -> UIContextMenuConfiguration? {
        guard let c = conversation(at: indexPath), let p = host?.parent else { return nil }
        return UIContextMenuConfiguration(identifier: c.id as NSString,
                                          previewProvider: { p.peek(c) },
                                          actionProvider: { _ in UIMenu(children: p.menuActions(c)) })
    }

    // MARK: - Headers

    /// Their numbers, read from `CLVTableDataSource.viewForHeaderInSection`: a plain container with
    /// layout margins of 14 above, 16 leading, 8 below and 16 trailing, holding a headline label in
    /// the label colour.
    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let s = ChatListSection(rawValue: section),
              let title = s.title(pinnedCount: state.pinned.count, unpinnedCount: state.unpinned.count)
        else { return UIView() }

        let container = UIView()
        container.backgroundColor = .clear
        container.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 14, leading: 16,
                                                                     bottom: 8, trailing: 16)
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.text = title
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        let g = container.layoutMarginsGuide
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: g.topAnchor),
            label.leadingAnchor.constraint(equalTo: g.leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: g.trailingAnchor),
            label.bottomAnchor.constraint(equalTo: g.bottomAnchor),
        ])
        return container
    }

    /// "Without returning a header with a non-zero height, a grouped table view will use a default
    /// spacing between sections. We do not want that spacing so we use the smallest possible
    /// height." — their comment, and their rule, applied to both headers and footers.
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        guard let s = ChatListSection(rawValue: section),
              s.title(pinnedCount: state.pinned.count, unpinnedCount: state.unpinned.count) != nil
        else { return .leastNormalMagnitude }
        return UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? { UIView() }

    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        .leastNormalMagnitude
    }

    // MARK: - Selection

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let c = conversation(at: indexPath) else { return }
        host?.parent.onOpen(c)
    }

    /// One lookup for every delegate method above. Bounds-checked because a swipe or a menu can
    /// outlive the row it started on — the list re-sorts on an incoming message, and an index path
    /// captured a moment ago may now be past the end.
    private func conversation(at indexPath: IndexPath) -> Conversation? {
        guard let s = ChatListSection(rawValue: indexPath.section),
              let id = state.ids(in: s)[safe: indexPath.row] else { return nil }
        return host?.conversation(id)
    }
}

/// A cell that is nothing but a host for the SwiftUI row.
private final class ChatListCell: UITableViewCell {
    static let reuseId = "ChatListCell"
}
