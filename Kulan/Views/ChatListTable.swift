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
    case pinned, unpinned, people

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
    func title(pinnedCount: Int, unpinnedCount: Int, peopleCount: Int) -> String? {
        switch self {
        // ⛔ "OTHER PEOPLE" IS NOT PART OF THEIR RULE AND MUST NOT BE FOLDED INTO IT. It is ours,
        // from his 2026-09-02 order: people you have never chatted with, under the chats, only while
        // searching. Its heading depends on nothing but its own emptiness — a search that finds a
        // stranger and no pinned chat still has to say what the stranger is.
        case .people:
            return peopleCount > 0 ? "Other people" : nil
        case .pinned:
            return pinnedCount > 0 ? "Pinned" : nil
        case .unpinned:
            return pinnedCount > 0 && unpinnedCount > 0 ? "Chats" : nil
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
    /// Uids of people found by the search who are not already a chat above — his "Other people".
    ///
    /// ⚠️ THEY GO THROUGH THE SAME DIFF AS THE CHATS, deliberately, rather than being reloaded as a
    /// block whenever the query changes. A uid and a conversation id can never collide (a conv id is
    /// built from BOTH uids), so one id space covers all three sections and a stranger appearing or
    /// leaving the results animates like any other row instead of the section blinking.
    var people: [String] = []

    /// ⛔ THE ONLY WAY THIS VALUE SHOULD BE BUILT, BECAUSE A REPEATED ID IS A GUARANTEED CRASH.
    ///
    /// `indexPath(of:)` returns the FIRST place it finds an id, and the diff collapses ids through a
    /// `Set` — but `numberOfRowsInSection` counts the raw array. So one id appearing twice makes the
    /// diff issue one operation for a row the data source counts twice, and `endUpdates` traps with
    /// "the number of rows contained in an existing section after the update must be equal to the
    /// number of rows contained in that section before the update, plus or minus the number
    /// inserted or deleted".
    ///
    /// ⚠️ IT IS NOT A THEORETICAL INPUT. Two reach it: the search can merge people out of a prefix
    /// query and a handle lookup and hand the same uid twice, and the screen classifies a chat as
    /// pinned or unpinned from a document that can say both across two snapshots. The old comment
    /// here reasoned that "a uid and a conversation id can never collide", which is true and is not
    /// the case that bites — the collision is an id with ITSELF.
    ///
    /// Deduping in the order the sections are searched keeps the first occurrence, which is the one
    /// `indexPath(of:)` would have returned anyway.
    static func make(pinned: [String], unpinned: [String], people: [String]) -> ChatListRenderState {
        var seen = Set<String>()
        func unique(_ ids: [String]) -> [String] { ids.filter { seen.insert($0).inserted } }
        return ChatListRenderState(pinned: unique(pinned),
                                   unpinned: unique(unpinned),
                                   people: unique(people))
    }

    func ids(in section: ChatListSection) -> [String] {
        switch section {
        case .pinned:   return pinned
        case .unpinned: return unpinned
        case .people:   return people
        }
    }

    var isEmpty: Bool { pinned.isEmpty && unpinned.isEmpty && people.isEmpty }

    func indexPath(of id: String) -> IndexPath? {
        if let r = pinned.firstIndex(of: id) {
            return IndexPath(row: r, section: ChatListSection.pinned.rawValue)
        }
        if let r = unpinned.firstIndex(of: id) {
            return IndexPath(row: r, section: ChatListSection.unpinned.rawValue)
        }
        if let r = people.firstIndex(of: id) {
            return IndexPath(row: r, section: ChatListSection.people.rawValue)
        }
        return nil
    }

    /// Which sections currently carry a heading. Used to decide whether the headers have to be
    /// re-synced when the pinned set empties or fills.
    func titledSections() -> Set<Int> {
        var out: Set<Int> = []
        for s in ChatListSection.allCases where s.title(pinnedCount: pinned.count,
                                                        unpinnedCount: unpinned.count,
                                                        peopleCount: people.count) != nil {
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
        let oldIds = Set(old.pinned + old.unpinned + old.people)
        let newIds = Set(new.pinned + new.unpinned + new.people)

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

/// Everything one chat row draws from, as a single comparable value.
///
/// ⛔ THIS EXISTS BECAUSE THE TABLE HAD NO `.update` PATH AT ALL, and that was the largest defect in
/// the port. `ChatListRowChanges` can only see ORDER: it compares id sets and index paths, so a
/// conversation whose CONTENT changed while its POSITION did not produced an empty diff and `apply`
/// returned without issuing a single UIKit call. The cell's `UIHostingConfiguration` holds a
/// `ChatRow` VALUE captured at `cellForRowAt` time and nothing observes it, so the row simply froze.
///
/// ⚠️ WHAT THAT ACTUALLY BROKE, none of which involves moving a row:
///   • a new message in the chat that is ALREADY at the top of its section — old preview, old time,
///     old unread count, because a row at index 0 never travels;
///   • "typing…" never appearing, and worse, never clearing once shown;
///   • the unread badge not clearing when you read a chat and came back (reading does not re-sort);
///   • "Draft: …" never appearing;
///   • the delivery tick never going from one to two.
/// The row only ever repaired itself by being scrolled off and back, or by some unrelated re-sort.
///
/// Theirs solves this with a fourth row-change kind whose handler is `updateCellContent(at:for:)`:
/// take the LIVE cell and re-configure it in place, deliberately not `reloadRows`, "to avoid what
/// can be a disruptive re-layout of the chat list". `refreshVisibleContent` is that, and this value
/// is how it knows which rows actually changed — the same fields `ChatRow.==` compares, so the test
/// here and the row's own skip-rebuild test can never disagree.
struct ChatRowContent: Equatable {
    var conv: Conversation
    var onCall: Bool
    var storySeen: [Bool]
    var draft: String
    var voiceDraftSecs: Double
    var voiceUnplayed: Bool
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
    /// Strangers the search turned up. Empty whenever the search field is, which is what makes the
    /// third section disappear without anybody deciding it should.
    var people: [UserProfile]
    var me: String
    var dark: Bool
    var onOpen: (Conversation) -> Void
    var onOpenPerson: (UserProfile) -> Void
    /// The stranger row itself, still built by the screen. It is one `AnyView` per visible search
    /// result and no more — this section is only ever a handful of rows and only while typing — and
    /// it keeps `newPersonRow` as the single place that row is described, privacy rules included.
    var personRow: (UserProfile) -> AnyView
    var onStoryTap: (Conversation) -> Void
    var storySeen: (Conversation) -> [Bool]

    /// ⛔ THE ROW'S LOCAL CONTEXT, AND IT IS NOT OPTIONAL DECORATION. `ChatRow` takes four values
    /// that live nowhere near the conversation document — a call running right now, an unsent text
    /// draft, a parked voice recording, and whether the newest incoming note has been heard. The
    /// screen reads them from four different singletons per row.
    ///
    /// ⚠️ THE FIRST VERSION OF THIS FILE BUILT `ChatRow` WITHOUT THEM, which would have shipped a
    /// list with no "Draft:" line, no green "Active call" row and no accent mic — three things he
    /// asked for by name — while looking, in a screenshot of a quiet list, completely correct.
    var onCall: (Conversation) -> Bool
    var draft: (Conversation) -> String
    var voiceDraftSecs: (Conversation) -> Double
    var voiceUnplayed: (Conversation) -> Bool

    /// Select mode. `selecting` drives the table's own editing state; `selection` is the same set
    /// the SwiftUI toolbar reads, so the two cannot disagree about what is ticked.
    ///
    /// ⚠️ THE CIRCLES ARE UIKit'S OWN. `allowsMultipleSelectionDuringEditing` plus `setEditing` is
    /// what the SwiftUI `List(selection:)` was asking the same UIKit for underneath — the difference
    /// is that the indent and the circle slide in on UIKit's clock now instead of on a SwiftUI
    /// animation wrapped around a state flag.
    var selecting: Bool
    @Binding var selection: Set<String>

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
    /// ⚠️ `UIMenuElement`, NOT `UIAction`. The mute entry is a SUBMENU — his five timed choices —
    /// and a `UIMenu` is not a `UIAction`, so an array of actions cannot express the menu the screen
    /// already has. Typing it as the element protocol is what lets the nested one through.
    var menuActions: (Conversation) -> [UIMenuElement]
    var peek: (Conversation) -> UIViewController

    func makeUIViewController(context: Context) -> ChatListTableController {
        let vc = ChatListTableController()
        vc.host = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: ChatListTableController, context: Context) {
        context.coordinator.parent = self
        // ⚠️ SELECT MODE IS SET BEFORE THE ROWS, and the order is not arbitrary. Entering Select
        // changes every row's indent; doing that in the same pass as an insert or a delete, but
        // after it, means UIKit animates the indent from a layout that the row change has already
        // invalidated. The editing state settles first, then the diff runs against it.
        vc.setTint(UIColor(Theme.defaultBubble(dark)))
        vc.setSelecting(selecting)
        vc.apply(state: .make(pinned: pinned.map(\.id),
                              unpinned: unpinned.map(\.id),
                              people: people.map(\.id)),
                 animated: true)
        // ⛔ THE TICKS ARE PUT BACK **AFTER** THE DIFF, AND THE ORDER IS A BUG FIX. A same-section
        // move is a delete plus an insert (their rule — see `ChatListRowChanges.between`), and a
        // table does NOT carry a row's selection through one: the row that comes back is a new row
        // at a new index path with no tick. So a chat you had ticked in Select mode lost its tick
        // the moment a message arrived and re-sorted the list, while `selection` still counted it —
        // the toolbar would say "2 Selected" over one visible tick. Syncing after the transaction
        // restores it from the id, which is the only thing that survives a re-sort.
        vc.syncTicks(selected: selection)
        // ⛔ THEIR `.update` CASE, AND WITHOUT IT THE LIST FREEZES. A row whose content changed but
        // whose position did not produces an empty diff, so nothing above this line touches it. See
        // `ChatRowContent` for the five things that were silently broken.
        vc.refreshVisibleContent()
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

        func person(_ id: String) -> UserProfile? {
            parent.people.first { $0.id == id }
        }

        /// Everything the row draws from, read fresh off the screen's stores. The four closures are
        /// the only way this table can see a draft, a live call, an unheard note or a story ring.
        func content(for conv: Conversation) -> ChatRowContent {
            ChatRowContent(conv: conv,
                           onCall: parent.onCall(conv),
                           storySeen: parent.storySeen(conv),
                           draft: parent.draft(conv),
                           voiceDraftSecs: parent.voiceDraftSecs(conv),
                           voiceUnplayed: parent.voiceUnplayed(conv))
        }

        /// The one writer of the SwiftUI-side selection set. The table reports a tick, this puts it
        /// where the toolbar can count it.
        func setSelected(_ id: String, _ on: Bool) {
            if on { parent.selection.insert(id) } else { parent.selection.remove(id) }
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

    /// ⛔ RE-ENTRANCY GUARD. `apply` assigns `state` and then opens a transaction; entering it again
    /// from inside that transaction would advance the state twice and nest `beginUpdates`, whose
    /// inner index paths would be read against the OUTER transaction's pre-state — an inconsistent
    /// update, which is a crash. Nothing reaches it synchronously today: the only inward path is
    /// `cellForRowAt`, which reads four closures on the screen, and SwiftUI coalesces any
    /// invalidation those cause to the next runloop. This costs one Bool and removes the whole
    /// class, including the day somebody puts a publisher that fires on read behind one of them.
    private var isApplying = false

    /// What each row's cell was last configured with, by id. The input to the in-place refresh —
    /// see `refreshVisibleContent`. Pruned to the live id set on every apply so it cannot grow with
    /// every chat that has ever been on screen.
    private var configured: [String: ChatRowContent] = [:]
    /// The theme the visible cells were built in. Not part of a row's content, and it changes all of
    /// them at once.
    private var configuredDark: Bool?

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
        .people: ChatListSectionHeader(),
    ]

    /// Their table, their style. See the file header for why `.grouped` rather than `.plain`.
    private lazy var tableView: UITableView = {
        let t = UITableView(frame: .zero, style: .grouped)
        t.separatorStyle = .none
        t.backgroundColor = .clear
        t.rowHeight = UITableView.automaticDimension
        t.estimatedRowHeight = 80          // our row: 56pt avatar + 12 above and below
        // ⛔ THE GREY UNDER EVERY ROW IS THE GROUPED STYLE'S, AND IT HAS TO BE TURNED OFF HERE TOO —
        // owner, 2026-09-02: "why is the chat list Chats card using grey, remove that". The SwiftUI
        // list needed `listRowBackground(.clear)` on every row for the same reason; a grouped table
        // paints each cell on `secondarySystemGroupedBackground` because that is the raised-card look
        // the style exists for. Cleared on the cell in `cellForRowAt`, and the table's own fill is
        // cleared here so the screen's background shows through both.
        t.backgroundView = nil
        // ⛔ 28pt OF CLEARANCE AT THE BOTTOM, HIS NUMBER, CARRIED OVER FROM THE LIST. Without it the
        // last rows sit UNDER the floating tab bar: its margins are transparent, so the row shows
        // through and the tap goes to the row rather than the pill.
        t.contentInset.bottom = 28
        t.verticalScrollIndicatorInsets.bottom = 28
        // ⛔ THE TICK IS THE CHAT COLOUR, NOT THE APP TINT — the same note the calls list carries.
        // The app's `.primary` tint draws a white check on a white disc, which is a tick you cannot
        // see. Set from `dark` in `updateUIViewController`, because the theme can change under it.
        // Select mode. UIKit draws the circles and the indent; see `setSelecting`.
        t.allowsMultipleSelectionDuringEditing = true
        t.allowsSelectionDuringEditing = true
        t.dataSource = self
        t.delegate = self
        t.register(ChatListCell.self, forCellReuseIdentifier: ChatListCell.reuseId)
        t.register(ChatListCell.self, forCellReuseIdentifier: ChatListCell.personReuseId)
        return t
    }()

    /// Enter or leave Select mode, and put the ticks where the SwiftUI side says they are.
    ///
    /// ⚠️ ANIMATED ONLY WHEN THE MODE ACTUALLY CHANGES. `updateUIViewController` runs on every
    /// SwiftUI pass — a keystroke in the search field, a new message on another chat — and calling
    /// `setEditing(_:animated: true)` with the value it already has restarts the indent animation
    /// from the start each time, which reads as the whole list twitching while you type.
    ///
    /// ⚠️ AND THE TICKS ARE PUSHED, NOT ONLY READ. A row that was selected before the list re-sorted
    /// keeps its tick because the selection set is by id; the table's own `indexPathsForSelectedRows`
    /// is by position and means nothing after a move.
    /// The Select-mode tick colour. Cheap to call on every pass — assigning the same `UIColor` is a
    /// comparison, and a changed one has to reach the table anyway when the theme flips.
    func setTint(_ color: UIColor) {
        guard tableView.tintColor != color else { return }
        tableView.tintColor = color
    }

    func setSelecting(_ on: Bool) {
        guard tableView.isEditing != on else { return }
        tableView.setEditing(on, animated: true)
    }

    /// Put the ticks where the SwiftUI side says they are.
    ///
    /// ⚠️ BY ID, NEVER BY POSITION. `indexPathsForSelectedRows` is a set of positions, and a
    /// position means nothing across a re-sort; the selection set is the truth and this is the one
    /// place it is written onto the table. Called after every diff — see `updateUIViewController`.
    func syncTicks(selected: Set<String>) {
        guard tableView.isEditing else { return }
        for section in ChatListSection.allCases {
            for (row, id) in state.ids(in: section).enumerated() {
                let ip = IndexPath(row: row, section: section.rawValue)
                let isSelected = selected.contains(id)
                let isMarked = tableView.indexPathsForSelectedRows?.contains(ip) ?? false
                guard isSelected != isMarked else { continue }
                if isSelected {
                    tableView.selectRow(at: ip, animated: false, scrollPosition: .none)
                } else {
                    tableView.deselectRow(at: ip, animated: false)
                }
            }
        }
    }

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

        // The heading's height is computed from the headline font, so a change to the phone's text
        // size changes it. Nothing else asks the table to re-measure a header, and this is rare
        // enough that a full reload is the honest answer rather than an optimisation.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (vc: ChatListTableController, _) in
            vc.tableView.reloadData()
        }
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
        // See `isApplying`. A nested call would advance the state twice and nest the transaction.
        guard !isApplying else { return }
        isApplying = true
        defer { isApplying = false }

        let old = state
        state = new
        // The content cache is keyed by id and would otherwise keep every chat that has ever been on
        // screen. Pruned here rather than in the refresh, because this is the one place that knows
        // which ids still exist.
        if configured.count > new.pinned.count + new.unpinned.count {
            let live = Set(new.pinned + new.unpinned)
            configured = configured.filter { live.contains($0.key) }
        }

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
            // ⛔ THEIRS, VERBATIM IN INTENT: "animate all UI changes within the same transaction",
            // and the change is dropping OUT of editing state when the list rearranges under an open
            // swipe. Their condition is `tableView.isEditing && !multiSelectState.isActive` — a
            // revealed swipe platter puts the table in editing state, and leaving it revealed over a
            // row that is being deleted or moved is how a platter ends up stranded on the wrong
            // chat. Select mode is the exception, because there editing IS the mode.
            if self.tableView.isEditing, !(self.host?.parent.selecting ?? false) {
                self.tableView.setEditing(false, animated: true)
            }
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
        //
        // ⚠️ THE WRAPPER IS NOT IN `applyRowChanges`, IT IS IN THEIR CALLER, and a reviewer looking
        // only at `applyRowChanges` will correctly report it as an addition of ours. It is theirs:
        // `ChatListViewController+Loading.swift`, the load path — `shouldAnimate = !suppressAnimations
        // && hasEverAppeared`, and when that is false the same `applyLoadResult` is called inside
        // `UIView.animate(withDuration: 0)`.
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
        let s = ChatListSection(rawValue: indexPath.section)
        let reuseId = s == .people ? ChatListCell.personReuseId : ChatListCell.reuseId
        let cell = tableView.dequeueReusableCell(withIdentifier: reuseId, for: indexPath)
        guard let c = cell as? ChatListCell, let s,
              let id = state.ids(in: s)[safe: indexPath.row],
              let host
        else { return cell }

        let p = host.parent
        c.backgroundColor = .clear

        // ⛔ A STRANGER FROM THE SEARCH, NOT A CHAT. Its own reuse identifier, because a cell that
        // has held a `ChatRow` hosting configuration and is then handed a person's is a different
        // view tree in the same cell — which is exactly the case their own comment warns about when
        // it refuses to `reconfigureRows` across a section whose cell type may have changed.
        if s == .people {
            guard let u = host.person(id) else { return cell }
            c.contentConfiguration = UIHostingConfiguration { p.personRow(u) }.margins(.all, 0)
            // He set `selectionDisabled(true)` on this row in SwiftUI: a stranger is not something
            // you can tick and then archive.
            c.selectionStyle = .default
            return c
        }

        guard let conv = host.conversation(id) else { return cell }
        configureChatCell(c, id: id, content: host.content(for: conv))
        return c
    }

    /// The ONE place a chat cell's content is built, so `cellForRowAt` and the in-place refresh
    /// cannot drift apart.
    ///
    /// ⚠️ `UIHostingConfiguration`, so the ROW ITSELF is still the SwiftUI `ChatRow` we already have.
    /// Nothing about how a row looks moved to UIKit here — only how rows are arranged and animated.
    ///
    /// ⚠️ THE HOSTING CONFIGURATION'S TYPE IS THE SAME ON EVERY CALL, which is what makes the
    /// in-place refresh work rather than merely not crash: UIKit hands the new configuration to the
    /// EXISTING content view, so SwiftUI updates the row in place and the row's own `@State` — the
    /// typing self-expire and the clock tick that ages "14:03" into "Yesterday" — survives. A
    /// different generic type there would rebuild the view and reset both, which is the other reason
    /// a stranger's row has its own reuse identifier.
    private func configureChatCell(_ cell: ChatListCell, id: String, content: ChatRowContent) {
        configured[id] = content
        let me = host?.parent.me ?? ""
        let dark = host?.parent.dark ?? false
        // ⛔ THE TAP READS THE COORDINATOR, NOT THE CAPTURED STRUCT. `host` is a reference and its
        // `parent` is replaced on every SwiftUI pass; the struct is a value frozen at build time. A
        // closure that captured the struct kept whatever `selecting` was true when the cell was
        // built, so a row built BEFORE Edit was tapped opened the person's story instead of ticking
        // the row — the SwiftUI list guarded that twice and neither guard survived the port.
        let coordinator = host
        let conv = content.conv
        cell.contentConfiguration = UIHostingConfiguration {
            ChatRow(conv: conv, me: me, dark: dark,
                    onCall: content.onCall,
                    storySeen: content.storySeen,
                    onStoryTap: { coordinator?.parent.onStoryTap(conv) },
                    draft: content.draft,
                    voiceDraftSecs: content.voiceDraftSecs,
                    voiceUnplayed: content.voiceUnplayed)
                .equatable()   // the row's own skip-rebuild test, kept — see `ChatRow.==`
        }
        .margins(.all, 0)
        cell.selectionStyle = .default
    }

    /// ⛔ THEIR `updateCellContent`, AND THE PORT WAS BROKEN WITHOUT IT. See `ChatRowContent` for the
    /// five things that silently stopped working.
    ///
    /// Walks only the rows that are actually on screen, compares each one's content with what its
    /// cell was last given, and re-configures the ones that differ — straight onto the live cell,
    /// never through `reloadRows` or `reconfigureRows`. That is their choice and their stated reason
    /// ("to avoid what can be a disruptive re-layout of the chat list"), and here it is also what
    /// makes this safe to run immediately after a pin: assigning a cell's configuration is not a
    /// table operation, so it cannot interrupt the transaction's animation the way `reloadSections`
    /// did.
    ///
    /// ⚠️ SAFE ONLY BECAUSE THE ROW'S HEIGHT CANNOT CHANGE. Every row reserves exactly two preview
    /// lines whatever its preview is (the hidden two-line label in `ChatRow`), so new content can
    /// never want a different height, and the table is never told about a size it does not know. If
    /// that reserve is ever removed, this has to become `reconfigureRows` and the pin animation has
    /// to be re-checked.
    func refreshVisibleContent() {
        guard let host else { return }
        let p = host.parent
        // A theme flip changes every row and is not part of any row's content value.
        let themeChanged = configuredDark != p.dark
        configuredDark = p.dark

        for ip in tableView.indexPathsForVisibleRows ?? [] {
            guard let s = ChatListSection(rawValue: ip.section), s != .people,
                  let id = state.ids(in: s)[safe: ip.row],
                  let conv = host.conversation(id),
                  let cell = tableView.cellForRow(at: ip) as? ChatListCell
            else { continue }
            let fresh = host.content(for: conv)
            guard themeChanged || configured[id] != fresh else { continue }
            configureChatCell(cell, id: id, content: fresh)
        }
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
    /// ⚠️ FALSE FOR A STRANGER, AND IT BUYS TWO THINGS AT ONCE. `canEditRowAt` gates the swipe
    /// platter AND the Select-mode circle, which is exactly the pair the SwiftUI row expressed as
    /// "no `swipeActions`" plus `.selectionDisabled(true)`. There is nothing to archive, mute or
    /// delete about somebody you have never spoken to.
    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        ChatListSection(rawValue: indexPath.section) != .people
    }

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
        // ⛔ OUR OWN DRAWING FOR PIN, NOT `pin.fill` — it is the mark he sent for this swipe, and the
        // SwiftUI list used it here (`MenuIcon("ic_pin_menu")`). The port had quietly substituted the
        // SF Symbol, which is the same idea drawn by somebody else. `.alwaysTemplate` so the platter
        // tints it white the way it tints a symbol; an asset defaults to its own colours and would
        // have come out as a dark pin on orange.
        pin.image = pinned ? UIImage(systemName: "pin.slash.fill")
                           : UIImage(named: "ic_pin_menu")?.withRenderingMode(.alwaysTemplate)
        pin.backgroundColor = .systemOrange

        return UISwipeActionsConfiguration(actions: [read, pin])
    }

    func tableView(_ tableView: UITableView,
                   trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let c = conversation(at: indexPath), let p = host?.parent else { return nil }
        let archive = UIContextualAction(style: .normal, title: "Archive") { _, _, done in
            p.onArchive(c); done(true)
        }
        // ⛔ THE SOLID DRAWING, `ic_archive_fill` — the SwiftUI swipe used it and its note says it is
        // "the one he sent for the swipe specifically". `ic_archive` (the outline) is the MENU's, and
        // the two are not interchangeable.
        archive.image = UIImage(named: "ic_archive_fill")?.withRenderingMode(.alwaysTemplate)
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
        header.title = s.title(pinnedCount: state.pinned.count, unpinnedCount: state.unpinned.count,
                               peopleCount: state.people.count)
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
                                            unpinnedCount: state.unpinned.count,
                                            peopleCount: state.people.count)
        }
    }

    /// "Without returning a header with a non-zero height, a grouped table view will use a default
    /// spacing between sections. We do not want that spacing so we use the smallest possible
    /// height." — their comment, and their rule, applied to both headers and footers.
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        guard let s = ChatListSection(rawValue: section),
              s.title(pinnedCount: state.pinned.count, unpinnedCount: state.unpinned.count,
                      peopleCount: state.people.count) != nil
        else { return .leastNormalMagnitude }
        // ⛔ AN EXPLICIT HEIGHT, NOT `automaticDimension` — see `ChatListSectionHeader.height`. The
        // automatic answer is a CACHED measurement of the header view, and setting the label's text
        // does not invalidate that cache; the heading would then appear late, at whatever moment
        // something unrelated forced a re-measure.
        return ChatListSectionHeader.height(for: traitCollection)
    }

    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? { UIView() }

    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        .leastNormalMagnitude
    }

    // MARK: - Selection

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        // ⛔ IN SELECT MODE A TAP IS A TICK, AND THE ROW STAYS SELECTED. Calling `deselectRow` here
        // unconditionally — which is what the open-a-chat path below wants — would untick the row
        // the finger just ticked, on the same frame, and the list would look like it refuses to
        // select anything. The whole row is the target, which is his rule and theirs: a tick that
        // can only be hit on the circle is a smaller target for no reason.
        if tableView.isEditing {
            // ⛔ A STRANGER MUST NEVER ENTER THE SELECTION SET. `canEditRowAt` being false takes the
            // CIRCLE away but not the selection: with `allowsSelectionDuringEditing` a tap still
            // lands here, and this used to put the person's UID into `selection`. The toolbar then
            // counted it, and Archive or Delete handed that uid to `ChatService` as if it were a
            // conversation id. The SwiftUI row said this with `selectionDisabled(true)` and the
            // meaning has to be restored explicitly, not inferred from the missing circle.
            guard ChatListSection(rawValue: indexPath.section) != .people else {
                tableView.deselectRow(at: indexPath, animated: false)
                return
            }
            guard let id = rowId(at: indexPath) else { return }
            host?.setSelected(id, true)
            return
        }

        tableView.deselectRow(at: indexPath, animated: true)
        // A stranger from the search opens — and creates — the chat with them.
        if ChatListSection(rawValue: indexPath.section) == .people {
            guard let id = rowId(at: indexPath), let u = host?.person(id) else { return }
            host?.parent.onOpenPerson(u)
            return
        }
        guard let c = conversation(at: indexPath) else { return }
        host?.parent.onOpen(c)
    }

    func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        guard tableView.isEditing, let id = rowId(at: indexPath) else { return }
        host?.setSelected(id, false)
    }

    /// The id at a position, whichever section it is in. Bounds-checked for the same reason
    /// `conversation(at:)` is.
    private func rowId(at indexPath: IndexPath) -> String? {
        guard let s = ChatListSection(rawValue: indexPath.section) else { return nil }
        return state.ids(in: s)[safe: indexPath.row]
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
    /// A stranger's row is a different view tree in the same cell class, so it gets its own queue.
    /// Mixing them under one identifier is how a recycled cell ends up holding the wrong hosting
    /// configuration for a frame.
    static let personReuseId = "ChatListPersonCell"
}

/// The "Pinned" / "Chats" heading.
///
/// Their numbers, read from `CLVTableDataSource.viewForHeaderInSection`: a plain container with
/// layout margins of 14 above, 16 leading, 8 below and 16 trailing, holding a headline label in the
/// label colour. Nothing here is a background or a separator — a grouped table's own header
/// furniture is exactly what the list is avoiding, which is why the container is clear.
final class ChatListSectionHeader: UIView {
    /// Their margins, and the two numbers the height is made of. Named because the height below has
    /// to use the SAME values the layout does — two copies of 14 that can drift apart is how a
    /// heading ends up half a point clipped.
    static let topMargin: CGFloat = 14
    static let bottomMargin: CGFloat = 8

    /// ⛔ THE HEIGHT IS ARITHMETIC, NOT A MEASUREMENT, AND THAT IS THE POINT.
    ///
    /// `heightForHeaderInSection` used to return `UITableView.automaticDimension`, which reads a
    /// CACHED `systemLayoutSizeFitting` of the header view. Setting `label.text` invalidates the
    /// LABEL; it does not invalidate the table's cached section-header size, and there is no public
    /// API that does short of `reloadSections` — the one call this whole design exists to avoid. The
    /// failure that buys is the nastiest kind: the heading appears LATE, whenever some unrelated
    /// relayout happens to re-measure it, so it looks fine in the one test you run.
    ///
    /// This header is a single line of a known style between two known margins, so its height can be
    /// computed outright. Deterministic, no cache to go stale, and it still grows with the phone's
    /// text size because the font does.
    static func height(for traits: UITraitCollection) -> CGFloat {
        let font = UIFont.preferredFont(forTextStyle: .headline, compatibleWith: traits)
        return ceil(font.lineHeight) + topMargin + bottomMargin
    }

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
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: Self.topMargin, leading: 16,
                                                           bottom: Self.bottomMargin, trailing: 16)

        label.font = .preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let g = layoutMarginsGuide
        // ⚠️ THE BOTTOM ONE IS 999, NOT REQUIRED. A titleless section is collapsed to
        // `leastNormalMagnitude`, and UIKit enforces that with its own required
        // `UIView-Encapsulated-Layout-Height`. A required bottom constraint fights it and logs a
        // constraint conflict on every pin — noise in the console for a view that is deliberately
        // being squashed to nothing. One point below required loses that fight silently and changes
        // nothing when the header is actually visible.
        let bottom = label.bottomAnchor.constraint(equalTo: g.bottomAnchor)
        bottom.priority = .defaultHigh + 1
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: g.topAnchor),
            label.leadingAnchor.constraint(equalTo: g.leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: g.trailingAnchor),
            bottom,
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
