import SwiftUI
import UIKit

// ⛔ THE CHAT LIST'S SEARCH IS ITS OWN PAGE NOW — owner, 2026-09-09, with a screenshot of ours:
// "When I click search button, Chatlist page and search page they are different, because search page
// has Recent … plz search Username and group … also search page make it uikit".
//
// What he photographed: tapping the search field left the chat list exactly where it was — Pinned
// and Chats headings, every row — with a keyboard drawn over the bottom half of it. The reference
// app never does that. Its search field belongs to a `UISearchController` whose
// `searchResultsController` is a SEPARATE view controller with its OWN table, and activating the
// field puts that controller over the inbox. Focus is the boundary between two pages, not a filter
// applied to one.
//
// This file is that second page. `ChatSearchPage` is shown by the chat list as an overlay for
// exactly as long as `\.isSearching` is true (see `chatSearchOverlay` in MainShell), which is the
// SwiftUI spelling of the same arrangement.
//
// ⚠️ TWO REFERENCES ARE MIXED HERE ON PURPOSE, AND ONLY ONE OF THEM COULD BE READ FROM SOURCE.
// The section list, their order and the empty-query behaviour below come from the reference app's
// own `ConversationSearchViewController`, read on 2026-09-09. **Recent does not exist in it at
// all** — its search page is blank until you type. Recent is from the other mainstream messenger he
// named, whose source we cannot read, so what is built here is HIS description of it and nothing
// more: the people and chats he has opened from search before, newest first, capped, clearable.
// Nothing about it is claimed to be a port.

// MARK: - The boundary between the two pages

/// ⛔ FOCUS IS THE BOUNDARY. Their `UISearchController` swaps its `searchResultsController` in the
/// moment the field becomes active; `\.isSearching` is the same fact, and this view is the only
/// thing in the app that reads it.
///
/// ⚠️ A VIEW OF ITS OWN RATHER THAN A BRANCH IN THE CHAT LIST'S BODY, for two reasons.
/// `\.isSearching` is only readable from INSIDE the `.searchable` scope, so it has to be a view
/// placed there. And the chat list's body is one of the two in this app the type-checker has given
/// up on before ("unable to type-check this expression in reasonable time") — one initialiser at the
/// call site is what it costs there instead of a conditional and nine arguments.
struct ChatSearchOverlay: View {
    let query: String
    let me: String
    let dark: Bool
    var searching: Bool
    var chats: () -> [Conversation]
    var people: () -> [UserProfile]
    var personRow: (UserProfile) -> AnyView
    var onOpenChat: (Conversation) -> Void
    var onOpenPerson: (UserProfile) -> Void

    @Environment(\.isSearching) private var isSearching

    /// ⚠️ SPELLED OUT, NOT SYNTHESISED. A single PRIVATE stored property — the environment read
    /// above — makes Swift's memberwise initialiser private too, and the call site in another file
    /// then cannot see it. That has cost this app a CI round before; it is in the build notes.
    init(query: String, me: String, dark: Bool, searching: Bool,
         chats: @escaping () -> [Conversation],
         people: @escaping () -> [UserProfile],
         personRow: @escaping (UserProfile) -> AnyView,
         onOpenChat: @escaping (Conversation) -> Void,
         onOpenPerson: @escaping (UserProfile) -> Void) {
        self.query = query
        self.me = me
        self.dark = dark
        self.searching = searching
        self.chats = chats
        self.people = people
        self.personRow = personRow
        self.onOpenChat = onOpenChat
        self.onOpenPerson = onOpenPerson
    }

    var body: some View {
        if isSearching {
            ChatSearchPage(query: query, me: me, dark: dark, searching: searching,
                           chats: chats, people: people, personRow: personRow,
                           onOpenChat: onOpenChat, onOpenPerson: onOpenPerson)
        }
    }
}

// MARK: - Recent

/// ⛔ RECENT, AND IT IS LOCAL — his ask, and there is no backend collection behind it. What you have
/// searched for is a list of who you are interested in; it belongs on the phone that did the
/// searching and nowhere else. `UserDefaults`, the same door `ContactNames` and `Drafts` use for
/// their own private-to-this-device state.
///
/// ⚠️ KEYED BY ACCOUNT. The key carries the signed-in uid, so signing out and into another account
/// on the same phone shows that account's Recent and never the previous one's. `syncAccount` is
/// what notices the change; it is called from the page's `onAppear` and before every write, never
/// from a getter — writing `entries` while a view is reading it in its body is a runtime complaint.
///
/// ⚠️ `@Observable`, not `ObservableObject`, like every other store a view reads in this app.
@Observable final class RecentSearches {
    static let shared = RecentSearches()

    enum Kind: String, Equatable { case chat, person }

    struct Entry: Identifiable, Equatable {
        let kind: Kind
        /// A conversation id for `.chat`, a uid for `.person`.
        let key: String
        /// What the row said when it was tapped. Re-read live where the app still knows better — a
        /// recent CHAT is drawn from the live conversation, so this is only the fallback name.
        let title: String
        /// The username, for a person. Empty for a chat.
        let handle: String
        var id: String { "\(kind.rawValue):\(key)" }
    }

    /// ⛔ THE CAP IS OURS AND IT IS ONE LINE. Twenty is a list you can still scan; the reference app
    /// has no cap to copy because it has no Recent. Pruning is the whole story of this store: an
    /// entry that is recorded again MOVES to the front rather than appearing twice, and the tail
    /// past this number is dropped on every write. There is no age rule — a name you searched for
    /// once a year ago is still the last thing you searched for, and the Clear button is the answer
    /// to "I do not want this remembered".
    static let cap = 20

    private(set) var entries: [Entry] = []
    /// The account `entries` was loaded for. Empty before the first load.
    private var account = ""

    /// ⚠️ LOADED HERE, NOT ON THE PAGE'S `onAppear`, AND THAT IS ABOUT ONE FRAME. `onAppear` fires
    /// AFTER the first body pass, so a store that waited for it would hand the first render an empty
    /// list — and an empty Recent draws the "nothing searched yet" state. The whole list would flash
    /// through it. Nothing observes this object while its own initialiser runs, so loading here is
    /// the one place a write is free.
    private init() { syncAccount() }

    /// Re-read for whoever is signed in NOW. Cheap and idempotent; the page calls it every time it
    /// appears so a sign-out between two openings cannot leave the previous account's list on screen.
    func start() { syncAccount() }

    /// ⚠️ THE `twin` ARGUMENT IS A DE-DUPLICATION, AND WITHOUT IT ONE PERSON APPEARS TWICE.
    /// Opening somebody from the People section is what CREATES the chat with them, so the next
    /// search finds them under Chats — record that and Recent holds two rows for one human, one
    /// saying their username and one showing a conversation. Each kind names the other's id so the
    /// newer row replaces the older instead of joining it.
    func record(chat: Conversation, me: String) {
        // ⚠️ `otherUid` RETURNS A PLAIN STRING AND ANSWERS "" FOR A GROUP, not nil. Tested for
        // emptiness rather than unwrapped, or a group's twin would be the id "person:".
        let other = chat.isGroup ? "" : chat.otherUid(me)
        let twin = other.isEmpty ? nil : "\(Kind.person.rawValue):\(other)"
        remember(Entry(kind: .chat, key: chat.id, title: chat.displayName(me), handle: ""), twin: twin)
    }

    func record(person: UserProfile, me: String) {
        let twin = me.isEmpty ? nil : "\(Kind.chat.rawValue):\(ChatService.convId(me, person.id))"
        remember(Entry(kind: .person, key: person.id,
                       title: person.name.isEmpty ? person.handle : person.name,
                       handle: person.handle),
                 twin: twin)
    }

    /// Everything, at once. There is no per-row delete: the section is a convenience, and a
    /// convenience with a management screen is not one.
    func clear() {
        syncAccount()
        entries = []
        persist()
    }

    private func remember(_ e: Entry, twin: String?) {
        syncAccount()
        // Recorded again = MOVED, never duplicated — and the same for the other kind's row for the
        // same person (see `record(chat:me:)`).
        var next = entries.filter { $0.id != e.id && $0.id != twin }
        next.insert(e, at: 0)
        if next.count > Self.cap { next = Array(next.prefix(Self.cap)) }
        entries = next
        persist()
    }

    private func syncAccount() {
        let uid = AuthService.shared.uid ?? ""
        guard uid != account else { return }
        account = uid
        entries = Self.load(for: uid)
    }

    private static func key(for uid: String) -> String { "recentSearches.v1.\(uid)" }

    private static func load(for uid: String) -> [Entry] {
        guard !uid.isEmpty,
              let raw = UserDefaults.standard.array(forKey: key(for: uid)) as? [[String: String]]
        else { return [] }
        return raw.compactMap { d in
            guard let k = d["k"], let kind = Kind(rawValue: k),
                  let key = d["i"], !key.isEmpty else { return nil }
            return Entry(kind: kind, key: key, title: d["t"] ?? "", handle: d["h"] ?? "")
        }
    }

    private func persist() {
        guard !account.isEmpty else { return }
        let raw = entries.map { ["k": $0.kind.rawValue, "i": $0.key, "t": $0.title, "h": $0.handle] }
        UserDefaults.standard.set(raw, forKey: Self.key(for: account))
    }
}

// MARK: - The page's model

/// One row of the search page. Deliberately just a KIND and a KEY: the row's content is looked up
/// live when the cell is built, so a row never carries a frozen copy of a conversation.
struct SearchPageRow: Identifiable, Equatable {
    enum Kind: String, CaseIterable, Equatable { case chat, group, person, recentChat, recentPerson }
    let kind: Kind
    /// Conversation id for a chat or a group, uid for a person.
    let key: String
    var id: String { "\(kind.rawValue):\(key)" }
}

/// A labelled run of rows. `title` nil collapses the heading the way the chat list's does.
struct SearchPageSection: Equatable {
    var title: String?
    /// Only Recent draws the Clear control beside its heading.
    var showsClear: Bool = false
    var rows: [SearchPageRow] = []
}

// MARK: - The page

/// ⛔ WHAT EACH SECTION HOLDS, AND WHY IN THIS ORDER.
///
/// Typed query, from their `SearchSection` enum (`contactThreads`, `groupThreads`, `contacts`,
/// `messages`) in that declared order, and their own comment on why chats come before everything:
/// "we want to give priority to chat and contact results above message results … if I search for a
/// string like 'Matthew' the first results will be the chat with my contact named 'Matthew'".
///   1. Chats   — your one-to-one conversations whose name matches
///   2. Groups  — group conversations whose name matches
///   3. People  — the one account that OWNS the username you typed, if it is not already above
///
/// ⚠️ THEIR FOURTH SECTION, MESSAGES, IS NOT HERE, and that is a gap rather than a decision I am
/// hiding: he asked for username and group, the chat list's search has never searched message text
/// (`searchMatches` matches the name only, because previews are ciphertext until a row decrypts
/// them), and the app's message-text search already exists on its own screen as `ChatSearchView`.
///
/// Empty query: Recent, and nothing else. Theirs shows a blank page with a spinner on an empty
/// query — `EmptySearchResultCell.configure` starts an activity indicator when `searchText.isEmpty`
/// — which is exactly the page he is asking us to replace.
struct ChatSearchPage: View {
    /// Already trimmed by the caller (`searchTrimmed`), so this page never re-answers that question.
    let query: String
    let me: String
    let dark: Bool
    /// True while the username lookup is in flight — suppresses "no results" for the moment between
    /// the last keystroke and the server's answer.
    var searching: Bool

    /// ⚠️ CLOSURES, NOT ARRAYS, AND THE REASON IS THIS FILE'S NEIGHBOUR. `visible` filters and sorts
    /// every conversation on each read and `newPeople` reads it again; the chat list's own note says
    /// so. Handed as arrays they would be computed on every pass of the chat list's body, search
    /// active or not. Handed as closures they are computed only when this page actually draws
    /// results — which is only while the field is focused AND something has been typed.
    var chats: () -> [Conversation]
    var people: () -> [UserProfile]
    /// The stranger row itself, still built by the chat list — the same handover `ChatListTable`
    /// already uses, and for the same reason: `newPersonRow` stays the single place that row is
    /// described, privacy rules included.
    var personRow: (UserProfile) -> AnyView

    var onOpenChat: (Conversation) -> Void
    var onOpenPerson: (UserProfile) -> Void

    @Environment(\.dismissSearch) private var dismissSearch
    private var repo = ConversationsRepository.shared
    private var recents = RecentSearches.shared

    init(query: String, me: String, dark: Bool, searching: Bool,
         chats: @escaping () -> [Conversation],
         people: @escaping () -> [UserProfile],
         personRow: @escaping (UserProfile) -> AnyView,
         onOpenChat: @escaping (Conversation) -> Void,
         onOpenPerson: @escaping (UserProfile) -> Void) {
        self.query = query
        self.me = me
        self.dark = dark
        self.searching = searching
        self.chats = chats
        self.people = people
        self.personRow = personRow
        self.onOpenChat = onOpenChat
        self.onOpenPerson = onOpenPerson
    }

    var body: some View {
        let model = buildModel()
        ZStack {
            // ⚠️ OPAQUE, AND THAT IS THE WHOLE POINT OF THE PAGE. A translucent overlay would be the
            // chat list with a keyboard over it again, which is the screenshot he sent.
            Color(uiColor: .systemBackground).ignoresSafeArea()

            SearchResultsTable(
                sections: model.sections,
                // Erased at the handover, because the table draws four unrelated row types through
                // one closure — see `SearchResultsTable.content`.
                content: { row in AnyView(content(row, model)) },
                onSelect: { row in select(row, model) },
                onClearRecent: { recents.clear() })

            if model.isEmpty { emptyState }
        }
        .onAppear { recents.start() }
    }

    // MARK: Sections

    /// Everything the table needs for one pass: the sections, plus the lookup tables its cells read.
    private struct PageModel {
        var sections: [SearchPageSection] = []
        var chats: [String: Conversation] = [:]
        var people: [String: UserProfile] = [:]
        var recents: [String: RecentSearches.Entry] = [:]
        var isEmpty: Bool { sections.allSatisfy { $0.rows.isEmpty } }
    }

    private func buildModel() -> PageModel {
        query.isEmpty ? recentModel() : resultsModel()
    }

    private func recentModel() -> PageModel {
        var m = PageModel()
        var rows: [SearchPageRow] = []
        // A conversation lookup for the whole list, once, rather than a scan per entry.
        var byId: [String: Conversation] = [:]
        // A pending request is not a chat (owner, 2026-09-11) — the same filter the chat list
        // applies, so a request remembered here from before it was hidden cannot resurface.
        for c in repo.conversations where MessageRequests.stance(c) != .incoming { byId[c.id] = c }

        for e in recents.entries {
            switch e.kind {
            case .chat:
                // ⛔ THE SECOND PRUNING RULE. A remembered chat is drawn from the LIVE conversation
                // so it looks exactly like the same chat does in the Chats section — same `ChatRow`,
                // same preview, same time. A chat that is no longer in the list (deleted, archived,
                // cleared, or a different account's) has nothing to draw and is simply skipped: a
                // row that cannot say who it is is worse than one fewer row.
                guard let c = byId[e.key] else { continue }
                m.chats[e.key] = c
                rows.append(SearchPageRow(kind: .recentChat, key: e.key))
            case .person:
                m.recents[e.key] = e
                rows.append(SearchPageRow(kind: .recentPerson, key: e.key))
            }
        }
        if !rows.isEmpty {
            m.sections = [SearchPageSection(title: "Recent", showsClear: true, rows: rows)]
        }
        return m
    }

    private func resultsModel() -> PageModel {
        var m = PageModel()
        var chatRows: [SearchPageRow] = []
        var groupRows: [SearchPageRow] = []

        // ⚠️ ALREADY FILTERED AND SORTED. `visible` has applied the query, the archive rule, the
        // never-messaged rule and the list filter; this only splits it the way their two sections
        // do. Nothing here decides which chats match.
        for c in chats() {
            m.chats[c.id] = c
            if c.isGroup {
                groupRows.append(SearchPageRow(kind: .group, key: c.id))
            } else {
                chatRows.append(SearchPageRow(kind: .chat, key: c.id))
            }
        }

        var personRows: [SearchPageRow] = []
        for u in people() {
            m.people[u.id] = u
            personRows.append(SearchPageRow(kind: .person, key: u.id))
        }

        var out: [SearchPageSection] = []
        if !chatRows.isEmpty { out.append(SearchPageSection(title: "Chats", rows: chatRows)) }
        if !groupRows.isEmpty { out.append(SearchPageSection(title: "Groups", rows: groupRows)) }
        if !personRows.isEmpty { out.append(SearchPageSection(title: "People", rows: personRows)) }
        m.sections = out
        return m
    }

    // MARK: Rows

    /// ⚠️ BUILT AT `cellForRowAt`, NOT UP FRONT. The table calls this for the rows it is about to
    /// show, so a hundred remembered names cost a handful of SwiftUI views.
    @ViewBuilder private func content(_ row: SearchPageRow, _ m: PageModel) -> some View {
        switch row.kind {
        case .chat, .group, .recentChat:
            if let c = m.chats[row.key] {
                // The app's own chat row, unchanged. A chat in the search results has to be the same
                // object it is in the list, or the page is a different app.
                ChatRow(conv: c, me: me, dark: dark)
            }
        case .person:
            if let u = m.people[row.key] { personRow(u) }
        case .recentPerson:
            if let e = m.recents[row.key] {
                RecentPersonRow(uid: e.key, title: e.title, handle: e.handle)
            }
        }
    }

    // MARK: Taps

    /// ⛔ TAPPING A RESULT DOES TWO THINGS, AND THE ORDER MATTERS.
    ///
    /// It records the row in Recent and it opens it. The open is pushed FIRST and the search is
    /// dismissed after, which is the same order `NewChatView`'s sheet already uses for the same
    /// reason: "push behind the sheet, then dismiss — no flash back to the list".
    ///
    /// ⚠️ WE DISMISS SEARCH; THE REFERENCE ONLY RESIGNS THE KEYBOARD (`conversationSearchDidSelectRow`
    /// keeps the results up and re-focuses on the way back). Ours cannot: this page exists for
    /// exactly as long as `\.isSearching`, and pushing a chat while a SwiftUI search is active is
    /// the kind of half-state that has cost this app builds before. Say it plainly rather than
    /// pretend it is their behaviour.
    private func select(_ row: SearchPageRow, _ m: PageModel) {
        switch row.kind {
        case .chat, .group, .recentChat:
            guard let c = m.chats[row.key] else { return }
            recents.record(chat: c, me: me)
            onOpenChat(c)
            dismissSearch()
        case .person:
            guard let u = m.people[row.key] else { return }
            recents.record(person: u, me: me)
            onOpenPerson(u)
            dismissSearch()
        case .recentPerson:
            guard let e = m.recents[row.key] else { return }
            // ⚠️ ONE DOCUMENT, BY UID. Recent stores who you opened, not a copy of their profile —
            // a stored photo url would keep showing a picture they have since hidden. This is the
            // same `get` on `users/{uid}` the app makes everywhere; it is NOT a directory query,
            // and it must never become one (see `ChatService.searchUsers`).
            Task {
                guard let u = await ProfileStore.shared.fetch(e.key) else { return }
                await MainActor.run {
                    recents.record(person: u, me: me)
                    onOpenPerson(u)
                    dismissSearch()
                }
            }
        }
    }

    // MARK: Empty states

    @ViewBuilder private var emptyState: some View {
        if query.isEmpty {
            // Nothing searched yet on this account. Theirs shows a spinner here; a spinner that
            // never resolves is what his screenshot is complaining about in another form.
            EmptyStateView(title: "Search", icon: "magnifyingglass",
                           text: "Find your chats and groups, or a person by their username.")
        } else if !searching {
            // ⚠️ NOT WHILE THE USERNAME LOOKUP IS STILL OUT. "No results" drawn over a person who
            // arrives 200ms later is the same bug the chat list's own overlay guards against.
            ContentUnavailableView.search(text: query)
        }
    }
}

/// A remembered person, drawn from what Recent stores plus what the app already knows.
///
/// ⚠️ THE PHOTO IS RESOLVED LIVE, NOT REMEMBERED. `ProfilePhotoIndex.header` answers synchronously
/// AND applies the Profile Picture audience, so somebody who has since set their photo to Contacts
/// Only stops showing one here without this row knowing anything about privacy. Same shape as
/// `newPersonRow` on the chat list: 56pt avatar with 12 above and below, headline name, subheadline
/// username.
private struct RecentPersonRow: View {
    let uid: String
    let title: String
    let handle: String

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: title.isEmpty ? handle : title, photoUrl: photo, size: 56)
                .padding(.vertical, 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(title.isEmpty ? handle : title).font(.headline).foregroundStyle(.primary)
                if !handle.isEmpty {
                    Text("@\(handle)").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
    }

    private var photo: String? {
        ProfilePhotoIndex.header(uid: uid, fallbackPhoto: nil, fallbackPoster: nil,
                                 iAmContact: PrivacyPrefs.isContact(uid)).photoUrl
    }
}

// MARK: - The results list, in UIKit

/// ⛔ THE LIST IS A `UITableView` — his explicit ask, 2026-09-09: "also search page make it uikit",
/// and the chat list beside it already is one.
///
/// ⚠️ THIS FOLLOWS `ChatListTable`'S SHAPE ON PURPOSE, NOT A SECOND ONE OF ITS OWN: a
/// `UIViewControllerRepresentable` wrapping a grouped table whose rows are SwiftUI views in a
/// `UIHostingConfiguration`, with a held header view per section and `leastNormalMagnitude`
/// headers/footers so the grouped style adds no spacing of its own. What it deliberately does NOT
/// carry over is everything that exists there for the pin animation — the render state, the
/// `beginUpdates`/`endUpdates` diff, the in-place `refreshVisibleContent`, the select mode and the
/// swipe actions. Nothing on a search page moves between sections; a new query is a new list.
struct SearchResultsTable: UIViewControllerRepresentable {
    var sections: [SearchPageSection]
    /// The row's view, built on demand. `AnyView` because this table draws four different row types
    /// and two of them are handed in from the screen — the same handover `ChatListTable.personRow`
    /// already makes. The cost is that a re-configured cell rebuilds its SwiftUI tree instead of
    /// updating in place, which on a page whose rows live for one query is not a cost.
    var content: (SearchPageRow) -> AnyView
    var onSelect: (SearchPageRow) -> Void
    var onClearRecent: () -> Void

    func makeUIViewController(context: Context) -> SearchResultsTableController {
        let vc = SearchResultsTableController()
        vc.host = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: SearchResultsTableController, context: Context) {
        context.coordinator.parent = self
        vc.apply(sections: sections)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator {
        var parent: SearchResultsTable
        init(_ parent: SearchResultsTable) { self.parent = parent }
    }
}

final class SearchResultsTableController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    var host: SearchResultsTable.Coordinator?

    private var sections: [SearchPageSection] = []
    /// What the table was last RELOADED for. See `apply`.
    private var signature = ""

    /// One header view per section index, kept rather than rebuilt — `ChatListTable`'s rule, minus
    /// the half of its reasoning that is about not disturbing a pin in flight. What is left is the
    /// cheap reason, which is still a reason: `viewForHeaderInSection` is asked on every scroll.
    private var headerViews: [Int: SearchSectionHeader] = [:]

    private lazy var tableView: UITableView = {
        let t = UITableView(frame: .zero, style: .grouped)
        t.separatorStyle = .none
        t.backgroundColor = .clear
        // The grouped style paints each cell on `secondarySystemGroupedBackground` — the raised-card
        // grey he had removed from the chat list ("why is the chat list Chats card using grey,
        // remove that"). Cleared on the table and again on every cell.
        t.backgroundView = nil
        // ⚠️ SELF-SIZING ROWS, WHICH IS A DELIBERATE DIFFERENCE FROM THE CHAT LIST. That table
        // computes an exact height because a self-sized row inside a `beginUpdates`/`endUpdates`
        // block corrects itself against offsets the same transaction is moving — his 2026-09-05
        // "the text and chat cells overlap each other". This table has no such block: it only ever
        // reloads. So the reference's own choice for its search table applies here unchanged
        // (`rowHeight = .automaticDimension`, `estimatedRowHeight = 60`); ours estimates 80 because
        // our row is a 56pt avatar with 12 above and below.
        t.rowHeight = UITableView.automaticDimension
        t.estimatedRowHeight = 80
        // ⛔ HIS 28pt OF CLEARANCE, the same number the chat list carries: the floating tab bar's
        // margins are transparent, so without it the last row shows through and takes the tap.
        t.contentInset.bottom = 28
        t.verticalScrollIndicatorInsets.bottom = 28
        // Their `conversationSearchViewWillBeginDragging`, which resigns the search bar the moment a
        // drag starts. UIKit does the same thing in one property and does it for whichever view is
        // actually first responder.
        t.keyboardDismissMode = .onDrag
        t.dataSource = self
        t.delegate = self
        for kind in SearchPageRow.Kind.allCases {
            t.register(SearchResultCell.self, forCellReuseIdentifier: kind.rawValue)
        }
        return t
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.addSubview(tableView)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// ⚠️ THE ARRAYS ARE TAKEN EVERY PASS; THE RELOAD IS NOT. `updateUIViewController` runs on every
    /// SwiftUI pass of the chat list — a typing indicator on some other chat is enough — and
    /// reloading a table the finger is scrolling is how a list fights back. The signature is the
    /// section titles and the row ids, so a reload happens exactly when the RESULTS changed.
    func apply(sections: [SearchPageSection]) {
        self.sections = sections
        let sig = Self.signature(of: sections)
        guard sig != signature else { return }
        signature = sig
        tableView.reloadData()
    }

    private static func signature(of sections: [SearchPageSection]) -> String {
        sections.map { s in
            (s.title ?? "") + (s.showsClear ? "*" : "") + "|" + s.rows.map(\.id).joined(separator: ",")
        }.joined(separator: ";")
    }

    private func row(at ip: IndexPath) -> SearchPageRow? {
        sections[safe: ip.section]?.rows[safe: ip.row]
    }

    // MARK: Data source

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[safe: section]?.rows.count ?? 0
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let r = row(at: indexPath), let host else { return UITableViewCell() }
        // ⚠️ A REUSE IDENTIFIER PER KIND. A cell that has held a chat row's view tree and is then
        // handed a person's is the case `ChatListTable`'s two identifiers exist for; four row types
        // here, four queues.
        let cell = tableView.dequeueReusableCell(withIdentifier: r.kind.rawValue, for: indexPath)
        guard let c = cell as? SearchResultCell else { return cell }
        c.backgroundColor = .clear
        c.contentConfiguration = UIHostingConfiguration { host.parent.content(r) }.margins(.all, 0)
        c.selectionStyle = .default
        return c
    }

    // MARK: Headers

    /// Their numbers, the same ones the chat list's heading uses: 14 above, 16 leading, 8 below,
    /// 16 trailing, a headline label in the label colour.
    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let model = sections[safe: section], model.title != nil else { return UIView() }
        let header: SearchSectionHeader
        if let existing = headerViews[section] {
            header = existing
        } else {
            header = SearchSectionHeader()
            headerViews[section] = header
        }
        header.title = model.title
        // Written out rather than as a ternary: a closure and `nil` in the same conditional is the
        // shape Swift most often calls ambiguous, and this is not worth a CI round to find out.
        if model.showsClear {
            header.onClear = { [weak self] in
                self?.host?.parent.onClearRecent()
            }
        } else {
            header.onClear = nil
        }
        return header
    }

    /// An explicit height rather than `automaticDimension`, for the reason the chat list's header
    /// carries: the automatic answer is a CACHED measurement, and setting the label's text does not
    /// invalidate that cache.
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        guard sections[safe: section]?.title != nil else { return .leastNormalMagnitude }
        return SearchSectionHeader.height(for: traitCollection)
    }

    /// "Without returning a footer with a non-zero height, a grouped table view will use a default
    /// spacing between sections. We do not want that spacing" — their comment, their rule.
    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? { UIView() }

    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        .leastNormalMagnitude
    }

    // MARK: Selection

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        guard let r = row(at: indexPath) else { return }
        host?.parent.onSelect(r)
    }

    /// No swipe actions on this page. The reference offers its chat and group results the same
    /// swipes as the inbox; ours are the chat list's handlers and he asked for a search page, not
    /// for a second place to archive from.
    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool { false }
}

/// A cell that is nothing but a host for the SwiftUI row.
private final class SearchResultCell: UITableViewCell {
    /// The chat list's fix, carried over rather than rediscovered: a cell holding a content
    /// configuration re-resolves its BACKGROUND configuration against its state, so the clear colour
    /// assigned once at dequeue is not the last word. Deciding it here is UIKit asking the cell what
    /// it looks like in the state it is actually in.
    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        var background = UIBackgroundConfiguration.clear()
        if state.isHighlighted {
            // The system's own press fill, resolved for this state rather than picked by eye.
            background.backgroundColor = UIBackgroundConfiguration.listPlainCell()
                .updated(for: state).backgroundColor ?? .systemFill
        }
        backgroundConfiguration = background
    }
}

/// The chat list's `ChatListSectionHeader` with one control added: Recent needs a way to be cleared,
/// and beside its own heading is where that lives. Same margins, same font, same arithmetic height —
/// a measurement needs a cache that can go stale behind you and arithmetic does not.
final class SearchSectionHeader: UIView {
    static let topMargin: CGFloat = 14
    static let bottomMargin: CGFloat = 8

    static func height(for traits: UITraitCollection) -> CGFloat {
        let font = UIFont.preferredFont(forTextStyle: .headline, compatibleWith: traits)
        return ceil(font.lineHeight) + topMargin + bottomMargin
    }

    /// Nil collapses the heading; the delegate answers `leastNormalMagnitude` for that section, and
    /// hiding the label stops it drawing in the sliver that remains.
    var title: String? {
        didSet {
            guard title != oldValue else { return }
            label.text = title
            label.isHidden = title == nil
        }
    }

    /// Nil hides the control. Assigning it on every pass is free — the button reads it at tap time.
    var onClear: (() -> Void)? {
        didSet { clearButton.isHidden = onClear == nil }
    }

    private let label = UILabel()
    private let clearButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: Self.topMargin, leading: 16,
                                                           bottom: Self.bottomMargin, trailing: 16)

        label.font = .preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        // ⚠️ THE HEADING YIELDS, THE CONTROL DOES NOT. The button is pinned to the trailing margin
        // and the label is kept 8pt clear of it by a REQUIRED inequality below; at the largest text
        // sizes a heading wide enough to break that would break the constraint instead. Lowering its
        // compression resistance lets it truncate, which is the answer, and raising the button's
        // says which of the two is allowed to.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        // ⚠️ `.label`, NOT THE WINDOW TINT. This app's tint is `.primary` by choice — the chat
        // list's note about the selection tick says the same thing from the other side ("the app's
        // `.primary` tint draws a white check on a white disc"). The weight is what separates the
        // control from the heading beside it, not the colour.
        clearButton.setTitle("Clear", for: .normal)
        clearButton.setTitleColor(.label, for: .normal)
        clearButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        clearButton.titleLabel?.adjustsFontForContentSizeCategory = true
        clearButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        clearButton.setContentHuggingPriority(.required, for: .horizontal)
        clearButton.isHidden = true
        clearButton.addTarget(self, action: #selector(clearTapped), for: .touchUpInside)
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clearButton)

        let g = layoutMarginsGuide
        // One point below required, for the reason the chat list's header states: a collapsed
        // section is squashed by UIKit's own required height constraint, and a required bottom
        // constraint here logs a conflict every time that happens.
        let bottom = label.bottomAnchor.constraint(equalTo: g.bottomAnchor)
        bottom.priority = .defaultHigh + 1
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: g.topAnchor),
            label.leadingAnchor.constraint(equalTo: g.leadingAnchor),
            bottom,
            clearButton.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
            clearButton.trailingAnchor.constraint(equalTo: g.trailingAnchor),
            clearButton.lastBaselineAnchor.constraint(equalTo: label.lastBaselineAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func clearTapped() { onClear?() }
}
