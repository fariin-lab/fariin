import SwiftUI

/// THE STORIES TAB — his call, 2026-08-30, with two mockups of the app beside each other: the story
/// row leaves the chat list and gets a page of its own, and the tab bar becomes Stories, Chats,
/// Calls, Settings.
///
/// ⛔ THE ROW IS THE SAME `StoriesRow`, NOT A SECOND ONE. Every card, its long press, the morph out
/// of it and the drag-down back into it are one UIKit view (`StoriesRowUIKit`) and they stay one.
/// What moved is where it is mounted and who owns the handlers around it; nothing about the row's
/// own behaviour changes, and a second implementation of it is the one outcome this file exists to
/// prevent.
///
/// ⚠️ WHAT THE CHAT LIST KEPT. The ringed avatars in the chat rows are NOT this row and did not
/// move: a ring belongs to a conversation and opens that one person's story (`openStoryFromRing`
/// there, `pinned` by default, because the ring is the only anchor that list has). This page's door
/// is the unpinned one — the viewer pages person to person and the row has a card for whoever you
/// paged to, so the anchor follows. Two doors, deliberately, and they are in the two files that own
/// their anchors.
///
/// ⚠️ NOT DISCOVER. His mockup has a Discover grid under the row and he said to leave it: "it has
/// its own logic, we still work on it". This page is the row and nothing else, so the grid has
/// somewhere to land without this file being unpicked first.
struct StoriesTabView: View {
    var onSignOut: () -> Void
    /// ⚠️ AN EXPLICIT INIT, LIKE `ChatsView`'S, AND IT IS NOT DECORATION. A struct with any
    /// private stored property gets a PRIVATE memberwise initializer, so `StoriesTabView(...)`
    /// from another file does not compile — "argument passed to call that takes no arguments".
    init(onSignOut: @escaping () -> Void = {}) { self.onSignOut = onSignOut }

    private var profile = ProfileStore.shared
    // (No `StoriesRepository` property: `StoriesRow` is UIKit and observes the repository
    // itself, so a copy here would be a second subscription that changes nothing.)
    private var storyDoorState = StoryDoorState.shared
    private var storyBudget: StoriesService { StoriesService.shared }

    @State private var path = NavigationPath()
    @State private var profileGroup: StoryGroup?
    /// The Glow section's people, resolved for their cards.
    @State private var glowPeople = GlowPeopleLoader()
    /// The Glowing grid: one card per glow person, carrying their newest live story.
    @State private var glowStories = GlowStoriesLoader()
    private var glow = GlowService.shared
    /// The server says this account may not post a story at all — see `AppLimits.storiesEnabled`.
    @State private var storiesOff = false
    @State private var storyLimitReached = false
    @AppStorage("storiesOptedOut") private var storiesOptedOut = false

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Stories")
                // ⛔ THREE BUTTONS, HIS REFERENCE: the ••• menu on the LEFT, and the bell and the
                // add-story mark together on the RIGHT — the two right-hand ones read as one glass
                // capsule in his mockup because iOS groups adjacent trailing items that way.
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { moreMenu }
                    ToolbarItem(placement: .topBarTrailing) { notificationsButton }
                    ToolbarItem(placement: .topBarTrailing) { addStoryButton }
                }
                .navigationDestination(for: GlowRoute.self) { glowDestination($0) }
                .navigationDestination(for: ChatTarget.self) { t in
                    // Same rule as the chat list's stack: the official channel is its own screen,
                    // and every chat gets a fresh ThreadView identity keyed by cid.
                    if OfficialChannel.isOfficial(t.id) {
                        OfficialChatView().id(t.id)
                    } else {
                        ThreadView(cid: t.id, title: t.name, photoUrl: t.photo)
                            .id(t.id)
                    }
                }
        }
        .sheet(item: $profileGroup) { g in
            NavigationStack {
                // .story source: no chat underneath → no Search/Wallpaper dead buttons.
                ContactInfoView(cid: storyCid(g.authorUid), name: g.name, photoUrl: g.photoUrl,
                                source: .story)
            }
        }
        // ⛔ AT THE TAP, BEFORE THE PICKER (his order, 2026-08-21: "the user must be informed before
        // selecting a photo or video"). Moved here with `composeStory`, because an alert without the
        // function that raises it is an alert nothing can show.
        .alert(AppLimits.storiesOffMessage, isPresented: $storiesOff) {
            Button("OK", role: .cancel) {}
        }
        .alert("That's today's limit", isPresented: $storyLimitReached) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You've posted \(StoriesService.dailyStoryLimit) stories today. "
                 + "You can post again in about \(storyBudget.dailyLimitHoursLeft) hours.")
        }
        // Ask once when the page appears, so the compose button already knows the answer when it is
        // pressed rather than finding out after the picker.
        .task { await storyBudget.refreshDailyBudget() }
        // The Glow section's rows. Keyed on the live set, so giving or receiving a glow refreshes
        // the strip without a manual reload — and re-running for an unchanged set is a no-op inside
        // the loader, so a re-render costs nothing.
        .task(id: glowKey) {
            await glowPeople.load(Array(glow.glowRelationship).sorted(), key: glowKey)
            await glowStories.load(Array(glow.glowRelationship).sorted(), key: glowKey)
        }
    }

    @ViewBuilder private var content: some View {
        if storiesOptedOut {
            // Stories switched off in Settings. The tab still exists — a tab that vanishes and
            // returns rearranges the bar under someone's thumb — and says why it is empty.
            ContentUnavailableView("Stories are off",
                                   systemImage: "circle.slash",
                                   description: Text("Turn stories back on in Settings to see them here."))
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    // ⛔ FRIENDS BECOMES A GRID WHEN THERE IS NO GLOWING SECTION — his seventh
                    // reference, 2026-09-02: "when the user doesn't have Glow story, friends design
                    // like this", showing the big two-column cards filling the page.
                    //
                    // The reasoning holds up: with a Glowing grid underneath it, Friends is a strip
                    // so the two sections can both be seen. With nothing underneath, a single strip
                    // leaves most of the page empty, and the cards are the better use of it.
                    if hasGlowGrid { StoriesRow(meName: profile.me?.name ?? "You", mePhoto: profile.me?.photoUrl,
                               // HOLD THE ROW STILL WHILE A STORY IS OPEN. Watching someone's last
                               // unseen story re-sorts the row live, so their card slid out from
                               // under the close before it could land on it.
                               freezeOrder: storyDoorState.isOpen,
                               onCompose: { composeStory() },
                               onOpen: { g in openStoryFromRow(g) },
                               onMessage: { g in openStoryChat(g) },
                               onProfile: { g in profileGroup = g },
                               onOpenUploading: { openUploadingStory() })
                    } else {
                        friendsGrid
                    }
                    // ⛔ GLOW SITS UNDER FRIENDS AND IS NOT MIXED INTO IT — his requirement 10,
                    // 2026-09-02: "Glowers must not be mixed into the Friends Story list". The row
                    // above is the friends row and is untouched; this is a second, separate
                    // section, which is also why it is a plain SwiftUI strip rather than a second
                    // `StoriesRow` — that row is one UIKit view with one anchor for the open/close
                    // morph, and a second instance of it would fight the first for that anchor.
                    //
                    // ⚠️ NO DISCOVER. His mockup had a Discover grid here and he removed it by name
                    // on 2026-09-02 ("no discover feature"). The file's older note said Discover was
                    // being left room to land in; that room is now Glow's.
                    glowSection
                }
            }
            // ⚠️ NO `contentMargins` DANCE HERE, AND THAT IS THE POINT OF THE MOVE. In the chat list
            // the row was drawn OUTSIDE the List and slid by hand against `chatScrollY`, with the
            // list carrying a top margin the height of the row, because a row INSIDE a list lifts as
            // one cell on a long press and each card has to lift on its own. On a page of its own it
            // is simply the first thing on the page, and all of that machinery is gone rather than
            // ported.
        }
    }

    /// Is there a Glowing grid below? Decides whether Friends is a strip or a grid.
    ///
    /// ⛔ ASKS THE RELATIONSHIP, NOT THE LOADER — his report, 2026-09-02: "first time I click story
    /// tab it's showing this, after refreshing it's showing glowing stories".
    ///
    /// ⚠️ THE BUG WAS THAT THIS ANSWERED A QUESTION ABOUT PICTURES. It read the loaded CARDS, which
    /// are empty for the moment the fetch takes — so the first frame decided "no Glowing section",
    /// drew Friends as the full-page grid, and then flipped the ENTIRE page to a strip plus a grid
    /// when the cards landed. A layout that changes shape after its data arrives is the worst kind
    /// of flicker: it is not a spinner replaced by content, it is one design replaced by another.
    ///
    /// `glowRelationship` is known synchronously off two listeners, so from the very first frame
    /// the page knows which of the two shapes it is — and the cards then simply fill into a grid
    /// that was always going to be there. This is the same rule the chat list follows about its
    /// own skeleton: decide the layout on what you know, fill it with what arrives.
    private var hasGlowGrid: Bool { !glow.glowRelationship.isEmpty }

    /// FRIENDS AS A GRID — the layout when nothing sits under it. Same card as Glowing.
    ///
    /// ⚠️ THIS IS A SECOND WAY OF DRAWING FRIENDS' STORIES, and this file's own header warns against
    /// exactly that: `StoriesRow` is one UIKit view that owns the card, its long press, and the
    /// ANCHOR the open/close morph flies from. These cards have no anchor registered, so opening one
    /// gets `StoryDoor`'s plain presentation rather than the morph out of the tapped card.
    ///
    /// It is built this way deliberately and the cost is stated rather than hidden: the alternative
    /// is teaching the UIKit row a second layout, which is a much larger change to the one file this
    /// app has been most often burned by. If the missing morph reads wrong on his phone, the fix is
    /// to register these cards with `StoryCardMorph` — not to reimplement the row.
    @ViewBuilder private var friendsGrid: some View {
        let groups = StoriesRepository.shared.others.filter { !StoryPrefs.isHidden($0.authorUid) }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                Text("Friends").font(.system(size: 22, weight: .bold))
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10)], spacing: 10) {
                // My own card first, wearing the ⊕ — his reference puts My Story at the front of
                // the grid exactly as it is at the front of the strip.
                if let mine = StoriesRepository.shared.mine, let newest = mine.stories.last {
                    Button { openStoryFromRow(mine) } label: {
                        GlowStoryCardView(thumbUrl: newest.thumbUrl.isEmpty ? newest.mediaUrl : newest.thumbUrl,
                                          name: "My Story",
                                          authorPhoto: profile.me?.photoUrl,
                                          isMine: true)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(groups) { g in
                    Button { openStoryFromRow(g) } label: {
                        GlowStoryCardView(
                            thumbUrl: g.stories.last.map { $0.thumbUrl.isEmpty ? $0.mediaUrl : $0.thumbUrl } ?? "",
                            name: g.name,
                            authorPhoto: g.photoUrl)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 4)
    }

    // MARK: - Glow

    /// ⛔ "GLOWING", A TWO-COLUMN GRID OF STORY CARDS — his sixth reference, 2026-09-02. My first
    /// pass was a horizontal strip of avatars, which is the FRIENDS row's language and wrong here:
    /// the friends row is a queue of people you already know, so a face is enough to pick one out.
    /// Glowing is people you may not know at all, and the picture is what makes one worth opening.
    /// Big cards, the story's own image, the author's name and face on it.
    ///
    /// It also takes the exact place the Discover grid used to occupy, which is why the grid shape
    /// is the one that already suited this page.
    @ViewBuilder private var glowSection: some View {
        let cards = glowStories.state.value ?? []
        // Present from the first frame whenever there IS a relationship — see `hasGlowGrid`. The
        // cards fill in underneath the heading rather than the heading appearing after them, so
        // the page never changes shape once it is on screen.
        if hasGlowGrid {
            VStack(alignment: .leading, spacing: 12) {
                NavigationLink(value: GlowRoute.people) {
                    HStack(spacing: 4) {
                        Text("Glowing").font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.primary)
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    if cards.isEmpty {
                        // Two empty cards while the pictures are fetched. They hold exactly the
                        // space the real ones will take, so nothing under them moves when they
                        // land — a placeholder that is a different size is just a slower jump.
                        ForEach(0..<2, id: \.self) { _ in
                            Color.primary.opacity(0.08)
                                .aspectRatio(0.74, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        }
                    } else {
                        ForEach(cards) { c in
                            NavigationLink(value: GlowRoute.profile(c.person.id, c.person.name,
                                                                    c.person.photoUrl ?? "")) {
                                GlowStoryCardView(card: c)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.top, 20)
        }
    }

    /// The Stories tab's own pushes. A single enum so the tab's stack has one destination table
    /// rather than a `navigationDestination` per screen scattered through the file.
    enum GlowRoute: Hashable {
        case people
        case notifications
        case storyPrivacy
        case profile(String, String, String)   // uid, name, photo
    }

    @ViewBuilder func glowDestination(_ r: GlowRoute) -> some View {
        switch r {
        case .people:
            GlowPeopleListView(side: .glowers)
        case .notifications:
            GlowNotificationsView()
        case .storyPrivacy:
            // ⛔ STRAIGHT TO THE REAL SETTINGS PAGE — his instruction, 2026-09-02: "in the 3 dot
            // button show story privacy, when the user clicks it go direct to the stories page in
            // settings". `StorySettingsView` is that page, the same one Settings pushes; a second
            // copy of those switches is how two screens come to disagree about one setting.
            StorySettingsView()
        case .profile(let uid, let name, let photo):
            GlowProfileView(uid: uid, initialName: name,
                            initialPhoto: photo.isEmpty ? nil : photo)
        }
    }

    /// The bell in the header, with the unread dot — his requirement 8: a notification indicator in
    /// the Stories tab's upper section that opens the Glow notifications page.
    ///
    /// ⚠️ UNREAD IS DERIVED FROM A READING POSITION, not a per-row flag. `GlowService.seenUpTo` is
    /// stamped when the page closes, so "unread" is simply "a glow arrived after that" — nothing to
    /// write per notification, nothing to migrate, and it cannot drift out of step with the rows.
    /// The ••• menu. One entry for now, his: Story privacy, straight to the settings page.
    @ViewBuilder private var moreMenu: some View {
        Menu {
            NavigationLink(value: GlowRoute.storyPrivacy) {
                Label("Story privacy", systemImage: "lock")
            }
        } label: {
            Image(systemName: "ellipsis")
        }
    }

    /// Compose a story — the mark that was only reachable from the row's own tile before. In the
    /// header it is reachable whatever the row is doing, which is what his reference shows.
    @ViewBuilder private var addStoryButton: some View {
        Button { composeStory() } label: {
            Image(systemName: "plus.circle")
        }
    }

    @ViewBuilder private var notificationsButton: some View {
        NavigationLink(value: GlowRoute.notifications) {
            Image(systemName: "bell")
                .overlay(alignment: .topTrailing) {
                    if hasUnreadGlow {
                        Circle().fill(GlowStyle.accent)
                            .frame(width: 8, height: 8)
                            .offset(x: 4, y: -3)
                    }
                }
        }
    }

    /// The identity of the current glow set — what the loader memoises on, and what makes the
    /// section refresh when a glow is given or taken back.
    private var glowKey: String { Array(glow.glowRelationship).sorted().joined(separator: ",") }

    private var hasUnreadGlow: Bool {
        // Cheap and live: the newest glow aimed at me, against the last time the page was opened.
        // The set itself carries no dates, so this asks the loader's rows when it has them and
        // falls back to "any glower at all before you have ever opened the page".
        if let rows = glowPeople.state.value, let newest = rows.map(\.at).max() {
            return newest > glow.seenUpTo
        }
        return !glow.displayGlowers.isEmpty && glow.seenUpTo == Date(timeIntervalSince1970: 0)
    }

    // MARK: - The doors

    /// Open a story from the row through `StoryDoor`: our screen, our gesture, our animation.
    ///
    /// `pinned: false` is what makes this door different from the chat list's ringed avatar: the
    /// viewer pages person to person, and the row has a card for whoever you paged to, so the
    /// anchor follows.
    private func openStoryFromRow(_ g: StoryGroup) {
        let others = StoriesRepository.shared.others.filter { !StoryPrefs.isHidden($0.authorUid) }
        StoryDoor.open(g, among: g.isMine ? [g] + others : others, from: g.id, pinned: false,
                       // These came out of `StoriesRepository.others`, whose query is "recipientUids
                       // contains me" — so being here IS the author's audience choice, and the reply
                       // bar follows it rather than testing my chat list a second time.
                       deliveredToMe: true,
                       onProfile: { grp in profileGroup = grp })
    }

    /// The still-uploading card's door. Same presentation and same flight as a posted story; its
    /// content is the handoff view, which swaps itself for the real viewer when the upload lands.
    private func openUploadingStory() {
        StoryDoor.openUploading(meName: profile.me?.name ?? "You",
                                mePhoto: profile.me?.photoUrl,
                                onProfile: { grp in profileGroup = grp })
    }

    /// THE FEATURE FIRST, THE ALLOWANCE SECOND. Being told "that is today's limit" when stories are
    /// switched off for everybody would be a true sentence about the wrong thing.
    ///
    /// The database is still the enforcement and this is not a second one: `dailyLimitReached` is
    /// false whenever the count is unknown, so nothing here can lock somebody out on its own.
    private func composeStory() {
        guard AppLimits.shared.storiesEnabled else { storiesOff = true; return }
        if storyBudget.dailyLimitReached {
            storyLimitReached = true
            // The cached count said full — confirm it against the server, so a window that rolled
            // while the app sat open opens the composer on the next tap instead of a day later.
            Task { await storyBudget.refreshDailyBudget() }
        } else {
            // The door, not a cover binding — it presents the camera itself, so nothing needs to be
            // mounted on this screen or on the tab shell for it.
            StoryCameraDoor.open()
        }
    }

    private func storyCid(_ other: String) -> String {
        [AuthService.shared.uid ?? "", other].sorted().joined(separator: "_")
    }

    private func openStoryChat(_ g: StoryGroup) {
        path.append(ChatTarget(id: storyCid(g.authorUid), name: g.name, photo: g.photoUrl))
    }
}
