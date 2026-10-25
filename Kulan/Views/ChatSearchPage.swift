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
    var onOpenPublicGroup: (PublicGroupTarget) -> Void
    /// Whether the search is up, told to the Chats tab so a door from outside can close it first.
    var onSearchingChange: (Bool) -> Void = { _ in }

    @Environment(\.isSearching) private var isSearching
    @Environment(\.dismissSearch) private var dismissSearch

    /// Posted by the Chats tab to close its search from outside (a notification, a link). The search
    /// is closed from INSIDE it, with `dismissSearch`, rather than through an `isPresented` binding
    /// on `.searchable`: with that binding iOS 26 sometimes drew its X as a wide capsule instead of
    /// the 44pt circle (owner 2026-10-23).
    static let closeRequest = Notification.Name("chatSearch.close")

    /// ⚠️ SPELLED OUT, NOT SYNTHESISED. A single PRIVATE stored property — the environment read
    /// above — makes Swift's memberwise initialiser private too, and the call site in another file
    /// then cannot see it. That has cost this app a CI round before; it is in the build notes.
    init(query: String, me: String, dark: Bool, searching: Bool,
         chats: @escaping () -> [Conversation],
         people: @escaping () -> [UserProfile],
         personRow: @escaping (UserProfile) -> AnyView,
         onOpenChat: @escaping (Conversation) -> Void,
         onOpenPerson: @escaping (UserProfile) -> Void,
         onOpenPublicGroup: @escaping (PublicGroupTarget) -> Void,
         onSearchingChange: @escaping (Bool) -> Void = { _ in }) {
        self.onSearchingChange = onSearchingChange
        self.query = query
        self.me = me
        self.dark = dark
        self.searching = searching
        self.chats = chats
        self.people = people
        self.personRow = personRow
        self.onOpenChat = onOpenChat
        self.onOpenPerson = onOpenPerson
        self.onOpenPublicGroup = onOpenPublicGroup
    }

    var body: some View {
        // ⛔ THE COVER COMES AT ONCE, THE RESULTS AFTER (owner 2026-10-19, third report of "the list
        // jumps up when I tap search", screenshot: rows sliding under the rising field). The
        // reference app's `SearchDisplayController.activate` fades an opaque page in the chat list's
        // colour over the list straight away (alpha 0 -> 1, 0.2s linear) and the results over 0.3s;
        // `deactivate` fades that page out over 0.3s. The list underneath is never seen moving. Ours
        // waited 0.28s before covering anything, so the list was on show for the whole rise.
        if isSearching {
            Color(uiColor: .systemBackground).ignoresSafeArea()
                .allowsHitTesting(false)
                .transition(.asymmetric(
                    insertion: .opacity.animation(.linear(duration: 0.2)),
                    removal: .opacity.animation(.easeOut(duration: 0.3))))
        }
        if isSearching {
            ChatSearchPage(query: query, me: me, dark: dark, searching: searching,
                           chats: chats, people: people, personRow: personRow,
                           onOpenChat: onOpenChat, onOpenPerson: onOpenPerson,
                           onOpenPublicGroup: onOpenPublicGroup)
                // ⛔ AFTER THE BAR HAS GONE UP (owner 2026-10-18, build 973: "the Recent heading goes
                // under the search bar"). The page is laid out at once for the bar's FINAL place, so
                // while the field was still rising it passed over Recent and the first rows. The
                // page now fades in once the rise is over (about 0.3s); leaving search is instant.
                .transition(.asymmetric(
                    // 0.3s from the tap, the reference's content fade, no wait (owner 2026-10-19:
                    // "Recent appears late"). The list is already hidden, so nothing shows through.
                    insertion: .opacity.animation(.easeOut(duration: 0.3)),
                    removal: .identity))
        }
        Color.clear.frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onChange(of: isSearching, initial: true) { _, on in onSearchingChange(on) }
            .onReceive(NotificationCenter.default.publisher(for: Self.closeRequest)) { _ in
                if isSearching { dismissSearch() }
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

    /// `.group`: a public group tapped in search (owner 2026-10-21: "I click the group, Recent does
    /// not show it"). Drawn as the chat once I am in it.
    enum Kind: String, Equatable { case chat, person, group }

    struct Entry: Identifiable, Equatable {
        let kind: Kind
        /// A conversation id for `.chat`, a uid for `.person`.
        let key: String
        /// What the row said when it was tapped. Re-read live where the app still knows better — a
        /// recent CHAT is drawn from the live conversation, so this is only the fallback name.
        let title: String
        /// The username, for a person. Empty for a chat.
        let handle: String
        /// A public group's photo url; empty otherwise.
        var photo: String = ""
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
        let twin = other.isEmpty ? "\(Kind.group.rawValue):\(chat.id)" : "\(Kind.person.rawValue):\(other)"
        remember(Entry(kind: .chat, key: chat.id, title: chat.displayName(me), handle: ""), twin: twin)
    }

    func record(person: UserProfile, me: String) {
        let twin = me.isEmpty ? nil : "\(Kind.chat.rawValue):\(ChatService.convId(me, person.id))"
        remember(Entry(kind: .person, key: person.id,
                       title: person.name.isEmpty ? person.handle : person.name,
                       handle: person.handle),
                 twin: twin)
    }

    func record(group: PublicGroupHit) {
        remember(Entry(kind: .group, key: group.cid, title: group.title, handle: group.handle,
                       photo: group.photoUrl ?? ""),
                 twin: "\(Kind.chat.rawValue):\(group.cid)")
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
            return Entry(kind: kind, key: key, title: d["t"] ?? "", handle: d["h"] ?? "", photo: d["p"] ?? "")
        }
    }

    private func persist() {
        guard !account.isEmpty else { return }
        let raw = entries.map { ["k": $0.kind.rawValue, "i": $0.key, "t": $0.title, "h": $0.handle, "p": $0.photo] }
        UserDefaults.standard.set(raw, forKey: Self.key(for: account))
    }
}

// MARK: - The page's model

/// One row of the search page. Deliberately just a KIND and a KEY: the row's content is looked up
/// live when the cell is built, so a row never carries a frozen copy of a conversation.
struct SearchPageRow: Identifiable, Equatable {
    /// `publicGroup` (2026-10-19 groups v2): a public group I am not in, from the server's search.
    enum Kind: String, CaseIterable, Equatable { case chat, group, person, recentChat, recentPerson, showMore, publicGroup }
    let kind: Kind
    /// Conversation id for a chat or a group (a public group too), uid for a person.
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
    var onOpenPublicGroup: (PublicGroupTarget) -> Void

    @Environment(\.dismissSearch) private var dismissSearch
    private var repo = ConversationsRepository.shared
    private var recents = RecentSearches.shared
    /// A recent person's profile fetch failed (offline, or the account is gone) and there was no
    /// existing chat with them to fall back to, so tapping the row did nothing to open on.
    @State private var recentPersonOpenFailed = false
    /// Show More tapped on the Global Search section; collapses again when the query changes.
    @State private var showAllPeople = false
    /// Global results shown before Show More (the reference collapses its global section past 3).
    static let globalCollapsed = 3
    /// 2026-10-19 groups v2: public groups whose @name starts with the query (GroupDirectory.search),
    /// asked beside the people search with the same 0.4s settle, answered queries kept for the page.
    @State private var groupHits: [PublicGroupHit] = []
    @State private var groupCache: [String: [PublicGroupHit]] = [:]
    @State private var groupSearching = false

    init(query: String, me: String, dark: Bool, searching: Bool,
         chats: @escaping () -> [Conversation],
         people: @escaping () -> [UserProfile],
         personRow: @escaping (UserProfile) -> AnyView,
         onOpenChat: @escaping (Conversation) -> Void,
         onOpenPerson: @escaping (UserProfile) -> Void,
         onOpenPublicGroup: @escaping (PublicGroupTarget) -> Void) {
        self.query = query
        self.me = me
        self.dark = dark
        self.searching = searching
        self.chats = chats
        self.people = people
        self.personRow = personRow
        self.onOpenChat = onOpenChat
        self.onOpenPerson = onOpenPerson
        self.onOpenPublicGroup = onOpenPublicGroup
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
                onClearRecent: { recents.clear() },
                header: peers.isEmpty ? nil : AnyView(TopPeersRow(peers: peers, me: me, onOpen: openPeer)))

            if model.isEmpty && peers.isEmpty { emptyState }
            // 2026-09-24 feature-audit: older chats are still being fetched for this search, so
            // more matches may come. Under the results, out of the way of the rows.
            if !model.isEmpty, !query.isEmpty, repo.loadingWholeList {
                VStack { Spacer(); ProgressView().padding(.bottom, 16) }
                    .allowsHitTesting(false)
            }
        }
        .onAppear { recents.start() }
        .onChange(of: query) { _, _ in showAllPeople = false }
        .task(id: query) { await lookUpGroups(query) }
        .alert("Couldn't open", isPresented: $recentPersonOpenFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Check your connection and try again.")
        }
    }

    // MARK: Sections

    /// Everything the table needs for one pass: the sections, plus the lookup tables its cells read.
    private struct PageModel {
        var sections: [SearchPageSection] = []
        var chats: [String: Conversation] = [:]
        var people: [String: UserProfile] = [:]
        var groups: [String: PublicGroupHit] = [:]
        var recents: [String: RecentSearches.Entry] = [:]
        var isEmpty: Bool { sections.allSatisfy { $0.rows.isEmpty } }
    }

    private func buildModel() -> PageModel {
        query.isEmpty ? recentModel() : resultsModel()
    }

    /// The top people row (owner 2026-10-25, the reference app's row above Recent): the people I
    /// chat with, most recent first, 1:1 chats only, up to 20. Theirs ranks by a server-side rating
    /// of who you write to; the chat list's own order is ours. Only on an empty query.
    private var peers: [Conversation] {
        guard query.isEmpty else { return [] }
        let hidden = TopPeersHidden.shared.ids
        let list = repo.conversations.filter { c in
            !c.isGroup && c.id.contains("_") && !hidden.contains(c.id)
                && !c.otherUid(me).isEmpty && c.otherUid(me) != me
                && MessageRequests.stance(c, myUid: me) != .incoming && !c.isCleared(me) && !c.isArchived(me)
        }
        return Array(list.sorted { $0.updatedAtMillis > $1.updatedAtMillis }.prefix(20))
    }

    private func openPeer(_ c: Conversation) {
        recents.record(chat: c, me: me)
        onOpenChat(c)
    }

    private func recentModel() -> PageModel {
        var m = PageModel()
        var rows: [SearchPageRow] = []
        // A conversation lookup for the whole list, once, rather than a scan per entry.
        var byId: [String: Conversation] = [:]
        // A pending request is not a chat (owner, 2026-09-11) — the same filter the chat list
        // applies, so a request remembered here from before it was hidden cannot resurface. A
        // cleared or archived chat is filtered the same way `MainShell.visible` filters it, so
        // one you cleared or archived cannot resurface with its name and last message either.
        for c in repo.conversations
            where MessageRequests.stance(c, myUid: me) != .incoming && !c.isCleared(me) && !c.isArchived(me) {
            byId[c.id] = c
        }

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
            case .group:
                // In it now: the chat row. Otherwise the public group row from what was saved.
                if let c = byId[e.key] {
                    m.chats[e.key] = c
                    rows.append(SearchPageRow(kind: .recentChat, key: e.key))
                } else if let hit = PublicGroupHit(["kind": "group", "cid": e.key, "handle": e.handle,
                                                     "title": e.title, "photoUrl": e.photo]) {
                    m.groups[e.key] = hit
                    rows.append(SearchPageRow(kind: .publicGroup, key: e.key))
                    let cid = e.key
                    DispatchQueue.main.async { GroupDirectory.warm(cid: cid) }   // opens at once (2026-10-21)
                }
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

        // ⛔ THE REFERENCE APP'S ORDER — owner, 2026-10-04. (1) Things you searched before and
        // still match come first (theirs pulls recently-searched peers out of the local list and
        // shows them on top); the rest keep the chat list's newest-first order. (2) The server's
        // people go under a "Global Search" heading, after everything local, and only the first 3
        // show until Show More (theirs collapses the global section past 3; local never collapses).
        let recentRank = Dictionary(recents.entries.enumerated().map { ($1.key, $0) }, uniquingKeysWith: { a, _ in a })
        func recentFirst(_ rows: [SearchPageRow]) -> [SearchPageRow] {
            rows.enumerated().sorted { a, b in
                let ra = recentRank[a.element.key] ?? Int.max, rb = recentRank[b.element.key] ?? Int.max
                return ra != rb ? ra < rb : a.offset < b.offset
            }.map(\.element)
        }
        chatRows = recentFirst(chatRows)
        groupRows = recentFirst(groupRows)
        personRows = recentFirst(personRows)
        // Public groups from the server join the people under Global Search, minus the ones I am in.
        let mine = Set(repo.conversations.filter { $0.isGroup && $0.users.contains(me) }.map { $0.id })
        // ⛔ A PUBLIC GROUP I AM IN, FOUND BY ITS @NAME — owner 2026-10-21 ("waraa3", No Results):
        // the local match reads titles only, and Global Search leaves out groups I am in, so a group
        // titled "All right" with the link waraa3 showed nowhere. It goes with my groups, as my chat.
        for g in groupHits where g.isMember || mine.contains(g.cid) {
            guard m.chats[g.cid] == nil, let c = repo.conversations.first(where: { $0.id == g.cid }) else { continue }
            m.chats[g.cid] = c
            groupRows.append(SearchPageRow(kind: .group, key: g.cid))
        }
        for g in groupHits where !g.isMember && !mine.contains(g.cid) {
            m.groups[g.cid] = g
            // The first few public hits are fetched ahead, so a tap opens with nothing to wait for
            // (owner 2026-10-21). Next turn: not while the page's model is being built.
            if m.groups.count <= 3 { let cid = g.cid; DispatchQueue.main.async { GroupDirectory.warm(cid: cid) } }
            personRows.append(SearchPageRow(kind: .publicGroup, key: g.cid))
        }
        if !showAllPeople, personRows.count > Self.globalCollapsed {
            personRows = Array(personRows.prefix(Self.globalCollapsed))
                + [SearchPageRow(kind: .showMore, key: "global")]
        }

        var out: [SearchPageSection] = []
        if !chatRows.isEmpty { out.append(SearchPageSection(title: "Chats", rows: chatRows)) }
        if !groupRows.isEmpty { out.append(SearchPageSection(title: "Groups", rows: groupRows)) }
        if !personRows.isEmpty { out.append(SearchPageSection(title: "Global Search", rows: personRows)) }
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
        case .publicGroup:
            if let g = m.groups[row.key] { PublicGroupHitRow(hit: g) }
        case .recentPerson:
            if let e = m.recents[row.key] {
                RecentPersonRow(uid: e.key, title: e.title, handle: e.handle)
            }
        case .showMore:
            HStack {
                Text("Show More").foregroundStyle(Color.accentColor)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .contentShape(Rectangle())
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
        case .showMore:
            showAllPeople = true
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
        case .publicGroup:
            // The join page (or the chat, when I joined meanwhile), presented by the Chats tab.
            guard let g = m.groups[row.key] else { return }
            recents.record(group: g)
            // A group I am in opens the way a chat row does (owner 2026-10-23: a Recent group
            // dropped him on a blank list with no tab bar). The router door pushed the chat a turn
            // later, while the search was closing, and the stack came out half pushed.
            if let c = repo.conversations.first(where: { $0.id == g.cid }), c.users.contains(me) {
                onOpenChat(c)
                dismissSearch()
                return
            }
            // ⛔ AND A GROUP I AM NOT IN OPENS THE SAME WAY, ON THIS TAP (owner 2026-10-23, 4th
            // report: list on screen, top buttons blank, no tab bar). `GroupDirectory.open` goes
            // through the router, which appends a main-queue turn later while the search is closing;
            // the stack took the page (its tab bar and toolbar preferences won) but kept showing the
            // list. Appended here before the search closes, it is the same navigation as a chat row.
            onOpenPublicGroup(PublicGroupTarget(cid: g.cid, name: g.handle))
            dismissSearch()
        case .recentPerson:
            guard let e = m.recents[row.key] else { return }
            // ⚠️ ONE DOCUMENT, BY UID. Recent stores who you opened, not a copy of their profile —
            // a stored photo url would keep showing a picture they have since hidden. This is the
            // same `get` on `users/{uid}` the app makes everywhere; it is NOT a directory query,
            // and it must never become one (see `ChatService.searchUsers`).
            // ⛔ OPENS AT ONCE (owner 2026-10-19: "Recent takes time to open"). It waited for the
            // server's copy of the profile before doing anything. A chat we already have opens
            // straight away; otherwise the phone's own copy of the profile, and only then the server.
            let existing = ChatService.convId(me, e.key)
            if let c = repo.conversations.first(where: { $0.id == existing }) {
                onOpenChat(c)
                dismissSearch()
                return
            }
            Task {
                if let u = await ProfileStore.shared.cachedPeer(e.key) {
                    await MainActor.run {
                        recents.record(person: u, me: me)
                        onOpenPerson(u)
                        dismissSearch()
                    }
                    return
                }
                if let u = await ProfileStore.shared.fetch(e.key) {
                    await MainActor.run {
                        recents.record(person: u, me: me)
                        onOpenPerson(u)
                        dismissSearch()
                    }
                    return
                }
                // The profile fetch failed. Tapping did nothing before this — fall back to the
                // chat itself if one already exists between us, and only say so when it does not.
                await MainActor.run {
                    let cid = ChatService.convId(me, e.key)
                    if let c = repo.conversations.first(where: { $0.id == cid }) {
                        onOpenChat(c)
                        dismissSearch()
                    } else {
                        recentPersonOpenFailed = true
                    }
                }
            }
        }
    }

    /// The group half of global search. A query answered before is answered again at once; a new
    /// one waits 0.4s and `.task(id:)` cancels it on the next keystroke, as the people search does.
    private func lookUpGroups(_ q: String) async {
        guard Flags.groupsEnabled, q.count >= 3 else { groupHits = []; groupSearching = false; return }
        let key = q.lowercased()
        if let hit = groupCache[key] { groupHits = hit; groupSearching = false; return }
        groupSearching = true
        try? await Task.sleep(nanoseconds: 400_000_000)
        if Task.isCancelled { return }
        let found = await GroupDirectory.search(q)
        if Task.isCancelled { return }
        groupCache[key] = found
        groupHits = found
        groupSearching = false
    }

    // MARK: Empty states

    @ViewBuilder private var emptyState: some View {
        if query.isEmpty {
            // Nothing searched yet on this account. Theirs shows a spinner here; a spinner that
            // never resolves is what his screenshot is complaining about in another form.
            // ⛔ THE MESSAGE REQUESTS EMPTY PAGE'S TYPE — owner 2026-10-16: title 17 semibold, line 15
            // secondary (MessageRequestsView `emptyLine`). The magnifier stays.
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                Text("Search")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("Find your chats and groups, or a person by their username.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if repo.loadingWholeList || searching || groupSearching {
            // ⛔ LOOKING IS SHOWN AS LOOKING — owner, 2026-09-27, with the message search's skeleton:
            // "add a loading screen like this while I search a username". It was a bare spinner
            // for older chats and NOTHING at all while the username lookup was out.
            ChatListSkeleton()
                .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
        } else {
            NoSearchResults(query: query)
        }
    }
}

/// ⛔ HIS WORDS, EVERY SEARCH — owner, 2026-09-27, with the screenshot: "No Results / There were no
/// results for "…". / Try a new search." One view, so the chat search and the message search
/// cannot say it two ways.
struct NoSearchResults: View {
    let query: String
    /// ⛔ THE MESSAGE REQUESTS EMPTY PAGE'S TYPE — owner 2026-10-16: "exactly the size, type and
    /// font of the message requests page". Title 17 semibold, line 15 secondary
    /// (MessageRequestsView `emptyLine`). Same words, still no icon.
    var body: some View {
        VStack(spacing: 10) {
            Text("No Results")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
            Text("There were no results for \"\(query)\".\nTry a new search.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                                 iAmContact: PrivacyPrefs.mayViewPhotoOf(uid)).photoUrl
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
/// People taken off the top row by a long press, per account, on this phone (theirs resets the
/// server rating; ours has none, so the choice is remembered here).
@Observable final class TopPeersHidden {
    static let shared = TopPeersHidden()
    private(set) var ids: Set<String> = []
    private var account = ""

    private static func key(_ uid: String) -> String { "topPeersHidden.v1.\(uid)" }

    private init() { sync() }

    private func sync() {
        let uid = AuthService.shared.uid ?? ""
        guard uid != account else { return }
        account = uid
        ids = Set(UserDefaults.standard.stringArray(forKey: Self.key(uid)) ?? [])
    }

    func hide(_ cid: String) {
        sync()
        ids.insert(cid)
        UserDefaults.standard.set(Array(ids), forKey: Self.key(account))
    }
}

/// The reference app's top people row: 60pt faces, the name under each in 11pt on one line, an
/// unread count at the face's top right (grey when muted). Tap opens the chat; a long press offers
/// Remove. 86pt tall, scrolling sideways.
struct TopPeersRow: View {
    static let height: CGFloat = 92
    let peers: [Conversation]
    let me: String
    var onOpen: (Conversation) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 0) {
                ForEach(peers) { c in
                    Button { onOpen(c) } label: { item(c) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                withAnimation(.easeInOut(duration: 0.2)) { TopPeersHidden.shared.hide(c.id) }
                            } label: { Label("Remove", systemImage: "trash") }
                        }
                }
            }
            .padding(.horizontal, 6)
        }
        .frame(height: Self.height)
    }

    private func item(_ c: Conversation) -> some View {
        let name = c.displayName(me)
        let first = name.split(separator: " ").first.map(String.init) ?? name
        let unread = c.unread(me)
        let muted = c.isMuted(me, now: Date().timeIntervalSince1970 * 1000)
        return VStack(spacing: 4) {
            AvatarView(name: name, photoUrl: c.displayPhoto(me), size: 60)
                .overlay(alignment: .topTrailing) {
                    if unread > 0 {
                        Text(unread > 99 ? "99+" : "\(unread)")
                            .font(.system(size: 14))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(Capsule().fill(muted ? Color(.systemGray) : Color.accentColor))
                            .overlay(Capsule().stroke(Color(.systemBackground), lineWidth: 2))
                            .offset(x: 4, y: -2)
                    }
                }
            Text(first)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: 64)
        }
        .padding(.top, 4)
        .frame(width: 72)
        .contentShape(Rectangle())
    }
}

struct SearchResultsTable: UIViewControllerRepresentable {
    var sections: [SearchPageSection]
    /// The row's view, built on demand. `AnyView` because this table draws four different row types
    /// and two of them are handed in from the screen — the same handover `ChatListTable.personRow`
    /// already makes. The cost is that a re-configured cell rebuilds its SwiftUI tree instead of
    /// updating in place, which on a page whose rows live for one query is not a cost.
    var content: (SearchPageRow) -> AnyView
    var onSelect: (SearchPageRow) -> Void
    var onClearRecent: () -> Void
    /// The top people row above Recent (owner 2026-10-25), scrolling with the list. Nil: none.
    var header: AnyView? = nil

    func makeUIViewController(context: Context) -> SearchResultsTableController {
        let vc = SearchResultsTableController()
        vc.host = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: SearchResultsTableController, context: Context) {
        context.coordinator.parent = self
        vc.apply(sections: sections)
        vc.apply(header: header)
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

    private var headerHost: UIHostingController<AnyView>?

    /// The table's header view: added, updated in place, or taken away.
    func apply(header: AnyView?) {
        guard let header else {
            if tableView.tableHeaderView != nil { tableView.tableHeaderView = nil }
            return
        }
        if let host = headerHost {
            host.rootView = header
        } else {
            let host = UIHostingController(rootView: header)
            host.view.backgroundColor = .clear
            if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
            addChild(host)
            host.didMove(toParent: self)
            headerHost = host
        }
        guard let v = headerHost?.view, tableView.tableHeaderView !== v else { return }
        v.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: TopPeersRow.height)
        tableView.tableHeaderView = v
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
