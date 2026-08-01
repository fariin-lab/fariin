import SwiftUI
import UIKit

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

    // CONVERSATIONS WAITING, NOT MESSAGES WAITING — how Signal and WhatsApp both badge it. One person
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
        return chatsRepo.conversations.filter {
            !$0.isCleared(me) && !$0.isArchived(me) && !$0.isBlockedByMe(me)
                && (Flags.groupsEnabled || !$0.isGroup)   // audit: a hidden legacy group badged a list that refused to show it
                && $0.unread(me) > 0
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
            Tab("Chats", image: "ic_chat", value: 0) {
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
                                        if selection.contains(run.id) { selection.remove(run.id) }
                                        else { selection.insert(run.id) }
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
                            .contextMenu {
                                Button {
                                    pendingCall = PendingCall(uid: call.otherUid, name: call.name, photo: call.photoUrl, video: false)
                                } label: { Label("Voice Call", systemImage: "phone") }
                                Button {
                                    pendingCall = PendingCall(uid: call.otherUid, name: call.name, photo: call.photoUrl, video: true)
                                } label: { Label("Video Call", systemImage: "video") }
                                Button {
                                    AppRouter.shared.pendingChatName = call.name
                                    AppRouter.shared.pendingChatPhoto = call.photoUrl
                                    AppRouter.shared.pendingChatId = call.cid
                                } label: {
                                    Label { Text("Chats") } icon: { Image("ic_menu_chat").renderingMode(.template)
                        .resizable().scaledToFit().frame(width: 20, height: 20) }
                                }
                                Button {
                                    withAnimation(.smooth(duration: 0.35)) { selecting = true; selection = [run.id] }
                                } label: { Label("Select", systemImage: "checkmark.circle") }
                                Divider()
                                Button(role: .destructive) { deleteRun(run) } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .animation(.spring(response: 0.38, dampingFraction: 0.86), value: shownRuns.map(\.id))   // deletes/filter switch animate (parity with chats)
                    .environment(\.defaultMinListRowHeight, 56)   // tight, compact rows
                    .environment(\.editMode, .constant(selecting ? .active : .inactive))
                }
            }
            .navigationTitle("Calls")
            .searchable(text: $searchText, prompt: "Search calls")
            .toolbar {
                if selecting {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { withAnimation(.smooth(duration: 0.35)) { selecting = false; selection = [] } } label: { Image(systemName: "xmark") }.tint(.primary)
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
                        Text(count > 1 ? "\(call.name) (\(count))" : call.name)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(call.missedIncoming ? Color.red : Color.primary)
                            .lineLimit(1)
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
// index. (No "Create Call Link" / phone-number search — those aren't real Kulan features.)
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
    @Environment(\.colorScheme) private var scheme
    @State private var showNew = false
    @State private var chatFilter = 0   // 0 = all, 1 = unread
    @State private var path = NavigationPath()
    @State private var pendingDelete: Conversation?
    @State private var pendingMute: Conversation?
    // Multi-select edit mode.
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var showArchived = false
    @State private var showDeleteSelected = false
    @State private var showCompose = false
    @State private var showMyQR = false   // welcome empty-state → My QR Code sheet
    @State private var welcomeGreet = 0   // one-shot greeting bounce on the welcome glyph
    @State private var viewerGroup: StoryGroup?
    @State private var viewerAnonymous = false
    // WHERE the story was opened from — the zoom grows out of (and closes back into) the
    // exact circle the user tapped: a top stories-row card (its group id) or a chat-row
    // ring ("row-<cid>"). Set BEFORE viewerGroup at every open site.
    @State private var viewerSourceID: String = ""
    @State private var showUploadViewer = false   // live viewer for the still-uploading story
    @State private var profileGroup: StoryGroup?
    @Namespace private var storyNS   // zoom transition: story card ⇄ full-screen viewer
    // Stories row scrolls WITH the chat list: the row stays OUTSIDE the List (per-card
    // long-press dies inside a List row — build 147) but is offset 1:1 by the list's
    // scroll, and the List gets a matching top margin so rows start below it.
    @State private var chatScrollY: CGFloat = 0
    @State private var storiesRowHeight: CGFloat = (UIScreen.main.bounds.width - 54) / 4 * 1.46 + 41
    // Stories opt-out (Settings > Stories > Turn Off Stories): the row disappears and chat-row
    // rings go dark — the whole surface, not a hidden-but-alive row.
    @AppStorage("storiesOptedOut") private var storiesOptedOut = false

    // Welcome empty state: icon + copy + the three ways to get a first chat going.
    // Reuses the existing flows (NewChatView search, MyQRView, Settings' invite text).
    private var inviteText: String {
        let h = profile.me?.handle ?? ""
        return h.isEmpty ? "Chat with me on Kulan." : "Chat with me on Kulan — my username is @\(h)"
    }
    // Big-app empty state (TG/WA/Signal rule: one visual, one line, ONE button).
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
            // empty inbox. X, Signal and iMessage all show only a glyph, a title and one line here -
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
                      && $0.unread(me) > 0 }
            .map(\.id)
        Task { for id in ids { await ChatService.resetUnread(id); await ChatService.markRead(id) } }
    }

    // One chat-list row: full-row Button (a NavigationLink would draw the disclosure chevron;
    // in edit mode a Button is auto-disabled so native multi-select toggles via the row tag),
    // long-press menu + conversation PEEK preview, swipe actions both edges.
    /// In edit mode the List's own selection only reacts to taps on NON-interactive row content, and
    /// every chat row is a Button — so a tap on the avatar, the name, or the empty space was swallowed
    /// and pushed the chat instead of selecting it. Only the checkbox (outside the Button) worked.
    /// Route those taps here so the whole row toggles, like Mail and Telegram.
    private func toggleSelection(_ id: String) {
        withAnimation(.smooth(duration: 0.2)) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        }
    }

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
        Button {
            path.append(ChatTarget(id: conv.id, name: conv.displayName(me),
                                   photo: conv.displayPhoto(me)))
        } label: {
            chatListRowLabel(conv)
        }
        .buttonStyle(.plain)   // no accent tint on the label, and no custom press flag to get stuck
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
                // Whole row toggles, like Mail and Telegram (taps on a Button's content were
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
                Label { Text("Archive") } icon: { Image("ic_archive_fill").renderingMode(.template)
                        .resizable().scaledToFit().frame(width: 22, height: 22) }
            }
            .tint(.gray)
            Button { pendingMute = conv } label: { Label("Mute", systemImage: "bell.slash.fill") }
            .tint(.indigo)
            Button(role: .destructive) {
                pendingDelete = conv
            } label: { Label("Delete", systemImage: "trash.fill") }
            .tint(.red)
        }
        .swipeActions(edge: .leading) {
            Button {
                Task { await ChatService.setPinned(conv.id, !conv.isPinned(me)) }
            } label: {
                Label { Text(conv.isPinned(me) ? "Unpin" : "Pin") } icon: {
                    conv.isPinned(me) ? AnyView(Image(systemName: "pin.slash"))
                                      : AnyView(Image("ic_pin_menu").renderingMode(.template)
                                                    .resizable().scaledToFit().frame(width: 20, height: 20))
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
                    if let g = storiesRepo.others.first(where: { $0.authorUid == conv.otherUid(me) }) {
                        viewerSourceID = "row-\(conv.id)"   // zoom from THIS row's ring
                        viewerAnonymous = false; viewerGroup = g
                    }
                },
                storyNS: storyNS,
                draft: Drafts.shared.text(conv.id),
                voiceUnplayed: PlayedVoice.shared.lastVoiceUnplayed(conv, me: me))
            .equatable()   // skip rebuild when this conversation is unchanged
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())   // whole row tappable (incl. empty space)
            .contextMenu {
                chatMenu(conv)
            } preview: {
                ChatPeekPreview(cid: conv.id, me: me)
            }
    }

    private var visible: [Conversation] {
        repo.conversations
            .filter { !$0.isCleared(me) && !$0.isArchived(me) }
            .filter { Flags.groupsEnabled || !$0.isGroup }
            // A 1:1 chat you merely OPENED (from search / a profile) but never exchanged a message
            // in stays OUT of the list (standard behavior) until something real happens: a message
            // either way, an unread, a pin, or a draft you typed. Groups always list — creating
            // one is deliberate.
            .filter { c in
                c.isGroup || !c.lastMessageCipher.isEmpty || c.unread(me) > 0 || c.isPinned(me)
                    || !Drafts.shared.text(c.id).isEmpty
            }
            .filter { c in   // Filter: 0 = All, 1 = Unread, 2 = Groups
                switch chatFilter {
                // Blocked-aware, like the row badge and the tab badge (audit: a silently blocked
                // chat appeared under Unread with no badge and a zero tab count).
                case 1: return !c.isBlockedByMe(me) && c.unread(me) > 0
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
            Button { showArchived = true } label: {
                Label { Text("Archive") } icon: { Image("ic_archive").renderingMode(.template)
                        .resizable().scaledToFit().frame(width: 20, height: 20) }
            }
            // Stories off (Settings > Stories > Turn Off Stories) → no Add Story entry.
            if !storiesOptedOut {
                Button { showCompose = true } label: {
                    Label { Text("Add Story") } icon: { Image("ic_stories").renderingMode(.template)
                        .resizable().scaledToFit().frame(width: 20, height: 20) }
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
                Button("Read All") { markReadSelected() }.tint(.primary).disabled(selection.isEmpty)
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
        if !conv.isBlockedByMe(me) && conv.unread(me) > 0 {
            Button {
                // Full parity with opening the chat: reset MY counter, send read receipts,
                // and drop its delivered notifications + fix the app badge.
                Task { await ChatService.resetUnread(conv.id); await ChatService.markRead(conv.id) }
                NotificationCleaner.clear(cid: conv.id)
            } label: {
                Label("Read", systemImage: "envelope.open")
            }
        } else {
            Button { Task { await ChatService.markUnread(conv.id) } } label: {
                Label { Text("Unread") } icon: { Image("ic_menu_unread").renderingMode(.template)
                        .resizable().scaledToFit().frame(width: 20, height: 20) }
            }
        }
        // Native submenu (clean popover) instead of a custom mute sheet.
        Menu {
            if conv.isMuted(me, now: Date().timeIntervalSince1970 * 1000) {
                Button("Unmute") { Task { await ChatService.setMute(conv.id, until: 0) } }
            }
            Button("Mute for 1 hour") { Task { await ChatService.setMute(conv.id, until: ChatService.muteUntil(1)) } }
            Button("Mute for 8 hours") { Task { await ChatService.setMute(conv.id, until: ChatService.muteUntil(8)) } }
            Button("Mute for 1 week") { Task { await ChatService.setMute(conv.id, until: ChatService.muteUntil(168)) } }
            Button("Mute Always") { Task { await ChatService.setMute(conv.id, until: ChatService.muteUntil(nil)) } }
        } label: { Label("Mute", systemImage: "bell.slash") }
        Button { Task { await ChatService.setPinned(conv.id, !conv.isPinned(me)) } } label: {
            Label { Text(conv.isPinned(me) ? "Unpin" : "Pin") } icon: {
                    conv.isPinned(me) ? AnyView(Image(systemName: "pin.slash"))
                                      : AnyView(Image("ic_pin_menu").renderingMode(.template)
                                                    .resizable().scaledToFit().frame(width: 20, height: 20))
                }
        }
        Button { Task { await ChatService.setArchived(conv.id, true) } } label: {
            Label { Text("Archive") } icon: { Image("ic_archive").renderingMode(.template)
                        .resizable().scaledToFit().frame(width: 20, height: 20) }
        }
        Button(role: .destructive) { pendingDelete = conv } label: {
            Label("Delete", systemImage: "trash")
        }
    }
    // Batch ops run the per-chat writes CONCURRENTLY (was sequential = N round-trips in series).
    private func archiveSelected() {
        let ids = selection
        Task { await withTaskGroup(of: Void.self) { g in for id in ids { g.addTask { await ChatService.setArchived(id, true) } } } }
        exitSelect()
    }
    private func markReadSelected() {
        // Skip silently-blocked chats, exactly like the tab badge, Mark All Read and the row menu
        // (audit): markRead writes lastRead, which flips the blocked person's messages to read ticks
        // and reveals the activity the block is hiding. Their rows show 0 unread, so nothing on
        // screen even hints they were included.
        let ids = selection.filter { id in
            !(repo.conversations.first { $0.id == id }?.isBlockedByMe(me) ?? false)
        }
        Task { await withTaskGroup(of: Void.self) { g in for id in ids { g.addTask { await ChatService.resetUnread(id); await ChatService.markRead(id) } } } }
        exitSelect()
    }
    private func deleteSelected() {
        let ids = selection
        Task { await withTaskGroup(of: Void.self) { g in for id in ids { g.addTask { await ChatService.deleteForMe(id) } } } }
        exitSelect()
    }

    var body: some View {
        NavigationStack(path: $path) {
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
                    ZStack(alignment: .top) {
                      // Selection is ALWAYS bound (a Set only selects in edit mode, so taps still OPEN
                      // the row when not editing). Swapping the binding nil<->$selection reconfigured
                      // the List and made the edit-mode transition POP; a stable binding lets the
                      // native circles-slide-in + rows-shift-right animate smoothly (withAnimation on
                      // `selecting` at the tap sites drives it).
                      List(selection: $selection) {
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
                    .animation(.spring(response: 0.38, dampingFraction: 0.86), value: visible.map(\.id))
                    .environment(\.editMode, .constant(selecting ? .active : .inactive))
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
                                 storyNS: storyNS,
                                 onCompose: { showCompose = true },
                                 onOpen: { g in viewerSourceID = g.isMine ? g.id : "story-\(g.id)"; viewerAnonymous = false; viewerGroup = g },
                                 onMessage: { g in openStoryChat(g) },
                                 onProfile: { g in profileGroup = g },
                                 onOpenAnon: { g in viewerSourceID = g.isMine ? g.id : "story-\(g.id)"; viewerAnonymous = true; viewerGroup = g },
                                 onOpenUploading: { showUploadViewer = true })
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
                                emptyWelcome
                                    .padding(.top, (storiesOptedOut ? 0 : storiesRowHeight) + 24)
                            } else {
                                // Per-filter copy — the Groups filter was showing the Unread text.
                                ContentUnavailableView(
                                    chatFilter == 2 ? "No groups yet" : "No unread chats",
                                    systemImage: chatFilter == 2 ? "person.3" : "checkmark.circle",
                                    description: Text(chatFilter == 2 ? "Groups you join will appear here." : "You're all caught up."))
                                    .padding(.top, (storiesOptedOut ? 0 : storiesRowHeight) + 24)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)   // one row: avatar · Chats · compose
            // Search now lives in its own tab (the detached search circle), so the old
            // in-list search FAB + inline search bar were removed.
            .toolbar { homeToolbar }
            // Hide the header icons whenever a chat is on the stack (incl. the swipe-back
            // drag); reveal them only when we're fully back at the root list.
            .onChange(of: path.count) { showHeaderIcons = path.isEmpty }
            .sheet(isPresented: $showCompose) {   // premium Add-Story picker (bottom sheet) → editor
                AddStorySheet { Task { await StoriesRepository.shared.load(force: true) } }
            }
            .fullScreenCover(item: $viewerGroup) { g in
                // Match the row: don't let swiping land on a HIDDEN person's story (M1).
                let others = StoriesRepository.shared.others.filter { !StoryPrefs.isHidden($0.authorUid) }
                let close: () -> Void = {
                    // Snappier zoom-back into the ring (user: the default felt sluggish): the
                    // cover dismissal follows the transaction's animation.
                    var t = Transaction(animation: .spring(response: 0.28, dampingFraction: 0.92))
                    withTransaction(t) { viewerGroup = nil }
                    // Defer the reload so the hero shrink animation lands BEFORE the row re-sorts (the
                    // just-seen bucket moves, which would otherwise make the zoom shrink toward a moving card).
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        Task { await StoriesRepository.shared.load(force: true) }   // refresh seen rings
                    }
                }
                // A friend's story opens the whole ordered list (swipe person to person);
                // My Story (not in `others`) opens on its own.
                Group {
                    if let idx = others.firstIndex(where: { $0.id == g.id }) {
                        StoryViewer(groups: others, startIndex: idx, anonymous: viewerAnonymous, onClose: close,
                                    onProfile: { grp in profileGroup = grp })
                    } else {
                        StoryViewer(group: g, anonymous: viewerAnonymous, onClose: close,
                                    onProfile: { grp in profileGroup = grp },
                                    onDeletedRemaining: { fresh in
                                        // A story was deleted but I still have others — re-feed the viewer the
                                        // remaining bucket instead of closing (animations off = instant swap,
                                        // no slide-down/up bounce to the chat list).
                                        var t = Transaction(); t.disablesAnimations = true
                                        withTransaction(t) { viewerGroup = nil }
                                        DispatchQueue.main.async { withTransaction(t) { viewerGroup = fresh } }
                                    })
                    }
                }
                // APPLE-NATIVE open + close (user's final call): the zoom transition provides the
                // ring→story hero AND its own interactive drag-to-dismiss — the shrink-over-chats
                // close from the user's reference. Its historical fast-flick "explosions" were the
                // CUBE folding while the system moved the pages (getAngle reads global minX): that
                // fold is now gated to real horizontal page swipes only, and the library's custom
                // dismiss pan is REMOVED (dismissEnabled: false) so exactly ONE close gesture
                // exists — Apple's. Do not reintroduce a custom dismiss pan alongside this.
                // Zoom from WHEREVER the story was opened: a top stories-row card or a chat-row
                // ring — viewerSourceID is set at every open site (falls back to the card).
                .navigationTransition(.zoom(sourceID: viewerSourceID.isEmpty ? (g.isMine ? g.id : "story-\(g.id)") : viewerSourceID, in: storyNS))
            }
            // Live viewer for the still-uploading story. When the upload finishes, the handoff swaps
            // to the real story viewer IN-PLACE inside this same cover — dismissing and re-presenting
            // (the old flow) flashed the chat list between the two covers.
            .fullScreenCover(isPresented: $showUploadViewer) {
                UploadingStoryHandoff(
                    meName: profile.me?.name ?? "You", mePhoto: profile.me?.photoUrl,
                    onClose: {
                        showUploadViewer = false
                        Task { await StoriesRepository.shared.load(force: true) }   // refresh seen rings
                    },
                    onProfile: { grp in profileGroup = grp })
                // Same native zoom close as every other story (user: uploading story used the custom
                // scroll-down pan — use Apple's zoom dismiss instead). Heroes from the uploading card.
                .navigationTransition(.zoom(sourceID: "my-story", in: storyNS))
            }
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
            .navigationDestination(for: ChatTarget.self) { t in
                ThreadView(cid: t.id, title: t.name, photoUrl: t.photo)
                    .id(t.id)
            }
            .sheet(isPresented: $showNew) {
                NewChatView { t in
                    // Push behind the sheet, then dismiss — no flash back to the list.
                    path.append(t)
                    showNew = false
                }
            }
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
            .confirmationDialog("Mute \(pendingMute?.displayName(me) ?? "")",
                                isPresented: Binding(get: { pendingMute != nil },
                                                     set: { if !$0 { pendingMute = nil } }),
                                titleVisibility: .visible) {
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
            .toolbar(selecting ? .hidden : .automatic, for: .tabBar)
            .sheet(isPresented: $showArchived) { ArchivedChatsView() }
            .sheet(isPresented: $showMyQR) { MyQRView() }
            .sheet(item: Binding(
                get: { Flags.groupsEnabled ? router.pendingInviteCode.map { InviteCodeItem(code: $0) } : nil },
                set: { router.pendingInviteCode = $0?.code }
            )) { item in
                JoinGroupSheet(code: item.code).presentationDetents([.large])
            }
            .confirmationDialog("Delete \(selection.count) chat\(selection.count == 1 ? "" : "s")?",
                                isPresented: $showDeleteSelected, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { deleteSelected() }
                Button("Cancel", role: .cancel) {}
            }
        }
        .onAppear { repo.start(); openPendingChat() }
        .onChange(of: router.pendingChatId) { _, _ in openPendingChat() }
        .onChange(of: repo.conversations.count) { _, _ in openPendingChat() }   // retry once chats load
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
        showArchived = false
        showNew = false
        showCompose = false
        viewerGroup = nil
        showUploadViewer = false
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
    private var repo = ConversationsRepository.shared
    private var storiesRepo = StoriesRepository.shared   // archived (hidden) stories appear at the top
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var search = ""
    @State private var path = NavigationPath()
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var showDeleteSelected = false
    @State private var viewerGroup: StoryGroup?   // tap an archived story card → view it
    @State private var prefsTick = 0              // re-render after Unhide

    private var me: String { AuthService.shared.uid ?? "" }
    private var dark: Bool { scheme == .dark }
    private var archivedStories: [StoryGroup] {
        _ = prefsTick
        return storiesRepo.others.filter { StoryPrefs.isHidden($0.authorUid) }
    }
    private var storyCardW: CGFloat { (UIScreen.main.bounds.width - 24 - 30) / 4 }

    // Horizontal cards of hidden people; tap to view, long-press to Unhide.
    private var archivedStoriesRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(archivedStories) { g in
                    Button { viewerGroup = g } label: {
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
                    .contextMenu {
                        Button { StoryPrefs.toggleHidden(g.authorUid); prefsTick += 1 } label: {
                            Label("Unhide Story", systemImage: "tray.and.arrow.up")
                        }
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
    }

    private var hasAnyArchived: Bool {
        repo.conversations.contains { $0.isArchived(me) && !$0.isCleared(me) && (Flags.groupsEnabled || !$0.isGroup) }
    }
    private var archived: [Conversation] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return repo.conversations
            .filter { $0.isArchived(me) && !$0.isCleared(me) }
            .filter { Flags.groupsEnabled || !$0.isGroup }
            .filter { q.isEmpty || $0.displayName(me).lowercased().contains(q) }
            .sorted { $0.displayUpdatedAt(me) > $1.displayUpdatedAt(me) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !hasAnyArchived && archivedStories.isEmpty {
                    EmptyStateView(title: "Nothing archived", icon: "archivebox",
                                   text: "Chats you archive and stories you hide will show here.")
                } else {
                    List(selection: $selection) {   // stable binding (Set selects only in edit mode) -> smooth edit transition
                        if !archivedStories.isEmpty {
                            archivedStoriesRow
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                                .selectionDisabled()
                        }
                        ForEach(archived) { conv in
                            Button {
                                if selecting {   // whole row toggles in edit mode, not just the checkbox
                                    withAnimation(.smooth(duration: 0.2)) {
                                        if selection.contains(conv.id) { selection.remove(conv.id) }
                                        else { selection.insert(conv.id) }
                                    }
                                    return
                                }
                                path.append(ChatTarget(id: conv.id, name: conv.displayName(me),
                                                       photo: conv.displayPhoto(me)))
                            } label: {
                                ChatRow(conv: conv, me: me, dark: dark,
                                        draft: Drafts.shared.text(conv.id),
                                        voiceUnplayed: PlayedVoice.shared.lastVoiceUnplayed(conv, me: me))
                            }
                            .buttonStyle(.plain)
                            .tag(conv.id)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            // Native swipe platter (grey) — no white listRowBackground override
                            // that painted over the row content on swipe.
                            .swipeActions(edge: .trailing) {
                                Button { Task { await ChatService.setArchived(conv.id, false) } } label: {
                                    Label("Unarchive", systemImage: "tray.and.arrow.up")
                                }.tint(.indigo)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .environment(\.editMode, .constant(selecting ? .active : .inactive))
                    .overlay { if archived.isEmpty && !search.isEmpty { ContentUnavailableView.search(text: search) } }
                }
            }
            .navigationTitle("Archived")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search archived")
            .navigationDestination(for: ChatTarget.self) { t in
                ThreadView(cid: t.id, title: t.name, photoUrl: t.photo).id(t.id)
            }
            .fullScreenCover(item: $viewerGroup) { g in
                StoryViewer(group: g, ownSwipeDismiss: true,   // no zoom hero on this cover -> library pan closes
                            onClose: { viewerGroup = nil }, onProfile: { _ in viewerGroup = nil })
            }
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
                        Button("Read All") { markReadSelected() }.tint(.primary).disabled(selection.isEmpty)
                        Spacer()
                        Button(role: .destructive) { showDeleteSelected = true } label: { Image(systemName: "trash") }
                            .disabled(selection.isEmpty)
                    }
                } else {
                    if hasAnyArchived {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Select") { withAnimation(.smooth(duration: 0.35)) { selecting = true } }.tint(.primary)
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
                }
            }
            .confirmationDialog("Delete \(selection.count) chat\(selection.count == 1 ? "" : "s")?",
                                isPresented: $showDeleteSelected, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { deleteSelected() }
                Button("Cancel", role: .cancel) {}
            }
        }
        .onAppear { repo.start() }
    }

    private func exitSelect() { withAnimation(.smooth(duration: 0.35)) { selecting = false; selection = [] } }
    private func unarchiveSelected() {
        let ids = selection
        Task { for id in ids { await ChatService.setArchived(id, false) } }
        exitSelect()
    }
    private func markReadSelected() {
        // Same blocked exclusion as the main list's version (audit) — the archived list can hold
        // silently blocked chats too, and markRead there leaks read receipts just the same.
        let me = AuthService.shared.uid ?? ""
        let ids = selection.filter { id in
            !(ConversationsRepository.shared.conversations.first { $0.id == id }?.isBlockedByMe(me) ?? false)
        }
        Task { for id in ids { await ChatService.resetUnread(id); await ChatService.markRead(id) } }
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


// Registers the ringed avatar as a zoom-transition anchor when a namespace is provided —
// the story viewer grows out of, and closes back into, this exact circle. The namespace is
// constant for the view's lifetime, so the branch never changes identity.
private struct RowStoryAnchor: ViewModifier {
    let ns: Namespace.ID?
    let id: String
    func body(content: Content) -> some View {
        if let ns {
            content.matchedTransitionSource(id: id, in: ns)
        } else {
            content
        }
    }
}

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
    var storyNS: Namespace.ID? = nil      // zoom namespace: the ringed avatar anchors the story open/close
    var draft: String = ""          // unsent composer text (local-only) → "Draft:" preview
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
            && l.draft == r.draft && l.voiceUnplayed == r.voiceUnplayed
    }

    private var decodedLast: String {
        #if DEBUG
        if DemoMode.active { return conv.lastMessageCipher }   // demo previews are stored plaintext
        #endif
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
        case "GIF":                  return ("sparkles", "GIF")
        case "📞 Missed call":         return ("phone.down.fill", "Missed call")
        case "📞 Call":                return ("phone.fill", "Call")
        case "📞 Declined call":       return ("phone.down.fill", "Declined call")
        case "📹 Missed video call":   return ("video.slash.fill", "Missed video call")
        case "📹 Video call":          return ("video.fill", "Video call")
        case "📹 Declined video call": return ("video.slash.fill", "Declined video call")
        default: return nil
        }
    }
    private func previewRow(_ icon: String, _ text: String, iconTint: Color? = nil) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(iconTint ?? Color.secondary)
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
            AvatarView(name: conv.displayName(me), photoUrl: conv.displayPhoto(me),
                       size: storySeen.isEmpty ? 56 : 49)
                // This circle is the story's zoom anchor: opening from here grows the viewer out
                // of THIS ring, and closing shrinks back into it (the standard behavior).
                // Anchored on the PHOTO ONLY — with the ring inside the anchor, the hero
                // stretched the grey ring segments during the zoom (user glitch screenshot).
                .modifier(RowStoryAnchor(ns: storyNS, id: "row-\(conv.id)"))
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
// Signal's model (verified in their source: `CLVTableDataSource.tableView(_:contextMenuConfigurationForRowAt:point:)`
// → `ChatListViewController.createPreviewController` → a real `ConversationViewController` with
// `previewSetup()`) is to show the ACTUAL conversation view with only its chrome suppressed — real
// image thumbnails, real voice notes, real call cells — and to set NO explicit size, letting UIKit size
// the platter from the view controller (so it lands at the screen's own proportions).
//
// So: real `MessageBubble`s (the same view the chat renders), the chat's real wallpaper behind them,
// bottom-aligned like a real conversation, at the screen's aspect. The one place we must diverge from
// Signal is the frame: a SwiftUI preview auto-sizes to intrinsic content and would collapse, so the
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

    // Screen-proportional, like the platter Signal gets for free from a full view controller.
    private var size: CGSize {
        let screen = UIScreen.main.bounds.size
        return CGSize(width: screen.width, height: screen.height * 0.62)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ChatWallpaperBackground(cid: cid)
            if !loaded {
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
            guard !loaded else { return }
            // Newest-first fetch → ascending for display.
            let fetched = await ChatService.galleryContent(cid, limit: 14)
            msgs = Array(fetched.reversed()).filter { !$0.isSystem }
            loaded = true
        }
    }
}
