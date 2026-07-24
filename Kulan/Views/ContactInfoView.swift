import SwiftUI
import FirebaseAuth
import FirebaseFirestore

// Modern-style profile screen: hero avatar, quick-action tiles, bio card, and a
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
    @State private var targetPrivacy: [String: String] = [:]   // their audience map (users doc)
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
    @State private var showProfilePhoto = false   // tap the hero avatar → in-place photo morph
    @State private var avatarFrame: CGRect = .zero   // hero avatar's global frame — the morph's start/end
    @State private var publicStory: StoryGroup?    // their active "Everyone" story, shown as a ring here
    @State private var showPublicStory = false     // ring tapped → play their public story
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
    var body: some View {
        withAlerts
            // In-place viewer (Telegram model, user request): the photo grows OUT of the avatar
            // circle and closes back INTO it — never a page. An overlay (not a cover) so the
            // profile stays visible behind and the drag can melt the white away.
            .overlay {
                if showProfilePhoto {
                    ProfilePhotoViewer(name: shownName, photoUrl: gatedPhotoUrl ?? "",
                                       sourceFrame: avatarFrame, isPresented: $showProfilePhoto)
                }
            }
    }

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
        if !isSelf && Flags.groupsEnabled {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader(groupsHeaderText)
                groupsInCommonCard
            }
        }
        if !isSelf { dangerCard }
    }

    // Block / Report always VISIBLE at the bottom of the profile (WhatsApp pattern, user
    // decision) — a user who feels unsafe must see the way out, not hunt a "..." menu.
    private var dangerCard: some View {
        VStack(spacing: 0) {
            if blocked {
                infoRow("Unblock \(shownName)", "checkmark.circle", chevron: false) {
                    Task { await ChatService.setBlocked(cid, false); blocked = false }
                }
            } else {
                infoRow("Block \(shownName)", "nosign", tint: .red, chevron: false) { showBlock = true }
            }
            rowDivider
            infoRow("Report \(shownName)", "exclamationmark.triangle", tint: .red, chevron: false) { showReport = true }
        }
        .background(cardColor, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    // Bold grouped-list section title above a card (standard grouped-list style).
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

    // The "More" tile's menu: housekeeping only. Block/Report moved OUT to the always-visible
    // dangerCard at the bottom of the page (WhatsApp pattern, user decision).
    @ViewBuilder private var moreMenuItems: some View {
        Button { changeWallpaper() } label: { Label("Change Wallpaper", systemImage: "paintpalette") }
        Button { showShare = true } label: { Label("Share Contact", systemImage: "square.and.arrow.up") }
        Button { showClear = true } label: { Label("Clear My Messages", systemImage: "trash") }
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
        // Keep the nav bar visible always: toggling it hidden while the photo viewer opens
        // shrank the scroll's top inset, which jumped the whole page UP (user report). The
        // viewer's own full-screen backdrop covers the bar, so no toggle is needed.
        .toolbar(.visible, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .navigationBarBackButtonHidden(false)
        .toolbar { navTrailing }
        .task {
            // Seed from the warm cache FIRST so "All Media" shows instantly (no late pop-in on
            // re-entry); the async load() then refreshes it.
            if media.isEmpty, let cached = ChatService.cachedSharedMedia(cid) { media = cached }
            await load()
            disappearSeconds = ConversationsRepository.shared.conversations.first(where: { $0.id == cid })?.disappearSeconds ?? 0
            localName = ContactNames.shared.name(for: otherUid)
            // Their public ("Everyone") story, if any — surfaces as a ring on the hero avatar so
            // anyone who reaches this profile can watch it, contact or not.
            if !isSelf {
                publicStory = await StoriesRepository.shared.publicStoryGroup(
                    for: otherUid, name: shownName, photoUrl: gatedPhotoUrl)
            }
        }
    }

    // Sheets, full-screen covers and pushes.
    private var withSheets: some View {
        coreScroll
            .fullScreenCover(item: $viewerImage) { msg in ImageViewerView(message: msg, cid: cid) }
            // Their public story, opened from the ring on the hero avatar. anonymous: we don't write a
            // view record (a non-contact may not have write access to the author's story views).
            .fullScreenCover(isPresented: $showPublicStory) {
                if let pg = publicStory {
                    StoryViewer(ownSwipeDismiss: true, groups: [pg], anonymous: true,
                                onClose: { showPublicStory = false })
                        .background(Color.black.ignoresSafeArea())
                }
            }
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
                    .presentationDetents([.medium, .large])   // small sheet by default (user request)
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
    }

    // Profile settings rows (standard order): Disappearing Messages, Sounds & Notifications,
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
                        .font(.system(size: 18, weight: .medium)).foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)   // the standard contact-row avatar size (.thirtySix)
                        .background(Circle().fill(Color(.systemGray5)))   // LIGHT grey (user request; grey4 was too dark)
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
    // "Muted until 1:12 PM" (today) / "Muted until 9 Jul, 1:12 PM" (later) / "Muted always" (standard).
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

    // Their privacy audience, honored by MY client: am I allowed their photo/bio/calls?
    // "Contact" = we share a real conversation (opened from a chat always qualifies).
    private var iAmContact: Bool { source == .chat || PrivacyPrefs.isContact(otherUid) }
    private var gatedPhotoUrl: String? {
        PrivacyPrefs.allows(targetPrivacy, "photo", contactOfMine: iAmContact) ? photoUrl : nil
    }
    private var gatedAbout: String {
        PrivacyPrefs.allows(targetPrivacy, "bio", contactOfMine: iAmContact) ? about : ""
    }
    private var canCallThem: Bool {
        PrivacyPrefs.allows(targetPrivacy, "calls", contactOfMine: iAmContact)
    }

    private var hero: some View {
        VStack(spacing: 6) {
            ZStack {
                // Story ring (Instagram/WhatsApp pattern): a colored gradient ring means this person has
                // an active public story — tap the avatar to watch it instead of opening the photo.
                if publicStory != nil {
                    Circle()
                        .stroke(LinearGradient(colors: [Color.pink, Color.orange, Color.yellow],
                                               startPoint: .topLeading, endPoint: .bottomTrailing),
                                lineWidth: 3)
                        .frame(width: 100, height: 100)
                        .opacity(showProfilePhoto ? 0 : 1)
                }
                AvatarView(name: shownName, photoUrl: gatedPhotoUrl, size: 88)
                    // The viewer IS this avatar while open — hide the original so the morph reads
                    // as one circle leaving and returning, not a copy floating over it.
                    .opacity(showProfilePhoto ? 0 : 1)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { avatarFrame = $0 }
            }
            .contentShape(Circle())
            .onTapGesture {
                if publicStory != nil { showPublicStory = true }
                else if gatedPhotoUrl?.isEmpty == false { showProfilePhoto = true }
            }
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
            if !gatedAbout.isEmpty {
                Text(gatedAbout)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32).padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    // Context-aware row. From Calls: Message (open the chat) leads. From a chat: Search
    // trails (pops back and opens the in-chat search bar). Video and Voice call live.
    private var quickActions: some View {
        HStack(spacing: 12) {
            if source == .calls {
                actionTile("message", "message.fill") { openChat = true }
            }
            // Your OWN profile: no call-yourself buttons, and NO message-self yet (opening a self-chat crashed —
            // that's the upcoming "My Space" feature, built separately). Friends keep video/voice.
            if !isSelf && canCallThem {
                actionTile("video", "video.fill") { CallService.shared.startCall(to: otherUid, name: name, photo: photoUrl, video: true) }
                actionTile("voice", "phone.fill") { CallService.shared.startCall(to: otherUid, name: name, photo: photoUrl) }
            }
            // Native menu (pops up) instead of a custom action sheet. When ALREADY muted, the menu
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
                        // Videos carry thumbUrl/thumbEnc (no imageUrl) — they were invisible here.
                        if let url = m.imageUrl ?? m.thumbUrl {
                            SecureImageView(imageUrl: url, enc: m.imageUrl != nil ? m.enc : m.thumbEnc, cid: cid)
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
        if let p = await ProfileStore.shared.fetch(otherUid) {
            handle = p.handle; about = p.about; targetPrivacy = p.privacy
        }
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

// In-place profile-photo viewer (tap the hero avatar). Telegram model, per the user's request:
// the circle GROWS out of the avatar, stays a circle the whole time, and closes back INTO the
// avatar — never presented as a page/cover. While the finger holds and moves the photo (or
// swipes down), the white theme backdrop melts away with drag distance so the profile shows
// through behind; release far enough closes into the avatar, otherwise it springs back.
// Chat media keeps its own always-black viewer — that's for real photos, this is a portrait.
// Profile photos are plain URLs (not E2EE) served from the same DiskImageCache AvatarView
// fills, so it opens instantly.
private struct ProfilePhotoViewer: View {
    let name: String
    let photoUrl: String
    let sourceFrame: CGRect          // the hero avatar, in global coords — morph start AND end
    @Binding var isPresented: Bool
    @State private var image: UIImage?
    @State private var progress: CGFloat = 0   // 0 = sitting on the avatar, 1 = open in the center
    @State private var drag: CGSize = .zero
    @State private var zoom: CGFloat = 1
    @State private var closing = false

    // Solid page when open and resting; the DRAG is what melts the white (fully, not partially).
    private var backdropOpacity: Double {
        let dist = Double(sqrt(drag.width * drag.width + drag.height * drag.height))
        return Double(progress) * max(0, 1 - dist / 260)
    }

    var body: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            let d = min(geo.size.width - 40, 360)   // open diameter, breathing room at the edges
            // Interpolate the circle between the avatar's frame and the screen center.
            let size = sourceFrame.width + (d - sourceFrame.width) * progress
            let srcX = sourceFrame.midX - origin.x, srcY = sourceFrame.midY - origin.y
            let x = srcX + (geo.size.width / 2 - srcX) * progress + drag.width
            let y = srcY + (geo.size.height / 2 - srcY) * progress + drag.height
            ZStack {
                Color(.systemBackground).opacity(backdropOpacity).ignoresSafeArea()
                    .onTapGesture { close() }
                Group {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Color(.secondarySystemFill)   // placeholder keeps the morph shape while loading
                    }
                }
                .frame(width: size, height: size)
                .clipShape(Circle())   // round from first frame to last — it never becomes a page
                .scaleEffect(zoom)
                .position(x: x, y: y)
                .gesture(
                    MagnificationGesture()
                        .onChanged { if !closing { zoom = max(1, $0) } }
                        .onEnded { _ in withAnimation(.spring(duration: 0.3)) { zoom = 1 } }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { if zoom == 1, !closing, progress == 1 { drag = $0.translation } }
                        .onEnded { v in
                            guard zoom == 1, !closing else { return }
                            let dist = sqrt(v.translation.width * v.translation.width
                                            + v.translation.height * v.translation.height)
                            if dist > 120 { close() }   // far enough → fly home from right here
                            else { withAnimation(.spring(duration: 0.3)) { drag = .zero } }
                        }
                )
            }
            .overlay(alignment: .top) {
                HStack {
                    Button { close() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold)).foregroundStyle(.primary)
                            .frame(width: 38, height: 38)
                            .background(Color.primary.opacity(0.08), in: Circle())
                    }
                    Spacer()
                    Text(name).font(.headline).foregroundStyle(.primary)
                    Spacer()
                    Color.clear.frame(width: 38, height: 38)   // balances the X so the name stays centered
                }
                .padding(.horizontal, 16)
                .opacity(progress == 1 && drag == .zero && !closing ? 1 : 0)   // chrome only at rest
                .animation(.easeOut(duration: 0.15), value: drag == .zero)
            }
        }
        .onAppear { withAnimation(.spring(duration: 0.38, bounce: 0.15)) { progress = 1 } }
        .task {
            if let cached = await DiskImageCache.shared.image(for: photoUrl) { image = cached; return }
            guard let url = URL(string: photoUrl),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let ui = UIImage(data: data) else { return }
            DiskImageCache.shared.store(ui, data: data, for: photoUrl)
            image = ui
        }
    }

    // Close = the reverse morph: progress and drag animate home TOGETHER, so the circle flies
    // from wherever the finger left it straight back into the avatar, shrinking as it goes.
    // The overlay is removed only after the animation lands (the hidden avatar swaps back in).
    private func close() {
        guard !closing else { return }
        closing = true
        withAnimation(.spring(duration: 0.34, bounce: 0.12)) { progress = 0; drag = .zero; zoom = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { isPresented = false }
    }
}
