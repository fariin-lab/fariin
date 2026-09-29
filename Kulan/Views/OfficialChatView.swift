import SwiftUI
import UIKit

// THE OFFICIAL CHAT, as the person reading it sees it.
//
// A separate screen from ThreadView on purpose. ThreadView is 400KB of composer, attach panel, calls,
// typing, reactions, replies, selection and media pipeline, and every one of those is meaningless
// here — this chat cannot be typed in. Threading an `isOfficial` flag through all of it would put a
// dead branch in the most-touched file in the project. What IS shared is everything that decides how
// it LOOKS: the same message list, the same wallpaper, the same bubble colour, the same corner
// geometry, the same header shape. It should be indistinguishable from a normal chat except for the
// two things that are deliberately different: the tick, and the bar where the composer would be.
struct OfficialChatView: View {
    private var store = OfficialChannelStore.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL

    @State private var isAtBottom = true
    @State private var scrollTarget: String?
    @State private var zoomedImage: String?
    @State private var pendingLink: URL?
    @State private var pushedScreen: AnnouncementButton.Screen?
    @State private var shareInvite = false
    @State private var barHeight: CGFloat = 0
    @State private var showInfo = false
    // Long press and selection, the same as a normal chat (owner, 2026-09-28).
    @State private var selecting = false
    @State private var wasSelecting = false
    @State private var selectedIds = Set<String>()
    @State private var forwarding: [Message]?
    @State private var morePickerId: String?
    @State private var reactorsFor: String?   // my chip tapped → the reactions list
    @State private var pendingDelete: [String]?
    @State private var showClearConfirm = false
    // Search in the chat itself, the normal chat's way (owner, 2026-09-28): top field, ↑/↓ and
    // "n of N" at the bottom, each step scrolls to the match.
    @State private var searching = false
    @State private var searchQuery = ""
    @State private var searchMatches: [String] = []   // announcement ids, oldest → newest
    @State private var searchIndex = 0
    @FocusState private var searchFocused: Bool

    private var dark: Bool { scheme == .dark }

    /// The window's home-indicator band (the bottom safe area).
    private static var homeBand: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow?.safeAreaInsets.bottom ?? 0
    }

    /// ⚠️ SPLIT FROM `body` ON PURPOSE: one chain holding the list, both bars, search, the sheets
    /// and the alerts was more than the type-checker would finish ("unable to type-check this
    /// expression in reasonable time", 2026-09-28, when search joined it).
    private var chatSurface: some View {
        list
            // ⛔ UNDER BOTH BARS, LIKE A CHAT — owner, 2026-09-28, three circles: a gap over the bar,
            // a hard edge where the bubbles stopped at the header, no blur. The list stopped at both
            // bars AND took the bar's height as extra inset, so the space was counted twice and the
            // header had nothing under it to blur. `ThreadView.scrollStack` is the model.
            .ignoresSafeArea(.container, edges: [.top, .bottom])
            // 2026-09-24 decision D-admin-loading: a spinner until the channel's listeners have all
            // answered, then the chat list's own empty line. Both used to be the same blank screen.
            .overlay {
                if !store.hasLoaded {
                    ProgressView()
                } else if store.visible.isEmpty {
                    Text("No messages yet").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .background {
                ChatWallpaperBackground(cid: OfficialChannel.cid)
                    .overlay { WallpaperAnchor(cid: OfficialChannel.cid) }   // the slices' reference — see WallpaperBlur
                    .ignoresSafeArea()
            }
            .floatingBottomBar { bottomBar }
            // Search owns the top while it is open, as in a normal chat (`ThreadView.searchBar`).
            .safeAreaInset(edge: .top) { if searching { searchBar } }
            .toolbar(searching ? .hidden : .automatic, for: .navigationBar)
            .onChange(of: searchQuery) { updateSearchMatches() }
            .onChange(of: store.visible.map(\.id)) { if searching { updateSearchMatches() } }
    }

    /// ⛔ FROM THE BAR'S TOP TO THE SCREEN'S BOTTOM, not the bar's own height — owner, 2026-09-28:
    /// "official messages go under the bottom bar". The list runs to the screen's edge and counts
    /// its clearance from there (`bottomClearance`, the no-composer path), so the home-indicator
    /// band under the bar was missing from it and the newest bubble ended that far under the glass.
    /// ⚠️ The gap under the bar is capped at the home-indicator band: with the search keyboard up it
    /// would include the keyboard, which the list already adds on its own.
    /// ⛔ 2026-09-29: measured from each bar's GLASS, not its container. The list adds the composer's
    /// own `barTopPad` above whatever is reported (`MessageListController.bottomClearance`), so the
    /// report is what the composer's container would be: the visible bar's top to the screen's
    /// bottom. The container's top also carried the chrome's padding, which is the extra space he
    /// circled. Reported with `onChange(of:initial:)` (a preference from inside the `safeAreaBar`
    /// never arrived, build 793).
    private var bottomBar: some View {
        Group {
            if selecting { selectionBar } else if searching { searchNavBar } else { cannotReplyBar }
        }
    }

    private func barGlassReporter() -> some View {
        GeometryReader { g in
            let under = UIScreen.main.bounds.height - g.frame(in: .global).maxY
            // ⛔ LESS THE HOME-INDICATOR BAND — build 796, his screenshot: still ~58pt of empty space
            // over the bar where ~14 belongs. The list's clearance is `keyboardOverlap + this + pad`,
            // and at rest `keyboardOverlap` IS the band (`restSafeBottom`), so a report that also
            // ran down to the screen's edge counted the band twice. The report is the glass's top
            // measured from the band's top. (`under` capped just past the band: with the search
            // keyboard up it would hold the keyboard, which `keyboardOverlap` already is.)
            let h = max(0, g.size.height + min(under, Self.homeBand + 10) - Self.homeBand)
            Color.clear.onChange(of: h, initial: true) { _, v in barHeight = v }
        }
    }

    var body: some View {
        chatSurface
            // Tapping the header opens the info screen, the same as every other chat. It used to do
            // nothing at all — I left the closure empty when this screen was built, so the one chat
            // people are most likely to be suspicious of was the one that would not tell them
            // anything about itself. Owner caught it.
            .background(ChatNavigationItem(model: headerModel, bar: navigationBar,
                                           onTap: { if !selecting { showInfo = true } }))
            .sheet(item: Binding(get: { forwarding.map(ForwardBatch.init) },
                                 set: { if $0 == nil { forwarding = nil } })) { batch in
                ForwardPicker(messages: batch.messages, sourceCid: OfficialChannel.cid,
                              onSent: { endSelection() })
            }
            .sheet(item: Binding(get: { morePickerId.map(ZoomTarget.init) },
                                 set: { morePickerId = $0?.url })) { target in
                EmojiMorePicker { store.react(target.url, $0) }
            }
            // The chat's own reactions list for my chip, "Tap to remove" included.
            .sheet(item: Binding(get: { reactorsFor.map(ZoomTarget.init) },
                                 set: { reactorsFor = $0?.url })) { target in
                let me = AuthService.shared.uid ?? ""
                ReactorsSheet(reactions: store.state.reactions[target.url].map { [me: $0] } ?? [:],
                              nameFor: { _ in
                                  let mine = ProfileStore.shared.me?.name.trimmingCharacters(in: .whitespaces) ?? ""
                                  return mine.isEmpty ? "You" : mine
                              },
                              photoFor: { _ in ProfileStore.shared.me?.photoUrl },
                              me: me,
                              onRemoveMine: { store.react(target.url, nil) })
            }
            .alert(deleteTitle, isPresented: Binding(get: { pendingDelete != nil },
                                                    set: { if !$0 { pendingDelete = nil } })) {
                Button("Delete for Me", role: .destructive) {
                    store.hide(pendingDelete ?? []); pendingDelete = nil; endSelection()
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            }
            .alert("Clear this chat?", isPresented: $showClearConfirm) {
                Button("Clear", role: .destructive) { store.clearHistory(); endSelection() }
                Button("Cancel", role: .cancel) {}
            }
            .navigationDestination(isPresented: $showInfo) {
                // Search pops back to the chat and opens its search there, as a normal chat's
                // profile does (`ContactInfoView.onSearch`), a beat later so the pop has finished.
                OfficialChatInfoView {
                    showInfo = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { startSearch() }
                }
            }
            .toolbar(.hidden, for: .tabBar)
            // Belt and braces under the custom header: UIKit shows the plain string title only
            // while titleView is nil, so any residual gap reads "Fariin" instead of nothing, and
            // the avatar+name header replaces it the instant it installs.
            .navigationTitle(OfficialChannel.name)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $pushedScreen) { screen in
                switch screen {
                case .appearance:    AppearanceSettingsView()
                case .chats:         ChatsSettingsView()
                case .stories:       StorySettingsView()
                case .privacy:       PrivacySettingsView()
                case .storage:       StorageDataView()
                case .notifications: NotificationsSettingsView()
                case .invite:        EmptyView()   // handled by the share sheet, never pushed
                case .devices:       DevicesView()
                }
            }
            .fullScreenCover(item: Binding(get: { zoomedImage.map(ZoomTarget.init) },
                                           set: { zoomedImage = $0?.url })) { target in
                AnnouncementImageViewer(url: target.url)
            }
            .sheet(isPresented: $shareInvite) { InviteShareSheet() }
            .alert("Open this link?", isPresented: Binding(get: { pendingLink != nil },
                                                          set: { if !$0 { pendingLink = nil } })) {
                // WebLink, not openURL: a link in the official channel opens in a sheet over the
                // app like any other, instead of handing the reader to Safari and losing the chat.
                Button("Open") { if let pendingLink { WebLink.open(pendingLink) }; pendingLink = nil }
                Button("Cancel", role: .cancel) { pendingLink = nil }
            } message: {
                Text(pendingLink?.absoluteString ?? "")
            }
            // The Block and Clear alerts that used to live here went with the "..." menu that was
            // their only trigger. They still exist in OfficialChatInfoView, including the ⚠️ note
            // about why they are alerts and not `confirmationDialog`s — on iOS 26 that renders as an
            // anchored popover and DROPS the cancel button.
            .onAppear {
                AppRouter.shared.activeChatId = OfficialChannel.cid
                store.markRead()
                NotificationCleaner.clear(cid: OfficialChannel.cid)
            }
            .onDisappear {
                if AppRouter.shared.activeChatId == OfficialChannel.cid { AppRouter.shared.activeChatId = nil }
            }
            // A new announcement landing while the chat is open is read the moment it is on screen —
            // but only if the reader is actually at the bottom looking at it.
            .onChange(of: store.visible.count) { if isAtBottom { store.markRead() } }
    }

    // MARK: The list

    private var list: some View {
        NativeMessageList(
            rowIds: store.visible.map(\.id),
            rowSignatures: Dictionary(uniqueKeysWithValues: store.visible.map { ($0.id, signature($0)) }),
            row: { id in
                guard let a = store.visible.first(where: { $0.id == id }) else { return AnyView(EmptyView()) }
                return AnyView(AnnouncementRow(
                    announcement: a,
                    dark: dark,
                    onImageTap: { url in if selecting { toggle(a.id) } else { zoomedImage = url } },
                    onButtonTap: { tap($0) },
                    countsAsRead: true,
                    // This channel is a full-screen chat on the same list as any other, so its
                    // bubbles take the real slice. See `wallpaperBlur` on the row.
                    wallpaperBlur: WallpaperBlur.state(for: OfficialChannel.cid, dark: dark,
                                                       frame: WallpaperBlur.windowFrame),
                    myReaction: store.state.reactions[a.id],
                    menuId: a.id,
                    onReactionTap: { reactorsFor = a.id },
                    onForward: selecting ? nil : { forwarding = [forwardable(a)] },
                    searchTerm: searching ? searchQuery.trimmingCharacters(in: .whitespaces) : ""
                )
                .padding(.horizontal, 16)
                .modifier(SelectableRow(selecting: selecting, wasSelecting: wasSelecting,
                                        selected: selectedIds.contains(a.id),
                                        tint: Color(hex: 0x0A84FF),
                                        onWallpaper: WallpaperStore.shared.hasWallpaper(for: OfficialChannel.cid),
                                        onToggle: { toggle(a.id) })))
            },
            onToggleSelect: { toggle($0) },
            // Double tap reacts with the chat's quick reaction, and again takes it off (owner,
            // 2026-09-28). Not on a picture: a picture opens on one tap (his 2026-07-29 rule).
            onUikitDoubleTap: { id in
                let quick = QuickReaction.current
                store.react(id, ThreadView.sameEmoji(store.state.reactions[id], quick) ? nil : quick)
            },
            hostedDoubleTap: { id in
                store.visible.first(where: { $0.id == id }).map { $0.mediaUrl == nil } ?? false
            },
            customMenuActions: { id in menuActions(id) },
            customReactConfig: { id in
                guard !selecting, store.visible.contains(where: { $0.id == id }) else { return nil }
                return (QuickReaction.bar, store.state.reactions[id])
            },
            onCustomReact: { id, choice in
                switch choice {
                case .more: morePickerId = id
                case .emoji(let e): store.react(id, e)
                }
            },
            // Nothing to page: the channel holds the most recent hundred announcements and that is the
            // whole history there is. The reference app trims the same way.
            onReachedTop: {},
            selecting: selecting,
            wasSelecting: wasSelecting,
            loadingOlder: false,
            composerBarHeight: barHeight,
            isAtBottom: $isAtBottom,
            scrollTarget: $scrollTarget,
            dayLabelFor: { id in store.visible.first(where: { $0.id == id }).map { dayLabel($0.sortAt) } }
        )
    }

    /// Changes that must redraw a row. Edited announcements are the reason this exists — an admin
    /// fixing a typo has to reach a phone that already has the old words on screen.
    private func signature(_ a: Announcement) -> String {
        // `hasAppStoreUrl`: the Update Link arriving shows the hidden "Update Now" (D-admin-update).
        "\(a.title.count)|\(a.body.count)|\(store.state.reactions[a.id] ?? "")|\(selecting)|\(wasSelecting)|\(selectedIds.contains(a.id))|\(a.mediaUrl ?? "")|\(a.buttons.count)|\(a.editedAt?.timeIntervalSince1970 ?? 0)|\(OfficialConfig.shared.hasAppStoreUrl)|\(searching ? searchQuery : "")"
    }

    private static let cal = Calendar.current
    private func dayLabel(_ d: Date) -> String {
        if Self.cal.isDateInToday(d) { return "Today" }
        if Self.cal.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    // MARK: Long press and selection

    /// ⛔ THE SAME MENU AS A CHAT MESSAGE — owner, 2026-09-28: "long press does not work, make it a
    /// normal bubble like chats". Copy, Forward, Select and Delete (for me), with the reaction bar
    /// above. There is no Reply or Edit: nobody can write in this chat. Delete only hides it from
    /// this person; the announcement is the same shared document for everybody.
    private func menuActions(_ id: String) -> [CMAction] {
        guard !selecting, let a = store.visible.first(where: { $0.id == id }) else { return [] }
        return [
            CMAction(title: "Copy", icon: "doc.on.doc") { UIPasteboard.general.string = plainText(a) },
            CMAction(title: "Forward", icon: "arrowshape.turn.up.right") { forwarding = [forwardable(a)] },
            CMAction(title: "Select", icon: "checkmark.circle") { startSelection(with: id) },
            CMAction(title: "Delete", icon: "trash", destructive: true) { pendingDelete = [id] },
        ]
    }

    /// The words as they read in the bubble: the title on its own line, then the body.
    private func plainText(_ a: Announcement) -> String {
        [a.title, a.body].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// An announcement forwards as its text, like a forwarded chat message.
    private func forwardable(_ a: Announcement) -> Message {
        var m = Message(localText: plainText(a), authorId: OfficialChannel.cid, clientId: a.id,
                        replyTo: nil, sendState: .sending)
        m.sendState = nil   // a finished message, not one of ours in flight
        return m
    }

    private var navigationBar: ChatNavigationItem.Bar {
        if selecting {
            return .selection(deleteAll: { showClearConfirm = true }, deleteEnabled: true,
                              cancel: { endSelection() })
        }
        return .custom([bellButton])
    }

    private var liveSelection: [Announcement] { store.visible.filter { selectedIds.contains($0.id) } }

    private var deleteTitle: String {
        let n = pendingDelete?.count ?? 0
        return n == 1 ? "Delete this message?" : "Delete \(n) messages?"
    }

    /// The chat's own selection bar: Delete, "N Selected", Forward.
    private var selectionBar: some View {
        SelectionToolbar(count: liveSelection.count,
                         deleteEnabled: !liveSelection.isEmpty,
                         forwardEnabled: !liveSelection.isEmpty,
                         onDelete: { pendingDelete = liveSelection.map(\.id) },
                         onForward: { forwarding = liveSelection.map(forwardable) })
            .frame(height: 44)
            .background { barGlassReporter() }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
    }

    private func startSelection(with id: String) {
        wasSelecting = false
        selecting = true
        selectedIds = [id]
    }

    private func toggle(_ id: String) {
        guard selecting else { return }
        if selectedIds.contains(id) { selectedIds.remove(id) } else { selectedIds.insert(id) }
    }

    /// The two-pass exit the chat uses: the circles slide out, then the lane goes.
    private func endSelection() {
        guard selecting else { return }
        wasSelecting = true
        selecting = false
        selectedIds = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { wasSelecting = false }
    }

    // MARK: Header

    /// The official channel in the UIKit header: its bundled mark for the avatar, its tick in the
    /// reference app's title-icon slot, its tagline as the subtitle.
    private var headerModel: ChatHeaderModel {
        var m = ChatHeaderModel(name: OfficialChannel.name, photoUrl: nil)
        m.avatarAsset = UIImage(named: "welcome-mark")
        m.subtitle = OfficialChannel.subtitle
        m.titleIcon = ChatHeaderModel.officialTick()
        m.backdrop = WallpaperBlur.headerBackdrop(for: OfficialChannel.cid, dark: dark)
        return m
    }

    /// Not named `toolbar`: `.toolbar { toolbar }` reads a property with the same name as the
    /// modifier it is being handed to, which is exactly the kind of thing the type-checker resolves
    /// differently on a bad day.
    /// The bell IS the state, the way the reference app's screenshot shows it: a struck-through bell
    /// means this chat is quiet. It starts struck through for everybody and stays that way unless
    /// somebody deliberately turns it on. A UIKit bar item now, set on the navigationItem by
    /// `ChatNavigationItem` like everything else in the header.
    ///
    /// NO "..." MENU. It held Mute, Clear Chat and Block — all three of which are in Chat Info, one
    /// tap away on the header, with the sentences that explain what each one actually does. Three
    /// doors to three actions on a chat you cannot even reply to is clutter. The bell stays because
    /// it is not a duplicate: it is the mute STATE, readable without opening anything (owner,
    /// 2026-08-05).
    private var bellButton: ChatNavigationItem.BarButton {
        ChatNavigationItem.BarButton(
            id: "bell",
            image: store.state.isMutedNow ? "ic_bell_off" : "ic_bell",
            accessibilityLabel: store.state.isMutedNow ? "Notifications off" : "Notifications on",
            action: { store.setMuted(!store.state.isMutedNow) })
    }

    // MARK: The bar where the composer would be

    /// The reference app replaces the composer with a blocking panel reading a line to the effect of
    /// "this is the only official chat"; another mainstream messenger's equivalent panel says only it can send messages here. Ours says the same thing
    /// in our own words. It is NOT a disabled text field — a greyed-out box invites tapping, and the
    /// point is that there is nothing to tap.
    private var cannotReplyBar: some View {
        // GLASS, IN THE COMPOSER'S SHAPE, matching every other bar that stands in for the composer
        // (see `ThreadView.composerNotice`). It was a full-width system strip with a hard Divider
        // ruled across the top, which is the bordered slab the owner circled: the one piece of this
        // screen that did not look like the rest of the app.
        // The chat's own notice text (`ThreadView.removedBar`), so the two bars read the same.
        Text(OfficialChannel.cannotReply)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .liquidGlass(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .background { barGlassReporter() }
            // ⛔ THE INPUT BAR'S OWN INSETS — owner, 2026-08-25. This bar stands where the composer
            // stands, so it is edge-attached SYSTEM CHROME and takes the device's margins and the
            // indicator-band dip, not the 12/6 that used to be written here. See `SystemBarChrome`.
            .systemBarChrome()
    }

    // MARK: Search

    private func startSearch() {
        searchQuery = ""; searchMatches = []; searchIndex = 0
        searching = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { searchFocused = true }
    }

    private func closeSearch() {
        searchFocused = false
        searching = false
        searchQuery = ""; searchMatches = []
    }

    /// The normal chat's rules (`ThreadView.updateSearchMatches`): two characters and up, every
    /// word a prefix of some word in the announcement, case and accents ignored; the position is
    /// kept counted from the newest end as the query is refined.
    private func updateSearchMatches() {
        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        let terms = q.count >= 2 ? ChatSearch.queryTerms(q) : []
        guard !terms.isEmpty else { searchMatches = []; return }
        let fromNewest = searchMatches.isEmpty ? 0 : max(0, searchMatches.count - 1 - searchIndex)
        searchMatches = store.visible
            .filter { ChatSearch.matches(tokens: ChatSearch.tokens($0.title + " " + $0.body), terms: terms) }
            .sorted { $0.sortAt < $1.sortAt }
            .map(\.id)
        guard !searchMatches.isEmpty else { return }
        searchIndex = max(0, searchMatches.count - 1 - min(fromNewest, searchMatches.count - 1))
        scrollTarget = searchMatches[searchIndex]
    }

    private func stepSearch(_ delta: Int) {
        guard !searchMatches.isEmpty else { return }
        searchIndex = min(max(0, searchIndex + delta), searchMatches.count - 1)
        scrollTarget = searchMatches[searchIndex]
    }

    /// The normal chat's search field and close button (`ThreadView.searchBar`).
    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundStyle(.secondary)
                TextField("Search", text: $searchQuery)
                    .font(.system(size: 17))
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .onSubmit {
                        searchFocused = false
                        if !searchMatches.isEmpty { stepSearch(1) }
                    }
                    .autocorrectionDisabled()
                if !searchQuery.isEmpty {
                    Button { searchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(.secondary)
                            .frame(width: 32, height: 32).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
                }
            }
            .padding(.horizontal, 12).frame(height: 44)
            .liquidGlass(Capsule(), interactive: false)
            Button { closeSearch() } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(.primary)
                    .frame(width: 44, height: 44).liquidGlass(Circle(), interactive: true)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close search")
        }
        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 8)
    }

    /// The normal chat's ↑/↓ and "n of N" (`ThreadView.searchNavBar`).
    private var searchNavBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 24) {
                Button { stepSearch(-1) } label: { Image(systemName: "chevron.up").font(.system(size: 16, weight: .semibold)) }
                    .disabled(searchIndex <= 0 || searchMatches.isEmpty)
                Button { stepSearch(1) } label: { Image(systemName: "chevron.down").font(.system(size: 16, weight: .semibold)) }
                    .disabled(searchIndex >= searchMatches.count - 1 || searchMatches.isEmpty)
            }
            .tint(.primary)
            .padding(.horizontal, 18).frame(height: 44)
            .liquidGlass(Capsule(), interactive: true)
            Spacer()
            if !searchMatches.isEmpty || searchQuery.trimmingCharacters(in: .whitespaces).count >= 2 {
                Text(searchMatches.isEmpty ? "No results" : "\(searchIndex + 1) of \(searchMatches.count)")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.horizontal, 18).frame(height: 44)
                    .liquidGlass(Capsule(), interactive: false)
            }
        }
        .frame(height: 44)
        .background { barGlassReporter() }
        .padding(.horizontal, 16).padding(.bottom, 6)
    }

    // MARK: Buttons

    private func tap(_ button: AnnouncementButton) {
        switch button.action {
        case .link:
            // Same confirm a link inside a normal message gets. An official chat is exactly where
            // somebody stops reading addresses, so it does not get to skip the step.
            if let url = URL(string: button.value) { pendingLink = url }
        case .appStore:
            if let url = URL(string: OfficialConfig.shared.appStoreUrl) { openURL(url) }
        case .screen:
            guard let screen = AnnouncementButton.Screen(rawValue: button.value) else { return }
            if screen == .invite { shareInvite = true } else { pushedScreen = screen }
        }
    }
}

private struct ForwardBatch: Identifiable {
    let messages: [Message]
    var id: String { messages.map(\.id).joined(separator: ",") }
}

private struct ZoomTarget: Identifiable {
    let url: String
    var id: String { url }
    init(_ url: String) { self.url = url }
}

// MARK: - Chat info

/// What you get when you tap the header, the same as tapping any other chat's header.
///
/// The one screen a suspicious person opens. So it is written for THEM: it says what this chat is,
/// what it will never do, and gives the way out. Everything else on it is the ordinary per-chat
/// state, in the ordinary places.
/// ⛔ THE OFFICIAL CHAT'S PROFILE, FROM HIS PICTURE — owner, 2026-09-28: a large profile card
/// (photo, name, tick, "Official Chat"), round Mute and Search buttons under it, then cards: About,
/// All Media, Help Center, and Clear Chat / Block in red with the block note under them. The words
/// in About are the ones this screen already carried; only the layout is new.
struct OfficialChatInfoView: View {
    /// Search: the chat closes this page and searches in place (owner, 2026-09-28: "search is not
    /// working like a normal chat"). It used to push a separate results list.
    private let onSearch: () -> Void
    private var store = OfficialChannelStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmBlock = false
    @State private var confirmClear = false
    @State private var showAllMedia = false
    @State private var zoomed: String?

    init(onSearch: @escaping () -> Void = {}) { self.onSearch = onSearch }

    /// The announcements that carry a picture, newest first.
    private var media: [Announcement] { Array(store.visible.filter { $0.mediaUrl != nil }.reversed()) }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                profileCard
                actionButtons
                aboutCard
                if !media.isEmpty { mediaCard }
                helpCard
                dangerCard
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showAllMedia) {
            OfficialMediaGrid(items: media) { zoomed = $0 }
        }
        .fullScreenCover(item: Binding(get: { zoomed.map(ZoomTarget.init) },
                                       set: { zoomed = $0?.url })) { target in
            AnnouncementImageViewer(url: target.url)
        }
        .alert("Clear this chat?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { store.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes these messages from this phone. New updates will still arrive.")
        }
        .alert("Block this chat?", isPresented: $confirmBlock) {
            Button("Block", role: .destructive) { store.setBlocked(true); dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will stop getting updates from Fariin. Security alerts about your own account still come through. Nothing is lost and you can unblock it later.")
        }
    }

    // MARK: Profile card

    private var profileCard: some View {
        VStack(spacing: 10) {
            OfficialAvatar(size: 112)
            HStack(spacing: 6) {
                Text(OfficialChannel.name).font(.system(size: 26, weight: .bold))
                VerifiedTick(size: 22)
            }
            Text(OfficialChannel.subtitle).font(.body).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }

    // MARK: Mute and Search

    /// ⛔ THE CHAT PROFILE'S OWN CIRCLES — owner, 2026-09-28: "make it exactly how it looks in a
    /// normal chat, and how it works". `ContactInfoView.actionsRow`: 60pt glass `PosterActionIcon`s
    /// with no captions, the bell showing what a tap does, Mute behind a menu.
    ///
    /// ⚠️ EACH CIRCLE IN A FIFTH OF THE ROW, the slot it has in a normal profile's five-circle row
    /// (owner, 2026-09-28: "the space between Mute and Search is too big"). `PosterActionIcon`
    /// stretches to fill its slot, so two of them split the whole width and sat half a screen apart.
    private var actionButtons: some View {
        HStack(spacing: 0) {
            // ⛔ THE CHAT'S OWN MUTE MENU — owner, 2026-09-29: "when I tap Mute show 1 hour, 8 hours,
            // 1 day, 1 week, Always". The same items and wording as `ContactInfoView.muteMenuItems`;
            // muted, it says until when and offers Unmute.
            Menu {
                if store.state.isMutedNow {
                    Section(muteUntilLabel) {
                        Button("Unmute") { store.setMuted(false) }
                    }
                } else {
                    Section("Mute this chat for…") {
                        Button("1 hour")  { store.setMuted(true, until: ChatService.muteUntil(1)) }
                        Button("8 hours") { store.setMuted(true, until: ChatService.muteUntil(8)) }
                        Button("1 day")   { store.setMuted(true, until: ChatService.muteUntil(24)) }
                        Button("1 week")  { store.setMuted(true, until: ChatService.muteUntil(168)) }
                        Button("Always")  { store.setMuted(true) }
                    }
                }
            } label: {
                PosterActionIcon(icon: store.state.isMutedNow ? "ic_bell" : "ic_bell_off", onPhoto: false)
                    .frame(width: actionSlot)
            }.tint(.primary)
            Button { onSearch() } label: {
                PosterActionIcon(icon: "magnifyingglass", onPhoto: false)
                    .frame(width: actionSlot)
            }.tint(.primary)
        }
        .frame(maxWidth: .infinity)
    }

    /// "Muted always" / "Muted until 3:40 PM", the chat profile's wording.
    private var muteUntilLabel: String {
        let end = store.state.mutedUntilMillis
        guard end > 0 else { return "Muted always" }
        let date = Date(timeIntervalSince1970: end / 1000)
        let t = Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
        return "Muted until \(t)"
    }

    /// One slot of a five-circle row across this page's width (16pt margins each side).
    private var actionSlot: CGFloat { (UIScreen.main.bounds.width - 32) / 5 }

    // MARK: Cards

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground)))
    }

    private var aboutCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Label("About", systemImage: "text.alignleft").font(.body)
                // ⛔ ONE SHORT TEXT, ONE STYLE — owner, 2026-09-28, circled the card: "this text is 3
                // types, clear all and write only one simple short text". The three paragraphs
                // (regular, medium, secondary with a tick) are gone.
                // Owner, 2026-09-29: these two lines, word for word.
                Text("The only official chat from Fariin\nKeep up to date with news & release notes")
            }
            .padding(18)
        }
    }

    private var mediaCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Button { showAllMedia = true } label: {
                    HStack {
                        Text("All Media").font(.title3.weight(.semibold)).foregroundStyle(.primary)
                        Spacer()
                        Text("See All").foregroundStyle(.primary)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(media.prefix(12))) { a in
                            MediaTile(url: a.mediaUrl ?? "", side: 84) { zoomed = a.mediaUrl }
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    /// The same Help Center Settings opens.
    private var helpCard: some View {
        card {
            Button {
                if let u = URL(string: "https://fariin.com/help") { WebLink.open(u) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "questionmark.circle").font(.system(size: 20))
                    Text("Help Center")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                }
                .padding(18)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
        }
    }

    private func dangerRow(_ title: String, color: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var dangerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            card {
                VStack(spacing: 0) {
                    dangerRow("Clear Chat", color: .red) { confirmClear = true }
                    Divider().padding(.horizontal, 18)
                    // Unblock when already blocked (audit 2026-09-24): nothing else calls setBlocked(false).
                    if store.state.blocked {
                        dangerRow("Unblock", color: .accentColor) { store.setBlocked(false) }
                    } else {
                        dangerRow("Block", color: .red) { confirmBlock = true }
                    }
                }
            }
            Text("Blocking stops the updates. It does not stop us telling you if something happens to your account.")
                .font(.footnote).foregroundStyle(.secondary)
                .padding(.horizontal, 18)
        }
    }
}

/// One square picture in the media strip and the grid.
private struct MediaTile: View {
    let url: String
    let side: CGFloat
    var onTap: () -> Void
    var body: some View {
        AnnouncementImage(url: url, square: true)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
    }
}

/// See All: every picture the channel has sent, three across.
private struct OfficialMediaGrid: View {
    let items: [Announcement]
    var onTap: (String) -> Void
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)
    var body: some View {
        GeometryReader { g in
            ScrollView {
                LazyVGrid(columns: cols, spacing: 2) {
                    ForEach(items) { a in
                        MediaTile(url: a.mediaUrl ?? "", side: (g.size.width - 4) / 3) {
                            onTap(a.mediaUrl ?? "")
                        }
                    }
                }
            }
        }
        .navigationTitle("All Media")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - The channel's face

/// The app's own icon on a circle. The reference app renders its own release-channel logo asset into the release channel's
/// avatar for the same reason: the one identity nobody else can wear is the app's own.
struct OfficialAvatar: View {
    var size: CGFloat = 48

    var body: some View {
        Group {
            if let ui = UIImage(named: "welcome-mark") {
                Image(uiImage: ui).resizable().scaledToFill()
            } else {
                // The mark is compiled into the app, so this cannot happen in a shipped build. It is
                // here so a missing asset degrades to a letter instead of an empty hole.
                ZStack {
                    Color.accentColor
                    Text("F").font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// The tick. Drawn ONLY here and only ever for the one channel — there is no verified flag on any
/// user document, and there is not meant to be, because a flag is a thing that can be written.
struct VerifiedTick: View {
    var size: CGFloat = 16

    var body: some View {
        Image(systemName: "checkmark.seal.fill")
            .font(.system(size: size * 0.82, weight: .semibold))
            .frame(width: size, height: size)
            .foregroundStyle(.white, Color(hex: 0x0A84FF))
            .accessibilityLabel("Verified official account")
    }
}

// MARK: - One announcement

/// Not private: the chat list's long-press peek renders the channel with these same bubbles, because
/// the generic peek reads `conversations/{cid}/messages` and the official channel has no such
/// collection — it would have shown "No messages yet" over a chat that plainly has messages.
struct AnnouncementRow: View {
    let announcement: Announcement
    let dark: Bool
    var onImageTap: (String) -> Void
    var onButtonTap: (AnnouncementButton) -> Void
    /// True ONLY in the real chat. The previews (the chat list's long-press peek, the admin compose
    /// preview, the admin history detail) draw the same bubble and must not tell the server that
    /// anybody read anything — an admin checking their own draft would otherwise be counted as a
    /// reader of it.
    var countsAsRead: Bool = false
    /// The blurred wallpaper this bubble shows a slice of — see `WallpaperBlur`. Passed ONLY by the
    /// real chat, whose wallpaper fills the window; the previews draw the same wallpaper at a size
    /// and place that is not the window's, and a slice there would show the wrong piece of it, so
    /// they leave this nil and take the material approximation instead.
    var wallpaperBlur: WallpaperBlurState? = nil
    /// 2026-09-24 decision D-admin-preview: the compose preview's picked picture, drawn inside the
    /// bubble exactly where the uploaded one will be (it used to sit above it as a separate shape).
    var localImage: UIImage? = nil
    /// This reader's own reaction, drawn as the chip inside the bubble like a chat message's.
    var myReaction: String? = nil
    /// The real chat only: publishes the bubble's outline so the long press lifts THIS bubble.
    var menuId: String? = nil

    /// My chip was tapped (the real chat only): opens the reactions list, where my row takes it back.
    var onReactionTap: (() -> Void)? = nil
    /// The round forward button beside the post (the real chat only; hidden while selecting).
    var onForward: (() -> Void)? = nil
    /// ⛔ THE CHAT'S SEARCH HIGHLIGHT — owner, 2026-09-29: "search in the official chat is not like a
    /// normal chat". A chat marks every matched term yellow with black text (`BubbleText.body`,
    /// `ChatSearch.highlightRanges`); these posts marked nothing, so a hit looked like no hit.
    var searchTerm: String = ""

    static func highlighted(_ text: String, _ term: String) -> AttributedString {
        var out = AttributedString(text)
        guard term.count >= 2 else { return out }
        for r in ChatSearch.highlightRanges(in: text, query: term) {
            guard let lo = AttributedString.Index(r.lowerBound, within: out),
                  let hi = AttributedString.Index(r.upperBound, within: out) else { continue }
            out[lo..<hi].backgroundColor = .yellow
            out[lo..<hi].foregroundColor = .black
        }
        return out
    }

    /// ⛔ A CHANNEL POST, NOT A CHAT BUBBLE — owner, 2026-09-29, with two reference screenshots:
    /// "the Official Chat should clearly feel like a channel, not a regular private conversation".
    /// Measured off his 924px-wide screenshots (430pt screen, 2.15px/pt):
    ///
    ///   post         699px wide = 0.76 of the screen, 16pt from the left edge, every post the
    ///                same width (a channel's column, not a bubble hugging its words)
    ///   corners      ~20pt, all four
    ///   header       none (2026-09-29, his word: the chat header already names the channel)
    ///   picture      edge to edge under the header, its own shape, never inset
    ///   words        12pt in from the sides; title semibold directly over the body, both 17pt
    ///   time         bottom-right under the words
    ///   buttons      full-width rows under a hairline, label centred
    ///   forward      a 32pt round button 14pt to the right of the post, centred on it
    ///
    /// Its list, scrolling, bottom position, long press and reactions are the chat's own; only the
    /// drawing of a post is the channel's.
    static var postWidth: CGFloat { min(UIScreen.main.bounds.width * 0.76, 380) }
    private static let radius: CGFloat = 20
    private static let side: CGFloat = 12

    /// 2026-09-24 decision D-admin-update: "Update Now" is hidden while the owner has not set the
    /// Update Link. It used to show and do nothing when tapped.
    private var usableButtons: [AnnouncementButton] {
        announcement.buttons.filter { $0.isUsable && ($0.action != .appStore || OfficialConfig.shared.hasAppStoreUrl) }
    }

    private var onWallpaper: Bool { WallpaperStore.shared.hasWallpaper(for: OfficialChannel.cid) }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            post
            if let onForward {
                Button(action: onForward) {
                    Image(systemName: "arrowshape.turn.up.right.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.black.opacity(0.28)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Forward")
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .onAppear { if countsAsRead { AnnouncementStats.countRead(announcement) } }
    }

    private var post: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ⛔ NO NAME ROW — owner, 2026-09-29, build 797: "don't show the Fariin name in the
            // bubble". The header already says who this chat is. A picture now starts at the
            // post's top edge; words without one start 10pt in.
            if let localImage {
                AnnouncementImage(url: "", width: announcement.mediaWidth,
                                  height: announcement.mediaHeight, local: localImage, tallest: 1.25)
            } else if let url = announcement.mediaUrl {
                AnnouncementImage(url: url, width: announcement.mediaWidth,
                                  height: announcement.mediaHeight, tallest: 1.25)
                    .contentShape(Rectangle())
                    .onTapGesture { onImageTap(url) }
            }

            VStack(alignment: .leading, spacing: 0) {
                if !announcement.title.isEmpty {
                    Text(Self.highlighted(announcement.title, searchTerm))
                        .font(.system(size: 17, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Parsed markdown, so the addresses in it are real links. While searching, the plain
                // words with the matches marked instead (the markdown would move them).
                if !announcement.body.isEmpty {
                    Group {
                        if searchTerm.count >= 2 {
                            Text(Self.highlighted(announcement.body, searchTerm))
                        } else {
                            Text(.init(announcement.body))
                        }
                    }
                    .font(.system(size: 17))
                    .tint(Color(hex: 0x0A84FF))
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Self.side)
            .padding(.top, announcement.mediaUrl != nil || localImage != nil ? 8 : 10)

            footer
                .padding(.horizontal, Self.side)
                .padding(.top, 4)
                .padding(.bottom, 10)

            if !usableButtons.isEmpty { buttonStack }
        }
        .frame(maxWidth: Self.postWidth, alignment: .leading)
        // An announcement takes the wallpaper like any incoming message, so it wears the same
        // surface and rim; only its shape and layout are the channel's.
        .background { ReceivedBubbleSurface(dark: dark, onWallpaper: onWallpaper, blur: wallpaperBlur) }
        .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .overlay {
            if onWallpaper {
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                    .strokeBorder(Theme.bubbleRim(dark), lineWidth: Theme.bubbleRimWidth)
                    .allowsHitTesting(false)
            }
        }
        .modifier(OptionalRectReporter(id: menuId, overhang: 0))
    }

    /// ⛔ READ LIVE FROM THE STORE IN THE REAL CHAT — owner, 2026-09-29, build 796: "when I react the
    /// badge appears late". The chip used to wait for the list to notice the row's signature change,
    /// reconfigure the hosted row and re-measure it (the chip made the footer taller). This body
    /// observes the store itself, so the chip draws in the same frame as the tap.
    /// The previews pass `myReaction` and have no store state of their own.
    private var shownReaction: String? {
        menuId != nil ? OfficialChannelStore.shared.state.reactions[announcement.id] : myReaction
    }

    /// My reaction chip (the chat's own look) on the left, "edited" and the time on the right.
    private var footer: some View {
        HStack(spacing: 4) {
            if let myReaction = shownReaction {
                // ⛔ WITH MY FACE, LIKE A CHAT'S CHIP — owner, 2026-09-29: "where's my avatar like
                // normal chat". `ReactionChipView`'s numbers: emoji at the lead 10, a 24pt face at
                // the trailing end 6 from the edge, 6 between.
                HStack(spacing: BubbleMetrics.reactionFaceGap) {
                    Text(myReaction).font(.system(size: BubbleMetrics.reactionEmojiFont))
                    AvatarView(name: ProfileStore.shared.me?.name ?? "You",
                               photoUrl: ProfileStore.shared.me?.photoUrl,
                               size: BubbleMetrics.reactionFace)
                }
                    .padding(.leading, BubbleMetrics.reactionFaceLead)
                    .padding(.trailing, BubbleMetrics.reactionFaceTrail)
                    .frame(height: BubbleMetrics.reactionChipHeight)
                    .background(Capsule().fill(Color(BubblePalette.accent).opacity(0.18)))
                    .contentShape(Capsule())
                    .onTapGesture { onReactionTap?() }
                    // ⛔ THE CHAT'S OWN POP — owner, 2026-09-29: "when I react there's no animation,
                    // add animation like normal chat". `MessageRowView`'s arriving chip: scale from
                    // 0.01 over `reactionDuration` (0.4s) on `reactionCurve`, opacity over 0.2s;
                    // a leaving one shrinks and fades the same way.
                    .transition(.scale(scale: 0.01).combined(with: .opacity))
                    .id(myReaction)   // a changed emoji pops as a new chip, as in a chat
            }
            Spacer(minLength: 0)
            if announcement.editedAt != nil {
                Text("edited").font(Font(BubbleMetrics.metaFont)).foregroundStyle(.secondary)
            }
            Text(announcement.sortAt.formatted(date: .omitted, time: .shortened))
                .font(Font(BubbleMetrics.metaFont))
                .foregroundStyle(.secondary)
        }
        // (No reserved chip height: owner, 2026-09-29, build 797, "the bubble always has an empty
        // area, with or without a reaction". The chip still draws live from the store.)
        .animation(.timingCurve(0.38, 0.7, 0.125, 1.0, duration: 0.4), value: shownReaction)
    }

    private var buttonStack: some View {
        VStack(spacing: 0) {
            ForEach(usableButtons) { button in
                Divider()
                Button { onButtonTap(button) } label: {
                    Text(button.label)
                        .font(.system(size: 17))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(hex: 0x0A84FF))
            }
        }
    }
}

/// The long-press outline, only where there is a menu (the previews have none).
private struct OptionalRectReporter: ViewModifier {
    let id: String?
    let overhang: CGFloat
    @ViewBuilder func body(content: Content) -> some View {
        if let id {
            content.modifier(CMBubbleRectReporter(id: id, radius: 18, bottomOverhang: overhang))
        } else {
            content
        }
    }
}

// MARK: - Media

/// Announcement pictures are PLAIN urls, like GIFs and story photos — see the note in
/// AnnouncementAdmin.uploadMedia for why sealing a worldwide broadcast would be a costume.
private struct AnnouncementImage: View {
    let url: String
    var width: Double?
    var height: Double?
    /// 2026-09-24 decision D-admin-preview: a picked, not-yet-uploaded picture (compose preview).
    var local: UIImage? = nil
    /// The profile's media strip and grid: a square crop instead of the picture's own shape.
    var square = false
    /// The tallest a picture may draw, as height over width (a channel post caps a portrait
    /// picture and crops the rest, 2026-09-29). nil = its own shape, however tall.
    var tallest: CGFloat? = nil

    @State private var image: UIImage?

    /// Pull the bytes down and put them in the cache, so this device only ever fetches once.
    ///
    /// Announcement images are ordinary Storage downloads, not chat media: there is no bubble to
    /// register, no rect to fly from and nothing to decrypt. `store` persists them, so a relaunch
    /// finds them on disk and this never runs again for the same image.
    static func fetch(_ url: String) async -> UIImage? {
        guard let u = URL(string: url),
              let (data, _) = try? await URLSession.shared.data(from: u),
              let img = UIImage(data: data) else { return nil }
        DiskImageCache.shared.store(img, data: data, for: url)
        return img
    }

    /// Reserve the real shape before the bytes land so the bubble does not jump when it loads. The
    /// admin screen records the size at upload, so this is known, not guessed.
    private var ratio: CGFloat {
        if square { return 1 }   // the profile's media tiles
        guard let width, let height, width > 0, height > 0 else { return 4.0 / 3.0 }
        let own = CGFloat(width / height)
        if let tallest { return max(own, 1 / tallest) }
        return own
    }

    var body: some View {
        ZStack {
            if let image = local ?? image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(ratio, contentMode: .fit)
        .clipped()
        .task(id: url) {
            if local != nil { return }   // the compose preview's picked picture, nothing to fetch
            if let cached = DiskImageCache.shared.memoryImage(for: url) { image = cached; return }
            if let onDisk = await DiskImageCache.shared.image(for: url) { image = onDisk; return }
            // ⚠️ NOBODY WAS EVER GOING TO PUT IT IN THE CACHE. This asked memory, then disk, and
            // stopped — but `image(for:)` says in its own comment that nil means "not cached
            // anywhere, caller should then download", and this caller never did. An announcement
            // image is uploaded by the admin console and has never been near this device, so both
            // lookups miss by construction and the bubble draws its grey placeholder for ever.
            // That is his "official chat images never appear", and it was never a permissions or
            // a URL problem: nothing was fetching them.
            image = await Self.fetch(url)
        }
    }
}

private struct AnnouncementImageViewer: View {
    let url: String
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var zoom: CGFloat = 1
    /// The download came back empty. Offline or a dead link used to leave the spinner up for ever.
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if failed {
                Image(systemName: "photo").font(.system(size: 40)).foregroundStyle(.white.opacity(0.5))
            } else if let image {
                Image(uiImage: image)
                    .resizable().scaledToFit()
                    .scaleEffect(zoom)
                    .gesture(MagnifyGesture()
                        .onChanged { zoom = max(1, min(4, $0.magnification)) }
                        .onEnded { _ in withAnimation(.spring(duration: 0.25)) { zoom = max(1, zoom) } })
            } else {
                ProgressView().tint(.white)
            }
        }
        .overlay(alignment: .topLeading) {
            CloseXButton { dismiss() }.padding(.leading, 16).padding(.top, 8)
        }
        .task {
            if let have = await DiskImageCache.shared.image(for: url) { image = have; return }
            image = await AnnouncementImage.fetch(url)   // same miss, same fix - see the note there
            failed = image == nil   // audit 2026-09-24: stop the endless spinner, the X still closes it
        }
    }
}

/// The Invite Friends button opens the same share sheet Settings does, with the same text.
private struct InviteShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    private var profile = ProfileStore.shared

    private var inviteText: String {
        let h = profile.me?.handle ?? ""
        return h.isEmpty ? "Chat with me on Fariin." : "Chat with me on Fariin, my username is @\(h)"
    }

    var body: some View {
        // The header shows the Fariin mark, not the system's text icon (2026-09-25).
        ShareSheet(items: [InviteActivityItem(text: inviteText)])
    }
}

/// UIActivityViewController bridge. SwiftUI's ShareLink is a button, not something a code path can
/// present, and this screen needs to present one from a tap on a message.
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
