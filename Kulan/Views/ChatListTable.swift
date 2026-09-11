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
        // ⛔ A ROW THAT ONLY SHIFTED INDEX IS NOT A CHANGE, AND THIS IS THE PIN BUG — his fifth
        // report, 2026-09-09, and the first one diagnosed by reading their diff rather than their
        // table calls.
        //
        // ⚠️ WHAT THIS USED TO DO. Every surviving id whose index path was not identical became an
        // operation. Pin the third of eight chats and the five rows BELOW it each shift up one, so
        // each one was deleted and re-inserted — five fades out and five fades back in, playing
        // over the top of the one row that is actually flying. Pin something near the bottom of a
        // long list and nearly everything on screen flickers. That is "several bugs, especially the
        // animation and transition"; it is not a timing problem and no animation constant would
        // have touched it.
        //
        // ⛔ THEIRS EMITS NOTHING FOR THOSE ROWS. Their diff computes the MINIMAL set of moves over
        // the ids present in both lists: it filters both sides down to the survivors and then only
        // names a row that genuinely changed its ORDER relative to the others. On a pin the
        // unpinned survivors are already in the same relative order, so their whole transaction is
        // one delete and one insert, which their pin special case then collapses into a single
        // cross-section `moveRow`. One operation, not eleven.
        //
        // The minimal set is the complement of the longest run of survivors that is already in the
        // right order. Walk the new order, look each id up in the old order, and take the longest
        // increasing run of those old positions: everything in that run is already sorted with
        // respect to everything else in it and needs no operation. Every survivor outside it moved.
        for id in oldIds.intersection(newIds) {
            guard let from = old.indexPath(of: id), let to = new.indexPath(of: id) else { continue }
            // A pin or unpin, and nothing else. Always a `moveRow` — see the note above.
            if from.section != to.section { out.moves.append((from: from, to: to)) }
        }
        // Same-section reordering, section by section, over the survivors alone.
        for section in ChatListSection.allCases {
            let survivors = new.ids(in: section).filter {
                oldIds.contains($0) && old.indexPath(of: $0)?.section == section.rawValue
            }
            guard survivors.count > 1 else { continue }
            let oldPos = Dictionary(uniqueKeysWithValues:
                old.ids(in: section).enumerated().map { ($0.element, $0.offset) })
            let positions = survivors.compactMap { oldPos[$0] }
            guard positions.count == survivors.count else { continue }
            let stay = Set(Self.longestIncreasingRun(positions))
            for (i, p) in positions.enumerated() where !stay.contains(p) {
                let id = survivors[i]
                guard let from = old.indexPath(of: id), let to = new.indexPath(of: id) else { continue }
                out.deletes.append(from)
                out.inserts.append(to)
            }
        }
        return out
    }

    /// The longest subsequence of `values` that is already increasing — the rows that may stay put.
    ///
    /// Patience sorting, so it is n log n rather than the quadratic table a longest-common-
    /// subsequence would build. A chat list is small, but this runs on every message that re-sorts
    /// it, which is the one place in this file that is genuinely hot.
    static func longestIncreasingRun(_ values: [Int]) -> [Int] {
        guard !values.isEmpty else { return [] }
        var tailIndex: [Int] = []          // index into `values` of each pile's smallest tail
        var previous = [Int](repeating: -1, count: values.count)
        for i in 0..<values.count {
            var lo = 0, hi = tailIndex.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if values[tailIndex[mid]] < values[i] { lo = mid + 1 } else { hi = mid }
            }
            if lo > 0 { previous[i] = tailIndex[lo - 1] }
            if lo == tailIndex.count { tailIndex.append(i) } else { tailIndex[lo] = i }
        }
        var out: [Int] = []
        var k = tailIndex.last ?? -1
        while k >= 0 { out.append(values[k]); k = previous[k] }
        return out.reversed()
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
        // ⛔ THE `.update` CASE MOVED INSIDE `apply`, AND THE CALL THAT USED TO BE HERE IS GONE.
        //
        // ⚠️ THIS LINE WAS THE LAST PIECE OF HIS PIN REPORT. It ran after EVERY apply, including
        // the ones carrying a pin, so on every pin the app reached into the live cells and assigned
        // each one a fresh `UIHostingConfiguration` while the rows were still in flight — a SwiftUI
        // layout pass landing on top of a UIKit animation. The same shape as the `reloadSections`
        // that was removed on 2026-09-05, quiet enough to survive that pass.
        //
        // Theirs never does this when the transaction moved anything: `useFallBackUpdateMechanism`
        // sends updated rows to `reloadRows` INSIDE the block and the in-place path is taken only
        // when nothing structural happened. `apply` now makes that choice, which is also the only
        // place that knows whether the diff was structural.
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
        // ⚠️ THESE TWO NOW SPEAK ONLY FOR THE STRANGER ROWS. A chat row's height is answered
        // outright by `heightForRowAt` / `estimatedHeightForRowAt` (see "Row height" below, and his
        // 2026-09-05 report of cells overlapping while swiping through the list) — a delegate answer
        // wins over `rowHeight` in every case, so what is left here is the fallback the `.people`
        // section still self-sizes against.
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
        // The starting value; `viewSafeAreaInsetsDidChange` adds the home indicator to it once the
        // view has one, now that the table runs to the screen's edge.
        t.contentInset.bottom = Self.bottomClearance
        t.verticalScrollIndicatorInsets.bottom = Self.bottomClearance
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
        // ⚠️ AND NOT WHILE ROWS ARE MOVING. This is the one thing left that reaches the table after
        // the transaction closes — theirs touches nothing after `endUpdates` and restores selection
        // by id only on a full reload. It fires in Select mode alone, but there it issues
        // `selectRow`/`deselectRow` against rows UIKit is still animating. Owed and replayed, the
        // same way the content update is.
        guard !isAnimatingRows else { ticksWereDeferred = selected; return }
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
        //
        // ⚠️ THE ROW HEIGHT IS THE SAME KIND OF ANSWER AND HAS TO BE DROPPED HERE TOO. It is cached
        // from the same two fonts, so a text-size change is the one event that can move it — the
        // reference clears their own `conversationCellHeightCache` on a reset for exactly this
        // reason. Cleared BEFORE the reload, or the reload re-reads the stale number it just asked
        // us to forget.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (vc: ChatListTableController, _) in
            vc.chatRowHeight = nil
            vc.tableView.reloadData()
        }
    }

    // ⛔ THE BARS WATCH THIS TABLE — owner, 2026-09-11, with the Calls page held beside this one:
    // "call page is working correct, top header is blur, no border, bottom bar is using the iOS 26
    // blur ... make the chat list like the call page". And, the same hour, "when I do a small
    // scroll the chat list is jumping, at the time it hides the search bar".
    //
    // Both are one missing registration. A navigation bar decides its scroll-edge look, a tab bar
    // decides its floating-pill blur, and a search field decides when to fold away by WATCHING A
    // SCROLL VIEW — the one the page registers with `setContentScrollView(_:for:)`. SwiftUI does
    // that for its own `List`, which is why the Calls page gets all three for free. This table
    // lives in a representable, so nothing registered it: the header could not turn its blur on
    // (the previous fix forced the bar opaque instead, which is the black band he photographed),
    // the pill had nothing to blur, and the search field folded on a heuristic of its own with the
    // inset snapping under the table — the jump.
    //
    // The page the navigation controller consults is the one directly beneath it: the hosting
    // controller SwiftUI made for this screen. Walk up to it and register there; the tab bar
    // controller asks the navigation controller, which asks that same page. Registered on this
    // controller too, in case the page answers by forwarding to its child. Done at both moments
    // the parent chain can complete — `didMove(toParent:)` fires before the page is in the
    // stack, `viewWillAppear` after — and it is idempotent, so twice costs nothing.
    //
    // ⚠️ THIS IS NOT AN OFFSET CORRECTION. See the note above `ChatListCell` for why that shape
    // was tried, shipped and reverted; this gives UIKit the scroll view and lets it do what it does
    // for every other list, instead of doing part of UIKit's job a second time.
    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        registerAsContentScrollView()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        registerAsContentScrollView()
    }

    /// ⛔ THE CLEARANCE GREW BY THE INDICATOR — owner, 2026-09-11, same report as the black strip
    /// under the pill. The page now hands this table the FULL height (`ignoresSafeArea(.container,
    /// edges: .bottom)` at the call site) so its rows run under the floating tab bar and give the
    /// blur something to blur. That moved the table's bottom EDGE down by the home indicator's
    /// height, so his 28 — measured when the edge stopped at the safe area — would leave the last
    /// row 34 points lower than it used to sit, half under the pill.
    ///
    /// Read from the view rather than typed, so it is right on a phone with no indicator as well as
    /// on one with a tall one, and it re-reads whenever that changes.
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        let clearance = Self.bottomClearance + view.safeAreaInsets.bottom
        guard abs(tableView.contentInset.bottom - clearance) > 0.5 else { return }
        tableView.contentInset.bottom = clearance
        tableView.verticalScrollIndicatorInsets.bottom = clearance
    }

    /// His 28, kept as the number it always was — see `viewSafeAreaInsetsDidChange` for what is now
    /// added to it and why.
    static let bottomClearance: CGFloat = 28

    private func registerAsContentScrollView() {
        setContentScrollView(tableView, for: .all)
        var page: UIViewController = self
        while let up = page.parent, !(up is UINavigationController), !(up is UITabBarController) {
            page = up
        }
        if page !== self { page.setContentScrollView(tableView, for: .all) }
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

        // ⚠️ THE IN-PLACE UPDATE STILL HAPPENS ON THE WAY OUT. Most passes through here are not row
        // changes at all — a theme flip, a new preview on a chat that is already at the top, a tick
        // going from one to two — and all of them reach this line with an empty diff. Returning
        // without the refresh is how the list would freeze; that defect is on the record.
        guard !changes.isEmpty || headerChanged else { refreshVisibleContent(); return }

        // ⛔ `.automatic` WHEN ANIMATING, `.none` WHEN NOT — `defaultRowAnimation` in their source is
        // literally `animated ? .automatic : .none`. The old code passed `.automatic` unconditionally
        // and simply never reached here on a non-animated apply, so the constant was never wrong;
        // it is spelled out now because the non-animated path below does reach here.
        let rowAnimation: UITableView.RowAnimation = animated ? .automatic : .none

        let work = {
            // ⛔ A SWIPED ROW THAT IS ABOUT TO BE DELETED LOSES ITS PLATTER FIRST, AND NOT INSIDE THE
            // TRANSACTION — owner, 2026-09-11, with the ghost photographed: swipe a chat, tap
            // Archive, and for a moment the row is drawn AGAIN over the top of the list before it
            // goes. "first time chat is appearing under to chats, after that is going archive."
            //
            // ⚠️ THE LEFT SHIFT IN HIS SCREENSHOT IS THE TELL. The ghost's avatar hangs off the
            // leading edge and its name sits on top of the first row's, which is the swiped cell's
            // own offset — the platter pushes the content left, and this cell still had it. So the
            // thing flying to the wrong place is the row that was under the finger.
            //
            // UIKit was asked to do two things to that one cell in a single transaction: un-swipe it
            // (its content animating back to the right) and delete it (the cell animating out of the
            // list). It composited the two into a cell that travels somewhere neither asked for.
            //
            // ⚠️ THE ANIMATED CLOSE BELOW STAYS, AND IS NOT WHAT WAS WRONG. It was written for the
            // MOVE case — a platter left stranded on the wrong chat when the list re-sorts under it
            // — and it is still right for that. A row that is LEAVING is the one case that does not
            // want its platter animated shut: it wants it gone before the delete begins. After this
            // runs `isEditing` is false, so the clause below simply finds nothing to do.
            if !changes.deletes.isEmpty, self.tableView.isEditing,
               !(self.host?.parent.selecting ?? false) {
                self.tableView.setEditing(false, animated: false)
            }
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
            // ⛔ THEIR `.update` CASE, AND IT BELONGS INSIDE THE TRANSACTION WHENEVER THE
            // TRANSACTION MOVED ANYTHING — their `useFallBackUpdateMechanism`. See the note above
            // `apply` for why this is the last piece of his pin report.
            //
            // Old index paths, because everything in this block is applied against the model as it
            // stood before it opened, and rows that MOVED are excluded: a same-section move is
            // already a delete plus an insert, which rebuilds the row, and the cross-section pin
            // move is the one row their comment says must NOT be reloaded.
            let stale = self.contentChangedOldPaths(old: old, new: new)
            if !stale.isEmpty { self.tableView.reloadRows(at: stale, with: .none) }
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
        // ⛔ THE FLIGHT IS FENCED, AND THIS IS THE PIN REPORT'S LAST PIECE — his fifth, 2026-09-09,
        // off a build that already had the four fidelity decisions AND the in-place update moved out
        // of the caller: "several bugs when I pin or unpin, especially the animation and transition".
        //
        // ⚠️ THE INTERRUPTION HAD MORE THAN ONE DOOR AND ONLY ONE WAS CLOSED. Moving
        // `refreshVisibleContent` off the caller stopped THIS apply from touching cells mid-flight.
        // It did nothing about the NEXT one. `updateUIViewController` runs on every SwiftUI
        // re-render of the parent — a new message on another chat, the theme, the selection, the
        // search field, a repaint we do not control — and the pin's animation lasts about a third of
        // a second, which is a long time for none of that to happen. Each of those arrives with an
        // empty diff, takes the early return, and reaches the in-place update, which hands every
        // visible cell a fresh hosting configuration. A SwiftUI layout pass on rows UIKit is still
        // moving.
        //
        // So the fence is a flag with a real end, not a guess at one: `CATransaction`'s completion
        // runs when the row animation has actually finished. Anything that wanted to refresh while
        // it was up is remembered and done once, afterwards.
        //
        // ⚠️ THIS DOES NOT BREAK THEIR "NOTHING RUNS AFTER THE BLOCK" RULE. That rule is about the
        // instant after `endUpdates()`, where a second table operation lands on top of a flight in
        // progress. This runs after the flight is over, which is the only safe moment there is.
        // ⛔ THE ROWS THAT ARE ABOUT TO TRAVEL ARE REPAINTED FIRST, WHILE NOTHING IS MOVING.
        //
        // ⚠️ HIS "the pin icon appears after the row lands". A `moveRow` carries the cell it already
        // has, so a row crossing between Pinned and Chats arrives still drawn as it was — and the
        // pin glyph then fades in by itself a third of a second later, because the in-place update
        // is fenced until the flight ends. Two motions where theirs has one.
        //
        // Theirs solves it upstream: `applyRowChanges` drops that thread's view-model and cell
        // content from its caches BEFORE issuing the operation, so the cell is rebuilt correct and
        // travels correct. We cannot drop a cache and get a rebuild — our content is assigned to the
        // cell — so the equivalent is to assign it now, in the moment before the transaction opens,
        // when no animation is running and touching a cell is free.
        for m in changes.moves {
            guard let s = ChatListSection(rawValue: m.from.section),
                  let id = old.ids(in: s)[safe: m.from.row],
                  let conv = host?.conversation(id),
                  let cell = tableView.cellForRow(at: m.from) as? ChatListCell,
                  let fresh = host.map({ $0.content(for: conv) })
            else { continue }
            configureChatCell(cell, id: id, content: fresh)
        }

        isAnimatingRows = true
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self else { return }
            self.isAnimatingRows = false
            if self.refreshWasDeferred {
                self.refreshWasDeferred = false
                self.refreshVisibleContent()
            }
            if let owed = self.ticksWereDeferred {
                self.ticksWereDeferred = nil
                self.syncTicks(selected: owed)
            }
        }
        if animated {
            work()
        } else {
            UIView.animate(withDuration: 0) { work() }
        }
        CATransaction.commit()

        // ⛔ AND NOTHING TOUCHES A LIVE CELL AFTERWARDS IF ANYTHING MOVED. When the diff was purely
        // a content change the in-place update is theirs and is the cheap path; when the diff moved
        // rows, the reload above has already done the work inside the transaction and reaching into
        // the cells now would be the second pass all over again.
        if changes.isEmpty { refreshVisibleContent() }
    }

    /// True from the moment a row transaction opens until its animation has actually finished.
    /// Everything that would reach into a live cell asks this first.
    private var isAnimatingRows = false
    /// Something wanted the in-place content update while rows were moving. It is owed once.
    private var refreshWasDeferred = false
    /// The selection a `syncTicks` wanted to apply mid-flight, owed until the flight ends.
    private var ticksWereDeferred: Set<String>?

    /// The rows whose CONTENT changed while their POSITION did not, addressed in the old model.
    ///
    /// A row that moved is deliberately absent: within a section it travels as a delete plus an
    /// insert and is rebuilt on arrival, and across sections it is the pinned row in flight, which
    /// their own comment says does not require reloading. Reloading either would be asking UIKit to
    /// redraw a row it is in the middle of animating.
    private func contentChangedOldPaths(old: ChatListRenderState,
                                        new: ChatListRenderState) -> [IndexPath] {
        guard let host else { return [] }
        var out: [IndexPath] = []
        for s in ChatListSection.allCases where s != .people {
            for id in new.ids(in: s) {
                // ⚠️ `configured[id]` IS NIL FOR EVERY ROW THAT HAS NEVER BEEN DEQUEUED, and
                // without this guard the comparison below is always true for them — so a pin in a
                // long list handed `reloadRows` most of the off-screen index paths above it, inside
                // the same transaction as the flight. Theirs takes its update set from the ids the
                // database reported changed, which can never include a row it has not seen.
                // A row with no cell has nothing to repaint; it will be built correctly when it is
                // first dequeued.
                guard let from = old.indexPath(of: id), let to = new.indexPath(of: id),
                      from == to,
                      let known = configured[id],
                      let conv = host.conversation(id) else { continue }
                if known != host.content(for: conv) { out.append(from) }
            }
        }
        return out
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
        // The fence — see `apply`. A refresh asked for mid-flight is owed, not dropped: the content
        // that prompted it is real, it just may not be painted onto a row that is still moving.
        guard !isAnimatingRows else { refreshWasDeferred = true; return }
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

    // MARK: - Row height

    /// ⛔ A CHAT ROW'S HEIGHT IS ARITHMETIC, NOT A SELF-MEASUREMENT — his report, 2026-09-05, off
    /// build 733: "when swiping through the chats, the text and chat cells overlap each other".
    ///
    /// `rowHeight = .automaticDimension` plus an `estimatedRowHeight` is what caused it. A
    /// self-sizing table lays every row out at the ESTIMATE first and corrects it afterwards, and
    /// inside a `beginUpdates`/`endUpdates` block holding deletes, inserts and a `moveRow` those
    /// corrections land against offsets the same transaction is already moving. A pin re-sorts the
    /// list, so the pin is the action that shows it worst: two rows correcting toward the same y and
    /// drawing on top of each other.
    ///
    /// ⛔ THIS FILE HAS NOW CARRIED TWO WRONG CLAIMS ABOUT THEIR ROW HEIGHTS. Here is the checked
    /// one, and how it was checked, so a third is not written.
    ///
    /// ⚠️ THE FIRST WRONG CLAIM said their `heightForRowAt` measures conversation rows through a
    /// `measureConversationCell` with a one-value cache. ⚠️ THE SECOND WRONG CLAIM, written on
    /// 2026-09-09 to "correct" the first, said their data source has no `heightForRowAt` at all and
    /// that their rows self-size. **The first was right and the second was written from a TRUNCATED
    /// FETCH** — `gh api ... --raw` returned 431 lines of a 997-line file and the reader drew a
    /// conclusion from what was in front of them. Check `wc -l` against the API's own byte count
    /// before believing any fetch of their source.
    ///
    /// WHAT THEY ACTUALLY DO, from the complete file: `CLVTableDataSource.heightForRowAt` returns
    /// `automaticDimension` for their non-conversation rows only, and `measureConversationCell` for
    /// the pinned and unpinned sections. That measures ONE cell and stores the answer in a single
    /// `CGFloat?` on the view state, handing the same number to every conversation row. The
    /// `rowHeight = .automaticDimension` and `estimatedRowHeight = 60` on their view controller are
    /// the fallback their other sections use. They implement no `estimatedHeightForRowAt`.
    ///
    /// ⛔ SO OURS IS THE SAME DESIGN, ARRIVED AT DIFFERENTLY: one number for every chat row, cached,
    /// invalidated only by the thing that can move it. Theirs measures it once; ours computes it,
    /// because a measurement needs a cache that can go stale behind you and arithmetic does not.
    ///
    /// We do implement `estimatedHeightForRowAt`, and that is a real and deliberate addition: our
    /// row is a SwiftUI `ChatRow` inside a `UIHostingConfiguration`, which reports its size back
    /// asynchronously, so leaving the estimate to the table's own 80 would let a first layout land
    /// at the wrong height inside a transaction that is already moving rows. That is his overlap.
    ///
    /// ⚠️ ONE NUMBER FOR EVERY CHAT ROW IS RIGHT HERE FOR THE SAME REASON IT IS RIGHT FOR THEM: the height
    /// cannot vary with the content. `ChatRow` reserves exactly two preview lines whatever the
    /// preview turns out to be — the hidden `Text(" \n ")` in the same style — so nothing a message
    /// can contain moves it, and only the phone's text size does. So the number is computed rather
    /// than measured, exactly as `ChatListSectionHeader.height(for:)` already computes the heading's,
    /// and for the same reason: a measurement needs a cache that can go stale behind you, and
    /// arithmetic does not.
    ///
    /// The two columns, both sets of numbers taken from `ChatRow`'s own body:
    ///
    ///     avatar column = 56 + 12 + 12                     (`avatarStackConfig`, vMargin 12) = 80
    ///     text column   = 7 + headline + 1 + 2 × subheadline + 9
    ///                     ↑   ↑         ↑   ↑                 ↑
    ///                     │   the name  │   the two reserved preview lines
    ///                     │             the VStack's spacing of 1
    ///                     `vStackConfig` margins — 7 above and 9 below, asymmetrical on purpose
    ///
    /// The row is the taller of the two: 80 at the default text size, and the text column above it.
    /// Each line height is `ceil`ed before it is added, so the sum can never land a fraction of a
    /// point short of the label it has to hold.
    private static let avatarSide: CGFloat = 56
    private static let avatarVMargin: CGFloat = 12
    private static let textTopMargin: CGFloat = 7
    private static let textBottomMargin: CGFloat = 9
    private static let nameToPreviewSpacing: CGFloat = 1
    private static let reservedPreviewLines: CGFloat = 2

    /// The cached answer. Cleared on a text-size change and nowhere else, because nothing else can
    /// move it. Named after their `conversationCellHeightCache` only by analogy — see the correction
    /// above; theirs is not a data-source height.
    private var chatRowHeight: CGFloat?

    private func conversationRowHeight() -> CGFloat {
        if let h = chatRowHeight { return h }
        let headline = UIFont.preferredFont(forTextStyle: .headline, compatibleWith: traitCollection)
        let subheadline = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traitCollection)
        let avatarColumn = Self.avatarSide + Self.avatarVMargin * 2
        let textColumn = Self.textTopMargin
            + ceil(headline.lineHeight)
            + Self.nameToPreviewSpacing
            + Self.reservedPreviewLines * ceil(subheadline.lineHeight)
            + Self.textBottomMargin
        let h = max(avatarColumn, textColumn)
        chatRowHeight = h
        return h
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        // ⚠️ A STRANGER'S ROW STAYS SELF-SIZING, deliberately. It is a different cell holding a view
        // this file does not own (`personRow`, handed in from the screen), so its height is not ours
        // to compute — and it is the one section that never takes part in the pin transaction: a
        // person from the search is inserted and removed with the query and never moves between
        // sections, so the estimate-then-correct pass it costs cannot collide with anything.
        guard ChatListSection(rawValue: indexPath.section) != .people else {
            return UITableView.automaticDimension
        }
        return conversationRowHeight()
    }

    /// ⚠️ THE ESTIMATE HAS TO BE THE SAME NUMBER, or the bug comes back for the rows that are off
    /// screen. With a non-zero `estimatedRowHeight` set on the table, UIKit asks `heightForRowAt`
    /// only for the rows it is about to show and uses the estimate for everything else — so a row
    /// that scrolls or animates into view would still arrive at 80 and then correct. Answering with
    /// the real height here means there is nothing to correct for a chat row, ever.
    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        guard ChatListSection(rawValue: indexPath.section) != .people else { return 80 }
        return conversationRowHeight()
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
        read.image = ChatListIcon.symbol(c.hasUnreadMark(p.me) ? "envelope.open.fill" : "envelope.badge.fill")
        read.backgroundColor = .systemBlue

        let pinned = c.isPinned(p.me)
        let pin = UIContextualAction(style: .normal, title: pinned ? "Unpin" : "Pin") { _, _, done in
            p.onTogglePin(c); done(true)
        }
        // ⛔ OUR OWN DRAWING FOR PIN, NOT `pin.fill` — it is the mark he sent for this swipe, and the
        // SwiftUI list used it here (`MenuIcon("ic_pin_menu")`). The port had quietly substituted the
        // SF Symbol, which is the same idea drawn by somebody else.
        //
        // ⛔ AND IT HAS TO BE GIVEN A SIZE, WHICH IS HIS 2026-09-05 REPORT: the pin drew far bigger
        // than the envelope on the platter beside it. `ic_pin_menu.svg` is authored at 64pt and a
        // `UIContextualAction` draws the image it is handed at the size it is handed, while the
        // symbols around it arrive already sized at the body text style. `ChatListIcon` redraws the
        // asset into the symbols' own measured box and re-marks it as a template, which is also what
        // makes the platter tint it white — an asset left in its own colours is a black pin on
        // orange, and black on black in the dark.
        pin.image = pinned ? ChatListIcon.symbol("pin.slash.fill")
                           : ChatListIcon.asset("ic_pin_menu")
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
        //
        // ⚠️ THROUGH THE SAME SIZER AS THE PIN, THOUGH HE DID NOT REPORT THIS ONE. Its artwork is
        // authored at 24 rather than 64, which is near enough to a symbol that nobody has noticed it
        // — but "near enough" and "the same" are different, and now that the pin beside it is exact
        // this one would be the odd platter. Nothing else about it changes.
        archive.image = ChatListIcon.asset("ic_archive_fill")
        archive.backgroundColor = .systemGray

        // ⚠️ `.destructive` ON DELETE, AND IT IS NOT ONLY THE COLOUR. A destructive contextual
        // action is the one a FULL swipe performs, and it is the one UIKit animates the row out on.
        // Ours was destructive too; the difference is that it now sits where theirs does.
        let del = UIContextualAction(style: .destructive, title: "Delete") { _, _, done in
            p.onDelete(c); done(true)
        }
        del.image = ChatListIcon.symbol("trash.fill")

        let mute = UIContextualAction(style: .normal, title: "Mute") { _, _, done in
            p.onMute(c); done(true)
        }
        mute.image = ChatListIcon.symbol("bell.slash.fill")
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

    /// ⛔ THE ROW LETS GO OF ITS HIGHLIGHT WHEN THE MENU CLOSES — owner, 2026-09-11: "when I long
    /// press, the highlight is locked, never gone".
    ///
    /// ⚠️ NOTHING WAS CLEARING IT. A long press highlights the row, UIKit raises the menu, and this
    /// table implemented the configuration and neither of the two interaction callbacks — so when
    /// the menu was dismissed the cell was never told to re-resolve. `updateConfiguration` is only
    /// asked when the state MOVES, and a highlight that UIKit stops tracking without a touch-up
    /// leaves it exactly where it was: a grey row, for the rest of the visit, with no gesture that
    /// puts it back. That is the full-width grey band in his screenshot.
    ///
    /// ⚠️ IN THE ANIMATOR'S COMPLETION, NOT ON THE CALL ITSELF. The dismissal is animated and the
    /// cell is still part of it while it runs; asking for a fresh configuration mid-flight would
    /// clear the grey under the preview as it flies home, which is a second visible glitch in place
    /// of the first. `addCompletion` is the moment the menu is really gone.
    ///
    /// ⚠️ EVERY VISIBLE CELL, NOT THE ONE THE MENU CAME FROM. The identifier names a CHAT, and this
    /// list re-sorts under an open menu whenever a message arrives, so the row that was pressed may
    /// not be at that index any more — and a stuck highlight is cheap to clear everywhere and
    /// expensive to miss.
    ///
    /// ⛔ CLEAR THE STATE, DO NOT RE-ASK FOR IT. THIS IS THE SECOND ATTEMPT AND THE FIRST ONE'S
    /// MISTAKE IS THE WHOLE LESSON — he reported the same grey band again on 2026-09-11.
    ///
    /// That attempt called `setNeedsUpdateConfiguration()` here, on the reasoning that the cell had
    /// never been asked to re-resolve. It HAD been asked, by this very line, and it answered with
    /// the same grey — because `setNeedsUpdateConfiguration` only makes UIKit ask the cell what it
    /// looks like in the state it is in, and the stuck state IS `isHighlighted == true`. Asking a
    /// question again does not change its answer. `updateConfiguration(using:)` faithfully painted
    /// the highlight it was told the row still had.
    ///
    /// `setHighlighted(false, …)` changes the fact instead of re-reading it, and the configuration
    /// update follows on its own because the state actually moved. `setSelected` goes with it for
    /// the dismissal that leaves a row selected rather than highlighted; that one paints nothing
    /// today, but it is the same stuck-state family and free to clear here.
    func tableView(_ tableView: UITableView,
                   willEndContextMenuInteraction configuration: UIContextMenuConfiguration,
                   animator: (any UIContextMenuInteractionAnimating)?) {
        // ⚠️ THE TYPE IS STATED AND THE OPTIONAL IS UNWRAPPED BY A `guard`, NOT BY CHAINING.
        // `tableView?.visibleCells.forEach { … }` makes the closure's result `()?` — an OPTIONAL
        // Void — so the whole thing infers as `() -> ()?` and will not convert to the `() -> Void`
        // that `addCompletion` wants. It reads as a Void body and is not one.
        let clear: () -> Void = { [weak tableView] in
            guard let tableView else { return }
            for cell in tableView.visibleCells {
                cell.setHighlighted(false, animated: false)
                cell.setSelected(false, animated: false)
            }
        }
        // The timing above was never the problem and is kept: in the completion when there is an
        // animator, because clearing mid-flight would take the grey out from under the preview as it
        // flies home, and immediately when there is none to wait for.
        if let animator { animator.addCompletion(clear) } else { clear() }
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

/// ⛔ ONE SIZE FOR EVERY ICON IN THE CHAT LIST'S MENU AND ITS SWIPE PLATTERS — two of his reports on
/// 2026-09-05, off build 733: the long-press menu's Unread / Mute / Pin / Archive / Delete "are
/// different sizes", and the swipe-to-pin glyph is too big on the orange platter.
///
/// ⛔ THE CAUSE IS MEASURABLE AND IT IS NOT SUBTLE. The menu and the swipes draw two kinds of image:
/// an SF Symbol, and one of our own drawings from the asset catalogue (the `ic_` convention this
/// file and `ChatRow` already use). A symbol arrives ALREADY SIZED — it is a glyph rendered for a
/// point size, and `UIImage(systemName:)` with no configuration comes out at the body text style,
/// roughly a 20pt box. Our drawings arrive at whatever the artwork was authored at, and three of the
/// four are authored at 64:
///
///     ic_pin_menu.svg      width="64" height="64"     (the menu's Pin, and the swipe's)
///     ic_menu_unread.svg   width="64" height="64"     (the menu's Unread)
///     ic_archive.svg       width="64" height="64"     (the menu's Archive)
///     ic_archive_fill.svg  width="24" height="24"     (the swipe's Archive — near enough, and it is
///                                                      the one platter he did not report)
///
/// Neither `UIMenu` nor `UIContextualAction` sizes the image it is handed. So a 64pt drawing is drawn
/// at 64 beside a 20pt glyph, which is the whole of both reports.
///
/// ⚠️ THE BOX IS MEASURED OFF THE SYMBOLS, NOT CHOSEN. Picking a number here would be a fourth size
/// to keep in step with Dynamic Type by hand. Instead the symbols are asked what they came out at,
/// at the configuration they are actually built with, and the drawings are redrawn to fit that. The
/// tallest of them wins, because a menu row's icons read as matching when their HEIGHTS agree —
/// their widths differ from each other anyway (`bell.slash` is wider than `trash`).
///
/// ⚠️ AND IT IS A COMPUTED SIZE, NOT A `static let`. A stored one is resolved once and frozen for the
/// life of the process, so the icons would keep the size they had when the first menu opened after a
/// change to the phone's text size. Building four small images when a menu opens costs nothing.
enum ChatListIcon {
    /// The symbols' own size, stated rather than left implicit. `.body` is what `UIImage(systemName:)`
    /// already resolves to with no configuration — naming it is what lets the drawings below be
    /// measured against the same thing instead of against a guess.
    static var configuration: UIImage.SymbolConfiguration { .init(textStyle: .body) }

    /// The square our own drawings are redrawn into: the tallest symbol the chat list actually shows,
    /// at that configuration. The fallback is the body font's own line height, which is the same
    /// answer by a different route and only matters if a symbol name is ever mistyped away.
    static var side: CGFloat {
        let heights = ["envelope.open", "bell.slash", "pin.slash", "trash"]
            .compactMap { UIImage(systemName: $0, withConfiguration: configuration)?.size.height }
        return ceil(heights.max() ?? UIFont.preferredFont(forTextStyle: .body).lineHeight)
    }

    /// An SF Symbol at that size. Applying the configuration explicitly rather than relying on the
    /// default is what makes the yardstick above honest: the things being measured and the things
    /// being drawn are built the same way.
    static func symbol(_ name: String) -> UIImage? {
        UIImage(systemName: name, withConfiguration: configuration)
    }

    /// One of our own drawings, redrawn to fit the symbols' box and returned as a template so the
    /// menu tints it with the row's colour and the swipe platter tints it white — an asset left in
    /// its own colours comes out as a black pin on orange, and as black-on-black in dark mode.
    ///
    /// ⚠️ ASPECT-FIT, NOT A SQUARE STRETCH. Every one of these is authored square today, so the two
    /// are the same answer; fitting is what keeps it the same answer if a future drawing is not.
    ///
    /// ⚠️ `.alwaysOriginal` GOING IN, `.alwaysTemplate` COMING OUT. The catalogue already marks these
    /// as template artwork, and drawing a template image into a context is not defined to reproduce
    /// its pixels — it is defined to stencil them. Taking the original guarantees the redraw copies
    /// the drawing, and the result is re-marked so nothing downstream loses the tinting.
    ///
    /// The redraw is from the vector: all four assets carry `preserves-vector-representation`, so
    /// scaling 64 down to 20 costs no sharpness the way a resampled bitmap would.
    static func asset(_ name: String) -> UIImage? {
        guard let art = UIImage(named: name)?.withRenderingMode(.alwaysOriginal),
              art.size.width > 0, art.size.height > 0 else { return nil }
        let box = side
        let scale = min(box / art.size.width, box / art.size.height)
        let fitted = CGSize(width: art.size.width * scale, height: art.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        return UIGraphicsImageRenderer(size: fitted, format: format)
            .image { _ in art.draw(in: CGRect(origin: .zero, size: fitted)) }
            .withRenderingMode(.alwaysTemplate)
    }
}

/// A cell that is nothing but a host for the SwiftUI row.
// ⛔ DO NOT COMPENSATE `contentOffset` FROM `adjustedContentInsetDidChange` HERE. It was tried on
// 2026-09-11 for his "the chat list jumps when I open and close search", shipped in build 736, and
// it did NOT fix the jump — he reported it again, with a new symptom beside it (the search field
// left drawing as an empty grey plate while the list settled).
//
// The reasoning was sound on its own terms: `.searchable` puts its field in the navigation bar, so
// the safe area above this table grows and shrinks, and a scroll view answers that by moving
// `adjustedContentInset` while leaving `contentOffset` alone. What it missed is that UIKit ALREADY
// compensates part of that itself during the search transition — so subtracting the delta a second
// time doubles the movement instead of cancelling it, and lands mid-animation where the search bar
// is still being laid out.
//
// Whatever the real cause is, it is not a missing offset correction, and a second guess of the same
// shape is not worth another build. Reverted whole rather than tuned.

private final class ChatListCell: UITableViewCell {
    static let reuseId = "ChatListCell"
    /// A stranger's row is a different view tree in the same cell class, so it gets its own queue.
    /// Mixing them under one identifier is how a recycled cell ends up holding the wrong hosting
    /// configuration for a frame.
    static let personReuseId = "ChatListPersonCell"

    /// ⛔ THE CELL'S BACKGROUND IS DECIDED HERE, ON EVERY STATE CHANGE, AND NOWHERE ELSE — his
    /// report, 2026-09-05 off build 733: after swiping a row, the row keeps a grey or coloured
    /// remnant instead of going back to how it looked before the swipe.
    ///
    /// ⚠️ TWO THINGS WERE PAINTING THIS CELL AND NEITHER WAS ASKED AGAIN WHEN THE SWIPE CLOSED.
    /// `cellForRowAt` assigns `backgroundColor = .clear` ONCE, at dequeue — that is the line that
    /// took the grouped style's raised-card grey off the list — and `selectionStyle = .default`
    /// leaves UIKit free to lay its own selected/highlighted fill over the top. But a cell carrying a
    /// content configuration also carries a BACKGROUND configuration, and it re-resolves that one
    /// against the cell's `UICellConfigurationState` every time the state moves. Swiping IS a state:
    /// `isSwiped` is part of it. So the swipe re-resolved a background over the clear one set at
    /// dequeue, and what the row was left wearing is whatever state it was left in.
    ///
    /// ⚠️ A ONE-OFF RESET — in `prepareForReuse`, or in the swipe's completion handler — WOULD BE THE
    /// WRONG SHAPE, and it is worth saying why rather than just doing this instead. It repairs the
    /// paths somebody thought of and leaves every one they did not: a swipe cancelled half open, a
    /// platter closed by scrolling away, a row that re-sorts out from under an open swipe because a
    /// message arrived. `updateConfiguration(using:)` is UIKit asking the cell what it looks like in
    /// the state it is ACTUALLY in, which covers all of those and anything added later.
    ///
    /// The look is unchanged where he has not complained about it: clear at rest, the system's own
    /// press fill while a finger is down. `selectionStyle` stays `.default` deliberately — a
    /// background configuration replaces `selectedBackgroundView` outright, so it no longer draws
    /// anything, but leaving it is what keeps UIKit delivering the highlighted state at all.
    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        var background = UIBackgroundConfiguration.clear()
        // ⚠️ HIGHLIGHTED ONLY, AND NEVER WHILE SWIPED. Out of Select mode a SELECTED row is a row on
        // its way into a chat and `didSelectRowAt` deselects it in the same breath; inside Select
        // mode the mark is the tick, and grey behind it would be a second answer to a question the
        // circle already answers. While swiped the row must stay clear so the platter's colour is
        // never seen through it.
        if state.isHighlighted && !state.isSwiped {
            // The system's own press fill, resolved for this state rather than picked by eye, so it
            // is right in both themes and stays right if Apple changes it.
            background.backgroundColor = UIBackgroundConfiguration.listPlainCell()
                .updated(for: state).backgroundColor ?? .systemFill
        }
        // ⛔ THE SWIPED ROW WEARS A GREY PLATE — owner, 2026-09-11, with Messages beside it: "when I
        // swipe left or right there is now no grey, please make the Apple grey highlight like image
        // 2". It is the same `isSwiped` state the clause above deliberately keeps CLEAR, and the two
        // are not in conflict: that one is about the PRESS fill, which must not sit under a half-open
        // platter, and this is the plate the row itself slides on.
        //
        // ⚠️ THIS IS NOT A RETURN OF THE 2026-09-05 REMNANT. That bug was a background resolved for
        // one state and never re-asked when the swipe closed; this is resolved by the same
        // `updateConfiguration` pass as everything else, so it goes when `isSwiped` goes. The reason
        // the reset lives here and not in a completion handler is written above and still holds.
        //
        // ⚠️ THE TWO NUMBERS ARE MEASURED OFF HIS SCREENSHOT, not read from a system API, because
        // there is no system background configuration for a swiped row to resolve. The radius is
        // about a quarter of the row's height in his reference, and the plate bleeds off the leading
        // edge rather than being inset there — it is sliding out from under the screen edge, so an
        // inset would draw a corner in mid-air.
        // ⛔ AND IT IS GONE AGAIN — owner, 2026-09-11, hours later and with the swipe photographed
        // mid-open: "when I start swipe I see also grey highlights, please use native Apple not
        // custom, and also Apple rounded corners ... now it looks like under the chat height".
        //
        // ⚠️ HE HAS REVERSED HIS OWN ASK AND BOTH READINGS WERE FAIR. The note above is his, from
        // this morning, with a reference screenshot; what that reference actually showed was the
        // system's own row treatment, and a hand-drawn plate is not that. These two lines were the
        // only thing on this screen the system did not draw: a colour and an 18pt radius measured
        // off a picture, which is what "custom" means and is exactly what he is now pointing at —
        // the plate's corner floats inside the row's height, so the row looks shorter than its
        // neighbours the moment a swipe starts.
        //
        // ⚠️ THE BUTTONS THEMSELVES WERE ALWAYS APPLE'S. They are `UIContextualAction`s in a
        // `UISwipeActionsConfiguration` (see the two delegate methods above) — the circles with
        // labels underneath are how iOS 26 draws that, not a style of ours, and there is no API to
        // ask for the older pill shape. Nothing to change there; deleting the plate is the whole of
        // what was ours.
        backgroundConfiguration = background
    }
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
