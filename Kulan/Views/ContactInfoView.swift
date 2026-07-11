import SwiftUI
import FirebaseAuth
import FirebaseFirestore

// Telegram-style profile screen: hero avatar, quick-action tiles, bio card, and a
// shared-media card. Real where the data exists (name/@handle, mute, block, clear,
// shared media, bio); honest "coming soon" for features not built yet (calls live
// on a separate branch; in-chat search isn't built). No fabricated data — the title
// is the @handle (Kulan has no phone numbers).
// Where this profile was opened from — the action row + a call-log card adapt to it.
// From a chat: you're already chatting, so offer Search (not Message). From the Calls
// tab: offer Message (jump into the chat) + show the recent call with this person.
enum ProfileSource { case chat, calls }

struct ContactInfoView: View {
    let cid: String
    let name: String
    let photoUrl: String?
    var source: ProfileSource = .chat
    var isSelf: Bool = false   // your OWN profile (opened from your own story) → no call-yourself buttons
    var onSearch: () -> Void = {}   // "search" tile → pop back to the chat and open in-chat search

    @State private var handle = ""
    @State private var about = ""
    @State private var muted = false
    @State private var mutedUntil: Double = 0   // millis; drives the "Muted until <time>" menu header
    @State private var blocked = false
    @State private var loaded = false
    @State private var media: [Message] = []
    @State private var viewerImage: Message?
    @State private var showClear = false
    @State private var showBlock = false
    @State private var showReport = false
    @State private var showShare = false
    @State private var showCallSoon = false
    @State private var showSearchSoon = false
    @State private var showVideoSoon = false
    @State private var openChat = false
    @State private var showAllMedia = false
    @State private var showVerify = false
    @State private var showDisappear = false
    @State private var disappearSeconds = 0
    @State private var showRename = false
    @State private var showSounds = false
    @State private var localName: String?       // local custom name (Edit) — device-only, never sent
    @State private var showAddGroup = false
    @State private var openGroup: Conversation?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    // The name shown here reflects a local rename (Edit) if one exists, else the passed-in name. Read
    // the observable store DIRECTLY (not the async-loaded @State), so the nickname shows immediately —
    // no 2s flash of the old name on open.
    private var shownName: String { ContactNames.shared.name(for: otherUid) ?? name }

    private var dark: Bool { scheme == .dark }
    // Native grouped-list card color: WHITE in light, 0x1C1C1E in dark — the exact
    // fill iOS Settings uses for its rows. It sits on `pageBackground` (grey/black) so
    // the cards pop, instead of the old flat grey-on-white look.
    private var cardColor: Color { Color(uiColor: .secondarySystemGroupedBackground) }
    // The grouped-list page behind the cards (light grey / true black), like Settings.
    private var pageBackground: Color { Color(uiColor: .systemGroupedBackground) }
    private var otherUid: String {
        let me = AuthService.shared.uid ?? ""
        return cid.split(separator: "_").map(String.init).first { $0 != me } ?? ""
    }

    // Split into layers so the type-checker doesn't time out on one giant modifier chain.
    var body: some View { withAlerts }

    @ViewBuilder private var sections: some View {
        hero
        quickActions
        if source == .calls, lastCall != nil { callLogCard }
        if !isSelf { settingsCard }
        if !media.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("All Media")
                mediaCard
            }
        }
        if !isSelf {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader(groupsHeaderText)
                groupsInCommonCard
            }
        }
    }

    // Bold grouped-list section title above a card (Signal/Apple style).
    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
    }
    private var groupsHeaderText: String {
        let n = sharedGroups.count
        return n == 0 ? "No Groups in Common" : "\(n) Group\(n == 1 ? "" : "s") in Common"
    }

    // Nav bar trailing: just Edit (rename). The "…" More menu is a quick-action tile (below).
    @ToolbarContentBuilder private var navTrailing: some ToolbarContent {
        if !isSelf {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { showRename = true }.tint(.primary)
            }
        }
    }

    // The "More" tile's menu: video · voice · mute · search · MORE.
    @ViewBuilder private var moreMenuItems: some View {
        Button { changeWallpaper() } label: { Label("Change Wallpaper", systemImage: "paintpalette") }
        Button { showShare = true } label: { Label("Share Contact", systemImage: "square.and.arrow.up") }
        Button { showClear = true } label: { Label("Clear My Messages", systemImage: "trash") }
        Divider()
        Button(role: .destructive) { showReport = true } label: { Label("Report \(shownName)", systemImage: "exclamationmark.triangle") }
        if blocked {
            Button { Task { await ChatService.setBlocked(cid, false); blocked = false } } label: { Label("Unblock \(shownName)", systemImage: "checkmark.circle") }
        } else {
            Button(role: .destructive) { showBlock = true } label: { Label("Block \(shownName)", systemImage: "nosign") }
        }
    }

    private var coreScroll: some View {
        ScrollView {
            VStack(spacing: 16) { sections }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
        }
        .background(pageBackground.ignoresSafeArea())   // grouped-list page (grey/black) so white cards pop, like Settings
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .navigationBarBackButtonHidden(false)
        .toolbar { navTrailing }
        .task {
            await load()
            disappearSeconds = ConversationsRepository.shared.conversations.first(where: { $0.id == cid })?.disappearSeconds ?? 0
            localName = ContactNames.shared.name(for: otherUid)
        }
    }

    // Sheets, full-screen covers and pushes.
    private var withSheets: some View {
        coreScroll
            .fullScreenCover(item: $viewerImage) { msg in ImageViewerView(message: msg, cid: cid) }
            .navigationDestination(isPresented: $showAllMedia) {
                MediaGalleryView(cid: cid, title: shownName, photoUrl: photoUrl)
            }
            // "Go to Chat" from the gallery: drop the gallery with animations DISABLED, in the same runloop
            // ThreadView drops this profile, so the whole branch collapses instantly to the conversation —
            // the profile is never rendered (SwiftUI's boolean nav can't animate a multi-level pop cleanly).
            .onReceive(NotificationCenter.default.publisher(for: .goToMessage)) { _ in
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { showAllMedia = false }
            }
            .navigationDestination(item: $openGroup) { g in
                let me = AuthService.shared.uid ?? ""
                ThreadView(cid: g.id, title: g.displayName(me), photoUrl: g.displayPhoto(me))
            }
            .navigationDestination(isPresented: $openChat) {
                ThreadView(cid: cid, title: name, photoUrl: photoUrl)
            }
            .navigationDestination(isPresented: $showVerify) {
                VerifyEncryptionView(cid: cid, peerName: name, peerUid: otherUid, peerPhotoUrl: photoUrl)
            }
            .navigationDestination(isPresented: $showSounds) { SoundsNotificationsView(cid: cid) }
            .sheet(isPresented: $showRename) {
                SetNicknameView(current: localName ?? "") { newName in
                    ContactNames.shared.set(newName, for: otherUid)
                    localName = ContactNames.shared.name(for: otherUid)
                }
            }
            .sheet(isPresented: $showDisappear) {
                DisappearingMessagesView(cid: cid, current: disappearSeconds) { s in
                    disappearSeconds = s
                    Task { await ChatService.setDisappear(cid, seconds: s) }
                }
            }
            .sheet(isPresented: $showShare) { SendContactSheet(contactText: shareText) }
            .sheet(isPresented: $showAddGroup) {
                AddToGroupView(contactUid: otherUid, contactName: shownName, contactPhoto: photoUrl)
            }
    }

    // Menus, dialogs and the rename alert.
    private var withAlerts: some View {
        withSheets
            .alert("Clear your messages?", isPresented: $showClear) {
                Button("Cancel", role: .cancel) {}
                Button("Clear", role: .destructive) {
                    Task { await ChatService.clearMyMessages(cid); media = await ChatService.sharedMedia(cid) }
                }
            } message: {
                Text("This deletes the messages you sent in this chat. It can't be undone.")
            }
            .alert("Block \(name)?", isPresented: $showBlock) {
                Button("Cancel", role: .cancel) {}
                Button("Block", role: .destructive) {
                    Task { await ChatService.setBlocked(cid, true); blocked = true }
                }
            } message: {
                Text("You won't be able to send messages in this chat until you unblock. \(name) won't be told they were blocked.")
            }
            .alert("Report \(name)?", isPresented: $showReport) {
                Button("Cancel", role: .cancel) {}
                Button("Report", role: .destructive) {
                    Task { await ChatService.report(reportedUid: otherUid, cid: cid, reason: "user") }
                }
                Button("Report and Block", role: .destructive) {
                    Task {
                        await ChatService.report(reportedUid: otherUid, cid: cid, reason: "user")
                        await ChatService.setBlocked(cid, true); blocked = true
                    }
                }
            } message: {
                Text("Our team will review this account within 24 hours. \(name) won't be told.")
            }
            .alert("Voice calls", isPresented: $showCallSoon) { Button("OK", role: .cancel) {} } message: { Text("Voice calling is coming soon.") }
            .alert("Search", isPresented: $showSearchSoon) { Button("OK", role: .cancel) {} } message: { Text("In-chat search is coming soon.") }
            .alert("Video calls", isPresented: $showVideoSoon) { Button("OK", role: .cancel) {} } message: { Text("Video calling is coming soon.") }
    }

    // Profile settings rows (Telegram order): Disappearing Messages, Sounds & Notifications,
    // Verify Encryption. Wallpaper / Share / Clear / Report / Block now live in the "…" menu.
    private var settingsCard: some View {
        VStack(spacing: 0) {
            infoRow("Disappearing Messages", "timer", value: disappearLabel) { showDisappear = true }
            rowDivider
            infoRow("Sounds & Notifications", "bell.badge", value: muted ? "Muted" : "On") { showSounds = true }
            rowDivider
            infoRow("Verify Encryption", "lock.fill", tint: .accentColor) { showVerify = true }
        }
        .background(cardColor, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    // Groups this contact and I both belong to. "N Groups in Common" + Add-to-a-Group + the list;
    // "No Groups in Common" + Add-to-a-Group only (no list) when there are none.
    private var sharedGroups: [Conversation] {
        let me = AuthService.shared.uid ?? ""
        return ConversationsRepository.shared.conversations
            .filter { $0.isGroup && $0.users.contains(otherUid) && $0.users.contains(me) && !$0.isCleared(me) }
            .sorted { $0.displayName(me).lowercased() < $1.displayName(me).lowercased() }
    }

    private var groupsInCommonCard: some View {
        let me = AuthService.shared.uid ?? ""
        let groups = sharedGroups
        return VStack(alignment: .leading, spacing: 0) {
            // Bigger "+" in a grey circle (matches the group-avatar rows below), not a tiny glyph.
            Button { showAddGroup = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .medium)).foregroundStyle(.white)
                        .frame(width: 36, height: 36)   // Signal's contact-row avatar size (.thirtySix)
                        .background(Circle().fill(Color(.systemGray4)))   // lighter grey (was systemGray3, too dark)
                    Text("Add to a Group").foregroundStyle(.primary)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            ForEach(groups) { g in
                rowDivider
                Button { openGroup = g } label: {
                    HStack(spacing: 12) {
                        AvatarView(name: g.displayName(me), photoUrl: g.displayPhoto(me), size: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(g.displayName(me)).foregroundStyle(.primary)
                            Text(g.memberCountLabel).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(cardColor, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func setMuted(_ until: Double) {
        muted = true; mutedUntil = until
        Task { await ChatService.setMute(cid, until: until) }
    }
    // "Muted until 1:12 PM" (today) / "Muted until 9 Jul, 1:12 PM" (later) / "Muted always" (Signal).
    private var muteUntilLabel: String {
        let secs = mutedUntil / 1000
        if secs > Date().addingTimeInterval(3600 * 24 * 365 * 5).timeIntervalSince1970 { return "Muted always" }
        let date = Date(timeIntervalSince1970: secs)
        let t = Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
        return "Muted until \(t)"
    }

    // "Change Wallpaper" (from the "…" menu): pop back to the chat, then open the wallpaper picker.
    private func changeWallpaper() {
        let target = cid
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NotificationCenter.default.post(name: .openChatWallpaper, object: target)
        }
    }

    // One tappable row: icon, title, optional trailing value, chevron. `tint` colors icon+title.
    private func infoRow(_ title: String, _ icon: String, value: String? = nil,
                         tint: Color = .primary, chevron: Bool = true,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 17)).frame(width: 26)
                    .foregroundStyle(tint)
                Text(title).foregroundStyle(tint)
                Spacer()
                if let value { Text(value).foregroundStyle(.secondary) }
                if chevron {
                    Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var rowDivider: some View { Divider().padding(.leading, 56) }

    // Compact in the row (8h / 10m / 1w); the picker inside shows the full text.
    private var disappearLabel: String {
        disappearSeconds == 0 ? "Off" : ChatService.disappearShortLabel(disappearSeconds)
    }
    // MARK: - Sections

    private var hero: some View {
        VStack(spacing: 6) {
            AvatarView(name: shownName, photoUrl: photoUrl, size: 88)
            Text(shownName).font(.title.weight(.bold))
            // Always reserve the @handle line (a space when it hasn't loaded yet) so the
            // async profile fetch fills it in WITHOUT pushing the action tiles down — that
            // height change was the up/down "jump" when opening a profile from Calls (cold
            // data) vs from a chat (warm). Reserving the row makes both equally smooth.
            Text(handle.isEmpty ? " " : "@\(handle)")
                .font(.subheadline).foregroundStyle(.secondary)
                .frame(minHeight: 20)
            // Bio shown as centered text under the handle (like a group's description under the member
            // count) — not a labeled "bio" card.
            if !about.isEmpty {
                Text(about)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32).padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    // Context-aware row. From Calls: Message (open the chat) leads. From a chat: Search
    // trails (you're already here). Video is an honest "coming soon"; Voice always calls.
    private var quickActions: some View {
        HStack(spacing: 12) {
            if source == .calls {
                actionTile("message", "message.fill") { openChat = true }
            }
            // Your OWN profile: no call-yourself buttons, and NO message-self yet (opening a self-chat crashed —
            // that's the upcoming "My Space" feature, built separately). Friends keep video/voice.
            if !isSelf {
                actionTile("video", "video.fill") { CallService.shared.startCall(to: otherUid, name: name, photo: photoUrl, video: true) }
                actionTile("voice", "phone.fill") { CallService.shared.startCall(to: otherUid, name: name, photo: photoUrl) }
            }
            // Native menu (pops up) instead of a custom action sheet. Signal: when ALREADY muted, the menu
            // is just "Muted until <time>" + Unmute — the durations only appear when the chat is unmuted.
            Menu {
                if muted {
                    Section(muteUntilLabel) {
                        Button("Unmute") { muted = false; mutedUntil = 0; Task { await ChatService.setMute(cid, until: 0) } }
                    }
                } else {
                    Section("Mute this chat for…") {
                        Button("1 hour") { setMuted(ChatService.muteUntil(1)) }
                        Button("8 hours") { setMuted(ChatService.muteUntil(8)) }
                        Button("1 day") { setMuted(ChatService.muteUntil(24)) }
                        Button("1 week") { setMuted(ChatService.muteUntil(168)) }
                        Button("Always") { setMuted(ChatService.muteUntil(nil)) }
                    }
                }
            } label: {
                tileLabel(muted ? "unmute" : "mute", muted ? "bell.fill" : "bell.slash.fill")
            }
            .tint(.primary)
            if source == .chat {
                actionTile("search", "magnifyingglass") { onSearch() }
            }
            // "More" tile (…): the menu that used to sit in the nav bar.
            if !isSelf {
                Menu { moreMenuItems } label: { tileLabel("more", "ellipsis") }.tint(.primary)
            }
        }
    }


    // Shareable contact link (opens/starts a chat with this user in Kulan).
    private var shareText: String {
        handle.isEmpty ? "Chat with \(name) on Kulan"
                       : "Chat with \(name) on Kulan: kulan://u/\(handle)"
    }

    // The most recent real call with this person (nil if none) — drives the call-log card.
    private var lastCall: CallEntry? {
        CallsRepository.shared.calls.filter { $0.cid == cid }.max { $0.date < $1.date }
    }

    private var callLogCard: some View {
        Group {
            if let call = lastCall {
                VStack(alignment: .leading, spacing: 8) {
                    Text(call.date.formatted(.dateTime.month(.abbreviated).day().year()))
                        .font(.subheadline).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Image(systemName: call.mine ? "phone.arrow.up.right" : "phone.arrow.down.left")
                            .foregroundStyle(call.missed ? .red : .secondary)
                        Text(call.missed ? "Missed voice call"
                                         : (call.mine ? "Outgoing voice call" : "Incoming voice call"))
                        Spacer()
                        Text(call.date.formatted(date: .omitted, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(cardColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private func actionTile(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { tileLabel(title, icon) }.tint(.primary)
    }

    private func tileLabel(_ title: String, _ icon: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(cardColor, in: Capsule())   // pill tile, icon only
            Text(title).font(.caption).foregroundStyle(.primary)   // label below the tile
        }
    }


    private var mediaCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(media.prefix(12)) { m in
                        if let url = m.imageUrl {
                            SecureImageView(imageUrl: url, enc: m.enc, cid: cid)
                                .frame(width: 84, height: 84)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .onTapGesture { viewerImage = m }   // tap a THUMBNAIL → just that image
                        }
                    }
                }
            }
            HStack {
                Text("See All").font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(cardColor, in: RoundedRectangle(cornerRadius: 24, style: .continuous))   // iOS 26 corners
        // Tap anywhere on the CARD (See All row / background) → the full media page. The thumbnails'
        // own tap wins over this for their area, so a photo tap opens just that photo.
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onTapGesture { showAllMedia = true }
    }

    // MARK: - Logic


    private func load() async {
        if let p = await ProfileStore.shared.fetch(otherUid) { handle = p.handle; about = p.about }
        if let snap = try? await Firestore.firestore().collection("conversations").document(cid).getDocument(),
           let d = snap.data() {
            let me = AuthService.shared.uid ?? ""
            let muteUntil = ((d["mutedBy"] as? [String: Any])?[me] as? NSNumber)?.doubleValue ?? 0
            muted = muteUntil > Date().timeIntervalSince1970 * 1000
            mutedUntil = muteUntil
            blocked = (d["blockedBy"] as? [String: Any])?[me] as? Bool ?? false
        }
        media = await ChatService.sharedMedia(cid)
        loaded = true
    }
}

// Full shared-media gallery (reached via "See All").
struct SharedMediaGridView: View {
    let cid: String
    let media: [Message]
    @Environment(\.dismiss) private var dismiss
    @State private var viewer: Message?
    private let cols = [GridItem(.flexible(), spacing: 3),
                        GridItem(.flexible(), spacing: 3),
                        GridItem(.flexible(), spacing: 3)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: cols, spacing: 3) {
                    ForEach(media) { m in
                        if let url = m.imageUrl {
                            SecureImageView(imageUrl: url, enc: m.enc, cid: cid)
                                .frame(height: 116)
                                .frame(maxWidth: .infinity)
                                .clipped()
                                .onTapGesture { viewer = m }
                        }
                    }
                }
                .padding(2)
            }
            .navigationTitle("Shared Media")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .fullScreenCover(item: $viewer) { ImageViewerView(message: $0, cid: cid) }
        }
    }
}
