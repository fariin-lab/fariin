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
///   • `rowHeight = .automaticDimension`, `estimatedRowHeight = 60` (ours is 80 — our row is taller).
///   • They set no `estimatedSectionHeaderHeight` and no `sectionHeaderTopPadding`. Do not add
///     either "to make the header size properly"; a grouped table self-sizes a header from its own
///     constraints, and an estimate here changes the spacing they do not have.
///
/// ⛔ THE PIN ANIMATION IS NOT AN ANIMATION ANYBODY WROTE — owner's question, 2026-09-05, asking for
/// their pin/unpin movement to the frame. Read out of `applyRowChanges`: there is no spring, no
/// duration, no curve, no `UIView.animate`, no `CATransaction`. They pass
/// `UITableView.RowAnimation.automatic` and let UIKit run its stock row animation. What makes it
/// feel like theirs is three decisions, all of them in `apply(state:animated:)` and
/// `ChatListRowChanges.between`, and all three were wrong here before that date:
///   1. cross-section move = `moveRow`; same-section move = delete + insert.
///   2. the transaction is opened only when something needs it.
///   3. nothing runs after the transaction. The `reloadSections` that used to follow it fired on
///      every pin and cut the flight in half.
/// Do not "improve" this with a custom animator. The reference's answer is that there isn't one.
///
/// ⚠️ BUILT BESIDE THE SwiftUI LIST, NOT IN PLACE OF IT YET. This file is the table, its data
/// source, the swipe set, the context menu and the headings; multi-select, the search section, the
/// empty and skeleton states and the story-ring tap still live on the SwiftUI screen and have to be
/// carried over one at a time, each verified on his phone. Swapping the whole screen in one commit
/// is how this file's own history says the chat list gets broken.
enum ChatListSection: Int, CaseIterable {
    case pinned, unpinned

    /// Nil means the header draws nothing and collapses — their rule for a section with no title,
    /// which is what a list with nothing pinned needs.
    ///
    /// ⛔ THEIR RULE, READ FROM `CLVRenderState.makeSection`, AND IT IS NOT SYMMETRICAL. One test
    /// turns the headings on for the whole list — `hasSectionTitles` is `!pinnedThreadUniqueIds
    /// .isEmpty`, nothing else — and each section then has to be non-empty on its own account:
    ///
    ///     pinned title    = hasSectionTitles && !pinned.isEmpty     → pinned.isEmpty == false
    ///     unpinned title  = hasSectionTitles && !unpinned.isEmpty   → both non-empty
    ///
    /// ⚠️ OURS REQUIRED BOTH HALVES FILLED FOR BOTH HEADINGS, which is the same answer everywhere
    /// except one case: a list where EVERY chat is pinned. Theirs says "Pinned" over it; ours said
    /// nothing, so the act of pinning the last unpinned chat silently removed a heading that had
    /// just appeared. Pinning is what turns the headings on, and it does not turn them back off.
    func title(pinnedCount: Int, unpinnedCount: Int) -> String? {
        guard pinnedCount > 0 else { return nil }
        switch self {
        case .pinned:   return "Pinned"
        case .unpinned: return unpinnedCount > 0 ? "Chats" : nil
        }
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
        //
        // ⛔ AND THEN THE SPLIT THIS FILE GOT WRONG. Their own words, from `applyRowChanges`:
        //
        //     if we're moving within the same section, we perform moves using a "delete" and
        //     "insert" rather than a "move". This ensures that moved items are also reloaded. This
        //     is how UICollectionView performs reloads internally. We can't do this when changing
        //     sections, because it results in a weird animation. This should generally be safe,
        //     because you'll only move between sections when pinning / unpinning which doesn't
        //     require the moved item to be reloaded.
        //
        // So the two kinds of movement this list produces are not one operation:
        //
        //   • ACROSS sections — pin and unpin, and nothing else. `moveRow`, because a delete plus an
        //     insert across a section boundary is the "weird animation" their comment names, and
        //     the flight between the two lists is the whole reason this file exists.
        //   • WITHIN a section — a new message re-sorting the inbox. Delete plus insert, because
        //     that REDRAWS the row as it travels. A `moveRow` carries the cell it already has, so
        //     the row that just moved to the top because of a new message would arrive still
        //     showing the old preview, the old timestamp and the old unread count, and would only
        //     correct itself on the next unrelated reload.
        //
        // Ours emitted `moveRow` for both, which is why the pin flight was right and every ordinary
        // re-sort landed stale.
        for id in oldIds.intersection(newIds) {
            guard let from = old.indexPath(of: id), let to = new.indexPath(of: id), from != to else { continue }
            if from.section != to.section {
                out.moves.append((from: from, to: to))
            } else {
                out.deletes.append(from)
                out.inserts.append(to)
            }
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

    /// Their `hasEverAppeared`. The first apply has nothing to animate from; every apply after it
    /// animates, including one that finds the list empty. See `apply(state:animated:)`.
    private var hasEverApplied = false

    /// ⛔ ONE HEADER VIEW PER SECTION, KEPT, NOT REBUILT. Two reasons, and the second is the one that
    /// matters for the pin animation.
    ///
    /// A `viewForHeaderInSection` that returns a freshly allocated `UIView` allocates two labels and
    /// a container every time the table asks — which is on every update pass, not only on scroll.
    /// That is the cheap reason.
    ///
    /// The real reason is that a heading which appears when you pin your first chat has to change
    /// WITHOUT `reloadSections`, because a section reload lands on top of the row's flight and kills
    /// it. Holding the view means the text can simply be set on it inside the same transaction,
    /// which is the header's version of their `updateCellContent`: change what is on screen in
    /// place, never ask the table to rebuild the thing that is currently animating.
    private lazy var headerViews: [ChatListSection: ChatListSectionHeader] = [
        .pinned: ChatListSectionHeader(),
        .unpinned: ChatListSectionHeader(),
    ]

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
    /// ⛔ THERE IS NO CUSTOM ANIMATION HERE AND THERE MUST NOT BE ONE. This was the owner's question
    /// on 2026-09-05 — make the pin movement feel exactly like the reference app's — and the answer
    /// read out of their source is that they do not animate it themselves at all. No spring, no
    /// duration, no curve, no `UIView.animate` wrapper, no `CATransaction`. `applyRowChanges` picks
    /// `UITableView.RowAnimation.automatic` and lets UIKit run its own row animation inside one
    /// begin/end block. Everything that makes their pin FEEL right is a decision about which
    /// operations are issued and what is refused around them:
    ///
    ///   1. cross-section move stays a `moveRow`, same-section move becomes delete+insert
    ///      (see `ChatListRowChanges.between`);
    ///   2. the block is opened only if something actually needs it — their comment: "only perform a
    ///      beginUpdates/endUpdates block if really necessary, otherwise strange scroll animations
    ///      may occur";
    ///   3. NOTHING follows the block. No `reloadSections`, no second pass.
    ///
    /// ⚠️ POINT 3 IS THE ONE THAT WAS BREAKING IT. This function used to reload BOTH sections
    /// immediately after `endUpdates()` whenever a heading appeared or disappeared — which is
    /// exactly when a chat is pinned or unpinned, so it fired on every single pin. `reloadSections`
    /// starts a second animation over the top of the first one, and the row that was mid-flight
    /// between the two lists is destroyed and rebuilt in place. Wrapping it in
    /// `performWithoutAnimation` did not save it; that only meant the interruption was instant.
    /// The heading is updated IN PLACE on the header view instead (`syncHeaderTitles`), the way
    /// their `updateCellContent` updates a cell in place rather than reloading its row.
    ///
    /// ⚠️ THE FIRST APPLY IS NOT ANIMATED, and after it every apply is. `hasEverApplied` is their
    /// `hasEverAppeared`: an explicit flag, not `old.isEmpty`, because a list that legitimately
    /// empties and refills — switching to the Unread filter and back — is not a first load and must
    /// not throw its cells away.
    func apply(state new: ChatListRenderState, animated: Bool) {
        let old = state
        state = new

        guard hasEverApplied else {
            hasEverApplied = true
            tableView.reloadData()
            syncHeaderTitles()
            return
        }

        let changes = ChatListRowChanges.between(old, new)
        // A heading appears or disappears when the pinned section fills or empties. It is not a row
        // change, and it is not a section reload either — see `syncHeaderTitles`.
        let headerChanged = old.titledSections() != new.titledSections()

        guard !changes.isEmpty || headerChanged else { return }

        // ⛔ `.automatic` WHEN ANIMATING, `.none` WHEN NOT — `defaultRowAnimation` in their source is
        // literally `animated ? .automatic : .none`. The old code passed `.automatic` unconditionally
        // and simply never reached here on a non-animated apply, so the constant was never wrong;
        // it is spelled out now because the non-animated path below does reach here.
        let rowAnimation: UITableView.RowAnimation = animated ? .automatic : .none

        let work = {
            self.tableView.beginUpdates()
            // The heading rides INSIDE the transaction so its appearance is part of the same
            // animation as the row that caused it, and so the header's new height is measured in the
            // same pass. `heightForHeaderInSection` already reads the new state — it was assigned at
            // the top of this function, before any of this — so UIKit re-measures both sections here
            // without being told to reload either of them.
            if headerChanged { self.syncHeaderTitles() }
            if !changes.deletes.isEmpty { self.tableView.deleteRows(at: changes.deletes, with: rowAnimation) }
            if !changes.inserts.isEmpty { self.tableView.insertRows(at: changes.inserts, with: rowAnimation) }
            // ⚠️ NO ANIMATION CONSTANT ON A MOVE, because `moveRow` does not take one. Its timing is
            // the block's, which is the other half of why the pin flight and the rows closing behind
            // it are one movement rather than two that happen to overlap.
            for m in changes.moves { self.tableView.moveRow(at: m.from, to: m.to) }
            self.tableView.endUpdates()
        }

        // Their suppression, and it is not a branch around the work — it is the same work inside a
        // zero-length animation. `reloadData()` here would be the easy version and it is wrong: it
        // drops every cell, which costs a full rebuild and loses the swipe or the menu the user may
        // have open on one of them.
        if animated {
            work()
        } else {
            UIView.animate(withDuration: 0) { work() }
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
        guard let s = ChatListSection(rawValue: section), let header = headerViews[s] else {
            return UIView()
        }
        header.title = s.title(pinnedCount: state.pinned.count, unpinnedCount: state.unpinned.count)
        return header
    }

    /// Push the current state's headings onto the two header views without touching the table.
    ///
    /// ⛔ THIS IS WHAT REPLACED `reloadSections`. Called from inside the update transaction, so the
    /// heading that appears because a chat was just pinned appears as part of that chat's flight
    /// rather than as a second animation that interrupts it. The header's HEIGHT still comes from
    /// `heightForHeaderInSection` — UIKit re-asks for it during the block, and the state it reads
    /// was assigned before the block opened — so the section grows and shrinks in the same pass.
    private func syncHeaderTitles() {
        for s in ChatListSection.allCases {
            headerViews[s]?.title = s.title(pinnedCount: state.pinned.count,
                                            unpinnedCount: state.unpinned.count)
        }
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

/// The "Pinned" / "Chats" heading.
///
/// Their numbers, read from `CLVTableDataSource.viewForHeaderInSection`: a plain container with
/// layout margins of 14 above, 16 leading, 8 below and 16 trailing, holding a headline label in the
/// label colour. Nothing here is a background or a separator — a grouped table's own header
/// furniture is exactly what the list is avoiding, which is why the container is clear.
final class ChatListSectionHeader: UIView {
    /// Nil collapses the heading. Setting it is the whole update path: no reload, no reconfigure,
    /// and it is a no-op when the text has not actually changed, so it is safe to call on every
    /// pass. See `ChatListTableController.syncHeaderTitles`.
    var title: String? {
        didSet {
            guard title != oldValue else { return }
            label.text = title
            // ⚠️ HIDDEN RATHER THAN REMOVED. The height is decided by the delegate, which returns
            // `leastNormalMagnitude` for a titleless section; this only stops the label drawing in
            // the sliver that remains, and keeps the view itself — and therefore its constraints —
            // alive across the change.
            label.isHidden = title == nil
        }
    }

    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 14, leading: 16, bottom: 8, trailing: 16)

        label.font = .preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let g = layoutMarginsGuide
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: g.topAnchor),
            label.leadingAnchor.constraint(equalTo: g.leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: g.trailingAnchor),
            label.bottomAnchor.constraint(equalTo: g.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
