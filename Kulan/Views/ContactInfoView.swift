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
enum ProfileSource { case chat, calls, story }   // story: no chat underneath → no Search, no Wallpaper

/// Carries the header's scroll position out to the nav bar. A preference rather than a shared
/// observable: it is per-screen state that must die with the screen, and two profiles pushed on top
/// of each other must never read each other's offset.
private struct HeroOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

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
    /// How much media this chat had last time we looked (disk-backed). Decides on the very first
    /// frame whether the All Media section exists at all — see ChatService.SharedMediaPresence.
    @State private var mediaHint = 0
    @State private var viewerImage: Message?
    @State private var viewerVideo: Message?   // videos get the PLAYER — the image viewer spun forever
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
    // NOTES CARD. Both flags are plain @State on a view that is rebuilt on every push, which is
    // exactly the owner's rule: leave to the chat, come back, and the note is collapsed again.
    @State private var noteExpanded = false
    @State private var noteWidth: CGFloat = 0   // real rendered width; drives the More test
    @State private var showAddGroup = false
    @State private var openGroup: Conversation?
    @State private var showProfilePhoto = false   // tap the hero avatar → in-place photo morph
    // A REAL photo is on screen (not the letter fallback). The tap gate used to be "url isn't
    // empty", which is a different thing: a removed or stale url still shows the letter, and
    // tapping it opened an empty grey circle (owner's screenshot).
    @State private var heroHasPhoto = false
    /// Live scroll position of the header, fed by HeroOffsetKey. Drives `collapse`.
    @State private var heroOffset: CGFloat = 0
    @State private var avatarFrame: CGRect = .zero   // hero avatar's global frame — the morph's start/end
    @State private var posterRect: CGRect = .zero    // poster photo's global square — the modern morph's start/end
    @AppStorage(ProfileLayoutStyle.storageKey) private var profileLayout = ProfileLayoutStyle.modern.rawValue
    @State private var publicStory: StoryGroup?    // their active "Everyone" story, shown as a ring here
    @State private var storyViewerGroup: StoryGroup?   // ring tapped → play it (item-driven, like every other story cover)
    @State private var showAvatarChoice = false     // has BOTH a story and a photo → ask which to open
    // Same zoom hero as everywhere else: the viewer grows out of the tapped thumbnail and the
    // drag-down close shrinks back into it.
    @Namespace private var mediaNS
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    // The name shown here reflects a local rename (Edit) if one exists, else the passed-in name. Read
    // the observable store DIRECTLY (not the async-loaded @State), so the nickname shows immediately —
    // no 2s flash of the old name on open.
    /// Every story in their group already watched → the ring goes grey instead of coloured, same rule
    /// as the chat list and the stories row.
    private var storyAllSeen: Bool {
        guard let g = publicStory, !g.stories.isEmpty else { return false }
        return !StoryPrefs.seenFlags(g.stories, upTo: g.lastViewedAt).contains(false)
    }

    /// Re-seed from the repository after the viewer closes: markSeenLocally advanced the group's
    /// watermark there, and reassigning `publicStory` is what re-evaluates the ring.
    private func refreshStorySeen() {
        if let known = StoriesRepository.shared.others.first(where: { $0.authorUid == otherUid }),
           !known.stories.isEmpty {
            publicStory = known
        }
    }

    private var shownName: String { ContactNames.shared.name(for: otherUid) ?? name }

    private var layoutStyle: ProfileLayoutStyle { ProfileLayoutStyle(rawValue: profileLayout) ?? .modern }

    /// A poster needs a picture. Someone with no photo keeps the classic circle and its existing
    /// empty state, rather than a header of flat colour pretending to be a portrait.
    ///
    /// Decided from the URL, which is known on the FIRST frame, and not from whether the bitmap has
    /// arrived — a layout that flips a beat after opening is the page rearranging itself, which this
    /// screen has already been reported for once.
    private var useModernHeader: Bool {
        layoutStyle == .modern && gatedPhotoUrl?.isEmpty == false
    }

    /// Chrome sitting on the photo: white on a dark picture, near-black on a pale one. Reads the
    /// sampling the poster already did, so nothing is measured twice.
    private var toolbarOnPhoto: Color {
        (PosterTone.cached(for: gatedPhotoUrl)?.topPrefersDarkText ?? false) ? Color.black.opacity(0.88) : .white
    }

    /// Bottom of the navigation bar in screen coordinates. From the window, because the page's own
    /// safe-area reading is the scroll view's, not the screen's.
    private var barBottom: CGFloat {
        (UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.top }
            .max() ?? 59) + 44
    }

    /// Is the photo still behind the bar? `.zero` counts as yes: the poster has not reported its
    /// rect on the very first frame, and it always opens with the photo at the top — reading that
    /// as "no" would flash a bar background over the photo for one frame.
    private var photoUnderBar: Bool {
        guard useModernHeader else { return false }
        return posterRect == .zero || posterRect.maxY > barBottom
    }

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
                    // The modern header flies out of the POSTER square and keeps the photo's own
                    // shape when it lands; the classic one keeps the circle it has always grown out
                    // of. Same machinery either way — only the start rect and the final shape differ.
                    ProfilePhotoViewer(name: shownName, photoUrl: gatedPhotoUrl ?? "",
                                       sourceFrame: useModernHeader ? posterRect : avatarFrame,
                                       poster: useModernHeader,
                                       isPresented: $showProfilePhoto)
                        // THE VIEWER OWNS THE WHOLE SCREEN. Without this the overlay is the page's
                        // frame, which stops below the status bar, and the viewer's chrome was being
                        // drawn up into the safe area by ignoring it one layer further in — drawn
                        // outside the frame it belongs to, which is a reliable way to get something
                        // you can see and cannot press. The viewer's own comment already claimed the
                        // container did this; now it actually does.
                        .ignoresSafeArea()
                }
            }
    }

    @ViewBuilder private var sections: some View {
        // The extra .padding(.top, 8) on each block below + the container's 20 = Signal's ~28pt
        // section rhythm (owner's circled side-by-side: ours sat tight and uneven against theirs).
        if useModernHeader {
            // One block, not two: the poster owns the name AND the round actions, because both sit
            // on the wash it draws and neither can be positioned without knowing where the photo
            // ends.
            posterHeader
        } else {
            hero
            quickActions
        }
        if source == .calls, lastCall != nil { callLogCard }
        notesCard.padding(.top, 8)   // between the tiles and the settings card (owner's screenshot)
        if !isSelf { settingsCard.padding(.top, 8) }
        // Reserved on the FIRST frame from the remembered count, so the page never shifts when the
        // real media arrives. No media ever sent → mediaHint is 0 and nothing is drawn, ever.
        // A HEADED section gets Signal's taller run-up: their header inset is
        // `defaultSpacingBetweenSections (20) + 12` above the title, so 12 on top of this
        // container's 20 — where a plain card keeps the 8 used elsewhere on the page.
        if !media.isEmpty || mediaHint > 0 {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("All Media")
                mediaCard
            }
            .padding(.top, 12)
        }
        if !isSelf && Flags.groupsEnabled {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader(groupsHeaderText)
                groupsInCommonCard
            }
            .padding(.top, 12)
        }
        if !isSelf { dangerCard.padding(.top, 8) }
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

    /// Section title above a card, with SIGNAL'S OWN numbers (OWSTableViewController2, fetched and
    /// read — not measured off a screenshot): `defaultHeaderFont` = dynamicTypeHeadlineClamped, i.e.
    /// headline (17pt semibold), in the primary label colour; and a section WITH a card background
    /// gets `cellHInnerMargin * 0.5` = 8pt of extra leading on top of the 16pt page margin, so the
    /// title sits 24pt from the edge — 8pt further in than the card itself. Their gap down to the
    /// card is 10pt, which this page already used.
    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
    }
    private var groupsHeaderText: String {
        let n = sharedGroups.count
        return n == 0 ? "No Groups in Common" : "\(n) Group\(n == 1 ? "" : "s") in Common"
    }

    // Nav bar trailing: just Edit (rename). The "…" More menu is a quick-action tile (below).
    @ToolbarContentBuilder private var navTrailing: some ToolbarContent {
        if !isSelf && !showProfilePhoto {   // no Edit floating over the open photo
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { showRename = true }.tint(.primary)
            }
        }
    }

    // The "More" tile's menu: housekeeping only. Block/Report moved OUT to the always-visible
    // dangerCard at the bottom of the page (WhatsApp pattern, user decision).
    @ViewBuilder private var moreMenuItems: some View {
        // (No "View Profile Photo" here: tapping the avatar now offers the choice directly when the
        // person has both a story and a photo, so a menu duplicate would be clutter.)
        // Wallpaper pops back to the CHAT and posts to its ThreadView — from a story-opened profile
        // there is no chat underneath and the tap silently did nothing (audit).
        if source == .chat {
            Button { changeWallpaper() } label: {
                Label { Text("Change Wallpaper") } icon: { Image("ic_wallpaper").renderingMode(.template)
                        .resizable().scaledToFit().frame(width: 20, height: 20) }
            }
        }
        // "Share Profile", not "Share Contact" — what it sends is a Kulan profile link, and there is no
        // contact card behind it (no phone book, no numbers).
        Button { showShare = true } label: { Label("Share Profile", systemImage: "square.and.arrow.up") }
        Button { showClear = true } label: { Label("Clear My Messages", systemImage: "trash") }
    }

    private var coreScroll: some View {
        ScrollView {
            VStack(spacing: 20) { sections }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
        }
        // Named so the backdrop can read its own offset and stretch on a rubber-band pull.
        .coordinateSpace(name: "profileScroll")
        // NO animation on this. The scroll IS the animation: animating a value that changes every
        // frame makes it chase the finger and lag. It only settles when the rubber band does, which
        // the scroll view already animates for us.
        .onPreferenceChange(HeroOffsetKey.self) { heroOffset = $0 }
        .background(pageBackground.ignoresSafeArea())   // grouped-list page (grey/black) so white cards pop, like Settings
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        // Keep the nav bar visible always: toggling it hidden while the photo viewer opens
        // shrank the scroll's top inset, which jumped the whole page UP (user report). The
        // viewer's own full-screen backdrop covers the bar, so no toggle is needed.
        .toolbar(.visible, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        // Hide the back chevron while the photo viewer is open so it doesn't float over the photo.
        // We hide the ITEMS, never the bar itself — toggling bar visibility changes the scroll
        // inset, which is what used to jump the whole page.
        .navigationBarBackButtonHidden(showProfilePhoto)
        .toolbar { navTrailing }
        // The name RIDES UP into the bar as the header goes. Without it, scrolling past the header
        // left nothing on screen saying whose profile this is: the title is deliberately empty
        // because the name used to live in the hero, and the hero now scrolls away.
        //
        // A small circle beside a name is the shape the CHAT header already uses, so a scrolled
        // profile lands on something the app does everywhere else rather than a new invention.
        .toolbar {
            ToolbarItem(placement: .principal) {
                ZStack {
                    // The story control, in the one strip of the photo nothing else occupies —
                    // between Back and Edit. It hands over to the name as the header leaves, so the
                    // middle of the bar is never empty and never holds two things at once.
                    if useModernHeader, !showProfilePhoto, let g = publicStory, !g.stories.isEmpty {
                        Button { storyViewerGroup = g } label: {
                            StoryStackBadge(group: g, textColor: toolbarOnPhoto)
                        }
                        .buttonStyle(.plain)
                        // Same zoom hero the classic avatar declared, moved to whatever is actually
                        // on screen: the story grows out of these circles and the drag-down rides
                        // back into them. The two never coexist, so the id is never claimed twice.
                        .matchedTransitionSource(id: "profile-story", in: mediaNS)
                        .opacity(1 - collapse)
                        // Dead once it has faded, so a name scrolled into its place can never be
                        // tapped into somebody's story.
                        .allowsHitTesting(collapse < 0.4)
                    }
                    HStack(spacing: 7) {
                        AvatarView(name: shownName, photoUrl: gatedPhotoUrl, size: 26)
                        Text(shownName).font(.headline).lineLimit(1)
                    }
                    .opacity(collapse)
                    // Rises the last few points rather than appearing in place, so it reads as the same
                    // name arriving from below and not a second one fading in.
                    .offset(y: (1 - collapse) * 7)
                    .allowsHitTesting(false)
                }
            }
        }
        // Let the photo run under the bar while it is still there, then hand the bar back its own
        // material the moment the photo's bottom edge passes it.
        //
        // Tied to where the PHOTO is, not to `collapse`: collapse is spent after 96pt of scrolling
        // and the photo is 393pt tall, so anything driven off it would drop a material over a photo
        // that is still on screen. This changes the bar's BACKGROUND, never its visibility —
        // toggling visibility resizes the scroll inset, which is what used to jump the whole page.
        .toolbarBackground(photoUnderBar ? .hidden : .automatic, for: .navigationBar)
        .task {
            // Seed from the warm cache FIRST so "All Media" shows instantly (no late pop-in on
            // re-entry); the async load() then refreshes it.
            // The remembered count first (disk, instant), then the warm cache, then the network.
            mediaHint = ChatService.SharedMediaPresence.count(cid)
            if media.isEmpty, let cached = ChatService.cachedSharedMedia(cid) { media = cached }
            // LOCAL values BEFORE the network round-trips (audit): the timer row said "Off" for
            // seconds on a slow connection — and the picker opened preselected wrong — though the
            // repository already knew the answer.
            disappearSeconds = ConversationsRepository.shared.conversations.first(where: { $0.id == cid })?.disappearSeconds ?? 0
            localName = ContactNames.shared.name(for: otherUid)
            // `load()` owns mediaHint from here: it is the only place that knows whether the count it
            // has is an ANSWER or a failure. Setting it from `media.count` out here zeroed the hint
            // whenever the load failed, which is how the section disappeared from a chat full of photos.
            await load()
            disappearSeconds = ConversationsRepository.shared.conversations.first(where: { $0.id == cid })?.disappearSeconds ?? 0
            // Their public ("Everyone") story, if any — surfaces as a ring on the hero avatar so
            // anyone who reaches this profile can watch it, contact or not.
            // NOT while Stories are turned off (audit): Settings promises "you will no longer be
            // able to share or view stories" and the chat list already draws no rings, but this page
            // still showed one, played the story, and wrote a view receipt to the author.
            if !isSelf, !UserDefaults.standard.bool(forKey: "storiesOptedOut") {
                // SEED SYNCHRONOUSLY from the already-loaded story tray first, so for anyone whose
                // story we know about the ring is there on the FIRST frame instead of blinking in
                // after the network round-trip. The fetch below then covers non-contacts (public
                // stories that were never in our tray).
                if publicStory == nil,
                   let known = StoriesRepository.shared.others.first(where: { $0.authorUid == otherUid }),
                   !known.stories.isEmpty {
                    publicStory = known
                }
                if let fresh = await StoriesRepository.shared.publicStoryGroup(
                    for: otherUid, name: shownName, photoUrl: gatedPhotoUrl) {
                    publicStory = fresh
                }
                // else: keep the tray-seeded group (a contacts-only story is still watchable here)
            }
        }
    }

    // Sheets, full-screen covers and pushes.
    private var withSheets: some View {
        coreScroll
            .fullScreenCover(item: $viewerImage) { msg in
                // No system .zoom: SignalMediaOpen flies the tapped thumb (see the strip's tap),
                // the same pipeline as the conversation and the gallery. The story cover below still
                // uses .zoom - stories deliberately keep the system hero transition.
                ImageViewerView(message: msg, cid: cid, rectScope: .profile)
            }
            // Audit: strip videos were routed into the IMAGE viewer, which guards on imageUrl (nil
            // for videos) and spun forever. Same player + routing the gallery uses.
            .fullScreenCover(item: $viewerVideo) { msg in
                VideoPlayerScreen(message: msg, cid: cid, clipProvider: { nil }, rectScope: .profile)
            }
            // Their story, opened from the ring on the hero avatar. Presented EXACTLY like every other
            // story cover (item-driven, ownSwipeDismiss: true because this cover has no zoom hero, and
            // NO extra background wrapper) — the previous isPresented + nested `if let` + black
            // `.background(...ignoresSafeArea())` version couldn't be closed cleanly: that wrapper sat
            // over the library's swipe-down pan, which is the gesture that dismisses it.
            // anonymous: we don't write a view record (a non-contact may not have write access to the
            // author's story views).
            .fullScreenCover(item: $storyViewerGroup) { g in
                // ownSwipeDismiss:FALSE + the native zoom transition = the identical close to a story
                // opened from the chat list: drag down, hold it part way, release and it springs back
                // into the avatar it came from. With `true` the library's own pan ran instead, which
                // is why closing here felt like a different (and worse) gesture.
                // anonymous: FALSE. With `true` the view was never recorded — not on the server and
                // not even in the local seen flags (markSeenItem bails on anonymous) — so watching a
                // story from a profile left the ring showing "unseen" forever. Viewing here counts
                // exactly like viewing from the chat list. For a non-contact the server write may be
                // refused by rules; that's non-fatal and the local watermark still updates.
                StoryViewer(group: g, anonymous: false, ownSwipeDismiss: false,
                            onClose: { storyViewerGroup = nil; refreshStorySeen() })
                    .navigationTransition(.zoom(sourceID: "profile-story", in: mediaNS))
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
                // The editor owns the whole card now (first/last/note + delete); this just re-reads
                // the resulting display name for the header.
                SetNicknameView(uid: otherUid, profileName: name, photoUrl: photoUrl) {
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
                    // A refusal here must not blank the strip — only a real answer replaces it.
                    Task {
                        await ChatService.clearMyMessages(cid)
                        if let fresh = await ChatService.sharedMedia(cid) { media = fresh; mediaHint = fresh.count }
                    }
                }
            } message: {
                Text("This deletes the messages you sent in this chat. It can't be undone.")
            }
            // shownName, not the raw name (audit): renamed to "Mom", the button said "Block Mom"
            // but this safety-critical confirm asked about "ayaan_99" — reads as a different person.
            .alert("Block \(shownName)?", isPresented: $showBlock) {
                Button("Cancel", role: .cancel) {}
                Button("Block", role: .destructive) {
                    Task { await ChatService.setBlocked(cid, true); blocked = true }
                }
            } message: {
                Text("You won't be able to send messages in this chat until you unblock. \(shownName) won't be told they were blocked.")
            }
            .alert("Report \(shownName)?", isPresented: $showReport) {
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
                Text("Our team will review this account within 24 hours. \(shownName) won't be told.")
            }
    }

    /// The private note from Edit (ContactNames, device-only — nothing here is ever sent, which is
    /// what lets the header say "only visible to you"). Read live from the store so saving the sheet
    /// updates this card instantly.
    private var contactNote: String {
        ContactNames.shared.card(for: otherUid).note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Notes card (owner's reference screenshot): icon + "Notes" + "only visible to you", the note
    /// under it at 2 lines, and More only when there is a third line to reveal. Collapsed on every
    /// fresh open by construction — see the @State pair.
    @ViewBuilder private var notesCard: some View {
        let note = contactNote
        if !isSelf, !note.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                // Matched to the settings rows below it (Disappearing Messages / Sounds / Verify):
                // same 14pt gap, same 26pt icon column, and the title in the SAME plain body font —
                // it was 17pt semibold, which read as a heading rather than a row label (owner:
                // "Notes is looks bold and big, use the font size disappearing message uses").
                HStack(spacing: 14) {
                    Image("ic_notes").renderingMode(.template).resizable().scaledToFit()
                        .frame(width: 21, height: 21).frame(width: 26)
                    Text("Notes")
                    Spacer(minLength: 8)
                    Text("only visible to you")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                }
                // Derived, never stored: editing the note re-measures on the next body run with no
                // stale flag to clear.
                let overflows = Self.noteExceedsTwoLines(note, width: noteWidth)
                Group {
                    if overflows && !noteExpanded {
                        // "More" RIDES THE END OF LINE 2 rather than taking a line of its own (owner:
                        // "more button Follow line 2 dont make line 3"). SwiftUI cannot place a Button
                        // inside wrapped text, so it is concatenated as a text run and the block below
                        // takes the tap. The note is pre-trimmed to the longest prefix that still
                        // leaves room for the tail, so the label always lands ON the second line
                        // instead of being pushed off by the system's own truncation.
                        Text(Self.noteCollapsedPrefix(note, width: noteWidth) + "… ")
                            + Text("More").foregroundStyle(Color.accentColor).fontWeight(.semibold)
                    } else {
                        Text(note)
                    }
                }
                    .font(.system(size: 16))
                    .foregroundStyle(.primary)
                    .lineLimit(noteExpanded ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Measure at the REAL rendered width: a 100-char note wraps to 2 or 3 lines
                    // depending on the device, so guessing by character count would show More on a
                    // note that already fits (and hide it on one that doesn't).
                    .background(
                        GeometryReader { g in
                            Color.clear.onChange(of: g.size.width, initial: true) { _, w in noteWidth = w }
                        }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard overflows else { return }
                        withAnimation(.easeInOut(duration: 0.2)) { noteExpanded.toggle() }
                    }
                // Expanded: "Less" keeps its own row — there is no truncated line for it to ride.
                if overflows && noteExpanded {
                    Button("Less") {
                        withAnimation(.easeInOut(duration: 0.2)) { noteExpanded = false }
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardColor, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    /// True when the note needs a third line at this width — the same font the card renders with.
    private static func noteExceedsTwoLines(_ note: String, width: CGFloat) -> Bool {
        guard width > 1, !note.isEmpty else { return false }
        let font = UIFont.systemFont(ofSize: 16)
        let box = CGSize(width: width, height: .greatestFiniteMagnitude)
        let height = (note as NSString).boundingRect(
            with: box, options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font], context: nil).height
        return height > font.lineHeight * 2 + 1   // +1 absorbs rounding on the exact-2-line case
    }

    /// The longest prefix of `note` that still fits two lines once "… More" is appended.
    ///
    /// Without this the system truncates to fill both lines and the appended label has nowhere to
    /// go but a third line, which is the exact thing being avoided. Binary search over a note capped
    /// at 100 characters is ~7 measurements. The tail is measured SEMIBOLD, the weight it renders
    /// at, so the reserved room is never short.
    private static func noteCollapsedPrefix(_ note: String, width: CGFloat) -> String {
        guard width > 1 else { return note }
        let font = UIFont.systemFont(ofSize: 16)
        let limit = font.lineHeight * 2 + 1
        func fits(_ count: Int) -> Bool {
            let s = NSMutableAttributedString(string: String(note.prefix(count)) + "… ",
                                              attributes: [.font: font])
            s.append(NSAttributedString(string: "More",
                                        attributes: [.font: UIFont.systemFont(ofSize: 16, weight: .semibold)]))
            return s.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                  options: [.usesLineFragmentOrigin, .usesFontLeading],
                                  context: nil).height <= limit
        }
        let full = note.count
        if fits(full) { return note }
        var lo = 0, hi = full
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if fits(mid) { lo = mid } else { hi = mid - 1 }
        }
        // Trim a dangling space so the ellipsis sits flush against the last word.
        return String(note.prefix(lo)).trimmingCharacters(in: .whitespaces)
    }

    // Profile settings rows (standard order): Disappearing Messages, Sounds & Notifications,
    // Verify Encryption. Wallpaper / Share / Clear / Report / Block now live in the "…" menu.
    private var settingsCard: some View {
        VStack(spacing: 0) {
            infoRow("Disappearing Messages", "ic_disappearing", value: disappearLabel) { showDisappear = true }
            rowDivider
            // The same glyph Settings uses for its Notifications row (owner: reuse that one).
            infoRow("Sounds & Notifications", "ic_notifications", value: muted ? "Muted" : "On") { showSounds = true }
            rowDivider
            infoRow("Verify Encryption", "ic_verify_encryption", tint: .accentColor) { showVerify = true }
        }
        .background(cardColor, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    // Groups this contact and I both belong to. "N Groups in Common" + Add-to-a-Group + the list;
    // "No Groups in Common" + Add-to-a-Group only (no list) when there are none.
    private var sharedGroups: [Conversation] {
        let me = AuthService.shared.uid ?? ""
        // Membership only — NOT isCleared (audit): swipe-deleting a quiet group's ROW while
        // remaining a member made it vanish from "Groups in Common", contradicting the header.
        return ConversationsRepository.shared.conversations
            .filter { $0.isGroup && $0.users.contains(otherUid) && $0.users.contains(me) }
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
                // "ic_" names an asset-catalog glyph, anything else an SF Symbol. Same 26pt slot
                // either way so the titles stay on one line no matter which kind a row uses.
                Group {
                    if icon.hasPrefix("ic_") {
                        Image(icon).renderingMode(.template).resizable().scaledToFit()
                            .frame(width: 21, height: 21)
                    } else {
                        Image(systemName: icon).font(.system(size: 17))
                    }
                }
                .frame(width: 26)
                .foregroundStyle(tint)
                Text(title).foregroundStyle(tint)
                Spacer()
                if let value { Text(value).foregroundStyle(.secondary) }
                if chevron {
                    Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 18)   // Signal's tall profile rows (~58pt)
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
    // "Contact" = we share a real conversation — which is what PrivacyPrefs.isContact tests
    // (a 1:1 with an actual last message). The old `source == .chat ||` shortcut treated ARRIVING
    // from a chat as proof, but a brand-new empty chat opened from an @handle search is also
    // "from a chat", so a stranger who never exchanged a word saw a My-Friends-only photo, bio and
    // live call tiles (audit). The callee-side call gate already used the message-history rule, so
    // the two disagreed.
    private var iAmContact: Bool { PrivacyPrefs.isContact(otherUid) }
    private var gatedPhotoUrl: String? {
        PrivacyPrefs.allows(targetPrivacy, "photo", contactOfMine: iAmContact) ? photoUrl : nil
    }
    private var gatedAbout: String {
        PrivacyPrefs.allows(targetPrivacy, "bio", contactOfMine: iAmContact) ? about : ""
    }
    private var canCallThem: Bool {
        PrivacyPrefs.allows(targetPrivacy, "calls", contactOfMine: iAmContact)
    }

    /// The backdrop behind the hero: their own photo, blurred, fading into the page.
    ///
    /// NO PHOTO IS NEVER A GREY BOX. The app already gives every name a fixed pair of colours
    /// (`AvatarPalette.gradient(for:)`, chosen by hashing the name) and fills their letter avatar
    /// with it. The cover reuses that exact pair, so kasim's profile is violet from top to bottom and
    /// it is the SAME violet as his circle in the chat list. The colour follows the person around the
    /// app instead of being decoration invented for this screen.
    ///
    /// Drawn behind the hero rather than replacing it, so the story ring, the tap routing and the
    /// avatar's geometry reporting are all untouched.
    @ViewBuilder private var heroBackdrop: some View {
        GeometryReader { geo in
            let minY = geo.frame(in: .named("profileScroll")).minY
            // Pull-to-stretch: minY goes POSITIVE as the scroll rubber-bands.
            let stretch = max(0, minY)
            LinearGradient(colors: AvatarPalette.gradient(for: shownName),
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                // SOFTENED, not raw. The same colour that is right on a 44pt circle is a shouting
                // block across a whole header, and at full strength the yellow and cyan in the
                // palette make the name on top hard to read. Drawing it at part opacity over the
                // page lets the page do the softening, which also means it lands correctly in dark
                // mode (deepened, not bleached) with no second set of hand-tuned colours.
                .opacity(0.40)
                // SCALE, never a frame change. Resizing re-measures the view every frame of the
                // pull; scaling is a GPU transform. `.bottom` anchor so it grows upward off-screen
                // and the join with the page below never moves.
                .scaleEffect(x: 1, y: 1 + (stretch / max(geo.size.height, 1)), anchor: .bottom)
                // Fades to the page colour so the cards below sit on the normal grey with no seam.
                // Measured from the BOTTOM, not as a fraction: the overshoot above changes the total
                // height, and a fractional stop would slide the fade up into the avatar with it.
                .mask(LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: max(0, 1 - 120 / max(geo.size.height, 1))),
                    .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom))
                // Published so the nav bar can fade its own copy of the name in as this leaves.
                .preference(key: HeroOffsetKey.self, value: minY)
        }
        // Full bleed: the hero is inside the 16pt page inset, and a cover that stopped at that inset
        // would read as a card rather than a header.
        .padding(.horizontal, -16)
        // UP BEHIND THE BARS. The hero begins below the safe area, so a backdrop sized to the hero
        // began there too and left a white strip across the status bar and nav bar (owner
        // screenshot). `ignoresSafeArea` alone does not help here: this is a background inside
        // scrolling content, and the scroll view's own inset is what is holding it down. Reaching up
        // by a fixed overshoot is what actually gets it behind the bar; anything past the top of the
        // screen is clipped and costs nothing, which is why the number is generous rather than
        // measured.
        .padding(.top, -180)
        .allowsHitTesting(false)
    }

    /// How far the header has scrolled away, 0 (at rest) to 1 (gone). ONE number, so everything that
    /// reacts to the scroll stays in step; separate triggers per element drift apart by a frame and
    /// read as loose. Clamped, so flinging cannot push anything past its end state.
    private var collapse: Double {
        min(1, max(0, Double(-heroOffset) / 96))
    }

    private var hero: some View {
        VStack(spacing: 6) {
            ZStack {
                // Story ring (Instagram/WhatsApp pattern): a colored gradient ring means this person has
                // an active public story — tap the avatar to watch it instead of opening the photo.
                //
                // ALWAYS RENDERED, only faded: the ring is wider than the avatar, so rendering it
                // conditionally resized this ZStack (88 → 100) the moment the async story lookup
                // landed — the page visibly re-arranged itself a beat after opening. Reserving the
                // space (same trick as the @handle line below) means the ring can only fade in, and
                // nothing ever moves.
                Circle()
                    .stroke(storyAllSeen
                            ? AnyShapeStyle(Color.secondary.opacity(0.5))     // watched → quiet grey
                            : AnyShapeStyle(LinearGradient(colors: [Color.pink, Color.orange, Color.yellow],
                                                           startPoint: .topLeading, endPoint: .bottomTrailing)),
                            lineWidth: 3)
                    .frame(width: 100, height: 100)
                    .opacity(publicStory != nil && !showProfilePhoto ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: publicStory != nil)
                AvatarView(name: shownName, photoUrl: gatedPhotoUrl, size: 88,
                           onPhotoResolved: { heroHasPhoto = $0 })
                    // The viewer IS this avatar while open — hide the original so the morph reads
                    // as one circle leaving and returning, not a copy floating over it.
                    .opacity(showProfilePhoto ? 0 : 1)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { avatarFrame = $0 }
            }
            .contentShape(Circle())
            // Hero source for the story's native zoom close, exactly like the story row in the chat
            // list: the viewer grows out of this avatar and the drag-down rides back into it.
            .matchedTransitionSource(id: "profile-story", in: mediaNS)
            .onTapGesture {
                // What the eye sees, not what the url says — no picture means nothing to open.
                let hasPhoto = heroHasPhoto
                // Both a story AND a photo → ASK which one (WhatsApp's "Select an action"). A single
                // tap can't serve both, and silently preferring the story is what made the profile
                // photo unreachable. With only one of them available, go straight there.
                if publicStory != nil, hasPhoto { showAvatarChoice = true }
                else if let s = publicStory { storyViewerGroup = s }
                else if hasPhoto { showProfilePhoto = true }
            }
            // Attached HERE, on the hero, not on the outer chain that already carries three alerts:
            // stacking presentations on one view is what made the Edit Photo sheet never appear.
            // Bottom sheet, not confirmationDialog: on iOS 26 the system dialog anchors itself to the
            // avatar as a little callout bubble, and the user wants a sheet from the bottom.
            .bottomActionSheet("Select an action", isPresented: $showAvatarChoice, actions: [
                SheetAction("View profile photo") { showProfilePhoto = true },
                SheetAction("View story") { storyViewerGroup = publicStory },
            ])
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
                    // A bio is variable height, so it can't be pre-reserved like the @handle line.
                    // The cache above removes the shift entirely for profiles we've seen; on a genuine
                    // first-ever open this makes it ease in rather than snap.
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
        .padding(.bottom, 14)
        .background(heroBackdrop)
        .animation(.easeOut(duration: 0.22), value: gatedAbout)
    }

    // Native menu (pops up) instead of a custom action sheet. When ALREADY muted, the menu is just
    // "Muted until <time>" + Unmute — the durations only appear when the chat is unmuted. NOT on
    // your own profile (audit): its "me_me" cid has no conversation, so picking a duration wrote a
    // mutedBy map into a phantom server doc. Shared by both headers so the two can never drift.
    @ViewBuilder private var muteMenuItems: some View {
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
    }

    // MARK: - Modern header

    private var posterHeader: some View {
        ProfilePosterHeader(
            name: shownName,
            photoUrl: gatedPhotoUrl,
            scrollSpace: "profileScroll",
            onPhotoRect: { posterRect = $0 },
            // The poster reports the same number the old hero published, so the nav bar's title
            // still rides in on `collapse` with nothing else changed.
            onScroll: { heroOffset = $0 },
            // A tap is the PHOTO, always. The story has its own control in the toolbar now, so the
            // "which did you mean" sheet the round avatar needed is gone from this path.
            onTap: { showProfilePhoto = true },
            // While the viewer is open the photo IS the viewer — hiding the header's copy keeps it
            // one picture moving rather than two stacked on each other. The wash stays, so the page
            // behind the viewer keeps its background.
            photoHidden: showProfilePhoto,
            caption: { posterCaption($0) },
            actions: { glassActions }
        )
    }

    /// Name, @handle and bio, sitting on the photo. Same content and the same anti-jump trick as the
    /// classic hero: the @handle line is always reserved, so the async profile fetch fills it in
    /// without pushing the buttons down.
    private func posterCaption(_ text: Color) -> some View {
        VStack(spacing: 3) {
            Text(shownName).font(.title.weight(.bold)).foregroundStyle(text)
                .lineLimit(2).multilineTextAlignment(.center)
            Text(handle.isEmpty ? " " : "@\(handle)")
                .font(.subheadline).foregroundStyle(text.opacity(0.82))
                .frame(minHeight: 20)
            if !gatedAbout.isEmpty {
                Text(gatedAbout)
                    .font(.subheadline).foregroundStyle(text.opacity(0.82))
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.22), value: gatedAbout)
    }

    /// The same five actions the tiles offer, as icon-only circles. Order follows the reference:
    /// voice, video, mute, search, more. Every rule the tiles enforce is enforced here too — a
    /// blocked person cannot be called, your own profile cannot call itself, and Search only exists
    /// where there is a chat to search.
    private var glassActions: some View {
        HStack(spacing: 0) {
            if source == .calls {
                Button { openChat = true } label: { PosterActionIcon(icon: "message.fill") }.tint(.primary)
            }
            if !isSelf && canCallThem && !blocked {
                Button { CallService.shared.startCall(to: otherUid, name: name, photo: photoUrl) } label: {
                    PosterActionIcon(icon: "phone.fill")
                }.tint(.primary)
                Button { CallService.shared.startCall(to: otherUid, name: name, photo: photoUrl, video: true) } label: {
                    PosterActionIcon(icon: "video.fill")
                }.tint(.primary)
            }
            if !isSelf {
                Menu { muteMenuItems } label: {
                    PosterActionIcon(icon: muted ? "ic_bell" : "ic_bell_off")
                }.tint(.primary)
            }
            if source == .chat && !isSelf {
                Button { onSearch() } label: { PosterActionIcon(icon: "magnifyingglass") }.tint(.primary)
            }
            if !isSelf {
                Menu { moreMenuItems } label: { PosterActionIcon(icon: "ellipsis") }.tint(.primary)
            }
        }
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
            // `!blocked` (audit): tapping Block then the voice tile one inch above it still rang the
            // blocked person — the tiles only checked THEIR privacy, never my own block.
            if !isSelf && canCallThem && !blocked {
                actionTile("video", "video.fill") { CallService.shared.startCall(to: otherUid, name: name, photo: photoUrl, video: true) }
                actionTile("voice", "phone.fill") { CallService.shared.startCall(to: otherUid, name: name, photo: photoUrl) }
            }
            // Native menu (pops up) instead of a custom action sheet. When ALREADY muted, the menu
            // is just "Muted until <time>" + Unmute — the durations only appear when the chat is unmuted.
            // NOT on your own profile (audit): its "me_me" cid has no conversation, so picking a
            // duration wrote a mutedBy map into a phantom server doc.
            if !isSelf {
                Menu { muteMenuItems } label: {
                    tileLabel(muted ? "unmute" : "mute", muted ? "ic_bell" : "ic_bell_off")
                }
                .tint(.primary)
            }
            // Only a CHAT-opened profile has the search bar to pop back to — from a story (or your
            // own profile) this tile was a dead button wired to the default no-op (audit).
            if source == .chat && !isSelf {
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
                        // Direction + kind from the entry itself (audit: this card hardcoded "voice
                        // call" for video calls, and used raw `missed` — my own unanswered outgoing
                        // call showed as a red "Missed". missedIncoming is the standard rule the
                        // Calls tab already follows.)
                        Image(systemName: call.missedIncoming
                              ? (call.video ? "video.slash.fill" : "phone.down.fill")
                              : (call.mine ? "phone.arrow.up.right" : "phone.arrow.down.left"))
                            .foregroundStyle(call.missedIncoming ? .red : .secondary)
                        Text({
                            let kind = call.video ? "video call" : "voice call"
                            if call.missedIncoming { return "Missed \(kind)" }
                            return call.mine ? "Outgoing \(kind)" : "Incoming \(kind)"
                        }())
                        Spacer()
                        Text(call.date.formatted(date: .omitted, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                // 24, matching every other card on this screen (the sections below, the action tiles, the
                // media card). This one was left at 14, so it sat directly above a 24 card with visibly
                // tighter corners - the mismatch the user circled. `.continuous` is the Apple curve.
                .background(cardColor, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
        }
    }

    private func actionTile(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { tileLabel(title, icon) }.tint(.primary)
    }

    private func tileLabel(_ title: String, _ icon: String) -> some View {
        VStack(spacing: 7) {
            Group {
                if icon.hasPrefix("ic_") {
                    Image(icon).renderingMode(.template).resizable().scaledToFit().frame(width: 24, height: 24)
                } else {
                    Image(systemName: icon).font(.system(size: 22))
                }
            }
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
                    // Reserved space, filled: while the real thumbnails load, the row holds the same
                    // number of quiet placeholder tiles the chat had last time. The section's height
                    // is therefore identical before and after the load, so nothing shifts.
                    if media.isEmpty {
                        ForEach(0..<min(mediaHint, 12), id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.primary.opacity(0.07))
                                .frame(width: 84, height: 84)
                        }
                    }
                    ForEach(media.prefix(12)) { m in
                        // Videos carry thumbUrl/thumbEnc (no imageUrl) — they were invisible here.
                        if let url = m.imageUrl ?? m.thumbUrl {
                            SecureImageView(imageUrl: url, enc: m.imageUrl != nil ? m.enc : m.thumbEnc, cid: cid)
                                .frame(width: 84, height: 84)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                // Own namespace — the chat and All Media register these same ids.
                                .modifier(MediaRectReporter(id: m.id, scope: .profile))
                                // OPEN LIKE THE CHAT: fly the thumb's media out of its tile (one
                                // pipeline, every entry point), falling back to a plain presentation.
                                // The system .zoom here scaled the whole cover AND ran its own dismiss
                                // pan alongside SignalDismissHost's.
                                .onTapGesture {
                                    let key = MediaOpenRects.key(.profile, m.id)
                                    // Both cache tiers, not memory only — see flyOrPresent.
                                    // Videos → the PLAYER (audit: they went to the image viewer,
                                    // whose loader guards on imageUrl and spun forever).
                                    SignalMediaOpen.flyOrPresent(
                                        imageUrl: url, rectKey: key,
                                        present: { MediaPresentGate.present {
                                            if m.isVideo { viewerVideo = m } else { viewerImage = m }
                                        } })
                                }
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
        // Your OWN profile (opened from your story): otherUid is "" and the "me_me" cid has no
        // conversation doc — the peer fetch below returned nil, so your @handle and bio never
        // loaded (audit). Read them from the profile store's own record instead.
        if isSelf {
            if let mine = ProfileStore.shared.me { handle = mine.handle; about = mine.about }
            loaded = true
            return
        }
        // Paint from Firestore's LOCAL cache first (no network): for anyone we've opened before, the
        // @handle and bio are there on the first frame, so the page doesn't shift when the server
        // fetch lands. The fetch below still runs and corrects anything stale.
        if handle.isEmpty, about.isEmpty, let c = await ProfileStore.shared.cachedPeer(otherUid) {
            handle = c.handle; about = c.about; targetPrivacy = c.privacy
        }
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
        // LOCAL FIRST, THE WAY SIGNAL DOES IT. Signal's media gallery is a query over its own message
        // database, so it renders offline and instantly; it never asks the network for something it has
        // already received. Kulan has no SQLite store, but it does keep this chat's decrypted messages
        // in memory — that cache is what lets the conversation paint before the push transition
        // finishes, and you reach this profile BY WAY OF that conversation, so it is warm exactly when
        // you need it. Reading media out of it costs nothing, needs no connection, and answers on the
        // first frame (user: "we are sending image but when i click profile all media I am not seeing…
        // why need internet that section").
        if let local = ThreadMessageCache.shared.messages(for: cid) {
            // Reverse the MESSAGES, then flatten (audit): reversing after flattening inverted the
            // items INSIDE each album, so the strip visibly reshuffled when the server pass —
            // which keeps album order — replaced this one a beat later.
            let localMedia = local
                .filter { $0.isImage || $0.isVideo || $0.isAlbum }
                .reversed()                       // cache is oldest-first; this strip is newest-first
                .flatMap { $0.expandedGalleryItems(cid: cid) }
            if !localMedia.isEmpty { media = Array(localMedia) }
        }
        // Then the server, which sees further back than the in-memory window. A FAILED load returns nil
        // and is ignored — it must never empty a strip that local knowledge already filled.
        if let fresh = await ChatService.sharedMedia(cid) {
            media = fresh
            mediaHint = fresh.count   // authoritative: a chat whose media was deleted stops reserving
        } else if !media.isEmpty {
            mediaHint = media.count   // offline, but we know what we have
        }
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
            // `.album` scope: this grid registers no rects either, so the close falls back honestly
            // instead of flying to a chat bubble hidden behind this sheet.
            .fullScreenCover(item: $viewer) { ImageViewerView(message: $0, cid: cid, rectScope: .album) }
        }
    }
}

// In-place profile-photo viewer (tap the hero avatar). Telegram model, per the user's request:
// the circle GROWS out of the avatar, stays a circle the whole time, and closes back INTO the
// avatar — never presented as a page/cover. While the finger holds and moves the photo (or
// swipes down), the white theme backdrop melts away with drag distance so the profile shows
// through behind; release far enough closes into the avatar, otherwise it springs back.
/// One shape for both morphs: a rounded rect whose radius is animated, which at half the shorter
/// side IS a circle. The classic viewer keeps its circle by holding the radius at w/2 the whole way;
/// the poster holds it at zero. Nothing branches at draw time.
private struct ViewerShape: Shape {
    var corner: CGFloat

    var animatableData: CGFloat {
        get { corner }
        set { corner = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(corner, min(rect.width, rect.height) / 2)
        return Path(roundedRect: rect, cornerRadius: r, style: .circular)
    }
}

// Chat media keeps its own always-black viewer — that's for real photos, this is a portrait.
// Profile photos are plain URLs (not E2EE) served from the same DiskImageCache AvatarView
// fills, so it opens instantly.
//
// Internal rather than file-private because a group's photo opens exactly the same way, and a
// second copy of a morph this carefully tuned is a second copy to keep in step.
struct ProfilePhotoViewer: View {
    /// Real window safe-area insets. The photo viewer draws full-bleed (its container ignores the safe
    /// area), so SwiftUI reports zero insets inside it and chrome has to be positioned from these.
    private var winInsets: UIEdgeInsets {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets }
            .max(by: { $0.top < $1.top }) ?? .zero
    }

    let name: String
    let photoUrl: String
    let sourceFrame: CGRect          // the hero avatar (or the poster square), in global coords — morph start AND end
    /// Poster mode: grow out of the square header and land at the photo's OWN aspect ratio, square
    /// corners throughout. Off: the round-avatar morph this viewer was built for, unchanged.
    var poster: Bool = false
    @Binding var isPresented: Bool
    @State private var image: UIImage?

    init(name: String, photoUrl: String, sourceFrame: CGRect, poster: Bool = false, isPresented: Binding<Bool>) {
        self.name = name
        self.photoUrl = photoUrl
        self.sourceFrame = sourceFrame
        self.poster = poster
        _isPresented = isPresented
        // The avatar this grows out of is already on screen, so its bitmap is already in memory.
        // Seeding here means the morph begins holding the photo, instead of a grey disc that swaps
        // to the photo a frame later — which reads as part of the "jump".
        _image = State(initialValue: DiskImageCache.shared.memoryImage(for: photoUrl))
    }
    @State private var progress: CGFloat = 0   // 0 = sitting on the avatar, 1 = open in the center
    @State private var drag: CGSize = .zero
    @State private var zoom: CGFloat = 1
    @State private var closing = false

    // Solid page when open and resting; the DRAG is what melts the white (fully, not partially).
    private var backdropOpacity: Double {
        let dist = Double(sqrt(drag.width * drag.width + drag.height * drag.height))
        return Double(progress) * max(0, 1 - dist / 260)
    }

    /// The picture's own shape. 1 until the bitmap is here, which is only ever the frame before the
    /// morph starts — and a square start is exactly what the poster header is showing anyway.
    private var imageAspect: CGFloat {
        guard let image, image.size.height > 0 else { return 1 }
        return image.size.width / image.size.height
    }

    /// The header dissolves its photo into the page over the bottom third. The viewer starts life
    /// wearing that same fade, so the first frame is indistinguishable from what was already on
    /// screen, and opens to the whole picture as it lifts. Without it the photo pops solid the
    /// instant it leaves the header, which is exactly the kind of one-frame jump this screen keeps
    /// being reported for. `Color.black` in the classic case is a mask that does nothing.
    @ViewBuilder private var liftMask: some View {
        if poster {
            LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.62 + 0.38 * progress),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        } else {
            Color.black
        }
    }

    var body: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            // Signal's exact sizing: AvatarViewController pins its CircleView to the view width minus
            // 48 (24pt inset each side), with no upper cap — so on a wide phone the circle keeps
            // growing instead of stopping at an arbitrary maximum, which is what our `min(…, 360)` did.
            let d = geo.size.width - 48
            // POSTER: the full width at the picture's OWN aspect ratio, or limited by height when the
            // picture is taller than the screen — so it lands showing everything, cropping nothing,
            // and running off nothing. The frame's shape travels from the header's square to the
            // photo's real one, which is why the crop opens up as it flies instead of the image
            // stretching.
            let targetW = poster ? min(geo.size.width, geo.size.height * imageAspect) : d
            let targetH = poster ? targetW / imageAspect : targetW
            // Interpolate between the header's rect and where it is going.
            let w = sourceFrame.width  + (targetW - sourceFrame.width)  * progress
            let h = sourceFrame.height + (targetH - sourceFrame.height) * progress
            // Round the whole way as an avatar; square the whole way as a poster.
            let corner = poster ? 0 : w / 2
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
                .frame(width: w, height: h)
                .clipShape(ViewerShape(corner: corner))   // one shape from first frame to last — it never becomes a page
                .mask { liftMask }
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
                            // Signal's rule, matched exactly (MediaInteractiveDismiss): progress is the
                            // straight-line distance over distanceToCompletion = 88, and `.ended`
                            // finishes whenever `percentComplete > 0` — ANY real movement closes it,
                            // cancel is effectively unreachable. Ours demanded 120pt before it would
                            // let go, which is why closing felt like work next to theirs.
                            let dist = sqrt(v.translation.width * v.translation.width
                                            + v.translation.height * v.translation.height)
                            if dist > 0 { close() }
                            else { withAnimation(.spring(duration: 0.3)) { drag = .zero } }
                        }
                )
                // Just the X (user spec): no name label — the photo is the subject, and the page's own
                // back/Edit chrome is hidden while this is open so nothing else floats over it.
                //
                // IN the ZStack, not in an overlay of it. As an overlay that ignored the safe area, the
                // button was drawn into a strip its own parent did not occupy: visible, and dead to
                // touch. Here it shares one coordinate space with the backdrop and the photo, both of
                // which take taps, so if they can be pressed so can this.
                //
                // The viewer now owns the whole screen (see .ignoresSafeArea() where it is presented),
                // so this space starts at the screen corner and winInsets is measured from the same
                // place. `.position` places the CENTRE, so the button's top edge sits 8pt below the
                // safe-area line — the line chrome must not cross — and the centre follows from its
                // own size.
                Button { close() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(.primary)
                        .frame(width: 48, height: 48)          // 48pt Liquid Glass, same as every
                        .liquidGlass(Circle(), interactive: true)   // other full-screen close button
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .position(x: 16 + 24, y: winInsets.top + 8 + 24)
                .opacity(progress == 1 && drag == .zero && !closing ? 1 : 0)   // chrome only at rest
                .animation(.easeOut(duration: 0.15), value: drag == .zero)
            }
        }
        .onAppear {
            // ONE FRAME AT THE START, THEN ANIMATE. This is why opening jumped while closing was
            // smooth: closing changes a view that is already on screen, so there is a previous frame
            // to move from. Opening ran inside the transaction that INSERTS the viewer, and a view
            // being inserted has no previous frame — SwiftUI drew it at progress 1 and there was
            // nothing left to animate. Handing the change to the next runloop means the avatar-sized
            // circle is really on screen first, and the spring then has somewhere to travel from.
            DispatchQueue.main.async {
                withAnimation(.spring(duration: 0.38, bounce: 0.15)) { progress = 1 }
            }
        }
        .task {
            if image != nil { return }   // already seeded from memory — don't re-fetch or flash
            if let cached = await DiskImageCache.shared.image(for: photoUrl) { image = cached; return }
            guard let url = URL(string: photoUrl),
                  let (data, _) = try? await MediaSession.shared.data(from: url),
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
