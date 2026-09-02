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
    /// The header's search field — his reference, 2026-09-02, has one sitting under the title.
    @State private var search = ""

    /// ⛔ 17, NOT 22 — owner, 2026-09-02, with "Glowing" ringed: "the text Glowing looks big".
    ///
    /// Measured off his own reference rather than adjusted by feel: the section heading there has a
    /// cap height of about 12pt, which is a 17pt face, and the 22 that was here was a guess at it.
    ///
    /// ⚠️ EVERY HEADING ON THE PAGE TAKES IT, not only the one he ringed. Friends and Glowing are
    /// the same kind of label, and two sizes for one kind of label is exactly the drift this page's
    /// card geometry has already been through once today.
    private static let sectionTitle = Font.system(size: 17, weight: .bold)

    /// A section heading that opens a page.
    ///
    /// ⛔ 44 TALL AND THE FULL WIDTH — owner, 2026-09-02: "the Glowing text touch area is so small,
    /// when I click the text at the same time a story opens". The heading was a bare `HStack`, which
    /// hugs its own words: about 80 by 22 points of target in a row 393 wide. A tap a few points off
    /// the letters missed it entirely and landed on the card underneath, which opens a story — so
    /// the miss did not feel like a miss, it felt like the wrong thing happening.
    ///
    /// `Spacer` + `contentShape` is what makes the whole row hittable rather than only the ink, and
    /// 44 is Apple's floor for a touch target. Nothing else lives on this row, so the width costs
    /// nothing.
    @ViewBuilder private func sectionHeading(_ title: String, route: GlowRoute) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: 4) {
                Text(title).font(Self.sectionTitle).foregroundStyle(.primary)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, GlowStoryCardView.margin)
            // ⛔ 34, DOWN FROM 44 — owner, 2026-09-02: "the spaces between the Glowing text and the
            // story card top and bottom, and between Friends and the cards, this is too much".
            //
            // ⚠️ THIS IS A TRADE AGAINST HIS OWN EARLIER REPORT AND IT STILL LANDS ON HIS SIDE. 44
            // was Apple's touch floor, taken after "the Glowing text touch area is so small"; the
            // complaint underneath that was that only the LETTERS were hittable — about 80 by 22
            // points. A 34pt row across the full 393 is still five times that area, and the eight
            // points come out of the dead air above and below the word, which is what he is
            // pointing at now.
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Stories")
                // ⛔ INLINE, THE SECOND HALF OF "make the header like this exactly" — his reference
                // centres a small "Stories" between the ••• and the bell/add capsule, with the
                // search field under it. A large title pushes the name onto its own line below the
                // buttons, which is the header he photographed and asked me to change.
                .navigationBarTitleDisplayMode(.inline)
                // ⛔ THREE BUTTONS, HIS REFERENCE: the ••• menu on the LEFT, and the bell and the
                // add-story mark together on the RIGHT — the two right-hand ones read as one glass
                // capsule in his mockup because iOS groups adjacent trailing items that way.
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { moreMenu }
                    ToolbarItem(placement: .topBarTrailing) { notificationsButton }
                    ToolbarItem(placement: .topBarTrailing) { addStoryButton }
                }
                // ⛔ THE SAME CALL THE CHAT LIST AND THE CALLS PAGE MAKE, placement and all — owner,
                // 2026-09-02: "make the story search bar exactly like the one on the chat list or
                // the calls page".
                //
                // ⚠️ THE PLACEMENT IS WHAT HE WAS SEEING, not the shape. This asked for
                // `.navigationBarDrawer(displayMode: .always)`, which pins the field open — and iOS
                // draws a PINNED field differently from a scrolling one: outlined on a light ground
                // rather than the filled grey the other two pages get. Two search fields in one app
                // that do not match, from one argument.
                //
                // I added `.always` off his earlier "the header must look exactly like this", where
                // the mockup showed the field sitting under a scrolled page. Matching the rest of
                // the app is the better reading of the same wish, and it is the one he has now
                // stated outright.
                .searchable(text: $search, prompt: "Search")
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
        } else if !search.trimmingCharacters(in: .whitespaces).isEmpty {
            // ⚠️ THE FIELD REPLACES THE PAGE RATHER THAN FILTERING IT IN PLACE. Friends is a UIKit
            // view that reads the repository itself, so there is no query to hand it; and a page
            // that keeps its shape while its contents shrink reads as broken anyway. One list of
            // matches, labelled by which section each came from.
            searchResults
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
                    // ⛔ THE STRIP GETS A HEADING TOO — owner, 2026-09-02: "add text for friends
                    // story… and when I click it show friends' stories". The grid layout has had
                    // one since it was built; the strip layout did not, so the same section was
                    // named on one design and anonymous on the other, and only one of them could be
                    // opened in full.
                    if hasGlowGrid { sectionHeading("Friends", route: .friends) }
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
                        friendsGrid()
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

    /// WHAT THE SEARCH FIELD FINDS: people with a live story, by name, across both sections.
    ///
    /// It searches the two things this page actually shows and nothing else. Searching the whole
    /// address book from here would answer a question the page is not asking — you are looking at
    /// stories, so you are looking for whose story to open.
    @ViewBuilder private var searchResults: some View {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let friends = StoriesRepository.shared.others
            .filter { !StoryPrefs.isHidden($0.authorUid) && $0.name.lowercased().contains(q) }
        let glowing = (glowStories.state.value ?? [])
            .filter { $0.person.name.lowercased().contains(q) }
        if friends.isEmpty && glowing.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !friends.isEmpty {
                        searchGroup("Friends") {
                            ForEach(friends) { g in
                                Button { openStoryFromRow(g) } label: {
                                    GlowStoryCardView(
                                        thumbUrl: g.stories.last.map { $0.thumbUrl.isEmpty ? $0.mediaUrl : $0.thumbUrl } ?? "",
                                        name: g.name,
                                        authorPhoto: g.photoUrl,
                                        rectKey: g.id)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if !glowing.isEmpty {
                        searchGroup("Glowing") {
                            ForEach(glowing) { c in
                                // Same split as the section this came from: the card is the story,
                                // the face on it is the person.
                                let key = "glow-\(c.person.id)"
                                Button { Task { await GlowStoryOpen.open(c.person, from: key) } } label: {
                                    GlowStoryCardView(card: c, rectKey: key) {
                                        path.append(GlowRoute.profile(c.person.id, c.person.name,
                                                                      c.person.photoUrl ?? ""))
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.top, 12)
            }
        }
    }

    /// One labelled block of result cards, in the same grid the sections themselves use.
    @ViewBuilder private func searchGroup<C: View>(_ title: String,
                                                   @ViewBuilder cards: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(Self.sectionTitle)
                .padding(.horizontal, GlowStoryCardView.margin)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: GlowStoryCardView.gutter),
                                GridItem(.flexible(), spacing: GlowStoryCardView.gutter)],
                      spacing: GlowStoryCardView.gutter) {
                cards()
            }
            .padding(.horizontal, GlowStoryCardView.margin)
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
    /// - Parameter showsHeading: false on the page the heading itself opens — a nav bar already
    ///   says "Friends" there, and a second one under it is the same word twice.
    @ViewBuilder private func friendsGrid(showsHeading: Bool = true) -> some View {
        let groups = StoriesRepository.shared.others.filter { !StoryPrefs.isHidden($0.authorUid) }
        // 4, matching the Glowing section — one gap under every heading on the page.
        VStack(alignment: .leading, spacing: 4) {
            if showsHeading { sectionHeading("Friends", route: .friends) }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: GlowStoryCardView.gutter),
                                GridItem(.flexible(), spacing: GlowStoryCardView.gutter)],
                      spacing: GlowStoryCardView.gutter) {
                // My own card first, wearing the ⊕ — his reference puts My Story at the front of
                // the grid exactly as it is at the front of the strip.
                // ⚠️ THE KEY IS THE GROUP'S OWN ID because `openStoryFromRow` opens `from: g.id`,
                // and it does not collide with the UIKit row's identical key: this grid is the
                // layout used INSTEAD of that row, never beside it.
                if let mine = StoriesRepository.shared.mine, let newest = mine.stories.last {
                    Button { openStoryFromRow(mine) } label: {
                        GlowStoryCardView(thumbUrl: newest.thumbUrl.isEmpty ? newest.mediaUrl : newest.thumbUrl,
                                          name: "My Story",
                                          authorPhoto: profile.me?.photoUrl,
                                          isMine: true,
                                          rectKey: mine.id)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(groups) { g in
                    Button { openStoryFromRow(g) } label: {
                        GlowStoryCardView(
                            thumbUrl: g.stories.last.map { $0.thumbUrl.isEmpty ? $0.mediaUrl : $0.thumbUrl } ?? "",
                            name: g.name,
                            authorPhoto: g.photoUrl,
                            rectKey: g.id)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, GlowStoryCardView.margin)
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
            // ⛔ 4, NOT 12 — the gap under a heading is the heading's own bottom air plus this, and
            // 12 on top of a 34pt row was reading as a blank band between the word and its cards.
            VStack(alignment: .leading, spacing: 4) {
                sectionHeading("Glowing", route: .stories)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: GlowStoryCardView.gutter),
                                    GridItem(.flexible(), spacing: GlowStoryCardView.gutter)],
                          spacing: GlowStoryCardView.gutter) {
                    if cards.isEmpty {
                        // Two empty cards while the pictures are fetched. They hold exactly the
                        // space the real ones will take, so nothing under them moves when they
                        // land — a placeholder that is a different size is just a slower jump.
                        ForEach(0..<2, id: \.self) { _ in
                            Color.primary.opacity(0.08)
                                .aspectRatio(GlowStoryCardView.aspect, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: GlowStoryCardView.corner,
                                                            style: .continuous))
                        }
                    } else {
                        ForEach(cards) { c in
                            // THE CARD OPENS THE STORY — his correction, 2026-09-02: "when I click
                            // story glowing, open story, don't open profile". The FACE on it opens
                            // the person; see `GlowStoryCardView.onAvatarTap`.
                            // ⚠️ A KEY OF ITS OWN, NOT the person's bare uid. The UIKit friends row
                            // registers `key(.storyRow, <uid>)` for ITS cards, and a friend you
                            // also have a Glow with would be two views claiming one key — the
                            // flight would land on whichever reported last.
                            let key = "glow-\(c.person.id)"
                            Button {
                                Task { await GlowStoryOpen.open(c.person, from: key) }
                            } label: {
                                GlowStoryCardView(card: c, rectKey: key) {
                                    path.append(GlowRoute.profile(c.person.id, c.person.name,
                                                                  c.person.photoUrl ?? ""))
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, GlowStoryCardView.margin)
            }
            // ⛔ 6, NOT 20 — the distance from the friends strip down to the Glowing heading. It was
            // 20 stacked on top of the heading's own top air and the strip's bottom label, which is
            // the widest of the three gaps he arrowed and the one he drew twice.
            .padding(.top, 6)
        }
    }

    /// The Stories tab's own pushes. A single enum so the tab's stack has one destination table
    /// rather than a `navigationDestination` per screen scattered through the file.
    enum GlowRoute: Hashable {
        case people
        /// All Glowing STORIES — what the "Glowing ›" heading opens. His correction, 2026-09-02:
        /// a section heading with a chevron promises more of THAT SECTION, and the section is
        /// stories. The people list belongs to the profile's stats card, where the question
        /// really is "who".
        case stories
        /// All FRIENDS' stories, the same grid the page falls back to when there is no Glowing
        /// section — owner, 2026-09-02: "add text for friends story, and when I click it show
        /// friends' stories". The strip shows four; this shows everybody.
        case friends
        case notifications
        case storyPrivacy
        case profile(String, String, String)   // uid, name, photo
    }

    @ViewBuilder func glowDestination(_ r: GlowRoute) -> some View {
        switch r {
        case .people:
            GlowPeopleListView(side: .glowers)
        case .stories:
            GlowStoriesGridView()
        case .friends:
            // The same grid the page draws when nothing sits under it — one definition, so the
            // full page and the no-Glow layout can never come to disagree about a card.
            ScrollView { friendsGrid(showsHeading: false).padding(.top, 4) }
                .navigationTitle("Friends")
                .navigationBarTitleDisplayMode(.inline)
        case .notifications:
            GlowNotificationsView()
        case .storyPrivacy:
            // ⛔ STRAIGHT TO THE REAL SETTINGS PAGE — his instruction, 2026-09-02: "in the 3 dot
            // button show story privacy, when the user clicks it go direct to the stories page in
            // settings". `StorySettingsView` is that page, the same one Settings pushes; a second
            // copy of those switches is how two screens come to disagree about one setting.
            StorySettingsView()
        case .profile(let uid, let name, let photo):
            // ⛔ THE ORDINARY PROFILE FOR ANOTHER PERSON — owner, 2026-09-02: "when I click a
            // profile you're showing me Glowers and Posted stories; that's the one I see when I
            // enter MY profile. Show a normal profile like the chat profile."
            //
            // `GlowProfileView` was built from his reference of HIS OWN page and stays that: the
            // stats card is a door to my own lists and the rail is my own stories with their view
            // counts. On somebody else it offers a card that cannot open and withholds everything
            // you actually want on a person — call, mute, media, disappearing messages — all of
            // which `ContactInfoView` already has, along with his Glow button.
            ContactInfoView(cid: storyCid(uid), name: name,
                            photoUrl: photo.isEmpty ? nil : photo, source: .story)
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
    ///
    /// ⛔ THE APP'S OWN MARK, NOT `plus.circle` — owner, 2026-09-02, sending the header he wants:
    /// the stacked cards with a plus, which is the glyph the Stories tab already wears in the tab
    /// bar. The tab and the button that fills it are one drawing; a generic ⊕ said "add something".
    ///
    /// ⚠️ An asset is sized by a `frame`, not by `font` — sizing a drawing with `font` does nothing
    /// at all, which is written up against the attach sheet's album button for the same reason.
    @ViewBuilder private var addStoryButton: some View {
        Button { composeStory() } label: {
            Image("ic_stories").renderingMode(.template).resizable().scaledToFit()
                .frame(width: 22, height: 22)
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
