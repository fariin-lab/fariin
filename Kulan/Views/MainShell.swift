import SwiftUI
import UIKit

/// Ticking a row on or off, everywhere a list in this file has multi-select.
///
/// It exists because the three lists had drifted into three different answers: the chat list used
/// `.smooth(0.2)`, the archive list repeated that by hand, and the calls list had NO animation at
/// all, so its circle simply appeared. One function means a tick feels the same wherever you are.
///
/// The spring is deliberate. `.smooth` is a pure ease and reads as a fade; a light overshoot is what
/// makes a tick feel like it LANDED. It is small on purpose (0.24s, damping 0.7): this fires on every
/// row you touch while picking twenty of them, and anything bouncier becomes noise by the third tap.
///
/// ⚠️ The circle itself is Apple's, drawn by `List(selection:)` in edit mode, so the curve and the
/// haptic are the whole of what we control here. A tick that draws its check on and scales from
/// nothing needs our own view, which is a much larger change to this file — see the note on the
/// row's structural identity in `chatListRow`.
/// ⚠️ A `Binding`, NOT `inout`. `inout` on a `@State` property is copy-in/copy-out: the assignment
/// inside `withAnimation` would land on a local temporary and only be written back to the real
/// storage when this function RETURNS, which is after the transaction has closed. The tick would
/// snap, the code would look correct, and nothing would say so. A Binding's setter runs at the point
/// of assignment, so it is inside the transaction where it belongs.
@MainActor func toggleTick(_ id: String, in selection: Binding<Set<String>>) {
    // The system's own tick sound-and-feel. `.selectionChanged()` is the light one Apple uses for a
    // picker detent, NOT an impact — an impact on every row of a twenty-row selection is a hammer.
    UISelectionFeedbackGenerator().selectionChanged()
    var next = selection.wrappedValue
    if next.contains(id) { next.remove(id) } else { next.insert(id) }
    withAnimation(.spring(response: 0.24, dampingFraction: 0.7)) { selection.wrappedValue = next }
}

// ⚠️ `StoryPresentation` IS GONE, AND SO IS THE FLAT WINDOW DIM IT DROVE (2026-08-07).
//
// It was one bool that switched a `Color.black.opacity(0.45)` over this whole shell — tab bar
// included — for as long as a story cover was up. It existed because a cover cannot darken what is
// behind it: anything inside the cover shrinks with the cover. Every door is on `StoryZoomPresenter`
// now, and that screen paints its own wall on the flight's own fraction (`heroDim`), so the backdrop
// answers to the finger continuously instead of snapping to grey on the first frame and back to
// white on the last. That snap is what the owner called "not fluid, not bound to the story frame".
//
// Do not reintroduce a boolean dim to "help" a door. Two dims on one flight is two curves fighting
// over the same pixels, and only one of them can be the one his finger is drawing.

// Native TabView keeps both tabs permanently mounted -> the header avatar never
// unmounts/blinks on tab switch (the RN bug, solved structurally).
struct MainShell: View {
    var onSignOut: () -> Void
    private var call: CallService { CallService.shared }
    private var profile = ProfileStore.shared
    private var callsRepo = CallsRepository.shared   // @Observable: drives the missed-call tab badge
    @State private var settingsIcon: UIImage?
    @State private var tab = 0
    @State private var previousTab = 0   // last non-search tab → drives what the search circle searches
    // Missed-call badge on the Calls tab: incoming missed calls newer
    // than the last time the tab was viewed. Local-only "seen" watermark.
    @AppStorage("callsSeenAt") private var callsSeenAt: Double = 0
    private var missedBadge: Int {
        callsRepo.calls.filter { $0.missedIncoming && $0.date.timeIntervalSince1970 > callsSeenAt }.count
    }

    // CONVERSATIONS WAITING, NOT MESSAGES WAITING — how the standard messengers badge it. One person
    // sending five messages moves this by ONE, not five: the badge answers "how many chats do I need to
    // open", which is the question a chat list badge is actually for.
    //
    // The filter is deliberately the same one `markAllRead` uses, so the badge and the action that
    // clears it can never disagree about what counts: not cleared, not archived, and not a chat we have
    // silently blocked (a blocked contact's messages never badge a row either).
    //
    // It is computed, not stored, so it needs no invalidation: opening a chat, marking one read, or a
    // new message arriving all change `repo.conversations`, and @Observable re-reads this on the spot.
    private var chatsRepo = ConversationsRepository.shared
    private var unreadChatsBadge: Int {
        let me = AuthService.shared.uid ?? ""
        guard !me.isEmpty else { return 0 }
        // The official channel counts here exactly like any other chat. It is MUTED, not silent:
        // muting stops the noise, it does not hide that something arrived, and a row showing an
        // unread badge while the tab above it shows none is the kind of disagreement that reads as
        // a bug (the same rule the blocked-chat audit landed on).
        return (chatsRepo.conversations + [OfficialChannelStore.shared.listEntry].compactMap { $0 }).filter {
            !$0.isCleared(me) && !$0.isArchived(me) && !$0.isBlockedByMe(me)
                && (Flags.groupsEnabled || !$0.isGroup)   // audit: a hidden legacy group badged a list that refused to show it
                // `hasUnreadMark`, not a count: a chat you marked unread yourself still badges the
                // tab, it just does not claim a number. See Conversation.unread.
                && $0.hasUnreadMark(me)
        }.count
    }

    init(onSignOut: @escaping () -> Void) { self.onSignOut = onSignOut }

    var body: some View {
        // iOS 26 gets the new `Tab` API: floating Liquid-Glass pill (Chats · Calls · Settings)
        // with a native selected-tab highlight, plus the `.search` role tab drawn as the
        // SEPARATE circular button detached to the right. Older OS (deployment target 17.0)
        // can't use the `Tab` API, so it falls back to the classic `.tabItem` bar with a
        // normal 4th Search tab — same screens, just not the floating/detached styling.
        Group {
            if #available(iOS 26.0, *) {
                modernTabView
            } else {
                legacyTabView
            }
        }
        // THE VOICE NOTE THAT IS STILL PLAYING, wherever you have walked to.
        //
        // `safeAreaInset` rather than an overlay, deliberately: an overlay would sit ON TOP of each
        // tab's own header, and every screen underneath would keep laying out as though the bar were
        // not there. An inset makes the room, so nothing is covered and nothing has to know about it.
        //
        // Mounted here, on the tab shell, so it survives moving between tabs and pushing into another
        // chat. It draws nothing at all unless a note is playing outside the chat on screen — see
        // `VoiceNotePlayer.barVisible`.
        .safeAreaInset(edge: .top, spacing: 0) { VoiceNoteBar() }
        // (The window dim that used to live here is gone — see the note above `MainShell`. The
        // presenter's own wall covers the tab bar and every tab's content, because it IS a screen
        // over them, and it is driven by the flight's fraction rather than by a bool.)
        // A pending chat (from a notification tap or the Calls "Go to Chat" menu) must
        // foreground the Chats tab — otherwise it opens on a hidden tab and looks like a no-op.
        .onChange(of: AppRouter.shared.pendingChatId) { _, id in
            if id != nil { tab = 0 }
        }
        // REMOVED: the conversations delta-detector banner. It was the SECOND in-app banner system.
        // `InAppBannerCenter`, added in build 383 and mounted on RootView, is driven by the push actually
        // arriving while the app is foregrounded — so one incoming message tripped both: the push fired
        // that one, and the Firestore listener updating the conversation fired this one. Two banners for
        // one message (user report).
        //
        // The push-driven one is the keeper: it rides above every screen rather than only MainShell, it
        // shows nothing for the chat you are already looking at, and it plays the chosen tone itself.
        // `InAppNotify` stays as a type because the Settings sound picker uses its `playTone` preview —
        // it just no longer presents anything.
        //
        // Known trade-off, stated rather than hidden: with notification permission denied there is no
        // push, so there is no in-app banner either. The delta detector used to cover that case. Showing
        // everyone two banners to serve a user who has switched notifications off is the wrong trade.
        // Keep Media (Settings > Storage): age out old re-downloadable photo cache on launch.
        .task {
            let d = UserDefaults.standard.integer(forKey: "keepMediaDays")
            if d > 0 { DiskImageCache.shared.sweep(olderThanDays: d) }
        }
        // An invite deep link (kulan://g/<code>) presents its Join sheet from the Chats tab — foreground
        // it so the sheet isn't dropped on a hidden tab.
        .onChange(of: AppRouter.shared.pendingInviteCode) { _, code in
            if code != nil { tab = 0 }
        }
        // Call UI is mounted at the root (CallContainer in RootView) so it survives all
        // navigation. Here we only start listening for incoming calls.
        .onAppear {
            call.observeIncoming()
            // Fresh install: a 0 watermark counted EVERY historical missed call in the badge —
            // treat everything before first launch as seen. (Same unit as the compare above: seconds.)
            if callsSeenAt == 0 { callsSeenAt = Date().timeIntervalSince1970 }
        }
        .task(id: profile.me?.photoUrl) { await loadSettingsIcon() }
        // Remember the last real tab so the search circle (tab 3) knows whether to do a
        // Chats / Calls / Settings search.
        .onChange(of: tab) { _, new in
            if new != 3 { previousTab = new }
            if new == 1 { callsSeenAt = Date().timeIntervalSince1970 }   // viewing Calls clears the badge
        }
        // New records landing while the user is already ON the Calls tab count as seen too.
        .onChange(of: callsRepo.calls) { _, _ in
            if tab == 1 { callsSeenAt = Date().timeIntervalSince1970 }
        }
        // Load call history at startup so the badge is right before the tab is ever opened
        // (CallsView's own .task keeps it fresh after; the 30s TTL stops double-fires).
        // STAGGERED ~1.5s (deferred app-readiness): this isn't needed for the first frame, and launching
        // it alongside the chat-list listener + key warm + stories load made a main-thread stampede in
        // the fragile launch window. Delaying non-critical launch work spreads the load out.
        .task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await CallsRepository.shared.load()
        }
    }

    // Your profile photo as the Settings tab icon (full-color circle); falls back to a
    // person glyph — outline when inactive, filled when this tab is active. SwiftUI does NOT
    // auto-swap a base SF Symbol to its .fill on selection (it only tints), so we pick it.
    @ViewBuilder private var settingsTabLabel: some View {
        Label {
            Text("Settings")
        } icon: {
            if let ui = settingsIcon {
                Image(uiImage: ui).renderingMode(.original)
            } else {
                Image(systemName: tab == 2 ? "person.crop.circle.fill" : "person.crop.circle")
                    .contentTransition(.symbolEffect(.replace))   // smooth fill<->outline swap
            }
        }
    }

    @available(iOS 26.0, *)
    private var modernTabView: some View {
        TabView(selection: $tab) {
            // FILLED WHEN YOU ARE ON IT, OUTLINE WHEN YOU ARE NOT — the Calls tab beside it has always
            // worked this way (`phone` / `phone.fill`) and this one never did, so it was the same
            // solid bubble whether you were in it or not and only the capsule said where you were
            // (owner 2026-08-19, asking how the reference app keeps its active tab solid black).
            //
            // This is also WHY a black tab bar works at all. When the tint is the same colour in both
            // states — ours is black in light and white in dark, deliberately — colour cannot carry
            // the state, so the SHAPE has to. `ic_chat_outline` is the same path as `ic_chat`,
            // stroked instead of filled, so the two cannot drift apart.
            Tab("Chats", image: tab == 0 ? "ic_chat" : "ic_chat_outline", value: 0) {
                ChatsView(onSignOut: onSignOut)
            }
            .badge(unreadChatsBadge)   // 0 hides it, same as the Calls tab
            Tab("Calls", systemImage: tab == 1 ? "phone.fill" : "phone", value: 1) {
                CallsView()
            }
            .badge(missedBadge)   // 0 hides it
            Tab(value: 2) {
                SettingsView(onSignOut: onSignOut, asTab: true)
            } label: {
                settingsTabLabel
            }
            // Detached circular search button (native iOS 26 search role). Context-aware:
            // searches Chats / Calls / Settings depending on the tab you came from.
            Tab(value: 3, role: .search) {
                SearchHubView(context: previousTab, onSignOut: onSignOut, onCancel: { tab = previousTab })
            }
        }
    }

    private var legacyTabView: some View {
        TabView(selection: $tab) {
            ChatsView(onSignOut: onSignOut)
                .tabItem { Label("Chats", image: "ic_chat") }
                .badge(unreadChatsBadge)
                .tag(0)
            CallsView()
                .tabItem { Label("Calls", systemImage: tab == 1 ? "phone.fill" : "phone") }
                .badge(missedBadge)
                .tag(1)
            SettingsView(onSignOut: onSignOut, asTab: true)
                .tabItem { settingsTabLabel }
                .tag(2)
            SearchHubView(context: previousTab, onSignOut: onSignOut, onCancel: { tab = previousTab })
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(3)
        }
    }

    private func loadSettingsIcon() async {
        guard let s = profile.me?.photoUrl, let url = URL(string: s) else { return }
        // Persistent cache first (same store as every other avatar) — was a raw URLSession fetch that
        // re-downloaded my own profile photo on every launch.
        var img = await DiskImageCache.shared.image(for: s)
        if img == nil, let (data, _) = try? await MediaSession.shared.data(from: url), let ui = UIImage(data: data) {
            DiskImageCache.shared.store(ui, data: data, for: s)
            img = ui
        }
        guard let img else { return }
        let circ = img.circularIcon(28)   // tab-icon size — 56 overflowed onto the label
        await MainActor.run { settingsIcon = circ }
    }
}

// Render a circular, aspect-filled thumbnail for use as a (non-tinted) tab-bar icon.
private extension UIImage {
    func circularIcon(_ size: CGFloat) -> UIImage {
        let s = CGSize(width: size, height: size)
        return UIGraphicsImageRenderer(size: s).image { _ in
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: s)).addClip()
            let scale = Swift.max(s.width / self.size.width, s.height / self.size.height)
            let d = CGSize(width: self.size.width * scale, height: self.size.height * scale)
            self.draw(in: CGRect(x: (s.width - d.width) / 2, y: (s.height - d.height) / 2,
                                 width: d.width, height: d.height))
        }.withRenderingMode(.alwaysOriginal)
    }
}

// Pending outbound call awaiting the user's confirm — thread-view parity (its call-history
// rows ask first); these surfaces dialed instantly on a stray tap.
struct PendingCall: Identifiable {
    let uid: String
    let name: String
    let photo: String?
    let video: Bool
    var id: String { uid + (video ? "-v" : "-a") }
}

// Native Phone-app-style call history (mockup IMG_4467): All / Missed segmented filter,
// search, rows with avatar, name (red if missed), direction, time, and an info button.
// Tap a row to call back; (i) opens the contact. Indigo brand kept.
struct CallsView: View {
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    @State private var repo = CallsRepository.shared
    @State private var filter = 0            // 0 = All, 1 = Missed
    @State private var profileTarget: CallEntry?
    @State private var showNew = false
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var showDeleteCalls = false
    @State private var searchText = ""
    @State private var pendingCall: PendingCall?   // confirm before dialing (thread-view parity)

    private var shown: [CallEntry] {
        var list = filter == 1 ? repo.calls.filter { $0.missedIncoming } : repo.calls
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty { list = list.filter { $0.name.lowercased().contains(q) } }
        return list
    }
    // Consecutive same-kind calls collapse into one "name (3)" row (like the native Phone app):
    // same person, same direction/outcome/type, same day, adjacent in the list.
    struct CallRun: Identifiable {
        var entries: [CallEntry]          // newest first (list order)
        var latest: CallEntry { entries[0] }
        var id: String { latest.id }
        var ids: Set<String> { Set(entries.map(\.id)) }
    }
    private var shownRuns: [CallRun] {
        var runs: [CallRun] = []
        for e in shown {
            if let last = runs.last?.latest,
               last.otherUid == e.otherUid, last.mine == e.mine,
               last.missed == e.missed, last.video == e.video,
               Calendar.current.isDate(last.date, inSameDayAs: e.date) {
                runs[runs.count - 1].entries.append(e)
            } else {
                runs.append(CallRun(entries: [e]))
            }
        }
        return runs
    }
    private func deleteRun(_ r: CallRun) {
        Task { await repo.delete(ids: r.ids) }   // a grouped row deletes ALL calls in the run
    }
    /// Is everything currently on screen already ticked? Drives the Select All button's two states.
    /// ⚠️ Compared against `shownRuns`, the same list the button acts on, so filtering or searching
    /// mid-selection cannot leave the button claiming "all" about rows that are no longer visible.
    private var allShownSelected: Bool {
        !shownRuns.isEmpty && shownRuns.allSatisfy { selection.contains($0.id) }
    }

    private func deleteSelectedCalls() {
        // A run's id is its NEWEST entry's id, and runs are regrouped live — a call ending mid-
        // selection (recordCall force-reloads the repo), or a change of filter/search, gives that
        // run a new id. Matching only against the CURRENT runs then silently dropped those rows
        // while the toolbar still said "N Selected", so Delete removed fewer than it promised.
        // Falling back to the id itself covers a run whose grouping moved under us (audit).
        var ids = Set<String>()
        for id in selection {
            if let run = shownRuns.first(where: { $0.id == id }) { ids.formUnion(run.ids) }
            else { ids.insert(id) }   // the run regrouped; its newest entry id is still a real record
        }
        Task { await repo.delete(ids: ids) }
        selecting = false; selection = []
    }

    var body: some View {
        NavigationStack {
            Group {
                if !repo.hasLoaded && ConversationsRepository.shared.expectsChats {
                    // Shimmer only for an account with history on this device — a fresh sign-up goes
                    // straight to the empty state instead of fake rows (same rule as the chat list).
                    CallListSkeleton()
                } else if !repo.hasLoaded || repo.calls.isEmpty {
                    EmptyStateView(title: "No Calls Yet", icon: "phone",
                                   text: "Your call history will appear here.")
                } else {
                    List(selection: $selection) {   // stable binding (Set selects only in edit mode) -> smooth edit transition
                        ForEach(shownRuns) { run in
                            let call = run.latest
                            CallHistoryRow(
                                call: call,
                                count: run.entries.count,
                                onProfile: { profileTarget = call },
                                onCall: {   // call back the same way (video stays video) — after a confirm
                                    pendingCall = PendingCall(uid: call.otherUid, name: call.name, photo: call.photoUrl, video: call.video)
                                }
                            )
                            // In edit mode the row's own buttons stayed live, so tapping the name or
                            // avatar pushed a profile and the round button dialled — instead of
                            // selecting the row. The chat list got this exact fix; this list didn't.
                            //
                            // allowsHitTesting, not disabled: disabled ALSO dims, and a greyed-out
                            // call list reads as switched off rather than ready to be picked from.
                            // Same fix, same reason, as the chat list one row type over.
                            .allowsHitTesting(!selecting)
                            .overlay {
                                if selecting {
                                    Color.clear.contentShape(Rectangle()).onTapGesture {
                                        toggleTick(run.id, in: $selection)
                                    }
                                }
                            }
                            .tag(run.id)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { deleteRun(run) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(.red)   // force red — the app's white tint was washing it out
                            }
                            // Long-press menu — every action is real.
                            // (Tick reposition lives in ChatRow; see chat list.)
                            // ⚠️ EVERY GLYPH CARRIES ITS OWN INK — `MenuIcon(ink:)`, never a bare
                            // `systemImage:`. A `.contextMenu` becomes a UIKit `UIMenu`, which tints
                            // its images with the presenting view's `tintColor`, and the app's
                            // `.tint(.primary)` is a SwiftUI value that never reaches it: white
                            // lettering, system-blue glyphs. See `MenuIcon.ink`.
                            .contextMenu {
                                Button {
                                    pendingCall = PendingCall(uid: call.otherUid, name: call.name, photo: call.photoUrl, video: false)
                                } label: { Label { Text("Voice Call") } icon: { MenuIcon(system: "phone", ink: .label) } }
                                Button {
                                    pendingCall = PendingCall(uid: call.otherUid, name: call.name, photo: call.photoUrl, video: true)
                                } label: { Label { Text("Video Call") } icon: { MenuIcon(system: "video", ink: .label) } }
                                Button {
                                    AppRouter.shared.pendingChatName = call.name
                                    AppRouter.shared.pendingChatPhoto = call.photoUrl
                                    AppRouter.shared.pendingChatId = call.cid
                                } label: {
                                    Label { Text("Chats") } icon: { MenuIcon("ic_menu_chat", ink: .label) }
                                }
                                Button {
                                    withAnimation(.smooth(duration: 0.35)) { selecting = true; selection = [run.id] }
                                } label: { Label { Text("Select") } icon: { MenuIcon(system: "checkmark.circle", ink: .label) } }
                                Divider()
                                // Red, to match its own title — the one item whose ink is not the label's.
                                Button(role: .destructive) { deleteRun(run) } label: {
                                    Label { Text("Delete") } icon: { MenuIcon(system: "trash", ink: .systemRed) }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    // ANIMATE THE HISTORY CHANGING, NOT THE QUESTION CHANGING (owner 2026-08-13: tap
                    // Missed and "the whole page sorts in front of me"). Keyed on `shownRuns` this
                    // fired on the FILTER and the SEARCH too, so switching All → Missed sprang every
                    // surviving row into a new position while the rest faded — a re-sort performed
                    // for somebody who only asked a different question. Keyed on the call count it
                    // still animates the things that are genuinely movement in the list (a call
                    // arrives, a run is deleted), and a filter or a search term, which change no
                    // history at all, simply show their answer.
                    .animation(.spring(response: 0.38, dampingFraction: 0.86), value: repo.calls.count)
                    .environment(\.defaultMinListRowHeight, 56)   // tight, compact rows
                    .environment(\.editMode, .constant(selecting ? .active : .inactive))
                    // THE SELECTION TICK. Edit mode draws its circle in the TINT, and this app tints
                    // itself `.primary` — so the filled tick was a white disc with a white check
                    // inside it, on a dark phone. Selected and unselected looked identical; the only
                    // way to know was the "4 Selected" title (owner 2026-08-16, calls page).
                    // Apple's own systemBlue, the same value and for the same reason as the unread
                    // count on the scroll-to-bottom button in ThreadView. Every swipe action in this
                    // list already names its own colour, so nothing else here moves.
                    .tint(Theme.defaultBubble(dark))
                }
            }
            .navigationTitle("Calls")
            .searchable(text: $searchText, prompt: "Search calls")
            .toolbar {
                if selecting {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { withAnimation(.smooth(duration: 0.35)) { selecting = false; selection = [] } } label: { Image(systemName: "xmark") }.tint(.primary)
                    }
                    // SELECT ALL, which this list never had (owner 2026-08-16, comparing against two
                    // other messengers). It is NOT a faster Delete All — that button is already
                    // beside it. It is for the opposite job: take everything, then untick the two
                    // you want to keep, instead of tapping forty rows by hand.
                    //
                    // ⚠️ It selects `shownRuns`, not the whole history: the All/Missed filter and the
                    // search box are both live in selection mode, so "all" has to mean what is on
                    // screen. Selecting hidden rows would delete calls the user cannot see.
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            UISelectionFeedbackGenerator().selectionChanged()
                            withAnimation(.spring(response: 0.24, dampingFraction: 0.7)) {
                                selection = allShownSelected ? [] : Set(shownRuns.map(\.id))
                            }
                        } label: {
                            Image(systemName: allShownSelected ? "checkmark.circle.fill" : "checkmark.circle")
                        }
                        .tint(.primary)
                        .disabled(shownRuns.isEmpty)
                    }
                    ToolbarItem(placement: .principal) {
                        Text(selection.isEmpty ? "Select Calls" : "\(selection.count) Selected").font(.headline)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .destructive) { showDeleteCalls = true } label: {
                            Image(systemName: "trash")
                        }
                        .disabled(selection.isEmpty).tint(.red)
                    }
                } else {
                    if !repo.calls.isEmpty {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Edit") { withAnimation(.smooth(duration: 0.35)) { selecting = true } }.tint(.primary)
                        }
                    }
                    ToolbarItem(placement: .principal) {
                        Picker("", selection: $filter) {
                            Text("All").tag(0)
                            Text("Missed").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 150)   // compact All/Missed pill, not full-width
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showNew = true } label: { Image(systemName: "phone.badge.plus") }
                    }
                }
            }
            .task { await repo.load() }
            .refreshable { await repo.load(force: true) }
            .confirmationDialog("Delete \(selection.count) call\(selection.count == 1 ? "" : "s")?",
                                isPresented: $showDeleteCalls, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { deleteSelectedCalls() }
                Button("Cancel", role: .cancel) {}
            }
            // Tapping a row pushes the contact's profile (back chevron, native). Calling
            // back happens only via the round phone button on the row.
            .navigationDestination(item: $profileTarget) { c in
                ContactInfoView(cid: c.cid, name: c.name, photoUrl: c.photoUrl, source: .calls)
            }
            .sheet(isPresented: $showNew) { NewCallView() }
            // Same native confirm the thread view uses — never dial on a stray tap.
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
    }
}

struct CallHistoryRow: View {
    let call: CallEntry
    var count: Int = 1        // consecutive same-kind calls collapsed into this row → "name (3)"
    var onProfile: () -> Void
    var onCall: () -> Void

    // Video calls get the camera-direction glyphs (Phone-app style); voice keeps the arrows.
    private var directionIcon: String {
        call.video ? (call.mine ? "arrow.up.right.video.fill" : "arrow.down.left.video.fill")
                   : (call.mine ? "arrow.up.right" : "arrow.down.left")
    }
    // Red "Missed" ONLY for calls THEY placed that I didn't answer; my own unanswered
    // outgoing call reads "Outgoing" like every big app (was wrongly red before).
    private var directionText: String { call.mine ? "Outgoing" : (call.missed ? "Missed" : "Incoming") }

    var body: some View {
        HStack(spacing: 12) {
            // Whole left area (avatar, name, direction, time) → opens the contact profile.
            Button(action: onProfile) {
                HStack(spacing: 12) {
                    AvatarView(name: call.name, photoUrl: call.photoUrl, size: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(count > 1 ? "\(call.name) (\(count))" : call.name)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(call.missedIncoming ? Color.red : Color.primary)
                                .lineLimit(1)
                            VerifiedMark(uid: call.otherUid, size: 13)
                        }
                        HStack(spacing: 4) {
                            Image(systemName: directionIcon).font(.system(size: 11, weight: .semibold))
                            Text(directionText).font(.system(size: 14))
                        }
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(timeLabel(call.date)).font(.system(size: 14)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Round call-back button → the ONLY thing that calls back; camera for video calls.
            Button(action: onCall) {
                Image(systemName: call.video ? "video.fill" : "phone.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.tint)
                    .frame(width: 38, height: 38)
                    .background(Color.primary.opacity(0.07), in: Circle())
                    .frame(width: 44, height: 44)        // 44pt hit target (HIG min) without enlarging the visual
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }

    private func timeLabel(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: d, to: Date()).day, days < 7 {
            return d.formatted(.dateTime.weekday(.wide))
        }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }
}

// "New call" picker: A–Z grouped contacts, each with REAL voice + video call buttons + a side
// index. (No "Create Call Link" / phone-number search — those aren't real Fariin features.)
struct NewCallView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var repo = ConversationsRepository.shared
    @State private var query = ""
    @State private var pendingCall: PendingCall?   // confirm before dialing (thread-view parity)
    private var me: String { AuthService.shared.uid ?? "" }

    private var sections: [(letter: String, convs: [Conversation])] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = repo.conversations.filter { !$0.otherUid(me).isEmpty && !$0.isGroup }
        let filtered = q.isEmpty ? all : all.filter { $0.displayName(me).lowercased().contains(q) }
        let grouped = Dictionary(grouping: filtered) { c -> String in
            let n = c.displayName(me).trimmingCharacters(in: .whitespaces).uppercased()
            guard let f = n.first, f.isLetter else { return "#" }
            return String(f)
        }
        return grouped
            .map { ($0.key, $0.value.sorted { $0.displayName(me).lowercased() < $1.displayName(me).lowercased() }) }
            .sorted { $0.letter == "#" ? false : ($1.letter == "#" ? true : $0.letter < $1.letter) }
    }
    private var indexLetters: [String] { sections.map(\.letter) }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if sections.isEmpty {
                        ContentUnavailableView("No contacts", systemImage: "phone",
                                               description: Text("Start a chat first, then you can call them."))
                    } else {
                        ForEach(sections, id: \.letter) { section in
                            Section(section.letter) {
                                ForEach(section.convs) { c in callRow(c) }
                            }
                            .id(section.letter)
                        }
                    }
                }
                .listStyle(.insetGrouped)   // grouped cards (matches the reference)
                .overlay(alignment: .trailing) {
                    if query.isEmpty && indexLetters.count > 1 {
                        VStack(spacing: 1) {
                            ForEach(indexLetters, id: \.self) { l in
                                Text(l).font(.system(size: 11, weight: .semibold)).foregroundStyle(.tint)
                                    .frame(width: 16).contentShape(Rectangle())
                                    .onTapGesture { withAnimation { proxy.scrollTo(l, anchor: .top) } }
                            }
                        }
                        .padding(.trailing, 1)
                    }
                }
            }
            .navigationTitle("New call")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search name or username")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "xmark") }.tint(.primary) }
            }
            // Same native confirm the thread view uses — never dial on a stray tap.
            .alert(pendingCall?.video == true ? "Video call" : "Voice call",
                   isPresented: Binding(get: { pendingCall != nil }, set: { if !$0 { pendingCall = nil } }),
                   presenting: pendingCall) { c in
                Button("Cancel", role: .cancel) { }
                Button("Call") {
                    CallService.shared.startCall(to: c.uid, name: c.name, photo: c.photo, video: c.video)
                    dismiss()
                }
            } message: { c in
                Text("\(c.video ? "Video call" : "Call") \(c.name)?")
            }
        }
    }

    private func callRow(_ c: Conversation) -> some View {
        HStack(spacing: 12) {
            AvatarView(name: c.displayName(me), photoUrl: c.displayPhoto(me), size: 42)
            Text(c.displayName(me)).font(.system(size: 17, weight: .medium)).lineLimit(1)
            Spacer()
            Button { call(c, video: false) } label: {
                Image(systemName: "phone").font(.system(size: 19)).foregroundStyle(.primary)
            }
            .buttonStyle(.plain).frame(width: 44, height: 44).contentShape(Rectangle())
            Button { call(c, video: true) } label: {
                Image(systemName: "video").font(.system(size: 19)).foregroundStyle(.primary)
            }
            .buttonStyle(.plain).frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .padding(.vertical, 2)
    }

    private func call(_ c: Conversation, video: Bool) {
        // Ask first; the alert's Call button dials + dismisses.
        pendingCall = PendingCall(uid: c.otherUid(me), name: c.displayName(me),
                                  photo: c.displayPhoto(me), video: video)
    }
}

struct ChatsView: View {
    var onSignOut: () -> Void
    init(onSignOut: @escaping () -> Void = {}) { self.onSignOut = onSignOut }
    private var repo = ConversationsRepository.shared
    private var profile = ProfileStore.shared
    private var router = AppRouter.shared
    private var storiesRepo = StoriesRepository.shared   // @Observable: drives the chat-list story rings
    private var officialChannel = OfficialChannelStore.shared   // @Observable: the one synthetic row in the list
    @Environment(\.colorScheme) private var scheme
    @State private var showNew = false
    /// FALSE UNTIL THE LIST HAS FINISHED ARRIVING, and it gates the reorder animation.
    ///
    /// The rows animate when a chat bumps to the top, which is right. On a cold launch it was also
    /// animating the list COMING INTO EXISTENCE: the cached chats land, the first server snapshot
    /// reorders them, and the official channel arrives separately from its own store, so `visible`
    /// changed three times in about a second and every row sprang toward a new position on each
    /// change. Mid-flight that draws rows on top of one another — the owner caught Fariin sitting
    /// across x test, half faded, on first open.
    ///
    /// An arrival is not a rearrangement. Nothing should animate until the list is a list.
    @State private var listSettled = false
    @State private var chatFilter = 0   // 0 = all, 1 = unread
    @State private var path = NavigationPath()
    // NO "CURRENTLY OPEN CHAT" HIGHLIGHT. There was one here, and it is gone on the owner's word
    // (2026-08-03): "highlight only while the user's finger is touching it… never during the back
    // swipe". The whole highlight is Apple's pressed state now and nothing of ours — see the note at
    // the row's Button.
    @State private var pendingDelete: Conversation?
    @State private var pendingMute: Conversation?
    // Multi-select edit mode.
    @State private var selecting = false
    @State private var selection = Set<String>()
    // A page in the chat list's own stack. NavigationPath is type-erased, so one case is all the
    // archive needs to become a destination.
    enum ArchiveRoute: Hashable { case archive }
    @State private var showDeleteSelected = false
    @State private var showCompose = false
    @State private var showMyQR = false   // welcome empty-state → My QR Code sheet
    @State private var welcomeGreet = 0   // one-shot greeting bounce on the welcome glyph
    /// ⚠️ THE COVER IS GONE, AND SO ARE `viewerSourceID` AND `viewerHero` (2026-08-07, migration
    /// complete). Every story door in the app — this row, the chat-row rings, the archive, both
    /// profiles, a reply quote and the uploading card — now opens through `StoryDoor`, which is our
    /// own presentation, our own gesture and our own animation end to end. There is no
    /// `fullScreenCover` and no `.navigationTransition(.zoom(...))` left on any of them.
    ///
    /// Do not bring one back to "fix" a door. Two presentations for one interaction is what made the
    /// scroll-down feel like a different gesture depending on which circle you had tapped, and it is
    /// what build 481's crash cost. `StoryDoor` is the one way in.
    @State private var profileGroup: StoryGroup?
    /// Whether a story viewer is up, so the row can hold its order still while one is. Read from the
    /// door rather than mirrored here — a second copy of this was how the row froze on a viewer that
    /// had already closed.
    private var storyDoorState = StoryDoorState.shared
    // Stories row scrolls WITH the chat list: the row stays OUTSIDE the List (per-card
    // long-press dies inside a List row — build 147) but is offset 1:1 by the list's
    // scroll, and the List gets a matching top margin so rows start below it.
    @State private var chatScrollY: CGFloat = 0
    @State private var storiesRowHeight: CGFloat = (UIScreen.main.bounds.width - 54) / 4 * 1.46 + 41
    // Stories opt-out (Settings > Stories > Turn Off Stories): the row disappears and chat-row
    // rings go dark — the whole surface, not a hidden-but-alive row.
    @AppStorage("storiesOptedOut") private var storiesOptedOut = false

    // MARK: - The stories-row door (our own presentation — owner's spec 2026-08-07)

    /// Open a story from the top stories row through `StoryDoor`: our screen, our gesture, our
    /// animation, nothing of Apple's presentation machinery in the interaction.
    ///
    /// `pinned: false` is what makes this door different from every other one: the viewer pages
    /// person to person, and the row has a card for whoever you paged to, so the anchor follows.
    private func openStoryFromRow(_ g: StoryGroup) {
        let others = StoriesRepository.shared.others.filter { !StoryPrefs.isHidden($0.authorUid) }
        // ⚠️ MY OWN STORY IS ONE PAGE AMONG SEVERAL NOW — the 2026-08-09 revert (build 512) is undone
        // on purpose, and the thing that made it unsafe is gone.
        //
        // The revert's note said the sheet stopped shrinking because "the real morph does not hold on
        // the pager's scroll view", and prescribed re-asserting the transform through UIKit's layout.
        // Both halves were wrong, and the revert commit (`e0d54d6b`) admits the diagnosis came off a
        // screenshot rather than a measurement. Nothing in this repo ever showed `_UIQueuingScrollView`
        // resetting `transform`, and per-frame re-assertion was ALREADY running when it was prescribed
        // (`SheetProgressAnimator`'s CADisplayLink drives `driveMorph` every frame of the drag AND the
        // release). The real difference was the ATTACH TARGET: the solo host attaches the morph to a
        // plain container it owns, this one attached it to UIKit's private scroll view — which also
        // crashed build 481 inside `queuingScrollView:didEndManualScroll:toRevealView:`.
        //
        // `757da9e4` moved the morph onto `StoryPagerHostVC.cardContainer`, a plain view we lay out
        // ourselves, and neutralises the internal scroll while the sheet is up. So the sheet now has
        // the same ground under it here as on the solo host.
        //
        // ⚠️ THE CHECK THAT WAS NEVER RUN, and the one to run on this build: pull the viewers sheet
        // over a FRIEND'S story and confirm it shrinks. Until mine came through here that combination
        // could not happen, because the sheet only exists on my own story and my story never paged.
        //
        // What this buys, both asked for on 2026-08-12: the cube swipe from my story to a friend's,
        // and tapping past my last story into the next person instead of closing the viewer.
        StoryDoor.open(g, among: g.isMine ? [g] + others : others, from: g.id, pinned: false,
                       // These came out of `StoriesRepository.others`, whose query is "recipientUids
                       // contains me" — so being here IS the author's audience choice, and the reply
                       // bar follows it rather than testing my chat list a second time.
                       deliveredToMe: true,
                       onProfile: { grp in profileGroup = grp })
    }

    /// THE CHAT LIST'S RINGED AVATAR. Same door, same flight, and because the ring reports its
    /// radius as half its width the story grows out of it and lands back into it as a CIRCLE —
    /// The reference app's shape, the owner's reference. See StoryCardMorph's circular branch.
    ///
    /// `pinned` (the door's default), unlike the row: the ring is the only anchor this list has for
    /// the person who was tapped, and paging on to somebody else does not produce a second one.
    ///
    /// One person's story alone (`among:` left empty). The list is sorted by conversation, not by
    /// story, so paging out of a ring would walk an order nothing on screen is showing.
    private func openStoryFromRing(_ conv: Conversation, _ g: StoryGroup) {
        StoryDoor.open(g, from: "row-\(conv.id)", deliveredToMe: true,
                       onProfile: { grp in profileGroup = grp })
    }

    /// The still-uploading card's door. Same presentation and same flight as a posted story; its
    /// content is the handoff view, which swaps itself for the real viewer when the upload lands.
    private func openUploadingStory() {
        StoryDoor.openUploading(meName: profile.me?.name ?? "You",
                                mePhoto: profile.me?.photoUrl,
                                onProfile: { grp in profileGroup = grp })
    }

    // Welcome empty state: icon + copy + the three ways to get a first chat going.
    // Reuses the existing flows (NewChatView search, MyQRView, Settings' invite text).
    private var inviteText: String {
        let h = profile.me?.handle ?? ""
        return h.isEmpty ? "Chat with me on Fariin." : "Chat with me on Fariin, my username is @\(h)"
    }
    // Big-app empty state (the big messengers rule: one visual, one line, ONE button).
    // The stacked three-pill version read as clutter — secondary actions are quiet
    // inline text links instead.
    private var emptyWelcome: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 40))
                .foregroundStyle(.quaternary)
                // One greeting bounce on appear (endless repeat read as fidgety).
                .symbolEffect(.bounce, value: welcomeGreet)
                .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { welcomeGreet += 1 } }
            VStack(spacing: 4) {
                Text("No chats yet").font(.title3.weight(.semibold))
                Text("Find a friend by username to start talking.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            // NOTHING ELSE. A fresh account used to get a "Find People" button plus "My QR" and
            // "Invite" links stacked under the message, which read as a landing page rather than an
            // empty inbox. The standard apps all show only a glyph, a title and one line here -
            // the actions already live in the compose button in the nav bar, so repeating them cluttered
            // the first thing a new user ever sees.
        }
        .padding(.horizontal, 32)
    }

    private func storyCid(_ other: String) -> String {
        [AuthService.shared.uid ?? "", other].sorted().joined(separator: "_")
    }
    private func openStoryChat(_ g: StoryGroup) {
        path.append(ChatTarget(id: storyCid(g.authorUid), name: g.name, photo: g.photoUrl))
    }
    // Header fade: hide the nav-bar icons while a chat is pushed so they
    // don't float statically over the screen during the interactive swipe-back. Driven by
    // navigation depth — a non-empty path (which holds through the ENTIRE drag) keeps them
    // hidden; they fade back only when the list is fully back (path empty again on commit).
    @State private var showHeaderIcons = true

    // Drops the toolbar icons to opacity 0 the instant we leave the list and fades them
    // back when it re-appears — without this SwiftUI keeps them pinned over the transition.
    private struct SwipeFade: ViewModifier {
        let on: Bool
        func body(content: Content) -> some View {
            content.opacity(on ? 1 : 0).animation(.easeInOut(duration: 0.15), value: on)
        }
    }

    private var me: String { AuthService.shared.uid ?? "" }
    private var dark: Bool { scheme == .dark }
    // Per-segment seen flags for the 1:1 peer's stories (empty = no active story → no ring).
    private func storySeen(_ conv: Conversation) -> [Bool] {
        guard !conv.isGroup,
              !UserDefaults.standard.bool(forKey: "storiesOptedOut"),   // opted out: no rings anywhere
              !StoryPrefs.isHidden(conv.otherUid(me)),   // hidden author: no ring on the chat-list avatar
              let g = storiesRepo.others.first(where: { $0.authorUid == conv.otherUid(me) })
        else { return [] }
        // upTo watermark = same split-brain guard as the stories row (server lastViewedAt
        // covers views from other devices / reinstalls, not just local flags).
        return StoryPrefs.seenFlags(g.stories, upTo: g.lastViewedAt)
    }

    // Mark every (non-archived) unread chat as read. Same filter as the tab badge — including
    // the blocked exclusion the badge always had: marking a silently-blocked chat read sent the
    // blocked person read receipts, revealing the block-hidden activity (audit).
    private func markAllRead() {
        let ids = repo.conversations
            .filter { !$0.isCleared(me) && !$0.isArchived(me) && !$0.isBlockedByMe(me)
                      && (Flags.groupsEnabled || !$0.isGroup)   // the clause the badge has; see above
                      && $0.hasUnreadMark(me) }   // clears a manual mark too — that is what "read all" means
            .map(\.id)
        Task { for id in ids { await ChatService.resetUnread(id); await ChatService.markRead(id) } }
    }

    // One chat-list row: full-row Button (a NavigationLink would draw the disclosure chevron;
    // in edit mode a Button is auto-disabled so native multi-select toggles via the row tag),
    // long-press menu + conversation PEEK preview, swipe actions both edges.
    /// In edit mode the List's own selection only reacts to taps on NON-interactive row content, and
    /// every chat row is a Button — so a tap on the avatar, the name, or the empty space was swallowed
    /// and pushed the chat instead of selecting it. Only the checkbox (outside the Button) worked.
    /// Route those taps here so the whole row toggles, like Mail and the reference app.
    private func toggleSelection(_ id: String) { toggleTick(id, in: $selection) }

    @ViewBuilder private func chatListRow(_ conv: Conversation) -> some View {
        // A real NavigationLink, not a Button with a hand-rolled press style.
        //
        // THE STUCK GREY ROW: ChatRowPressStyle painted the highlight from the ButtonStyle's `isPressed`.
        // That flag strands whenever the button's identity changes mid-press - and this list RE-SORTS on
        // updatedAt, so a message arriving while a finger rests on a row does exactly that. The row then
        // stayed grey with nothing to clear it, which is the "selected grey without selecting" report.
        // The system's own row highlight cannot get stuck this way, and it is also what makes the swipe
        // actions behave properly, since UIKit owns the whole cell interaction instead of splitting it
        // between a Button and the swipe platter.
        // ONE structure for both modes (owner's report: entering Select cross-faded TWO copies of
        // every row — the old if-selecting/else swap changed the row's structural identity, so
        // SwiftUI faded the plain-label copy in over the Button copy instead of sliding one row).
        // The Button stays permanently; Select mode just disables it and lays a tap-catcher on top,
        // so the native edit-mode indent slides the single row smoothly.
        //
        // A Button that pushes onto the same path, NOT a NavigationLink — because a
        // NavigationLink row draws the disclosure chevron and there is no API to turn it off
        // (user: "remove the arrow in chat list"). The link ALSO set the List's selection, and
        // SwiftUI never cleared it on the way back; fixed in the two onChange handlers on the List.
        // ⚠️ THAT LEFT THE ROW WITH NO HIGHLIGHT AT ALL, and the paragraph that used to sit here said
        // the opposite: that a plain-styled Button in a List row lets the cell's own pressed state
        // paint through it. It does not. The Button takes the touch, the cell never learns a press
        // happened, and `.plain` adds no feedback of its own — so tapping a chat to open it looked
        // like nothing had been tapped (owner 2026-08-13). The grey is ours again, via RowPressFill,
        // which carries the watchdog that makes the old stranding impossible.
        //
        // A row used to stay lit while its chat was open (the reference app's `selectRow`, build 441). It is
        // deleted. On a phone that highlight is only ever VISIBLE during the back swipe, because
        // that is the one moment the list is on screen with a chat still on the stack — and it was
        // being cleared by `path.count` reaching zero, which happens when the pop FINISHES. So the
        // grey sat there at full strength for the whole gesture. the reference app solves that by deselecting
        // inside the navigation transition's own animation, which SwiftUI gives no way to reach; the
        // owner chose the simpler end of that trade deliberately: no state, no grey, nothing to fade.
        Button {
            path.append(ChatTarget(id: conv.id, name: conv.displayName(me),
                                   photo: conv.displayPhoto(me)))
        } label: {
            chatListRowLabel(conv)
        }
        // `.plain` is what left a tap with no feedback at all — see RowPressFill, which paints the
        // grey the cell underneath was never going to paint, and cannot strand it.
        .buttonStyle(RowPressFill())
        // Edit mode: the push is off, and the tap-catcher overlay below owns the tap.
        //
        // `.disabled(selecting)` was the wrong tool and `.opacity(1)` did not rescue it. Disabled
        // does two things — it stops the interaction AND it dims — and only the first was ever
        // wanted. The dimming is applied by the button style INSIDE, from the environment, so an
        // opacity of 1 on the outside means "change nothing further"; it cannot undo a fade that has
        // already been drawn. That is why Select Chats still greyed every avatar, name and preview
        // after the last attempt at this.
        //
        // allowsHitTesting stops the interaction and nothing else. The row keeps its own colours,
        // and the overlay above still receives the tap because the Button simply declines it.
        .allowsHitTesting(!selecting)
        .overlay {
            if selecting {
                // Whole row toggles, like Mail and the reference app (taps on a Button's content were
                // otherwise swallowed and only the checkbox worked).
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { toggleSelection(conv.id) }
            }
        }
        .tag(conv.id)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)   // clean, no row lines
        // NO explicit row background: forcing systemBackground made the swiped row paint a
        // white slab OVER its own content (blank row on swipe, user report). The native
        // swipe platter (grey) is correct and keeps the row content visible.
        .moveDisabled(true)   // reordering removed — pinned chats stay fixed
        // Full-swipe enabled like the leading (Pin) edge. The FIRST action is what a full
        // swipe triggers, so Archive leads; Mute/Delete are still revealed for a tap.
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                Task { await ChatService.setArchived(conv.id, true) }
            } label: {
                // The SOLID archive drawing, which is the one he sent for the swipe specifically.
                // MenuIcon, not a frame-modified Image: swipe actions drop view modifiers the same
                // way menus do, so the frame(22) never applied (see MenuIcon).
                Label { Text("Archive") } icon: { MenuIcon("ic_archive_fill") }
            }
            .tint(.gray)
            // Apple's symbols go through MenuIcon too now: it trims each icon to its ink, so a
            // symbol's built-in air no longer makes it read smaller than our drawings beside it.
            Button { pendingMute = conv } label: {
                Label { Text("Mute") } icon: { MenuIcon(system: "bell.slash.fill") }
            }
            .tint(.indigo)
            Button(role: .destructive) {
                pendingDelete = conv
            } label: { Label { Text("Delete") } icon: { MenuIcon(system: "trash.fill") } }
            .tint(.red)
        }
        .swipeActions(edge: .leading) {
            Button {
                Task { await ChatService.setPinned(conv.id, !conv.isPinned(me)) }
            } label: {
                Label { Text(conv.isPinned(me) ? "Unpin" : "Pin") } icon: {
                    // No size of its own. One number for menus and swipes alike, so a report about
                    // one place cannot leave the other behind — see MenuIcon.standard.
                    conv.isPinned(me) ? AnyView(MenuIcon(system: "pin.slash"))
                                      : AnyView(MenuIcon("ic_pin_menu"))
                }
            }
            .tint(.orange)
        }
    }

    // The row CONTENT with the context menu attached to it (not the Button — a Button in a
    // List swallows the long-press) + the conversation peek as the menu preview.
    private func chatListRowLabel(_ conv: Conversation) -> some View {
        ChatRow(conv: conv, me: me, dark: dark,
                storySeen: storySeen(conv),
                onStoryTap: {   // open this person's story in the same viewer the stories row uses
                    // The ring has its own tap gesture, which would beat the row's selection toggle.
                    if selecting { toggleSelection(conv.id); return }
                    // On the app's own presentation, and it lands back into the ring as a CIRCLE —
                    // see `openStoryFromRing`.
                    if let g = storiesRepo.others.first(where: { $0.authorUid == conv.otherUid(me) }) {
                        openStoryFromRing(conv, g)
                    }
                },
                draft: Drafts.shared.text(conv.id),
                voiceDraftSecs: AudioRecorder.draftIndex[conv.id] ?? 0,
                voiceUnplayed: PlayedVoice.shared.lastVoiceUnplayed(conv, me: me))
            .equatable()   // skip rebuild when this conversation is unchanged
            .frame(maxWidth: .infinity, alignment: .leading)
            // NO BACKGROUND OF OUR OWN. A fill painted here used to mark the open chat; it is gone
            // (see the Button above). Do not bring one back on this modifier, or on the List's
            // selection binding, or on `.listRowBackground`: the binding stranded a permanent grey
            // row twice, and listRowBackground painted a slab over the row's own content while it
            // was swiped. The cell's pressed state is the only highlight this row has, and it is
            // drawn by UIKit underneath everything here.
            .contentShape(Rectangle())   // whole row tappable (incl. empty space)
            .contextMenu {
                chatMenu(conv)
            } preview: {
                ChatPeekPreview(cid: conv.id, me: me)
            }
    }

    // ARCHIVE, VISIBLE FROM THE CHAT LIST (owner 2026-08-13: "make our archive visible ... now it
    // needs finding other ways"). It only lived in the filter menu, which is a place you have to
    // already know about. The reference app puts it where he pointed: one compact row at the top of
    // the chats, only there when the drawer holds something, scrolling away with the list.
    private var archivedChats: [Conversation] {
        // Same filter the archive page itself uses — including the official channel, which can be
        // archived like any other chat, so the count cannot disagree with what opens.
        (repo.conversations + [officialChannel.listEntry].compactMap { $0 })
            .filter { $0.isArchived(me) && !$0.isCleared(me) }
            .filter { Flags.groupsEnabled || !$0.isGroup }
    }
    // Hidden people's stories live in the archive too, so the way in has to exist for them even
    // with no archived chat at all — otherwise unhiding somebody becomes unreachable.
    private var hasArchivedStories: Bool {
        storiesRepo.others.contains { StoryPrefs.isHidden($0.authorUid) }
    }
    // The number goes accent instead of grey when something in there is unread: same digit, and the
    // colour is the only thing saying there is news behind the door.
    private var archivedUnread: Bool {
        archivedChats.contains { !$0.isBlockedByMe(me) && $0.hasUnreadMark(me) }
    }
    // Not while selecting (the row carries no tag, so it can never be part of a selection), and not
    // under a filter — Unread and Groups are questions about the chats on THIS page.
    private var showsArchivedRow: Bool {
        // ⚠️ `selecting` IS NOT IN HERE ANY MORE (his reference, 2026-08-14): in select mode the row
        // STAYS, greyed and unselectable, instead of vanishing. A row that disappears the moment you
        // tap Edit reads as something you broke; theirs dims it, which says "not this one" without
        // moving anything. It carries no tag and takes `selectionDisabled`, so it never grows a
        // checkbox and can never end up in a selection.
        chatFilter == 0 && (!archivedChats.isEmpty || hasArchivedStories)
    }
    /// 22pt of icon between two 11pt paddings. Only the empty-state overlay needs the number, and it
    /// needs it BEFORE layout, which is why it is written down rather than measured.
    private let archivedRowHeight: CGFloat = 44

    @ViewBuilder private var archivedEntryRow: some View {
        if showsArchivedRow {
            // The archive is a page of this stack (his call), and the row's own metrics went back to
            // ours with the chat rows' — 56pt column, 12pt gap.
            Button { path.append(ArchiveRoute.archive) } label: {
                HStack(spacing: 12) {
                    // Centred in the 56pt column the avatars stand in, so "Archived" starts on the
                    // same left edge as every chat name under it.
                    // 20, which is `MenuIcon.custom` — the size every one of OUR drawings is drawn
                    // at everywhere else in the app (two points under a system symbol's box, because
                    // a solid shape carries more weight than a stroked one). It was 22 because this
                    // one stands alone in a wide column; his call, 2026-08-14: smaller, but not
                    // small. The app's own number is exactly that.
                    MenuIcon("ic_archive", size: 20)
                        .foregroundStyle(.secondary)
                        .frame(width: 56)
                    // ⚠️ IT IS NOT A PEER OF THE ROWS UNDER IT, and the line that used to sit here
                    // said it was: a chat name's font, `.primary`, semibold. That made the heaviest
                    // type on the whole screen belong to the row people tap least, and it made the
                    // archive read as a conversation with a strange name. Owner 2026-08-19, holding
                    // ours beside the reference app's: theirs is grey and lighter than every name
                    // below it, and it reads as a shelf rather than as a chat. This reverses his own
                    // earlier call on the same row; the icon size he set that day is untouched.
                    Text("Archived")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if !archivedChats.isEmpty {
                        Text("\(archivedChats.count)")
                            .font(.system(size: 15))
                            // `Theme.accent(dark)`, which is the SAME colour `Color.accentColor` was
                            // giving here, spelled so it cannot drift: the List now sets a tint of
                            // its own for the selection tick, and accentColor would have followed it.
                            .foregroundStyle(archivedUnread ? Theme.accent(dark) : Color.secondary)
                    }
                }
                .padding(.vertical, 11)
                .padding(.horizontal, 16)   // the chat row's gutter, for the same reason (row insets are zero)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowPressFill())    // the same touch grey as the chat rows under it
            // Select mode: dimmed and dead, not gone. `disabled` is the right tool here for once —
            // it stops the tap AND greys the row, and greyed is exactly the state being asked for.
            .disabled(selecting)
            .selectionDisabled(true)        // no checkbox, ever
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .deleteDisabled(true)
            .moveDisabled(true)
        }
    }

    private var visible: [Conversation] {
        // The official channel joins the list as an ordinary Conversation value, so every filter,
        // sort, badge and swipe below treats it like any other chat and none of them had to learn
        // what an announcement is. It is nil until it has something to say — another mainstream messenger
        // keeps its release channel hidden the same way (an internal visibility flag) so a brand-new account never
        // opens onto an empty official chat.
        (repo.conversations + [officialChannel.listEntry].compactMap { $0 })
            .filter { !$0.isCleared(me) && !$0.isArchived(me) }
            .filter { Flags.groupsEnabled || !$0.isGroup }
            // A 1:1 chat you merely OPENED (from search / a profile) but never exchanged a message
            // in stays OUT of the list (standard behavior) until something real happens: a message
            // either way, an unread, a pin, or a draft you typed. Groups always list — creating
            // one is deliberate.
            .filter { c in
                c.isGroup || !c.lastMessageCipher.isEmpty || c.hasUnreadMark(me) || c.isPinned(me)
                    || !Drafts.shared.text(c.id).isEmpty
                    || AudioRecorder.draftIndex[c.id] != nil   // a parked voice draft keeps its chat listed
            }
            .filter { c in   // Filter: 0 = All, 1 = Unread, 2 = Groups
                switch chatFilter {
                // Blocked-aware, like the row badge and the tab badge (audit: a silently blocked
                // chat appeared under Unread with no badge and a zero tab count).
                case 1: return !c.isBlockedByMe(me) && c.hasUnreadMark(me)
                case 2: return c.isGroup
                default: return true
                }
            }
            .sorted { a, b in
                if a.isPinned(me) != b.isPinned(me) { return a.isPinned(me) }
                // Both pinned: manual order (higher rank = higher in list).
                if a.isPinned(me) && b.isPinned(me) {
                    if a.pinRank(me) != b.pinRank(me) { return a.pinRank(me) > b.pinRank(me) }
                    return a.displayUpdatedAt(me) > b.displayUpdatedAt(me)
                }
                return a.displayUpdatedAt(me) > b.displayUpdatedAt(me)   // recency (frozen if blocked)
            }
    }


    // Native nav bar with a crisp circle avatar — glass stripped via the iOS 26
    // opt-out, same as the chat header. Keeps the large "Chats" title + smooth
    // push transitions instead of a hand-rolled bar.
    // Avatar dropdown menu: Select Chats / Settings / Archive.
    // Left: Edit (multi-select). Settings moved to its own tab, so no avatar here anymore.
    private var editButton: some View {
        Button("Edit") { withAnimation(.smooth(duration: 0.35)) { selecting = true } }.tint(.primary)
    }
    // Right: Mark all read + filter (All / Unread / Groups) + Archived + Add Story.
    private var filterMenu: some View {
        Menu {
            Button { markAllRead() } label: { Label("Mark All Read", systemImage: "checkmark.circle") }
            Divider()
            // Flat filter items (no "Filter by" header) — checkmark on the active one.
            Button { chatFilter = 0 } label: { if chatFilter == 0 { Label("All", systemImage: "checkmark") } else { Text("All") } }
            Button { chatFilter = 1 } label: { if chatFilter == 1 { Label("Unread", systemImage: "checkmark") } else { Text("Unread") } }
            if Flags.groupsEnabled {
                Button { chatFilter = 2 } label: { if chatFilter == 2 { Label("Groups", systemImage: "checkmark") } else { Text("Groups") } }
            }
            Divider()
            Button { path.append(ArchiveRoute.archive) } label: {
                Label { Text("Archive") } icon: { MenuIcon("ic_archive") }
            }
            // Stories off (Settings > Stories > Turn Off Stories) → no Add Story entry.
            if !storiesOptedOut {
                Button { showCompose = true } label: {
                    Label { Text("Add Story") } icon: { MenuIcon("ic_stories") }
                }
            }
        } label: {
            // Plain three-lines filter glyph (no inner circle) — Apple moved off the
            // `.circle` variant; the glass button already supplies the round shape, so
            // the old symbol drew a circle-inside-a-circle. Active filter = accent tint.
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 18))
                .foregroundStyle(chatFilter != 0 ? Color.accentColor : .primary)
        }
        .tint(.primary)
    }
    private var composeButton: some View {
        Button { showNew = true } label: {
            Image(systemName: "square.and.pencil").font(.system(size: 18))
        }
        .tint(.primary)   // glass circle (default), black glyph
    }

    @ToolbarContentBuilder private var homeToolbar: some ToolbarContent {
        if selecting {
            // Minimal X close (replaces "Cancel"); no "Select All" — tap rows to select.
            ToolbarItem(placement: .topBarLeading) {
                Button { exitSelect() } label: { Image(systemName: "xmark") }.tint(.primary)
            }
            ToolbarItem(placement: .principal) {
                Text(selection.isEmpty ? "Select Chats" : "\(selection.count) Selected").font(.headline)
            }
            // Native bottom toolbar (like Mail/Photos edit mode) — no custom glass bar.
            ToolbarItemGroup(placement: .bottomBar) {
                Button { archiveSelected() } label: {
                    Image("ic_archive").renderingMode(.template).resizable().scaledToFit()
                        .frame(width: 22, height: 22)
                }
                    .tint(.primary).disabled(selection.isEmpty)
                Spacer()
                Button(readTitle) { markReadTargets() }.tint(.primary).disabled(readTargets.isEmpty)
                Spacer()
                Button(role: .destructive) { showDeleteSelected = true } label: { Image(systemName: "trash") }
                    .disabled(selection.isEmpty)
            }
        } else if #available(iOS 26.0, *) {
            // Edit keeps its native Liquid Glass capsule (no sharedBackgroundVisibility opt-out).
            ToolbarItem(placement: .topBarLeading) { editButton.modifier(SwipeFade(on: showHeaderIcons)) }
            ToolbarItemGroup(placement: .topBarTrailing) {
                filterMenu.modifier(SwipeFade(on: showHeaderIcons))
                composeButton.modifier(SwipeFade(on: showHeaderIcons))
            }
        } else {
            ToolbarItem(placement: .topBarLeading) { editButton.modifier(SwipeFade(on: showHeaderIcons)) }
            ToolbarItemGroup(placement: .topBarTrailing) {
                filterMenu.modifier(SwipeFade(on: showHeaderIcons))
                composeButton.modifier(SwipeFade(on: showHeaderIcons))
            }
        }
    }

    // Persist a pinned-chat reorder via fractional indexing.
    private func reorderPinned(from source: IndexSet, to destination: Int) {
        let rows = visible
        guard let from = source.first, rows.indices.contains(from) else { return }
        let moved = rows[from]
        guard moved.isPinned(me) else { return }

        let pinnedCount = rows.prefix { $0.isPinned(me) }.count
        guard pinnedCount > 1 else { return }

        // Clamp into the pinned block so a pin can't be dropped among unpinned chats.
        let dest = min(max(destination, 0), pinnedCount)
        var pinned = Array(rows[0..<pinnedCount])
        pinned.move(fromOffsets: IndexSet(integer: from), toOffset: dest)
        guard let pos = pinned.firstIndex(where: { $0.id == moved.id }) else { return }

        let above = pos > 0 ? pinned[pos - 1].pinRank(me) : nil          // higher in list = bigger rank
        let below = pos < pinned.count - 1 ? pinned[pos + 1].pinRank(me) : nil
        let step = 1_000_000.0
        let newRank: Double
        switch (above, below) {
        case let (a?, b?): newRank = (a + b) / 2
        case let (a?, nil): newRank = a - step
        case let (nil, b?): newRank = b + step
        case (nil, nil): return
        }
        Task { await ChatService.setPinOrder(moved.id, newRank) }
    }

    private func exitSelect() { withAnimation(.smooth(duration: 0.35)) { selecting = false; selection = [] } }
    private func selectAll() { selection = Set(visible.map { $0.id }) }

    // System action list for a chat row's context menu (HIG order + SF Symbols).
    @ViewBuilder private func chatMenu(_ conv: Conversation) -> some View {
        // Blocked-aware like the row badge (audit: the menu offered "Read" — which would leak read
        // receipts to the blocked person — for a chat whose row displays zero unread).
        // `hasUnreadMark`, NOT `unread(me) > 0`. A chat you marked unread yourself stores -1 as a
        // sentinel, and `unread()` clamps with max(0,…) so the list can never print "-1" — which
        // means the manual mark reads as ZERO here. The menu therefore offered "Unread" on a chat
        // that was already unread, and there was no way to undo it: mark it unread, and the only
        // thing on offer forever after is marking it unread again. That is what he circled.
        //
        // The archived menu below already asks the right question. This one was missed when the
        // sentinel went in.
        if !conv.isBlockedByMe(me) && conv.hasUnreadMark(me) {
            Button {
                // Full parity with opening the chat: reset MY counter, send read receipts,
                // and drop its delivered notifications + fix the app badge.
                Task { await ChatService.resetUnread(conv.id); await ChatService.markRead(conv.id) }
                NotificationCleaner.clear(cid: conv.id)
            } label: {
                Label { Text("Read") } icon: { MenuIcon(system: "envelope.open", ink: .label) }
            }
        } else {
            Button { Task { await ChatService.markUnread(conv.id) } } label: {
                Label { Text("Unread") } icon: { MenuIcon("ic_menu_unread", ink: .label) }
            }
        }
        // The official channel's mute is a plain on/off, not a timer. A "Mute for 1 hour" that
        // silently never un-mutes would be a label that lies — and un-muting on a timer is the exact
        // behaviour the channel promises never to have.
        if OfficialChannel.isOfficial(conv.id) {
            let quiet = conv.isMuted(me, now: Date().timeIntervalSince1970 * 1000)
            Button { Task { await ChatService.setMuted(conv.id, !quiet) } } label: {
                Label { Text(quiet ? "Unmute" : "Mute") } icon: { MenuIcon(system: quiet ? "bell" : "bell.slash", ink: .label) }
            }
        } else {
        // Native submenu (clean popover) instead of a custom mute sheet.
        Menu {
            if conv.isMuted(me, now: Date().timeIntervalSince1970 * 1000) {
                Button("Unmute") { Task { await ChatService.setMute(conv.id, until: 0) } }
            }
            Button("Mute for 1 hour") { Task { await ChatService.setMute(conv.id, until: ChatService.muteUntil(1)) } }
            Button("Mute for 8 hours") { Task { await ChatService.setMute(conv.id, until: ChatService.muteUntil(8)) } }
            Button("Mute for 1 week") { Task { await ChatService.setMute(conv.id, until: ChatService.muteUntil(168)) } }
            Button("Mute Always") { Task { await ChatService.setMute(conv.id, until: ChatService.muteUntil(nil)) } }
        } label: { Label { Text("Mute") } icon: { MenuIcon(system: "bell.slash", ink: .label) } }
        }
        Button { Task { await ChatService.setPinned(conv.id, !conv.isPinned(me)) } } label: {
            Label { Text(conv.isPinned(me) ? "Unpin" : "Pin") } icon: {
                    conv.isPinned(me) ? AnyView(MenuIcon(system: "pin.slash", ink: .label))
                                      : AnyView(MenuIcon("ic_pin_menu", ink: .label))
                }
        }
        Button { Task { await ChatService.setArchived(conv.id, true) } } label: {
            Label { Text("Archive") } icon: { MenuIcon("ic_archive", ink: .label) }
        }
        Button(role: .destructive) { pendingDelete = conv } label: {
            Label { Text("Delete") } icon: { MenuIcon(system: "trash", ink: .systemRed) }
        }
    }
    // Batch ops run the per-chat writes CONCURRENTLY (was sequential = N round-trips in series).
    private func archiveSelected() {
        let ids = selection
        Task { await withTaskGroup(of: Void.self) { g in for id in ids { g.addTask { await ChatService.setArchived(id, true) } } } }
        exitSelect()
    }
    // SELECT MODE'S READ BUTTON, that same messenger's rule (the reference implementation).
    //
    // With NOTHING selected it reads "Read All" and clears every unread chat in the list you are
    // looking at — you do not have to select anything first. The moment one chat is selected it
    // becomes "Read" and touches only the selection. Either way it is DISABLED when there is
    // nothing unread to act on, so the button never offers work it would not do. The old version
    // said "Read All" always, was dead until you selected something, and then quietly acted on the
    // selection only: the label and the behaviour disagreed.
    private var readTitle: String { selection.isEmpty ? "Read All" : "Read" }

    /// The chats the button would actually mark. Empty = nothing to do = disabled.
    /// Already-read chats drop out here, which is what makes "Read" ignore a read chat you picked.
    ///
    /// Skips silently-blocked chats, exactly like the tab badge, Mark All Read and the row menu
    /// (audit): markRead writes lastRead, which flips the blocked person's messages to read ticks
    /// and reveals the activity the block is hiding. Their rows show 0 unread, so nothing on
    /// screen even hints they were included.
    private var readTargets: [String] {
        // Nothing selected -> the whole list as it is currently filtered, which is that same messenger scoping
        // Read All to the rendered list. Selected -> resolve out of the repo, so a chat that the
        // filter stopped showing while you were selecting is still honoured.
        let pool = selection.isEmpty ? visible : repo.conversations.filter { selection.contains($0.id) }
        // hasUnreadMark, so Read All also clears the ones you marked unread BY HAND. `unread()`
        // clamps the -1 sentinel to zero, so those chats were invisible to this filter and survived
        // a "mark everything read" untouched.
        return pool.filter { !$0.isBlockedByMe(me) && $0.hasUnreadMark(me) }.map(\.id)
    }

    private func markReadTargets() {
        let ids = readTargets
        guard !ids.isEmpty else { return }
        Task { await withTaskGroup(of: Void.self) { g in for id in ids { g.addTask { await ChatService.resetUnread(id); await ChatService.markRead(id) } } } }
        exitSelect()
    }
    private func deleteSelected() {
        let ids = selection
        Task { await withTaskGroup(of: Void.self) { g in for id in ids { g.addTask { await ChatService.deleteForMe(id) } } } }
        exitSelect()
    }

    // THE BINDINGS AND THE DIALOG BODY LIVE OUT HERE, not inline in the modifier chain.
    //
    // `body` stopped compiling — "unable to type-check this expression in reasonable time" — and an
    // inline `Binding(get:set:)` is one of the most expensive things you can put in a chain that
    // long, because the compiler has to infer the closure types against every overload of the
    // modifier. Naming them costs nothing at runtime and hands the type-checker the answer.
    //
    // The cascade is worth remembering too: the SECOND error was "cannot find 'call' in scope",
    // pointing at a property declared at the top of this very file. It was not a real missing
    // symbol, it was the compiler giving up on the body and losing track of what was in it.

    /// EVERY dial site, including the profile. It used to read `!$0.fromProfile`, so a refusal raised
    /// from a profile fell through to a bottom sheet instead — see the alert for why that is gone.
    /// `fromProfile` is still carried on the value; nothing reads it any more, and it stays only so
    /// the call sites do not all need editing to drop an argument.
    private var restrictedCalleeAlert: Binding<Bool> {
        Binding(get: { CallService.shared.restrictedCallee != nil },
                set: { if !$0 { CallService.shared.restrictedCallee = nil } })
    }

    private var mutePrompted: Binding<Bool> {
        Binding(get: { pendingMute != nil }, set: { if !$0 { pendingMute = nil } })
    }

    private var muteTitle: String {
        guard let c = pendingMute else { return "Mute" }
        return "Mute \(c.displayName(me))"
    }

    @ViewBuilder private var muteActions: some View {
        if let c = pendingMute {
            if c.isMuted(me, now: Date().timeIntervalSince1970 * 1000) {
                Button("Unmute") { Task { await ChatService.setMute(c.id, until: 0) }; pendingMute = nil }
            }
            Button("Mute for 1 hour") { Task { await ChatService.setMute(c.id, until: ChatService.muteUntil(1)) }; pendingMute = nil }
            Button("Mute for 8 hours") { Task { await ChatService.setMute(c.id, until: ChatService.muteUntil(8)) }; pendingMute = nil }
            Button("Mute for 1 week") { Task { await ChatService.setMute(c.id, until: ChatService.muteUntil(168)) }; pendingMute = nil }
            Button("Mute Always") { Task { await ChatService.setMute(c.id, until: ChatService.muteUntil(nil)) }; pendingMute = nil }
        }
        Button("Cancel", role: .cancel) { pendingMute = nil }
    }

    private var pendingInvite: Binding<InviteCodeItem?> {
        Binding(get: { Flags.groupsEnabled ? router.pendingInviteCode.map { InviteCodeItem(code: $0) } : nil },
                set: { router.pendingInviteCode = $0?.code })
    }

    /// THE LOADED CHAT LIST: the List, the stories row floating over it, and every modifier
    /// the two need. Lifted out of `body` because the type-checker gave up on it — "unable to
    /// type-check this expression in reasonable time". `body` was already close to the budget
    /// and this is the heaviest part of it by a wide margin; splitting the value out is the
    /// documented fix and costs nothing at runtime.
    private var loadedChatList: some View {
                        ZStack(alignment: .top) {
                          // Selection is ALWAYS bound (a Set only selects in edit mode, so taps still OPEN
                          // the row when not editing). Swapping the binding nil<->$selection reconfigured
                          // the List and made the edit-mode transition POP; a stable binding lets the
                          // native circles-slide-in + rows-shift-right animate smoothly (withAnimation on
                          // `selecting` at the tap sites drives it).
                          List(selection: $selection) {
                          // The way into the archive, above the chats. Empty when there is nothing
                          // archived — the `if` lives inside the property so this body only grows by
                          // one element (this file's type-checker budget is a known cost).
                          archivedEntryRow
                          // Row body extracted (chatListRow): the inline closure blew past the
                          // type-checker's budget once the peek preview + row background joined it.
                          ForEach(visible) { conv in chatListRow(conv) }
                        }
                        .listStyle(.plain)
                        // THE STUCK GREY ROW, real cause. This List carries a `selection` binding for
                        // multi-select, and every row carries a `.tag`. A NavigationLink row does not only
                        // push - it ALSO sets the List's selection - and SwiftUI does not clear that on the
                        // way back, so the row stays SELECTED, and selected renders as a permanent grey fill.
                        // It is not a press highlight at all, which is why removing the custom press style
                        // did not fix it: the highlight was correct, the selection underneath it was not.
                        // Outside edit mode there is no such thing as a selected chat, so say so.
                        .onChange(of: selection) { _, sel in
                            if !selecting, !sel.isEmpty { selection.removeAll() }
                        }
                        .onChange(of: selecting) { _, on in
                            if !on, !selection.isEmpty { selection.removeAll() }   // leaving edit mode clears it
                        }
                        // When a new message bumps a chat to the top, the rows
                        // slide to their new order instead of popping. Scoped to the order/
                        // membership only, so it won't animate unrelated content changes.
                        // Nil until the list has settled, so a cold launch PAINTS its rows instead of
                        // flying them in from nowhere on top of each other. See `listSettled`.
                        .animation(listSettled ? .spring(response: 0.38, dampingFraction: 0.86) : nil,
                                   value: visible.map(\.id))
                        // A GRACE PERIOD FROM WHEN THE LIST FIRST EXISTS, not from `hasLoaded`.
                        //
                        // Keying it to `hasLoaded` looks right and is not: on a cold launch the skeleton
                        // holds this branch until `hasLoaded` is ALREADY true, so the List first appears
                        // on the far side of that flip and would unlock animation on its very first
                        // frame. The official channel then lands from its own store a moment later and
                        // flies in alone — the exact row he photographed sitting across another one.
                        //
                        // Timing from first appearance covers every path: skeleton-then-list,
                        // cached-chats-render-instantly, and empty-then-populated alike.
                        .onAppear {
                            guard !listSettled else { return }   // warm return: already a list, animate now
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { listSettled = true }
                        }
                        .environment(\.editMode, .constant(selecting ? .active : .inactive))
                        // The selection tick, same as the calls list — the app's `.primary` tint made
                        // it a white check on a white disc. See the note there.
                        .tint(Theme.defaultBubble(dark))
                        // Rows start below the stories row; as the list scrolls, the row above is
                        // offset by the same amount, so both move as ONE scroll surface.
                        .contentMargins(.top, storiesOptedOut ? 8 : storiesRowHeight, for: .scrollContent)
                        // Extra bottom clearance so chat rows don't sit UNDER the native floating tab bar
                        // (its transparent margins otherwise show + tap-through to a row behind the pill).
                        .contentMargins(.bottom, 28, for: .scrollContent)
                        // Now that the list truly underlaps the nav bar (clip fix), the header draws
                        // its HARD edge line whenever content is beneath it — in BOTH scroll
                        // directions. Soft top edge = blur fade, no drawn line (bottom stays default,
                        // which the user confirmed fixed).
                        .scrollEdgeEffectStyle(.soft, for: .top)
                        .onScrollGeometryChange(for: CGFloat.self,
                                                of: { $0.contentOffset.y + $0.contentInsets.top },
                                                action: { _, y in chatScrollY = y })

                          // Stories row stays OUTSIDE the List so EACH card long-presses on its
                          // own. Inside a List, the whole row lifts as one cell (the bug). (Build 147.)
                          if !storiesOptedOut {
                          StoriesRow(meName: profile.me?.name ?? "You", mePhoto: profile.me?.photoUrl,
                                     // HOLD THE ROW STILL WHILE A STORY IS OPEN. Watching someone's last
                                     // unseen story re-sorts the row live, so their card slid out from
                                     // under the close before it could land on it — his story leaving
                                     // sideways towards the screen edge. See `StoriesRow.displayedOthers`.
                                     freezeOrder: storyDoorState.isOpen,
                                     onCompose: { showCompose = true },
                                     // EVERY SURFACE IS ON OUR OWN TRANSITION NOW (migration finished
                                     // 2026-08-07). The viewer is presented by `StoryZoomPresenter` — a
                                     // screen we own, added and removed with no system animation — and
                                     // the card flying out of this row IS the open. The drag-down close
                                     // is the same flight in reverse, on the same view. `StoryDoor` is
                                     // the only way in, from here and from the other five doors alike.
                                     //
                                     // THE 481 LESSON THIS IS BUILT ON: the previous custom transition
                                     // flew UIPageViewController's INTERNAL scroll view and UIKit
                                     // asserted while animating it. The flight now transforms only the
                                     // presenter's own container (`StoryCardMorph.flightCard`); nothing
                                     // private is ever touched, so that crash is structurally gone.
                                     onOpen: { g in openStoryFromRow(g) },
                                     onMessage: { g in openStoryChat(g) },
                                     onProfile: { g in profileGroup = g },
                                     // ⚠️ A METHOD, NOT AN INLINE CLOSURE. Written out here it tipped this
                                     // body over the type-checker's budget ("unable to type-check this
                                     // expression in reasonable time") — `body` is already a very large
                                     // single expression and every optional-chained default inside a new
                                     // closure is more work for it. Same rule as the other handlers above.
                                     onOpenUploading: { openUploadingStory() })
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { storiesRowHeight = $0 }
                            .offset(y: -chatScrollY)
                            // NO clip and NO mask on the stories row (user's 3-stage proof, build 225):
                            // ANY truncation chops the card images in a straight line while they slide
                            // away — that visible cut WAS the "top border" all along. Unclipped, the
                            // cards slide up behind the glass header pills exactly like the chat rows
                            // do once the stories are gone (stage 3, confirmed "looks normal").
                            // MELT-AWAY (user's 4-stage proof, build 226): the row is a separate layer
                            // from the List, so its header blur and the List's own edge blur are TWO
                            // systems — a visible seam where they met ("feels like two pages"). Fade
                            // the row out over the last stretch of its slide (untouched through the
                            // approved stage-2 phase), so only ONE blur is ever visible — no seam.
                            .opacity({
                                let h = max(1, storiesRowHeight)
                                let t = (chatScrollY - h * 0.45) / (h * 0.45)
                                return 1 - min(1, max(0, t))
                            }())
                          }   // if !storiesOptedOut
                        }   // ZStack (stories row scrolling in sync above the list)
                        // Empty state sits BELOW the stories row (which stays visible). "No chats yet"
                        // only when truly unfiltered; a filtered empty result says so instead.
                        .overlay(alignment: .top) {
                            // `hasLoaded` too, or the quiet window before the skeleton arms would show
                            // "No chats yet" to someone who has chats. An empty list is only news once
                            // we have actually heard back.
                            if visible.isEmpty, repo.hasLoaded {
                                if chatFilter == 0 {
                                    // First run: an empty list must TEACH the next step, not dead-end
                                    // (big-app pattern) — find people, share your QR, invite friends.
                                    // With stories opted out the row is unmounted but storiesRowHeight
                                    // keeps its initial value — the empty state floated ~175pt too low
                                    // (audit). Pad only for a row that actually exists.
                                    // + the archive row when it is showing: archive every chat you
                                    // have and the list is "empty", so this overlay would otherwise
                                    // land on top of the one row still standing (and eat its taps).
                                    emptyWelcome
                                        .padding(.top, (storiesOptedOut ? 0 : storiesRowHeight) + 24
                                                 + (showsArchivedRow ? archivedRowHeight : 0))
                                } else {
                                    // Per-filter copy — the Groups filter was showing the Unread text.
                                    ContentUnavailableView(
                                        chatFilter == 2 ? "No groups yet" : "No unread chats",
                                        systemImage: chatFilter == 2 ? "person.3" : "checkmark.circle",
                                        description: Text(chatFilter == 2 ? "Groups you join will appear here." : "You're all caught up."))
                                        .padding(.top, (storiesOptedOut ? 0 : storiesRowHeight) + 24)
                                        // No archive row under a filter (see showsArchivedRow), so
                                        // this branch needs no clearance for it.
                                        .allowsHitTesting(false)
                                }
                            }
                        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            // ⚠️ TYPE-ERASED, AND THAT IS NOT DECORATION. This body is one of the two in the app
            // that the compiler has given up on before ("unable to type-check this expression in
            // reasonable time" — three CI rounds in one day, recorded in the build notes), and adding
            // the archive's destination to the chain was enough to tip it again. AnyView resets the
            // complexity the stack has to solve, exactly the way the messages chain in ThreadView is
            // erased at its own boundary. No behaviour changes; the same views render.
            AnyView(homeStackC)
        }
        // Both stores seeded from disk on the SAME line, synchronously, before the first frame.
        // The stories row had a persisted copy all along; it just could not reach the screen in
        // time, because every path to it went through `await load(force:)`. See `seedRowFromDisk`.
        .onAppear { repo.start(); StoriesRepository.shared.seedRowFromDisk(); openPendingChat() }
        .onChange(of: router.pendingChatId) { _, _ in openPendingChat() }
        .onChange(of: repo.conversations.count) { _, _ in openPendingChat() }   // retry once chats load
    }

    /// SLICE ONE of the chat list's chain. ⚠️ THE CHAIN IS CUT INTO THREE AND EACH JOIN IS AN
    /// `AnyView`, because the whole of it in one expression is what the compiler gives up on
    /// ("unable to type-check this expression in reasonable time", twice tonight, and three CI
    /// rounds in one day before that — it is in the build notes). ThreadView's picker chain is cut
    /// the same way for the same reason. Nothing renders differently; the compiler just gets three
    /// small problems instead of one it cannot finish.
    private var homeStackA: some View {
            Group {
                if !repo.hasLoaded && repo.expectsChats && repo.skeletonArmed {
                    // Shimmer placeholders on a cold load — ONLY for an account that has ever had
                    // chats here. A fresh sign-up skips the fake rows and lands on the real empty
                    // state directly (its chats, if any ever come, still pop in via the listener).
                    ChatListSkeleton()
                } else {
                    // NOTE: the empty state is an OVERLAY inside this ZStack (below), not a separate
                    // branch — a separate branch replaced the whole view incl. the Stories row, so
                    // filtering to Unread with nothing unread made all stories vanish + showed a
                    // wrong "No chats yet". The row now always stays; only the list area goes empty.
                    loadedChatList
                }
            }
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)   // one row: avatar · Chats · compose
            // Search now lives in its own tab (the detached search circle), so the old
            // in-list search FAB + inline search bar were removed.
            .toolbar { homeToolbar }
            // Hide the header icons whenever a chat is on the stack (incl. the swipe-back
            // drag); reveal them only when we're fully back at the root list.
            .onChange(of: path.count) {
                showHeaderIcons = path.isEmpty
            }
            // Add Story opens the CAMERA, full screen (owner 2026-08-03). It was a bottom sheet
            // holding a picker; a camera in a card with the chat list showing behind it is not a
            // camera, and the sheet's own drag-to-dismiss would fight the preview.
            .fullScreenCover(isPresented: $showCompose) {
                AddStorySheet { Task { await StoriesRepository.shared.load(force: true) } }
            }
            // ONE ANSWER, EVERYWHERE, and it is this alert.
            //
            // A profile used to get a bottom sheet with the person's avatar on it while every other
            // dial site got this. The owner asked for the sheet gone: "no bottom sheet should ever be
            // shown". He is right that two presentations for one refusal was the wrong shape — the
            // sheet was a whole screen of furniture to say a sentence, and it made the same tap
            // behave differently depending on which screen you happened to be standing on.
            .alert("Can't Call", isPresented: restrictedCalleeAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("This person restricts who can call them.")
            }
    }

    /// SLICE TWO: the presentations and the two navigation destinations. See homeStackA.
    private var homeStackB: some View {
        AnyView(homeStackA)
            .sheet(item: $profileGroup) { g in
                NavigationStack {
                    // .story source: no chat underneath → no Search/Wallpaper dead buttons (audit).
                    ContactInfoView(cid: storyCid(g.authorUid), name: g.name, photoUrl: g.photoUrl,
                                    source: .story)
                }
            }
            // ONE destination type for every chat (list taps AND search results),
            // keyed by cid via .id(...) so each conversation gets a fresh ThreadView
            // identity — a new chat can never inherit the previous chat's @State
            // (repo/cid), which was the cross-routing bug.
            // THE ARCHIVE IS A PAGE OF THIS STACK, not a sheet over it (owner 2026-08-13: "make it
            // like a sub page"). It rides the same path as a chat, so the back chevron is the system's
            // and a chat opened from inside the archive lands on top of it — back returns to the
            // archive, which is what both references do and what a sheet could never do.
            .navigationDestination(for: ArchiveRoute.self) { _ in
                ArchivedChatsView(pushed: true, onOpenChat: { t in path.append(t) })
            }
            .navigationDestination(for: ChatTarget.self) { t in
                // The official channel gets its own screen. ThreadView is built around a composer and
                // an encrypted message pipeline, neither of which exists here.
                if OfficialChannel.isOfficial(t.id) {
                    OfficialChatView().id(t.id)
                } else {
                    ThreadView(cid: t.id, title: t.name, photoUrl: t.photo)
                        .id(t.id)
                }
            }
            .sheet(isPresented: $showNew) {
                NewChatView { t in
                    // Push behind the sheet, then dismiss — no flash back to the list.
                    path.append(t)
                    showNew = false
                }
            }
    }

    /// SLICE THREE: the alerts and the last of the sheets. See homeStackA.
    private var homeStackC: some View {
        AnyView(homeStackB)
            // Native alert (the confirmationDialog rendered as an anchored popover bubble on iOS 26,
            // which read as non-native). A destructive-action confirmation as an alert with a red
            // Delete button is the textbook Apple HIG pattern.
            .alert("Delete this chat?",
                   isPresented: Binding(get: { pendingDelete != nil },
                                        set: { if !$0 { pendingDelete = nil } })) {
                Button("Delete Chat", role: .destructive) {
                    if let c = pendingDelete { Task { await ChatService.deleteForMe(c.id) } }
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("This removes the chat from your list. It comes back if you get a new message.")
            }
            // displayName, not name(for:) — the latter shows a MEMBER's name for groups.
            .confirmationDialog(muteTitle, isPresented: mutePrompted,
                                titleVisibility: .visible) { muteActions }
            .toolbar(selecting ? .hidden : .automatic, for: .tabBar)
            // (The archive is PUSHED now — see `archiveRoute` on the navigationDestination above.)
            .sheet(isPresented: $showMyQR) { MyQRView() }
            .sheet(item: pendingInvite) { item in
                JoinGroupSheet(code: item.code).presentationDetents([.large])
            }
            .confirmationDialog("Delete \(selection.count) chat\(selection.count == 1 ? "" : "s")?",
                                isPresented: $showDeleteSelected, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { deleteSelected() }
                Button("Cancel", role: .cancel) {}
            }
    }

    // Open a chat from a notification tap. Stays pending until the chat list loads
    // so we can resolve name/photo, then routes straight to it.
    private func openPendingChat() {
        guard let cid = router.pendingChatId else { return }
        // CLOSE WHATEVER IS COVERING THIS STACK FIRST (audit). The chat is pushed onto the path
        // underneath, so with the Archive sheet, a story cover, the compose sheet or a profile sheet
        // up, a notification tap looked like it did nothing — and the intent is consumed below, so
        // it never healed. This file's own comment already treats "opens somewhere hidden" as the
        // failure to prevent.
        // (No archive sheet to close any more: it is a page of this stack, and the chat is pushed
        // on top of it — see the ArchiveRoute destination.)
        showNew = false
        showCompose = false
        // The story viewer is not a cover any more, so it cannot be dismissed by clearing a binding:
        // it is a presented screen and the door takes it away. Same job, one call.
        StoryDoor.dismiss()
        profileGroup = nil
        // Navigate even if the conv isn't cached yet (e.g. a brand-new 1:1 opened from a
        // group member sheet) — fall back to the name/photo the caller supplied.
        let conv = repo.conversations.first(where: { $0.id == cid })
        let name = conv?.displayName(me) ?? router.pendingChatName ?? "Chat"
        let photo = conv?.displayPhoto(me) ?? router.pendingChatPhoto
        var p = NavigationPath()
        p.append(ChatTarget(id: cid, name: name, photo: photo))
        path = p
        router.pendingChatId = nil
        router.pendingChatName = nil
        router.pendingChatPhoto = nil
    }
}

// Archived chats (reached from the avatar menu). Swipe to unarchive.
struct ArchivedChatsView: View {
    /// PUSHED, NOT PRESENTED (owner 2026-08-13, ours beside both references: "make it like a sub
    /// page"). Both of them push the archive onto the chat list's own stack — back chevron top left,
    /// the list sliding in from the right — and a drawer that slides up from the bottom reads as a
    /// detour instead of a place inside the app.
    ///
    /// ⚠️ WHEN PUSHED IT MUST NOT BUILD ITS OWN NavigationStack, and it must not declare a
    /// `navigationDestination` for ChatTarget either: it is INSIDE the chat list's stack, which
    /// already has one, and two registrations for the same type in one stack is a fight over who
    /// answers. So a pushed archive hands the tap up to its parent instead.
    var pushed = false
    var onOpenChat: ((ChatTarget) -> Void)? = nil
    /// ⚠️ SPELLED OUT, because the synthesised one cannot be called from here. Every other stored
    /// property below is `private`, so the memberwise initializer is synthesised private too — and
    /// `private` reaches this type and its own extensions, NOT the view next door that presents it,
    /// even in the same file. Without this, `ArchivedChatsView(pushed:)` resolves to the no-argument
    /// init and the compiler says the call takes no arguments.
    init(pushed: Bool = false, onOpenChat: ((ChatTarget) -> Void)? = nil) {
        self.pushed = pushed
        self.onOpenChat = onOpenChat
    }
    private var repo = ConversationsRepository.shared
    private var storiesRepo = StoriesRepository.shared   // archived (hidden) stories appear at the top
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var path = NavigationPath()
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var showDeleteSelected = false
    @State private var pendingDelete: Conversation?     // one chat, from the swipe or the row menu
    @State private var showArchiveSettings = false
    @State private var showHowItWorks = false
    @State private var prefsTick = 0              // re-render after Unhide

    private var me: String { AuthService.shared.uid ?? "" }
    private var dark: Bool { scheme == .dark }
    private var archivedStories: [StoryGroup] {
        _ = prefsTick
        return storiesRepo.others.filter { StoryPrefs.isHidden($0.authorUid) }
    }
    private var storyCardW: CGFloat { (UIScreen.main.bounds.width - 24 - 30) / 4 }

    /// The archived row's long-press menu. Deliberately short: this is a drawer you visit to take
    /// something OUT of, so the actions are the ones that belong to that, and every one of them is
    /// real. It does not reuse the chat page's `chatMenu` because half of that menu (Archive, Pin)
    /// makes no sense on a chat that is already archived.
    @ViewBuilder private func archivedMenu(_ conv: Conversation) -> some View {
        Button { Task { await ChatService.setArchived(conv.id, false) } } label: {
            Label { Text("Unarchive") } icon: { MenuIcon("ic_archive") }
        }
        if conv.hasUnreadMark(me) {
            Button {
                Task { await ChatService.resetUnread(conv.id); await ChatService.markRead(conv.id) }
            } label: {
                Label { Text("Read") } icon: { MenuIcon("ic_menu_unread") }
            }
        } else {
            Button { Task { await ChatService.markUnread(conv.id) } } label: {
                Label { Text("Unread") } icon: { MenuIcon("ic_menu_unread") }
            }
        }
        // Through the same confirmation the swipe uses, and the same one the chat list has always
        // had. This one deleted on the spot, which made the archive the only place in the app where
        // a chat could go with one tap and no question.
        Button(role: .destructive) { pendingDelete = conv } label: {
            Label { Text("Delete") } icon: { MenuIcon(system: "trash.fill") }
        }
    }

    // Horizontal cards of hidden people; tap to view, long-press to Unhide.
    private var archivedStoriesRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                // KEYED ON `authorUid`, THE SAME THING THE `.id()` BELOW SETS, and that mismatch is
                // his "long press the first story and it opens the second".
                //
                // `ForEach` was keying on `StoryGroup.id` while the row then re-declared its identity
                // as `authorUid`. Two different answers to "which view is this", so when SwiftUI
                // rebuilt the row it could hand a card's context menu to the neighbour it thought was
                // the same view. One key, declared once, and there is nothing left to disagree.
                ForEach(archivedStories, id: \.authorUid) { g in
                    Button {
                        // Archived stories are a drawer of ONE person each — no paging out of the
                        // card you tapped into somebody else's, which the row does and this must not.
                        StoryDoor.open(g, from: "arch-\(g.id)", deliveredToMe: true,
                                       onClosed: { prefsTick += 1 })
                    } label: {
                        VStack(spacing: 6) {
                            ZStack(alignment: .bottomLeading) {
                                StoryImage(url: g.stories.last?.previewUrl ?? "")
                                    .frame(width: storyCardW, height: storyCardW * 1.46)
                                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))   // match home cards
                                AvatarView(name: g.name, photoUrl: g.photoUrl, size: 32)
                                    .overlay(StoryRingView(seen: StoryPrefs.seenFlags(g.stories, upTo: g.lastViewedAt), lineWidth: 2)   // watermark: match the stories row
                                        .frame(width: 37, height: 37))
                                    .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                                    .padding(8)
                            }
                            Text(g.name.isEmpty ? "User" : g.name)
                                .font(.system(size: 12)).lineLimit(1).frame(width: storyCardW)
                        }
                    }
                    .buttonStyle(.plain)
                    // The flight's source. Same 24 the card is actually drawn with, so the story
                    // lands as a CARD here rather than the circle a ringed avatar gets — the shape
                    // is read from this number and nowhere else.
                    .modifier(MediaRectReporter(id: "arch-\(g.id)", scope: .storyRow, cornerRadius: 24))
                    // NO `.contextMenu` HERE ANY MORE (his 2026-08-08: "in archive page story when i
                    // long press is using native plz use my custom longpress"). Apple's menu did not
                    // lift this card, it rebuilt a second one from a `preview:` closure — the same
                    // thing the stories row was moved off in `4d1e02f`. The press below lifts the
                    // card's own pixels into the app's menu, so the two screens now feel the same.
                    // No `.id()` here any more: the ForEach above keys on `authorUid`, so the identity
                    // is already stable. Declaring it twice was the whole problem.
                }
            }
            // ONE recogniser for the whole strip, on its scroll view, exactly as the stories row
            // does it — never one per card. A recogniser that lives on a card has to be
            // hit-testable, and then the card's own Button never sees the tap.
            .background(StoryRowLongPress(target: archivedMenuTarget))
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
    }

    /// Which archived card is under the finger, and what its menu says. The rectangles come from the
    /// same registry the story flight flies to, so the lift and the flight cannot disagree about
    /// where a card is — the rule the stories row's own `menuTarget` is built on.
    ///
    /// THE PICTURE ALONE IS LIFTED. The reported rect here covers the whole button, name included,
    /// because that is what the flight was given; but the card is rounded and the name is not, so
    /// cutting the pair under one 24pt radius would round the label's bottom. The card's height is
    /// known exactly (`storyCardW * 1.46`, the frame two lines up from the reporter), so the strip
    /// that is lifted is the top of that rect and nothing else.
    private func archivedMenuTarget(at p: CGPoint) -> StoryMenuTarget? {
        for g in archivedStories {
            let key = MediaOpenRects.key(.storyRow, "arch-\(g.id)")
            guard let r = MediaOpenRects.liveRect(key), r.contains(p) else { continue }
            // THE HIT USES THE MODEL RECT, THE LIFT USES THE DRAWN ONE — the same split the chat
            // list's `menuTarget` makes, and for the same reason: a card mid-press-dip has already
            // committed 0.92 to the model while its pixels are still nearer 0.96, so a window crop
            // taken at the model rectangle lifts a magnified card (his 2026-08-09 zoom report). The
            // finger test stays on `liveRect`, which is what the flight flies to.
            let drawn = MediaOpenRects.drawnRect(key) ?? r
            let cardRect = CGRect(x: drawn.minX, y: drawn.minY, width: drawn.width,
                                  height: min(drawn.height, storyCardW * 1.46))
            return StoryMenuTarget(key: key, rect: cardRect, actions: [
                CMAction(title: "Unhide Story", icon: "tray.and.arrow.up") {
                    StoryPrefs.toggleHidden(g.authorUid)
                    prefsTick += 1
                },
            ])
        }
        return nil
    }

    private var hasAnyArchived: Bool {
        repo.conversations.contains { $0.isArchived(me) && !$0.isCleared(me) && (Flags.groupsEnabled || !$0.isGroup) }
    }
    private var archived: [Conversation] {
        // The official channel can be archived like any other chat, so it has to be findable here or
        // archiving it would look like deleting it.
        (repo.conversations + [OfficialChannelStore.shared.listEntry].compactMap { $0 })
            .filter { $0.isArchived(me) && !$0.isCleared(me) }
            .filter { Flags.groupsEnabled || !$0.isGroup }
            .sorted { $0.displayUpdatedAt(me) > $1.displayUpdatedAt(me) }
    }

    var body: some View {
        // Pushed: no stack of its own, and no ChatTarget destination — the parent owns both. See the
        // note on `pushed`.
        if pushed { content } else { NavigationStack(path: $path) { content } }
    }

    private var content: some View {
            Group {
                if !hasAnyArchived && archivedStories.isEmpty {
                    EmptyStateView(title: "Nothing archived", icon: "archivebox",
                                   text: "Chats you archive and stories you hide will show here.")
                } else {
                    VStack(spacing: 0) {
                        // THE STORIES ROW SITS OUTSIDE THE LIST, exactly as it does on the main
                        // chat page, and for the reason written there since build 147: inside a
                        // List a long press lifts the WHOLE CELL as one preview, so every card in
                        // the row rises together and the menu belongs to the row rather than to the
                        // story you pressed. That is what he is seeing. Out here each card carries
                        // its own menu, and `.id(authorUid)` keeps that menu bound to its person.
                        if !archivedStories.isEmpty { archivedStoriesRow }
                        // ⚠️ TEMPORARY — comes out with `StoryPressDebug.on`. Fourth report on this
                        // row's long press, three source-reasoned fixes shipped and reported dead.
                        // See the note above `StoryPressDebug`.
                        if !archivedStories.isEmpty { StoryPressDebugReadout() }
                        List(selection: $selection) {   // stable binding (Set selects only in edit mode) -> smooth edit transition
                            ForEach(archived) { conv in
                                Button {
                                    if selecting {   // whole row toggles in edit mode, not just the checkbox
                                        toggleTick(conv.id, in: $selection)
                                        return
                                    }
                                    let t = ChatTarget(id: conv.id, name: conv.displayName(me),
                                                       photo: conv.displayPhoto(me))
                                    if let onOpenChat { onOpenChat(t) } else { path.append(t) }
                                } label: {
                                    ChatRow(conv: conv, me: me, dark: dark,
                                            draft: Drafts.shared.text(conv.id),
                                            voiceDraftSecs: AudioRecorder.draftIndex[conv.id] ?? 0,
                                            voiceUnplayed: PlayedVoice.shared.lastVoiceUnplayed(conv, me: me))
                                }
                                .buttonStyle(RowPressFill())   // the same touch grey the chat list has
                                .tag(conv.id)
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                                // Native swipe platter (grey) — no white listRowBackground override
                                // that painted over the row content on swipe.
                                //
                                // Unarchive stays FIRST, which is both the outermost button and the
                                // one a full swipe fires: taking something out is what this drawer is
                                // for, and it is what the reference app puts under the same finger.
                                // Delete was menu-only, so the one action people reach for by swiping
                                // on every other list was missing here (owner 2026-08-13).
                                .swipeActions(edge: .trailing) {
                                    Button { Task { await ChatService.setArchived(conv.id, false) } } label: {
                                        Label("Unarchive", systemImage: "tray.and.arrow.up")
                                    }.tint(.indigo)
                                    // `.tint(.red)`, not left to `role: .destructive`. The role only
                                    // colours a swipe action while the app has not tinted itself,
                                    // and this one tints `.primary` app-wide — so the button took
                                    // WHITE at night and drew a white glyph on it (owner 2026-08-16,
                                    // screenshot: an empty white pill beside a purple Unarchive).
                                    // The chat list's own Delete already forces red for this reason.
                                    Button(role: .destructive) { pendingDelete = conv } label: {
                                        Label { Text("Delete") } icon: { MenuIcon(system: "trash.fill") }
                                    }
                                    .tint(.red)
                                }
                                // THERE WAS NO LONG-PRESS MENU HERE AT ALL, and that is both of his
                                // reports about this list. The chat page has carried one since it was
                                // built; this list only ever had swipe actions, so a long press had
                                // nothing to open — AND nothing to hand the press to. A List row with
                                // no menu keeps the press highlight it lit on touch-down, which is the
                                // grey that never went away. Giving the row a menu takes the gesture
                                // and takes the highlight with it.
                                // AND THE SAME PEEK THE CHAT LIST HAS (his question, 2026-08-14: does
                                // the archive not have the preview?). It did not — menu only, while
                                // the chat list showed the conversation's real last messages above
                                // it. Same card, same builder; an archived chat is still a chat and
                                // the whole point of the peek is reading it without opening it.
                                .contextMenu {
                                    archivedMenu(conv)
                                } preview: {
                                    ChatPeekPreview(cid: conv.id, me: me)
                                }
                            }
                        }
                        .listStyle(.plain)
                        .environment(\.editMode, .constant(selecting ? .active : .inactive))
                        // The selection tick, same as the calls list. See the note there.
                        .tint(Theme.defaultBubble(dark))
                    }
                }
            }
            .navigationTitle("Archived")
            .navigationBarTitleDisplayMode(.inline)
            // THE TAB BAR HAS NO BUSINESS HERE (owner 2026-08-19, screenshot). The archive is a
            // PUSHED page of the chats stack, so it inherited the shell's tab bar and the floating
            // Chats/Calls/Settings pill sat under a sub page. Every other pushed page in the app
            // already hides it (ThreadView, ContactInfoView). Only when pushed: presented as a
            // sheet this view lives outside the TabView and there is nothing to hide.
            .toolbar(pushed ? .hidden : .automatic, for: .tabBar)
            // NO SEARCH BAR (his call, 2026-08-13, first thing he caught on 571). It has been here
            // since June and neither reference has one: the archive is the short list you put things
            // in on purpose, and a permanent search field over a handful of rows is furniture. The
            // app's own search tab still finds these chats — archiving hides a chat from the list,
            // it does not hide it from search.
            // ⚠️ ONLY WHEN THIS VIEW OWNS THE STACK. Pushed, the chat list's stack already answers
            // for ChatTarget, and a second registration for the same type in one stack is two views
            // claiming the same destination.
            .navigationDestination(for: ChatTarget.self) { t in
                if pushed {
                    EmptyView()
                } else if OfficialChannel.isOfficial(t.id) {
                    OfficialChatView().id(t.id)
                } else {
                    ThreadView(cid: t.id, title: t.name, photoUrl: t.photo).id(t.id)
                }
            }
            // (No story cover here any more: the archived card opens through `StoryDoor`, which is
            // the same presentation, the same flight and the same drag-down close as every other
            // door in the app. See the Button above.)
            .toolbar {
                if selecting {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { exitSelect() } label: { Image(systemName: "xmark") }.tint(.primary)
                    }
                    ToolbarItem(placement: .principal) {
                        Text(selection.isEmpty ? "Select Chats" : "\(selection.count) Selected").font(.headline)
                    }
                    // Native bottom toolbar, same as the main chat list selection mode.
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button { unarchiveSelected() } label: { Image(systemName: "tray.and.arrow.up") }
                            .tint(.primary).disabled(selection.isEmpty)
                        Spacer()
                        Button(readTitle) { markReadTargets() }.tint(.primary).disabled(readTargets.isEmpty)
                        Spacer()
                        Button(role: .destructive) { showDeleteSelected = true } label: { Image(systemName: "trash") }
                            .disabled(selection.isEmpty)
                    }
                } else {
                    // Select moved off the left and into the menu, where the reference app keeps it —
                    // two doors into one mode is clutter. Done stays exactly where it was.
                    ToolbarItem(placement: .topBarTrailing) { archiveMenu }
                    // Pushed, the back chevron is the way out and a Done beside it is a second one.
                    if !pushed {
                        ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
                    }
                }
            }
            .confirmationDialog("Delete \(selection.count) chat\(selection.count == 1 ? "" : "s")?",
                                isPresented: $showDeleteSelected, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { deleteSelected() }
                Button("Cancel", role: .cancel) {}
            }
            // Word for word the chat list's own delete alert — one question, asked the same way
            // wherever a chat can go.
            .alert("Delete this chat?",
                   isPresented: Binding(get: { pendingDelete != nil },
                                        set: { if !$0 { pendingDelete = nil } })) {
                Button("Delete Chat", role: .destructive) {
                    if let c = pendingDelete { Task { await ChatService.deleteForMe(c.id) } }
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("This removes the chat from your list. It comes back if you get a new message.")
            }
            .sheet(isPresented: $showArchiveSettings) { ArchiveSettingsView() }
            .sheet(isPresented: $showHowItWorks) { ArchiveHelpView() }
            .onAppear { repo.start() }
    }

    /// The page's own menu. Everything it holds was already in the app and unreachable from here:
    /// the auto-archive switch lived three taps away in Settings > Chats, nothing explained what the
    /// drawer does, and Select was a word in the corner (owner 2026-08-13).
    private var archiveMenu: some View {
        Menu {
            Button { showArchiveSettings = true } label: {
                Label { Text("Archive Settings") } icon: { MenuIcon(system: "slider.horizontal.3") }
            }
            Button { showHowItWorks = true } label: {
                Label { Text("How Does It Work?") } icon: { MenuIcon(system: "questionmark.circle") }
            }
            if hasAnyArchived {
                Button { withAnimation(.smooth(duration: 0.35)) { selecting = true } } label: {
                    Label { Text("Select Chats") } icon: { MenuIcon(system: "checkmark.circle") }
                }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 18))
        }
        .tint(.primary)
    }

    private func exitSelect() { withAnimation(.smooth(duration: 0.35)) { selecting = false; selection = [] } }
    private func unarchiveSelected() {
        let ids = selection
        Task { for id in ids { await ChatService.setArchived(id, false) } }
        exitSelect()
    }
    // Identical rule to the main chat list's Read button — see the long note on `readTargets`
    // there. "Read All" here means every unread chat in the ARCHIVE, which is the list this
    // screen renders; that same messenger scopes Read All the same way, to the rendered list.
    private var readTitle: String { selection.isEmpty ? "Read All" : "Read" }

    private var readTargets: [String] {
        let pool = selection.isEmpty ? archived : repo.conversations.filter { selection.contains($0.id) }
        // Same blocked exclusion as the main list's version (audit) — the archived list can hold
        // silently blocked chats too, and markRead there leaks read receipts just the same.
        // hasUnreadMark, so Read All also clears the ones you marked unread BY HAND. `unread()`
        // clamps the -1 sentinel to zero, so those chats were invisible to this filter and survived
        // a "mark everything read" untouched.
        return pool.filter { !$0.isBlockedByMe(me) && $0.hasUnreadMark(me) }.map(\.id)
    }

    private func markReadTargets() {
        let ids = readTargets
        guard !ids.isEmpty else { return }
        Task { await withTaskGroup(of: Void.self) { g in for id in ids { g.addTask { await ChatService.resetUnread(id); await ChatService.markRead(id) } } } }
        exitSelect()
    }
    private func deleteSelected() {
        let ids = selection
        Task { for id in ids { await ChatService.deleteForMe(id) } }
        exitSelect()
    }
}

// Grey press highlight while a chat row is held (before the context menu lifts it).
// Drives the stories-row overlay: the sentinel reports its top (scroll offset), the row reports its height.
private struct StoryHeaderOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private struct StoryRowHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}


// (`RowStoryAnchor` is gone with the zoom it fed. The ringed avatar registers itself with
// `MediaOpenRects` instead — see the ChatRow avatar — which is what the flight actually reads.)

// Adds a high-priority tap ONLY when the avatar has a story, so it opens the story instead of the
// chat; otherwise the row's normal open-chat tap is untouched.
private struct StoryAvatarTap: ViewModifier {
    let active: Bool
    let action: () -> Void
    func body(content: Content) -> some View {
        // ONE STRUCTURE, ALWAYS. This used to be `if active { content.gesture } else { content }`,
        // which gives an avatar WITH a story a different view tree from one without. Structure is
        // identity to SwiftUI, so when Select mode slid the checkbox in and indented every row, a
        // ringed avatar was rebuilt rather than moved — it snapped to its new place while the plain
        // ones slid, which is exactly the row that stood out of line in his screenshot.
        //
        // `including:` carries the same meaning without the branch: `.subviews` leaves the
        // recogniser present but unreachable, so a story-less avatar still passes its taps through
        // to the row. Same fix, and same reason, as the view-once bubble's double tap.
        content.highPriorityGesture(TapGesture().onEnded(action),
                                    including: active ? .all : .subviews)
    }
}

struct ChatRow: View, Equatable {
    let conv: Conversation
    let me: String
    let dark: Bool
    var storySeen: [Bool] = []      // per-segment seen flags for this person's stories ([] = no active story)
    var onStoryTap: (() -> Void)? = nil   // tap the ringed avatar → open their story (not the chat)
    var draft: String = ""          // unsent composer text (local-only) → "Draft:" preview
    var voiceDraftSecs: Double = 0  // parked voice recording (local-only) → "Draft: 🎤 0:05" preview
    var voiceUnplayed: Bool = false // newest incoming voice note not played yet → accent mic

    // The 15s self-clear the THREAD's typing already had, applied to the row (audit HIGH: a sender
    // whose app died mid-typing/recording labeled this row "typing…"/"recording…" FOREVER, across
    // restarts, hiding the real preview). task(id: typingRawKey) restarts the window whenever the
    // raw map changes — recording's 10s refresh changes its value string, so a live recording
    // stays labeled; a stuck flag ages out like it does inside the chat.
    @State private var activityExpired = false

    // Time-driven repaint (audit): `muted` and `timeStr` read the clock at render, and this row is
    // Equatable on conv alone — so a lapsed 1-hour mute kept its bell-slash indefinitely and a row
    // from yesterday kept showing "14:03" instead of "Yesterday". The tick task below sleeps to the
    // nearest deadline (mute expiry or just past midnight), flips this, and re-arms.
    @State private var clockTick = false

    // Skip re-rendering a row whose conversation is unchanged, even when the parent body re-runs on
    // every snapshot (typing/unread/presence on OTHER chats). Conversation is Equatable → covers
    // lastMessage/unread/updatedAt/pinned/muted/etc.; decryption/avatars/time only recompute on change.
    static func == (l: ChatRow, r: ChatRow) -> Bool {
        l.conv == r.conv && l.me == r.me && l.dark == r.dark
            && l.storySeen == r.storySeen
            && l.draft == r.draft && l.voiceDraftSecs == r.voiceDraftSecs
            && l.voiceUnplayed == r.voiceUnplayed
    }

    private var voiceDraftLabel: String {
        let s = Int(voiceDraftSecs)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var decodedLast: String {
        #if DEBUG
        if DemoMode.active { return conv.lastMessageCipher }   // demo previews are stored plaintext
        #endif
        // The official channel is a public broadcast, so its preview is already plaintext — there is
        // no key and nothing to decrypt. Running it through the decryptor would return an empty
        // string and the row would show a blank line.
        if OfficialChannel.isOfficial(conv.id) { return conv.lastMessageCipher }
        if conv.leaksBlocked(me) { return "" }   // don't leak a blocked person's message into the list
        // Group last-message is sealed by its sender → decrypt with the sender's key, not the cid pair.
        if conv.isGroup {
            return Crypto.shared.decryptGroupCached(conv.lastMessageCipher, cid: conv.id, authorId: conv.lastSender)   // memoized
        }
        return Crypto.shared.decryptCached(conv.lastMessageCipher, cid: conv.id)   // memoized: no re-decrypt per render
    }
    // Stored plaintext markers → an SF Symbol + clean label (native look, no emoji).
    private func previewBadge(_ s: String) -> (String, String)? {
        // Newer voice markers carry the length ("🎤 Voice message · 0:53") — prefix match
        // keeps old plain markers working and surfaces the duration when present.
        if s.hasPrefix("🎤 Voice message") {
            return ("mic.fill", "Voice message" + String(s.dropFirst("🎤 Voice message".count)))
        }
        if s.hasPrefix("🎥 Video") {   // video MESSAGE (🎥) — distinct from 📹 call markers
            return ("video.fill", "Video" + String(s.dropFirst("🎥 Video".count)))
        }
        // Generic media markers ("🎥 2 Videos", "📷 Photos", "📷 3 Photos"…): same native icon+label
        // treatment as single photos/videos — never raw emoji text in the preview.
        if s.hasPrefix("🎥 ") { return ("video.fill", String(s.dropFirst("🎥 ".count))) }
        if s.hasPrefix("📷 ") { return ("photo.fill", String(s.dropFirst("📷 ".count))) }
        // Mixed photo+video albums ("🎬 3 Media") — same icon+label treatment, never raw emoji.
        if s.hasPrefix("🎬 ") { return ("photo.on.rectangle.angled", String(s.dropFirst("🎬 ".count))) }
        switch s {
        case "📄 File":              return ("doc.fill", "File")
        // Our own GIF mark, the one the composer button wears. `sparkles` was standing in for a
        // symbol Apple does not ship, and it says "magic" rather than "GIF" (his 573 screenshot).
        case "GIF":                  return ("ic_gif", "GIF")
        case "📞 Missed call":         return ("phone.down.fill", "Missed call")
        case "📞 Call":                return ("phone.fill", "Call")
        // Legacy markers from before declines were removed from the log (2026-08-12): old
        // conversations may still hold the string, but it must not SAY declined to anyone.
        case "📞 Declined call":       return ("phone.down.fill", "Missed call")
        case "📹 Missed video call":   return ("video.slash.fill", "Missed video call")
        case "📹 Video call":          return ("video.fill", "Video call")
        case "📹 Declined video call": return ("video.slash.fill", "Missed video call")
        default: return nil
        }
    }
    /// "ic_" names one of OUR drawings; anything else is an SF Symbol — the same convention the
    /// composer's attachment tiles use. It exists here because of the GIF row: SF Symbols has no GIF
    /// glyph at all, which is why that preview wore `sparkles` and read as anything but a GIF.
    private func previewRow(_ icon: String, _ text: String, iconTint: Color? = nil) -> some View {
        HStack(spacing: 5) {
            Group {
                if icon.hasPrefix("ic_") {
                    Image(icon).renderingMode(.template).resizable().scaledToFit()
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: icon).font(.system(size: 12))
                }
            }
            .foregroundStyle(iconTint ?? Color.secondary)
            Text(text).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
    /// The emoji shown as the row's trailing badge — the same fresh-reaction test the preview text
    /// uses, so the badge and the words always agree. Only when it was aimed at ME in a 1:1 (a badge
    /// for my own reaction, or for two other people's in a group, is noise).
    private var freshReactionEmoji: String? {
        // Aimed at ME everywhere, groups included — the old `isGroup ||` escape badged Alice
        // reacting to Bob on MY row, exactly the noise this comment forbids (audit).
        guard conv.freshReaction(me), conv.lastReactionBy != me,
              conv.lastReactionToAuthor == me,
              let enc = conv.lastReactionEnc else { return nil }
        let emoji = conv.isGroup
            ? Crypto.shared.decryptGroupCached(enc, cid: conv.id, authorId: conv.lastReactionBy)
            : Crypto.shared.decryptCached(enc, cid: conv.id)
        return emoji.isEmpty ? nil : emoji
    }

    // "Reacted 🙏" preview when the newest event in the chat is a reaction.
    private var reactionPreview: String? {
        guard conv.freshReaction(me), let enc = conv.lastReactionEnc else { return nil }
        let emoji = conv.isGroup
            ? Crypto.shared.decryptGroupCached(enc, cid: conv.id, authorId: conv.lastReactionBy)   // sealed by the reactor
            : Crypto.shared.decryptCached(enc, cid: conv.id)
        guard !emoji.isEmpty else { return nil }
        if conv.lastReactionBy == me { return "You reacted \(emoji)" }
        if conv.isGroup {
            let n = conv.names[conv.lastReactionBy] ?? "Someone"
            let first = n.split(separator: " ").first.map(String.init) ?? n
            return "\(first) reacted \(emoji)"
        }
        return conv.lastReactionToAuthor == me ? "Reacted \(emoji) to your message" : "Reacted \(emoji)"
    }
    // Live "recording…" for the list — the voice-note flavour of typingLabel, same synced field.
    private var recordingLabel: String? {
        guard !conv.isBlockedByMe(me) else { return nil }
        let recs = conv.others(me).filter { conv.recording[$0] == true }
        guard !recs.isEmpty else { return nil }
        if !conv.isGroup { return "recording…" }
        let n = conv.names[recs[0]] ?? "Someone"
        let first = n.split(separator: " ").first.map(String.init) ?? n
        return "\(first) is recording…"
    }
    // Live "typing…" for the list — the conv doc already syncs the typing map, so this is free.
    private var typingLabel: String? {
        guard !conv.isBlockedByMe(me) else { return nil }
        let typers = conv.others(me).filter { conv.typing[$0] == true }
        guard !typers.isEmpty else { return nil }
        if !conv.isGroup { return "typing…" }
        let names = typers.map { u in
            let n = conv.names[u] ?? "Someone"
            return n.split(separator: " ").first.map(String.init) ?? n
        }
        return names.count == 1 ? "\(names[0]) is typing…" : "\(names.joined(separator: ", ")) are typing…"
    }
    // "Alice: " prefix for group previews so you can tell who sent the last message.
    // Only for real messages (ciphertext or media markers) — NOT system events like "X added Y".
    private var lastSenderPrefix: String {
        guard conv.isGroup, !conv.lastSender.isEmpty, conv.lastSender != me else { return "" }
        let c = conv.lastMessageCipher
        guard c.hasPrefix("enc") || c.hasPrefix("📷") || c.hasPrefix("🎤 Voice message") || c.hasPrefix("🎥") || c.hasPrefix("🎬") else { return "" }
        let n = conv.names[conv.lastSender] ?? "Someone"
        return "\(n.split(separator: " ").first.map(String.init) ?? n): "
    }
    private var unread: Int { conv.isBlockedByMe(me) ? 0 : conv.unread(me) }   // silent block: no badge
    private var muted: Bool { conv.isMuted(me, now: Date().timeIntervalSince1970 * 1000) }

    // The last message is media we can thumbnail (ANY 📷/🎥 marker — single, album, or multi-video —
    // and not a frozen blocked-chat row). 📹 call markers are unaffected.
    private var isPhotoPreview: Bool {
        !conv.leaksBlocked(me)
            && (conv.lastMessageCipher.hasPrefix("📷") || conv.lastMessageCipher.hasPrefix("🎥") || conv.lastMessageCipher.hasPrefix("🎬"))
            && (conv.lastImageUrl?.isEmpty == false)
    }
    // "Photo" / "Photos" / "Video · 0:12" / "2 Videos" next to the little thumbnail (emoji stripped).
    private var photoPreviewLabel: String {
        let c = conv.lastMessageCipher
        if c.hasPrefix("🎥 ") { return String(c.dropFirst("🎥 ".count)) }
        if c.hasPrefix("📷 ") { return String(c.dropFirst("📷 ".count)) }
        if c.hasPrefix("🎬 ") { return String(c.dropFirst("🎬 ".count)) }   // mixed album → "3 Media"
        return "Photo"
    }
    // Preview area, in priority order: blocked freeze → live typing → unsent draft →
    // photo thumbnail → media/call badge → say-hello → decrypted text.
    @ViewBuilder private var previewContent: some View {
        if conv.leaksBlocked(me) {
            previewRow("hand.raised.fill", "Blocked")
        } else if let r = recordingLabel, !activityExpired {
            (Text(Image(systemName: "mic.fill")).font(.system(size: 12)) + Text(" \(r)"))
                .font(.system(size: 14)).foregroundStyle(Theme.accent(dark)).lineLimit(1)
        } else if let t = typingLabel, !activityExpired {
            Text(t).font(.system(size: 14)).foregroundStyle(Theme.accent(dark)).lineLimit(1)
        } else if voiceDraftSecs > 0 {
            // A parked voice recording (his reference screenshots): the same red "Draft:" the text
            // draft below wears, then the mic and the note's length. Wins over a text draft — the
            // recording is the thing most in danger of being forgotten.
            (Text("Draft: ").foregroundStyle(.red)
             + Text(Image(systemName: "mic.fill")).font(.system(size: 12))
             + Text(" " + voiceDraftLabel).foregroundStyle(.secondary))
                .font(.system(size: 14)).lineLimit(1)
        } else if !draft.isEmpty {
            (Text("Draft: ").foregroundStyle(.red) + Text(draft).foregroundStyle(.secondary))
                // 2 lines is the design, but the first layout pass can offer almost no width, and
                // without a cap the text stacks one letter per line. See the note on timeStr.
                .font(.system(size: 14)).lineLimit(2).truncationMode(.tail)
        } else if let r = reactionPreview {
            Text(r).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
        } else if isPhotoPreview {
            HStack(spacing: 5) {
                SecureImageView(imageUrl: conv.lastImageUrl ?? "", enc: conv.lastImageEnc, cid: conv.id)
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                Text(lastSenderPrefix + photoPreviewLabel).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
            }
        } else if let badge = previewBadge(conv.lastMessageCipher) {
            // Unheard voice note = accent mic (like an unread badge, but for your ears).
            previewRow(badge.0, lastSenderPrefix + badge.1,
                       iconTint: voiceUnplayed ? Theme.accent(dark) : nil)
        } else if decodedLast.isEmpty {
            previewRow("hand.wave.fill", "Say hello")
        } else if decodedLast.hasPrefix(Message.contactMarker) {
            // Shared-contact card → native icon + "Contact", never the raw marker text.
            previewRow("person.crop.circle.fill", lastSenderPrefix + "Contact")
        } else if decodedLast.hasPrefix(Message.locationMarker) {
            previewRow("mappin.circle.fill", lastSenderPrefix + "Location")
        } else if decodedLast.hasPrefix(Message.pinMarker) {
            // Pin notice — a marker THIS build fully supports. It must render as a friendly preview, NOT
            // the "newer version" fallback below (user report: both users on the latest build saw
            // "Message from a newer version" for a pin because pin had no case here and fell through to
            // the generic feature-marker catch-all). Every KNOWN marker (contact/location/pin) is handled
            // explicitly above; only genuinely-unknown markers reach the fallback.
            previewRow("pin.fill", lastSenderPrefix + "Pinned a message")
        } else if decodedLast.hasPrefix(Message.pollMarker) {
            previewRow("chart.bar.fill", lastSenderPrefix + "Poll")
        } else if decodedLast.range(of: Message.featureMarkerPattern, options: .regularExpression) != nil {
            // A newer-version feature this build doesn't recognize → never show the raw marker.
            previewRow("arrow.up.circle.fill", "Message from a newer version")
        } else {
            Text(lastSenderPrefix + decodedLast)
                .font(.system(size: 14, weight: unread > 0 ? .medium : .regular))
                .foregroundStyle(unread > 0 ? Color.primary : .secondary).lineLimit(2)   // darker when unread
        }
    }

    // Delivery ticks for MY last message: single grey = sent, double accent = read.
    @ViewBuilder private var ticksView: some View {
        let read = conv.lastReadByOther(me)
        HStack(spacing: -3) {
            Image(systemName: "checkmark")
            if read { Image(systemName: "checkmark") }
        }
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(read ? Theme.accent(dark) : Color.secondary)
    }

    private var timeStr: String {
        let ms = conv.displayUpdatedAt(me)   // frozen at block time for blocked chats
        guard ms > 0 else { return "" }
        let d = Date(timeIntervalSince1970: ms / 1000)
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: d, to: Date()).day, days < 7 {
            return d.formatted(.dateTime.weekday(.abbreviated))
        }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }

    var body: some View {
        // 56pt avatar; up to 2 preview lines; mute/pin/tick indicators inline.
        HStack(spacing: 12) {
            let _ = clockTick   // dependency: the tick task's flip must re-evaluate muted/timeStr
            // Rule: a story ring must NOT enlarge the row — the photo shrinks a hair
            // inside the same 56pt footprint, so ringed and ringless avatars line up equal.
            Group {
                // The official channel has no account and therefore no profile photo to fetch: its
                // face is the app's own mark, drawn from the bundle. Same 56pt footprint as every
                // other row, so nothing about the list's rhythm changes.
                if OfficialChannel.isOfficial(conv.id) {
                    OfficialAvatar(size: storySeen.isEmpty ? 56 : 49)
                } else {
                    AvatarView(name: conv.displayName(me), photoUrl: conv.displayPhoto(me),
                               size: storySeen.isEmpty ? 56 : 49)
                }
            }
                // THIS CIRCLE IS THE STORY'S DOOR: opening from here grows the viewer out of it, and
                // the drag-down flies home into it. (Apple's `matchedTransitionSource` that used to
                // sit beside this is gone with the zoom it belonged to.)
                //
                // The radius is HALF THE SIDE, which is the whole trick: `StoryCardMorph` reads what
                // its source reports, and a source reporting half its short side gets a CIRCULAR
                // flight — square crop, round mask, all the way rather than only at the landing.
                // The reference app's shape, no per-site branch.
                //
                // Reported on the PHOTO, not the ring: with the ring inside the anchor the transition
                // stretched the grey ring segments, which the owner screenshotted.
                .modifier(MediaRectReporter(id: "row-\(conv.id)", scope: .storyRow,
                                            cornerRadius: (storySeen.isEmpty ? 56 : 49) / 2))
                .frame(width: 56, height: 56)
                .overlay {   // story ring around the avatar when this person has an active story
                    if !storySeen.isEmpty {
                        StoryRingView(seen: storySeen, lineWidth: 2)
                            .frame(width: 56, height: 56)
                    }
                }
                // Tap the ringed avatar → open their story (high-priority so it beats the row's open-chat tap).
                .modifier(StoryAvatarTap(active: !storySeen.isEmpty && onStoryTap != nil) { onStoryTap?() })
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(conv.displayName(me))
                        .font(.system(size: 16, weight: unread > 0 ? .bold : .semibold))   // heavier when unread
                        .lineLimit(1)
                    // TWO TICKS, from two different authorities, and they are not interchangeable.
                    //
                    // The official channel's is drawn from a HARDCODED id rather than any field on
                    // any document, so there is nothing a copycat account could write to earn one.
                    // That is the right rule for the one channel that must never be impersonable.
                    //
                    // Everybody else's comes from the verification record on their own document,
                    // which only an admin holding `verify` can write. `VerifiedMark` draws nothing
                    // when there is no record, so it needs no `if` around it — and no `if` around it
                    // is the point, because an `if` here is a place for the rule to be restated
                    // slightly differently.
                    if OfficialChannel.isOfficial(conv.id) {
                        VerifiedTick(size: 15)
                    } else if !conv.isGroup {
                        VerifiedMark(uid: conv.otherUid(me), size: 15)
                    }
                    if muted {
                        Image(systemName: "bell.slash.fill")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 8)
                    Text(timeStr)
                        .font(.system(size: 12))
                        .foregroundStyle(unread > 0 ? Theme.accent(dark) : .secondary)
                        // NEVER WRAP. The list's first layout pass can offer a row almost no width,
                        // and an unconstrained Text answers that by stacking one letter per line —
                        // "Yesterday" became a vertical column of e/s/t/e/r/d/a/y (owner caught it
                        // frame by frame on a cold launch). It was invisible before only because
                        // there were no rows on screen that early to lay out badly.
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                HStack(alignment: .top, spacing: 4) {
                    previewContent
                    Spacer(minLength: 8)
                    // Status tick now lives in the right column — under the timestamp, beside the pin.
                    if conv.lastIsMine(me) { ticksView.padding(.top, 1) }
                    if conv.isPinned(me) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    // ONE badge for every reaction, never the emoji itself (user spec 2026-07-29, with
                    // the reference screenshot: "if react always use that badge"). The preview text
                    // beside it already spells out WHICH emoji — "Reacted 🐱 to your message" — so
                    // repeating it here just made the right edge of the row a second, competing emoji.
                    // A constant heart reads as "there is a reaction" at a glance, and keeps the row's
                    // trailing column visually stable whatever anyone reacts with. Same freshness rule
                    // as the text, so the two can never disagree.
                    if freshReactionEmoji != nil {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .transition(.scale.combined(with: .opacity))
                    }
                    if unread > 0 {
                        Text("\(min(unread, 99))")
                            .font(.caption2.bold()).foregroundColor(Theme.onAccent(dark))
                            .contentTransition(.numericText())   // count rolls instead of snapping
                            .padding(.horizontal, 5)
                            .frame(minWidth: 19, minHeight: 19)   // 19×19 min badge
                            .background(Theme.accent(dark)).clipShape(Capsule())
                    } else if conv.manuallyUnread(me) {
                        // A PLAIN DOT, no number. You marking a chat unread is a note to yourself;
                        // writing "1" on it claims somebody sent you something, which is what the
                        // owner reported — he read the chat to the end and the list then told him it
                        // held one unread message. Same circle, same colour, nothing written in it.
                        Circle()
                            .fill(Theme.accent(dark))
                            .frame(width: 12, height: 12)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            }
        }
        .frame(minHeight: 76)
        .animation(.easeInOut(duration: 0.22), value: unread)   // smooth bold/color/badge changes
        .animation(.easeInOut(duration: 0.22), value: muted)
        .animation(.easeInOut(duration: 0.22), value: conv.isPinned(me))   // pin icon fade
        // Restarts on every raw typing-map change (see activityExpired above); no-op for quiet rows.
        .task(id: conv.typingRawKey) {
            activityExpired = false
            guard conv.typing.values.contains(true) || conv.recording.values.contains(true) else { return }
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if !Task.isCancelled { activityExpired = true }
        }
        // The clock tick (see clockTick above): wake at mute expiry / just past midnight, repaint.
        .task(id: conv.mutedBy[me] ?? 0) {
            while !Task.isCancelled {
                let nowMs = Date().timeIntervalSince1970 * 1000
                var deadlines: [Double] = []
                let mute = conv.mutedBy[me] ?? 0
                if mute > nowMs { deadlines.append(mute) }
                if let midnight = Calendar.current.nextDate(after: Date(),
                                                            matching: DateComponents(hour: 0, minute: 0, second: 5),
                                                            matchingPolicy: .nextTime) {
                    deadlines.append(midnight.timeIntervalSince1970 * 1000)
                }
                guard let next = deadlines.min() else { return }
                try? await Task.sleep(nanoseconds: UInt64(max(1, (next - nowMs) / 1000) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                clockTick.toggle()
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 16)   // 16pt gutter moved inside the cell (row insets are now
                                    // zero) so the reorder drag preview matches the cell width
                                    // and stays locked to the vertical axis (no horizontal drift)
    }
}

// Long-press PEEK of a conversation (reference behavior): the chat's real last messages as
// simple read-only bubbles. Cache-first — a chat opened this session renders instantly from
// ThreadMessageCache; otherwise one light fetch. Deliberately NOT ThreadView (a peek must stay
// cheap and side-effect free: no listeners, no read receipts, no keyboard).
// The long-press platter for a chat row.
//
// This used to be a hand-rolled fake: emoji text pills ("📷 Photo", "🎥 Video call") in a fixed 330pt
// box on a plain background, which read as a mock-up rather than the chat.
//
// the reference app's model (verified in their source: `CLVTableDataSource.tableView(_:contextMenuConfigurationForRowAt:point:)`
// → `ChatListViewController.createPreviewController` → a real `ConversationViewController` with
// `previewSetup()`) is to show the ACTUAL conversation view with only its chrome suppressed — real
// image thumbnails, real voice notes, real call cells — and to set NO explicit size, letting UIKit size
// the platter from the view controller (so it lands at the screen's own proportions).
//
// So: real `MessageBubble`s (the same view the chat renders), the chat's real wallpaper behind them,
// bottom-aligned like a real conversation, at the screen's aspect. The one place we must diverge from
// the reference app is the frame: a SwiftUI preview auto-sizes to intrinsic content and would collapse, so the
// size is stated explicitly and derived from the screen rather than being a magic number.
private struct ChatPeekPreview: View {
    let cid: String
    let me: String
    @State private var msgs: [Message]
    @State private var loaded: Bool
    @Environment(\.colorScheme) private var scheme

    init(cid: String, me: String) {
        self.cid = cid
        self.me = me
        let cached = (ThreadMessageCache.shared.messages(for: cid) ?? []).filter { !$0.isSystem }
        _msgs = State(initialValue: Array(cached.suffix(14)))
        _loaded = State(initialValue: !cached.isEmpty)
    }

    // Screen-proportional, like the platter the reference app gets for free from a full view controller.
    private var size: CGSize {
        let screen = UIScreen.main.bounds.size
        return CGSize(width: screen.width, height: screen.height * 0.62)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ChatWallpaperBackground(cid: cid)
            if OfficialChannel.isOfficial(cid) {
                // The channel's messages are announcements, not documents under this cid, so the
                // generic fetch below would find nothing and claim the chat was empty.
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(OfficialChannelStore.shared.visible.suffix(8)) { a in
                            AnnouncementRow(announcement: a, dark: scheme == .dark,
                                            onImageTap: { _ in }, onButtonTap: { _ in })
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDisabled(true)
            } else if !loaded {
                ProgressView()
            } else if msgs.isEmpty {
                Text("No messages yet").font(.subheadline).foregroundStyle(.secondary)
            } else {
                // Bottom-aligned and clipped at the top: a conversation reads from the bottom up, and
                // the newest messages are the ones worth previewing.
                // ANCHORED TO THE BOTTOM, so the NEWEST message is always fully visible and it is the
                // oldest that gets cut off at the top. The previous version was a plain VStack inside a
                // fixed frame: 14 bubbles are routinely taller than the platter, and SwiftUI centres an
                // oversized child, so it clipped BOTH ends - the last message was sliced in half at the
                // bottom, which is the opposite of what a conversation preview is for. A Spacer cannot fix
                // that, because it only has room to push when the content is SHORTER than the frame.
                // Scrolling is off: the platter is a preview, not an interactive view.
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(msgs) { m in
                            MessageBubble(message: m, isMe: m.authorId == me, dark: scheme == .dark, cid: cid)
                                .allowsHitTesting(false)   // the platter is not interactive
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDisabled(true)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .task {
            // ⚠️ ALWAYS REFRESH — `guard !loaded` used to sit here, so a chat with anything cached
            // never asked the server and the peek showed the conversation as it stood the last time
            // it was OPENED. Messages that arrived since were simply absent (owner 2026-08-16).
            //
            // The cache is still what draws first, instantly, and that is the point of it. It just
            // is not the answer any more. Same shape as the chat list: paint what we know, then
            // correct it.
            //
            // ⚠️ AND THIS GOT WORSE THE DAY THE CACHE MOVED TO DISK. While it lived in memory a cold
            // launch had nothing to serve, so the peek fetched; now it can answer with something days
            // old and the fetch never ran. A cache that gains reach needs its readers re-checked.
            //
            // Still no listener, deliberately: a peek must stay cheap and side-effect free — no read
            // receipts, nothing marked seen. One fetch is the whole cost.
            guard !OfficialChannel.isOfficial(cid) else { return }
            // Newest-first fetch → ascending for display.
            let fetched = await ChatService.galleryContent(cid, limit: 14)
            msgs = Array(fetched.reversed()).filter { !$0.isSystem }
            loaded = true
        }
    }
}
