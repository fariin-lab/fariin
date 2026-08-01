import SwiftUI
import FirebaseFirestore
import FirebaseAuth

// The single search-circle tab (iOS 26 `.search` role) routes to a context-specific
// search based on which main tab the user came from:
//   Chats    -> full message search (names + the text of every message)
//   Calls    -> everyone you've chatted with, tap to start a call
//   Settings -> search within Settings
extension View {
    // Auto-focus a `.searchable` field so the keyboard opens the moment the search
    // page appears (no second tap). `searchFocused` is iOS 18+, so older OS just no-ops.
    @ViewBuilder func autoFocusSearch(_ focused: FocusState<Bool>.Binding) -> some View {
        if #available(iOS 18.0, *) { self.searchFocused(focused) } else { self }
    }
}

struct SearchHubView: View {
    let context: Int            // 0 = Chats, 1 = Calls, 2 = Settings
    var onSignOut: () -> Void = {}
    var onCancel: () -> Void = {}   // tapping the search field's Cancel returns to the prior tab

    var body: some View {
        switch context {
        case 1: ContactsSearchView(onCancel: onCancel)
        case 2: SettingsSearchView(onSignOut: onSignOut, onCancel: onCancel)
        default: ChatSearchView(onCancel: onCancel)
        }
    }
}

// Watches the native search field; when the user cancels (search deactivates with an
// empty query and nothing pushed), it calls onCancel so we can return to the prior tab.
private struct SearchCancelWatcher: View {
    var canReturn: () -> Bool
    var onCancel: () -> Void
    @Environment(\.isSearching) private var isSearching
    @State private var wasSearching = false
    var body: some View {
        Color.clear
            .onChange(of: isSearching) { _, now in
                if now { wasSearching = true }
                else if wasSearching {
                    wasSearching = false
                    if canReturn() { onCancel() }
                }
            }
    }
}

// MARK: - Chats: full message-history search

// One message that matched the query, carrying its chat context for display + tap.
struct MessageHit: Identifiable {
    let messageId: String
    let cid: String
    let chatName: String
    let photoUrl: String?
    let text: String
    let date: Date
    var id: String { cid + "/" + messageId }
}

// Searches names instantly + the decrypted text of every message across all chats.
// Message search is on-demand and bounded (most-recent page per chat) so it can't
// run away on a long history; it's debounced so typing doesn't refire per keystroke.
struct ChatSearchView: View {
    var onCancel: () -> Void
    init(onCancel: @escaping () -> Void = {}) { self.onCancel = onCancel }
    private var repo = ConversationsRepository.shared
    @Environment(\.colorScheme) private var scheme
    @State private var query = ""
    @State private var path = NavigationPath()
    @State private var corpus: [SearchableMessage] = []   // loaded once; filtered in memory
    @State private var loadingCorpus = false
    @State private var loadTask: Task<Void, Never>?
    @State private var foundByHandle: UserProfile?         // exact @username match (global — start a new chat)
    @State private var handleTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    private var me: String { AuthService.shared.uid ?? "" }
    private var dark: Bool { scheme == .dark }
    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    // Cheap, instant name matches (no decryption needed).
    private var nameMatches: [Conversation] {
        let q = trimmed.lowercased()
        guard !q.isEmpty else { return [] }
        return repo.conversations
            .filter { Flags.groupsEnabled || !$0.isGroup }
            .filter { !$0.isCleared(me) && $0.name(for: me).lowercased().contains(q) }
            .sorted { $0.displayUpdatedAt(me) > $1.displayUpdatedAt(me) }
    }

    // Instant in-memory filter over the cached corpus — no network/decrypt per keystroke.
    private var hits: [MessageHit] {
        let q = trimmed.lowercased()
        guard !q.isEmpty else { return [] }
        return corpus
            .filter { $0.text.lowercased().contains(q) }
            .sorted { $0.date > $1.date }
            .prefix(60)
            .map { MessageHit(messageId: $0.id, cid: $0.cid, chatName: $0.chatName,
                              photoUrl: $0.photoUrl, text: $0.text, date: $0.date) }
    }

    private var nothingFound: Bool { nameMatches.isEmpty && hits.isEmpty && foundByHandle == nil }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                // Exact @username match — find anyone globally to start a NEW chat.
                if let u = foundByHandle {
                    Section("People") {
                        Button { openUser(u) } label: {
                            HStack(spacing: 12) {
                                AvatarView(name: u.name.isEmpty ? u.handle : u.name, photoUrl: u.photoUrl, size: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(u.name.isEmpty ? u.handle : u.name).font(.system(size: 15, weight: .semibold))
                                    Text("@\(u.handle)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "message").foregroundStyle(.tint)
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowSeparator(.hidden)
                    }
                }
                if !nameMatches.isEmpty {
                    Section("Chats") {
                        ForEach(nameMatches) { conv in
                            Button { open(conv.id, conv.name(for: me), conv.photoUrl(for: me)) } label: {
                                ChatRow(conv: conv, me: me, dark: dark)
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                        }
                    }
                }
                if !hits.isEmpty {
                    Section("Messages") {
                        ForEach(hits) { hit in
                            Button { open(hit.cid, hit.chatName, hit.photoUrl) } label: {
                                MessageHitRow(hit: hit)
                            }
                            .buttonStyle(.plain)
                            .listRowSeparator(.hidden)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if trimmed.isEmpty {
                    EmptyStateView(title: "Search messages", icon: "magnifyingglass",
                                   text: "Search names and the text of every message.")
                } else if loadingCorpus && nothingFound {
                    ChatListSkeleton()   // skeleton rows instead of a spinner while indexing
                } else if !loadingCorpus && nothingFound {
                    ContentUnavailableView.search(text: trimmed)
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)   // no top nav bar -> search field anchors at the BOTTOM (above keyboard), consistently
            .background { SearchCancelWatcher(canReturn: { trimmed.isEmpty && path.isEmpty }, onCancel: onCancel) }
            .navigationDestination(for: ChatTarget.self) { t in
                ThreadView(cid: t.id, title: t.name, photoUrl: t.photo).id(t.id)
            }
        }
        .searchable(text: $query,
                    prompt: "Search messages")
        .autoFocusSearch($searchFocused)
        .onChange(of: query) { _, _ in lookupHandle() }   // username (@handle) lookup
        .onAppear {
            repo.start()
            // Focus immediately so the keyboard opens at once; retry shortly as a fallback
            // in case the search field isn't mounted on the very first frame.
            searchFocused = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { searchFocused = true }
            loadTask?.cancel()
            loadingCorpus = corpus.isEmpty
            loadTask = Task {
                let loaded = await MessageSearch.loadCorpus(me: me)
                if Task.isCancelled { return }
                await MainActor.run { corpus = loaded; loadingCorpus = false }
            }
        }
        .onDisappear {
            // Cancel background work so it doesn't linger after navigating away.
            loadTask?.cancel();   loadTask   = nil
            handleTask?.cancel(); handleTask = nil
        }
    }

    private func open(_ cid: String, _ name: String, _ photo: String?) {
        path.append(ChatTarget(id: cid, name: name, photo: photo))
    }

    // Debounced exact @username lookup across ALL users (not just existing chats), so
    // global search finds people by username. Hidden if they're already in the chat list.
    private func lookupHandle() {
        handleTask?.cancel()
        let q = trimmed
        guard q.count >= 2 else { foundByHandle = nil; return }
        handleTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            let u = await ChatService.findByHandle(q)
            await MainActor.run {
                if let u, !nameMatches.contains(where: { $0.otherUid(me) == u.id }) { foundByHandle = u }
                else { foundByHandle = nil }
            }
        }
    }

    // Open (or start) a chat with a user found by @username.
    private func openUser(_ u: UserProfile) {
        Task {
            guard let cid = try? await ChatService.openConversation(other: u) else { return }
            await MainActor.run { open(cid, u.name.isEmpty ? u.handle : u.name, u.photoUrl) }
        }
    }
}

private struct MessageHitRow: View {
    let hit: MessageHit
    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: hit.chatName, photoUrl: hit.photoUrl, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(hit.chatName).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(hit.date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).fixedSize()   // never wrap -> row can't grow vertically
                }
                Text(hit.text).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

// One cached, already-decrypted message (text only) — the unit for fast in-memory search.
struct SearchableMessage {
    let id: String
    let cid: String
    let chatName: String
    let photoUrl: String?
    let text: String
    let date: Date
}

// Loads the recent messages across all chats ONCE (decrypting ONLY the text field, not
// reactions/replies), so typing filters this in memory instead of re-querying Firestore
// and re-decrypting on every keystroke (the cause of the lag/freeze).
enum MessageSearch {
    private static let perChatLimit = 250

    static func loadCorpus(me: String) async -> [SearchableMessage] {
        let convs = await MainActor.run {
            ConversationsRepository.shared.conversations
                .filter { !$0.isCleared(me) }
                .filter { Flags.groupsEnabled || !$0.isGroup }
        }
        let db = Firestore.firestore()
        var out: [SearchableMessage] = []
        // Fetch all chats CONCURRENTLY instead of sequentially — N serial round-trips
        // become a parallel fan-out, so the search index loads much faster on big accounts.
        await withTaskGroup(of: [SearchableMessage].self) { group in
            for c in convs {
                group.addTask {
                    if Task.isCancelled { return [] }
                    guard let snap = try? await db.collection("conversations").document(c.id)
                        .collection("messages")
                        .order(by: "createdAt", descending: true)
                        .limit(to: perChatLimit)
                        .getDocuments() else { return [] }
                    // Warm the keys needed to decrypt: the 1:1 peer, or EVERY author in a group
                    // (group messages are sealed per-sender). Without this, group search indexed
                    // raw ciphertext and could never match plaintext.
                    let isGroup = c.isGroup
                    if isGroup {
                        let authors = Set(snap.documents.compactMap { $0.data()["authorId"] as? String })
                        for a in authors where a != me { _ = await Crypto.shared.preloadKey(a) }
                    } else {
                        _ = await Crypto.shared.preloadKey(c.otherUid(me))
                    }
                    let name = c.name(for: me), photo = c.photoUrl(for: me)
                    // Silent block: the thread hides everything that arrived after the block, and the
                    // chat list freezes at that moment — but search indexed the newest 250 docs
                    // regardless, so a blocked person's new messages were fully readable here and
                    // tapping one opened a thread that doesn't contain it (audit).
                    let blockCutoff = c.isBlockedByMe(me) ? c.blockedAtMillis(me) : 0
                    return snap.documents.compactMap { doc -> SearchableMessage? in
                        let data = doc.data()
                        // View-once is NEVER searchable — the in-chat corpus in this same file
                        // enforces that rule; the global one didn't, so view-once captions leaked
                        // (and stayed searchable after the single view was spent).
                        guard (data["viewOnce"] as? Bool) != true else { return nil }
                        let author = data["authorId"] as? String ?? ""
                        let text = isGroup
                            ? Crypto.shared.decrypt(data["text"] as? String ?? "", cid: c.id, authorId: author)
                            : Crypto.shared.decrypt(data["text"] as? String ?? "", cid: c.id)
                        guard !text.isEmpty else { return nil }
                        let date = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
                        if blockCutoff > 0, author != me,
                           date.timeIntervalSince1970 * 1000 > blockCutoff { return nil }
                        // Index the SAFE label, not the raw "kulan-…:" payload — contact/location
                        // cards then match and display as "Contact"/"Location", never the marker.
                        return SearchableMessage(id: doc.documentID, cid: c.id, chatName: name,
                                                 photoUrl: photo, text: quoteSafeLabel(text), date: date)
                    }
                }
            }
            for await chunk in group { out.append(contentsOf: chunk) }
        }
        return out
    }
}

// MARK: - In-chat search (one conversation's whole history)

// One decrypted message from a single chat, for in-chat search.
struct InChatMessage: Identifiable {
    let id: String
    let text: String
    let authorId: String
    let date: Date
    var tokens: [String] = []   // normalized search tokens, computed ONCE at corpus build (not per keystroke)
}

extension MessageSearch {
    // Load (up to `limit`) of ONE chat's messages, decrypting only the text. Group messages are sealed
    // per-sender, so every author's key is warmed first (same as the global corpus loader).
    // The reference approach indexes messages incrementally instead of re-scanning on every search. Kulan's version:
    // cache the decrypted corpus per chat for a short TTL, so reopening search moments later doesn't
    // re-fetch + re-decrypt up to 1000 messages again.
    private static var corpusCache: [String: (at: Date, corpus: [InChatMessage])] = [:]

    static func loadChat(cid: String, isGroup: Bool, me: String, limit: Int = 1000) async -> [InChatMessage] {
        if let hit = corpusCache[cid], Date().timeIntervalSince(hit.at) < 120 { return hit.corpus }
        let db = Firestore.firestore()
        guard let snap = try? await db.collection("conversations").document(cid)
            .collection("messages")
            .order(by: "createdAt", descending: true)
            .limit(to: limit)
            .getDocuments() else { return [] }
        if isGroup {
            let authors = Set(snap.documents.compactMap { $0.data()["authorId"] as? String })
            for a in authors where a != me { _ = await Crypto.shared.preloadKey(a) }
        } else {
            let other = cid.split(separator: "_").map(String.init).first { $0 != me } ?? ""
            _ = await Crypto.shared.preloadKey(other)
        }
        let out = snap.documents.compactMap { doc -> InChatMessage? in
            let data = doc.data()
            let author = data["authorId"] as? String ?? ""
            let text = isGroup
                ? Crypto.shared.decrypt(data["text"] as? String ?? "", cid: cid, authorId: author)
                : Crypto.shared.decrypt(data["text"] as? String ?? "", cid: cid)
            guard !text.isEmpty else { return nil }
            if data["viewOnce"] as? Bool == true { return nil }   // view-once is never searchable
            let date = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
            // Same raw-marker guard as the global corpus: index/display the safe label.
            let safe = quoteSafeLabel(text)
            return InChatMessage(id: doc.documentID, text: safe, authorId: author, date: date,
                                 tokens: ChatSearch.tokens(safe))
        }
        corpusCache[cid] = (Date(), out)
        return out
    }
}

// Search inside a single conversation. Loads the chat's text history once, filters in memory as you
// type, and hands the picked message id back so ThreadView can scroll to + flash it.
struct InChatSearchView: View {
    let cid: String
    let isGroup: Bool
    let me: String
    var nameFor: (String) -> String = { _ in "" }
    var onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var corpus: [InChatMessage] = []
    @State private var loading = false
    @FocusState private var focused: Bool

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    private var results: [InChatMessage] {
        guard trimmed.count >= 2 else { return [] }   // same 2-char floor as the in-conversation search
        let terms = ChatSearch.queryTerms(trimmed)
        guard !terms.isEmpty else { return [] }
        return Array(corpus.filter { ChatSearch.matches(tokens: $0.tokens, terms: terms) }
            .sorted { $0.date > $1.date }.prefix(100))
    }

    var body: some View {
        NavigationStack {
            List(results) { m in
                Button { onPick(m.id); dismiss() } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            if isGroup {
                                Text(nameFor(m.authorId)).font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.tint).lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Text(m.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary).fixedSize()
                        }
                        Text(highlighted(m.text)).font(.system(size: 15)).lineLimit(2)
                    }
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .overlay {
                if trimmed.isEmpty {
                    EmptyStateView(title: "Search this chat", icon: "magnifyingglass",
                                   text: "Find any message in this conversation.")
                } else if loading && results.isEmpty {
                    ProgressView()
                } else if !loading && results.isEmpty {
                    ContentUnavailableView.search(text: trimmed)
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search this chat")
            .autoFocusSearch($focused)
        }
        .task {
            focused = true
            loading = true
            corpus = await MessageSearch.loadChat(cid: cid, isGroup: isGroup, me: me)
            loading = false
        }
    }

    // Bold the matched span inside the snippet so the hit is obvious.
    private func highlighted(_ text: String) -> AttributedString {
        var str = AttributedString(text)
        let q = trimmed
        guard !q.isEmpty, let r = text.range(of: q, options: .caseInsensitive),
              let lo = AttributedString.Index(r.lowerBound, within: str),
              let hi = AttributedString.Index(r.upperBound, within: str) else { return str }
        str[lo..<hi].font = .system(size: 15, weight: .bold)
        return str
    }
}

// MARK: - Calls: search anyone you've chatted with, tap to call

struct ContactsSearchView: View {
    var onCancel: () -> Void
    init(onCancel: @escaping () -> Void = {}) { self.onCancel = onCancel }
    private var repo = ConversationsRepository.shared
    @Environment(\.colorScheme) private var scheme
    @State private var query = ""
    @State private var pendingCall: PendingCall?   // confirm before dialing (thread-view parity)
    @FocusState private var searchFocused: Bool

    private var me: String { AuthService.shared.uid ?? "" }
    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    private var results: [Conversation] {
        let q = trimmed.lowercased()
        // Exclude groups: 1:1 calling needs a real other-uid; a group's otherUid is "" → startCall(to:"").
        let base = repo.conversations.filter { !$0.isCleared(me) && !$0.isGroup }
        let list = q.isEmpty ? base : base.filter { $0.name(for: me).lowercased().contains(q) }
        return list.sorted { $0.name(for: me).lowercased() < $1.name(for: me).lowercased() }
    }

    var body: some View {
        NavigationStack {
            List(results) { conv in
                Button {
                    // Ask first (never dial on a stray tap) — same confirm as the thread view.
                    pendingCall = PendingCall(uid: conv.otherUid(me), name: conv.name(for: me),
                                              photo: conv.photoUrl(for: me), video: false)
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(name: conv.name(for: me), photoUrl: conv.photoUrl(for: me), size: 46)
                        Text(conv.name(for: me)).font(.system(size: 16, weight: .medium))
                        Spacer()
                        Image(systemName: "phone.fill").foregroundStyle(.tint)
                    }
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .overlay {
                if results.isEmpty {
                    if trimmed.isEmpty {
                        EmptyStateView(title: "Call a contact", icon: "phone",
                                       text: "Search anyone you've chatted with to start a call.")
                    } else {
                        ContentUnavailableView.search(text: trimmed)
                    }
                }
            }
            .navigationTitle("Call")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)   // search field anchors at the BOTTOM, consistently
            .background { SearchCancelWatcher(canReturn: { trimmed.isEmpty }, onCancel: onCancel) }
            // Same native confirm the thread view uses before calling back.
            .alert(pendingCall?.video == true ? "Video call" : "Voice call",
                   isPresented: Binding(get: { pendingCall != nil }, set: { if !$0 { pendingCall = nil } }),
                   presenting: pendingCall) { c in
                Button("Cancel", role: .cancel) { }
                Button("Call") {
                    CallService.shared.startCall(to: c.uid, name: c.name, photo: c.photo, video: c.video)
                }
            } message: { c in
                Text("\(c.video ? "Video call" : "Call") \(c.name)?")
            }
        }
        .searchable(text: $query,
                    prompt: "Search contacts")
        .autoFocusSearch($searchFocused)
        .onAppear { repo.start() }
        .task { searchFocused = true; try? await Task.sleep(nanoseconds: 200_000_000); searchFocused = true }
    }
}

// MARK: - Settings search

struct SettingsSearchView: View {
    var onSignOut: () -> Void
    var onCancel: () -> Void
    init(onSignOut: @escaping () -> Void = {}, onCancel: @escaping () -> Void = {}) {
        self.onSignOut = onSignOut; self.onCancel = onCancel
    }
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    private struct Entry: Identifiable {
        var id: String { title }   // stable identity (was UUID() -> new id each render = List flicker)
        let title: String
        let icon: String
        /// true = an SF Symbol, false = one of the app's own icon assets. Same distinction
        /// SettingsRowLabel makes, because these rows now ARE settings rows.
        var system = false
        let keywords: String
        let dest: AnyView
    }

    private var entries: [Entry] {
        [
            Entry(title: "Account", icon: "ic_account",
                  keywords: "account name username id sign out delete",
                  dest: AnyView(AccountSettingsView(onSignOut: onSignOut))),
            Entry(title: "My Profile", icon: "person.text.rectangle", system: true,
                  keywords: "profile bio photo edit stories",
                  dest: AnyView(MyProfileView())),
            Entry(title: "Devices", icon: "ic_linked_devices",
                  keywords: "devices sessions linked signed in log out sign out",
                  dest: AnyView(DevicesView())),
            Entry(title: "Notifications", icon: "ic_notifications",
                  keywords: "notifications push sound vibrate preview",
                  dest: AnyView(NotificationsSettingsView())),
            Entry(title: "Appearance", icon: "paintbrush", system: true,
                  keywords: "appearance theme dark light",
                  dest: AnyView(AppearanceSettingsView())),
            Entry(title: "Stories", icon: "ic_stories",
                  keywords: "stories status view receipts",
                  dest: AnyView(StorySettingsView())),
            Entry(title: "Privacy & Security", icon: "ic_privacy",
                  keywords: "privacy security read receipts typing last seen app lock screen",
                  dest: AnyView(PrivacySettingsView())),
            Entry(title: "Blocked Users", icon: "hand.raised", system: true,
                  keywords: "blocked block users",
                  dest: AnyView(BlockedUsersView())),
            Entry(title: "Help & About", icon: "questionmark.circle", system: true,
                  keywords: "help about version",
                  dest: AnyView(AboutView())),
        ]
    }

    private var results: [Entry] {
        let q = trimmed.lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter { $0.title.lowercased().contains(q) || $0.keywords.contains(q) }
    }

    var body: some View {
        NavigationStack {
            List(results) { e in
                NavigationLink { e.dest } label: {
                    // The SAME row as the settings page itself, so a result and the row it leads to
                    // are the same thing wearing the same icon.
                    e.system ? SettingsRowLabel(e.title, system: e.icon)
                             : SettingsRowLabel(e.title, e.icon)
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if results.isEmpty { ContentUnavailableView.search(text: trimmed) }
            }
            .navigationTitle("Search Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)   // search field anchors at the BOTTOM, consistently
            .background { SearchCancelWatcher(canReturn: { trimmed.isEmpty }, onCancel: onCancel) }
        }
        .searchable(text: $query,
                    prompt: "Search settings")
        .autoFocusSearch($searchFocused)
        .task { searchFocused = true; try? await Task.sleep(nanoseconds: 200_000_000); searchFocused = true }
    }
}
