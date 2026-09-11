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
    /// The person a long press asked to hide, and the alert that asks before it happens. The strip
    /// puts up a `UIAlertController` from its own presenter; a SwiftUI grid says it this way, with
    /// the same title, the same message and the same destructive button.
    ///
    /// Set by `friendActions`, presented by `hidePrompt` on the stack in `body`.
    @State private var hideTarget: StoryGroup?
    /// ⚠️ WHAT REDRAWS THE FRIENDS GRID AFTER A HIDE. `StoryPrefs.isHidden` is a `UserDefaults` read
    /// behind a static, so nothing about hiding somebody publishes anything for SwiftUI to observe —
    /// the row they were on would simply stay there until the next unrelated redraw. The UIKit strip
    /// has `prefsChanged()` for this and the chat list has its own tick; this is the same idea, read
    /// in the grid so the filter is re-run.
    ///
    /// Bumped by the hide alert's destructive button, read by `visibleFriends`.
    @State private var prefsTick = 0

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
            // ⛔ 14 ABOVE, 8 BELOW — owner, 2026-09-02: first "this is too much", then "not too
            // small, use Apple spaces". Both were right, and shrinking the box was the wrong lever.
            //
            // ⚠️ THE PROBLEM WAS THAT THE SPACE WAS SYMMETRIC. A `frame(height:)` centres the label,
            // so 44 gave 11 above and 11 below — and then a section gap was added underneath, which
            // put more air under the word than over it and made the heading float between its own
            // section and the one before. Apple's section heading, and the reference app's own
            // (`layoutMargins` 14/8 in `CLVTableDataSource`, measured earlier today), is
            // DELIBERATELY TOP-HEAVY: it belongs to what follows it, so the gap above is nearly
            // twice the gap below.
            //
            // Stated as padding rather than a height, the row still comes out about 44 — his touch
            // target is back, and the space is where Apple puts it instead of split down the middle.
            .padding(.top, 14)
            .padding(.bottom, 8)
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
        // ⛔ THE STRIP'S HIDE CONFIRMATION, SAID IN SwiftUI — the grids' Hide entry raises this
        // rather than hiding on the spot, because the strip has asked first since it was built and
        // one action must not be two different promises. `StoriesRow.confirmHide` puts up a
        // `UIAlertController` from its own presenter; a grid has none to reach for, so the same
        // alert is stated here with the same title, the same sentence and the same destructive
        // button. Change one and change both.
        //
        // ⚠️ ON THE STACK, NOT ON A GRID. Friends is one layout of this page, the "All story
        // friends" page pushed on this same stack is another, and both raise it — an alert hung on
        // either one would be missing from the other.
        .alert("Hide Stories?", isPresented: hidePrompt, presenting: hideTarget) { g in
            Button("Hide Stories", role: .destructive) {
                StoryPrefs.setHidden(g.authorUid, true)
                // What takes them off the grid — see `visibleFriends`.
                prefsTick += 1
            }
            Button("Cancel", role: .cancel) {}
        } message: { g in
            Text("New story updates from \(g.name.isEmpty ? "this person" : g.name) "
                 + "won't appear at the top of the stories list anymore.")
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
                    // ⚠️ A DEBUG BAND, FOR ONE BUILD ONLY — 2026-09-09. It draws nothing unless
                    // `StoryPressDebug.on`, which goes back to false in the very next build. The
                    // long press on the grids below has now been reported dead six times and every
                    // fix so far was reasoned out of the source rather than measured. These three
                    // lines say which of the three failures it actually is. See `StoryPressDebug`.
                    StoryPressDebugReadout()
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
                               // ⛔ THE ORDER IS HELD FOR THE SESSION, THE RINGS ONLY WHILE THE
                               // VIEWER IS UP — owner, 2026-09-11. See
                               // `StoryDoorState.orderHeldForSession`: closing a story greys its
                               // ring at once and moves nothing; the row re-sorts when he leaves
                               // the tab and comes back, which is where the hold is dropped.
                               freezeOrder: storyDoorState.isOpen || storyDoorState.orderHeldForSession,
                               freezeRings: storyDoorState.isOpen,
                               onCompose: { composeStory() },
                               onOpen: { g in openStoryFromRow(g) },
                               onMessage: { g in openStoryChat(g) },
                               onProfile: { g in profileGroup = g },
                               onOpenUploading: { openUploadingStory() },
                               onPostedStories: { g in path.append(GlowRoute.postedStories(g.name)) })
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
    ///
    /// ⛔ AND THE ANSWER IT ARRIVES AT COUNTS — owner, 2026-09-05, with two grey boxes on his screen:
    /// "when user doesn't have glowing story it's showing skeleton screen… when it's empty it's
    /// empty, friends story make full".
    ///
    /// ⚠️ THE SKELETON WAS THE *LOADING* STATE AND NOTHING EVER TOOK IT DOWN. `glowSection` drew it
    /// on `cards.isEmpty`, and `cards` is `state.value ?? []` — which is empty both while the fetch
    /// is in flight AND when the fetch has come back with nothing. Those are not the same fact.
    /// Somebody with a Glow whose glows have simply not posted anything sat under two grey
    /// rectangles for ever, because there was no story coming to replace them.
    ///
    /// `GlowLoad` has always been able to tell the difference; this just asks it. The distinction
    /// also keeps the flicker fix above intact rather than trading one report for the other:
    ///
    ///   • no relationship            → false from the first frame, as before. No flip.
    ///   • relationship, loading      → TRUE, so the strip and the skeletons hold the space. This is
    ///                                  the case his 2026-09-02 report was about, and it still
    ///                                  behaves the way that fix made it behave.
    ///   • relationship, loaded, full → TRUE, and it was already TRUE a moment ago. No flip.
    ///   • relationship, loaded, EMPTY → false. The section goes, and Friends takes the whole page.
    ///   • failed                     → false. Two grey boxes are a worse answer to a failed fetch
    ///                                  than simply not claiming there is a section.
    ///
    /// The last two are the only shape change, it happens once when the load settles, and it is the
    /// one he asked for. There is no way to have it without a change of shape short of holding the
    /// whole page back until the glow fetch returns, which would delay Friends for everybody to
    /// spare this case.
    private var hasGlowGrid: Bool {
        guard !glow.glowRelationship.isEmpty else { return false }
        switch glowStories.state {
        case .loading:          return true
        case .loaded(let c):    return !c.isEmpty
        case .failed:           return false
        }
    }

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
        let groups = visibleFriends
        // 0, matching the Glowing section — the heading carries its own 8 below.
        VStack(alignment: .leading, spacing: 0) {
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
                } else {
                    // ⛔ AND WHEN THERE IS NO STORY YET, THE SAME CARD IS THE WAY TO POST ONE —
                    // owner, 2026-09-11, on a fresh account: "when i create new account, add story
                    // card is not appearing".
                    //
                    // ⚠️ THE GRID HAD NO DOOR TO THE COMPOSER AT ALL. The branch above is gated on
                    // `mine` AND on that group holding a story, which is exactly the state a new
                    // account is not in — so the page drew its "Friends" heading over nothing, with
                    // no way to post from the screen whose whole purpose is posting. The UIKit strip
                    // has always had its compose card (`onCompose`), and this grid is the layout
                    // used INSTEAD of that strip, so losing it here lost it outright.
                    //
                    // It is deliberately the same card rather than a second design: same face, ring,
                    // badge, corner and aspect as the My Story card it becomes the moment something
                    // is posted, so the page does not change shape when the first story lands.
                    Button { composeStory() } label: {
                        GlowStoryCardView(thumbUrl: "",
                                          name: "Add Story",
                                          authorPhoto: profile.me?.photoUrl,
                                          isMine: true,
                                          isAdd: true)
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
            // ⛔ THE HOLD, WHICH THIS LAYOUT HAS NEVER HAD — owner, 2026-09-05: a long press does
            // nothing on the grids. The press itself was written and left unattached; this is its
            // call site. Same menu as the strip's cards, so the layout a person is looking at does
            // not change what a hold on their card offers. See `GlowCardPress`.
            .glowCardLongPress { friendsGridTarget(at: $0) }
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
            // 0 — the heading owns the 8 under its own words now, and anything here is added on top
            // of it. See `sectionHeading`.
            VStack(alignment: .leading, spacing: 0) {
                sectionHeading("Glowing", route: .stories)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: GlowStoryCardView.gutter),
                                    GridItem(.flexible(), spacing: GlowStoryCardView.gutter)],
                          spacing: GlowStoryCardView.gutter) {
                    if cards.isEmpty {
                        // Two empty cards while the pictures are fetched. They hold exactly the
                        // space the real ones will take, so nothing under them moves when they
                        // land — a placeholder that is a different size is just a slower jump.
                        //
                        // ⚠️ THIS BRANCH IS NOW ONLY REACHABLE WHILE THE LOAD IS IN FLIGHT, and that
                        // is the whole of his 2026-09-05 fix. `cards` is `state.value ?? []`, which
                        // is also empty when the fetch has RETURNED with nothing — and this used to
                        // draw the same two grey boxes for that, for ever, because no story was
                        // coming to replace them. `hasGlowGrid` now collapses the section on a
                        // loaded-empty or failed result, so by the time control reaches here the
                        // only reason `cards` can be empty is that the answer has not arrived yet.
                        // Do not "simplify" this by reading `cards.isEmpty` on its own again.
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
                // ⛔ THE HOLD ON A GLOWING CARD — owner, 2026-09-05: a long press does nothing here.
                // The placeholder branch above registers no rects at all, so while the pictures are
                // still coming a press finds no card and returns — which is the right answer for two
                // grey boxes. See `GlowCardPress` for why this is a `.background` and not a
                // `.contextMenu`.
                .glowCardLongPress { glowGridTarget(at: $0) }
                // ⛔ 10 BETWEEN THE HEADING AND THE FIRST CARD — owner, 2026-09-05, with that gap
                // ringed: "add space between the Glowing text and the story".
                //
                // ⚠️ HERE AND NOT IN `sectionHeading`, WHICH IS THE WHOLE POINT. That heading's 14
                // above and 8 below are the chat list's own numbers, taken from the reference app's
                // source on his instruction, and Friends wears the same heading — moving them would
                // change a heading he has already settled and drag the other section with it.
                //
                // 10 IS NOT A TASTE, IT IS THE NUMBER THE FRIENDS SECTION ALREADY HAS. The strip
                // under the Friends heading carries `StoryRowMetrics.vPad` = 10 of its own air above
                // its cards, so a friend's card starts 8 + 10 = 18 below the word. The Glowing grid
                // had no such inset, so its cards started at 8 — and two sections whose headings sit
                // at different heights above their own content is exactly what he was looking at.
                // With this the two are identical, and the number came off the page rather than out
                // of my eye.
                //
                // ⚠️ NOT ADDED TO THE `VStack`'s SPACING, which is 0 deliberately (see the note
                // below): spacing there would also push the section away from what is above it.
                .padding(.top, 10)
            }
            // ⛔ NOTHING — owner, 2026-09-02: "Glowing, copy the spacing from the chat list's Chats
            // text; use the top and bottom it uses".
            //
            // The chat list's headings carry 14 above and 8 below and NOTHING else: its list margin
            // is 0 and its section spacing is 0, which is the reference app's rule read from source
            // ("we do not want that spacing") and the reason his chat list looks right. This page
            // added 8 on top of that, so the same heading sat 22 from what came before it there and
            // 14 here. One number for one kind of label, across both pages.

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
        /// MY posted stories, the page the profile's "See All" opens — owner, 2026-09-11: "when I
        /// long press my story and click Posted Stories it just opens the story; make it open my
        /// owner page posted stories, I already have that page."
        case postedStories(String)             // my display name for the title
    }

    @ViewBuilder func glowDestination(_ r: GlowRoute) -> some View {
        switch r {
        case .people:
            GlowPeopleListView(side: .glowers)
        case .stories:
            GlowStoriesGridView()
        case .friends:
            // ⛔ THE POSTED STORIES GRID, NOT THE GLOWING ONE — owner, 2026-09-09, with this page
            // photographed twice: "cards and corners it will be same like page posted stories".
            //
            // ⚠️ THIS REVERSES HIS 2026-09-02 CHOICE AND BOTH WERE RIGHT WHEN MADE. That day he
            // photographed this page and asked for the Glowing grid, so it took two wide columns.
            // Today he photographed it again, full of cards too big to read, and named the posted
            // stories page as the thing to match. Three tighter columns is that page's geometry, and
            // it now comes from one place so the two cannot drift.
            //
            // ⚠️ IT USED TO CALL `friendsGrid`, WHICH IS THE STORIES TAB'S OWN SECTION — a `VStack`
            // carrying its heading, its top padding and its section spacing, all of which are that
            // page's business and none of which belong on a page of its own. That stays true; only
            // the numbers below have changed.
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: StoryTileGrid.gap),
                                         count: StoryTileGrid.columns),
                          spacing: StoryTileGrid.gap) {
                    // ⛔ NO "MY STORY" ON THIS PAGE — owner, 2026-09-11, with it ringed: "when i
                    // click all friends story page, only show friends story, not my owner story."
                    //
                    // The card belongs on the TAB, where the section is the row you post from and
                    // yours is the first thing in it. This page is what the "Friends" heading opens,
                    // and it answers one question — what have my friends posted. My own story is not
                    // an answer to it, and it is already two taps away in both directions.
                    ForEach(visibleFriends) { g in
                        let key = Self.friendsPageKey(g.id)
                        Button { openStoryFromRow(g, sourceKey: key) } label: {
                            GlowStoryCardView(
                                thumbUrl: g.stories.last.map { $0.thumbUrl.isEmpty ? $0.mediaUrl : $0.thumbUrl } ?? "",
                                name: g.name,
                                authorPhoto: g.photoUrl,
                                rectKey: key,
                                corner: StoryTileGrid.corner)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, StoryTileGrid.margin)
                .padding(.top, 8)
                // The same hold as the section this page opens from — the cards are the shared
                // thing and so is what a press on one offers. Its own `ScrollView`, so the press
                // installs on this page's scroller rather than the tab's.
                .glowCardLongPress {
                    friendsGridTarget(at: $0, corner: StoryTileGrid.corner,
                                      key: Self.friendsPageKey)
                }
            }
            .navigationTitle("Friends")
            .navigationBarTitleDisplayMode(.inline)
            // A pushed page is not a tab — the same rule the Glow pages took, and the reason his
            // last row sat under the floating bar.
            .toolbar(.hidden, for: .tabBar)
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
        case .postedStories(let name):
            // ⛔ THE PAGE THAT ALREADY EXISTS, NOT A SECOND ONE — his words, and the reason this is
            // a route rather than anything new: the profile's "See All" pushes exactly this view
            // with exactly these arguments, so the hold menu and the profile arrive at one screen
            // with one filter, one select mode and one set of numbers.
            PostedStoriesView(uid: AuthService.shared.uid ?? "", isMe: true, title: name)
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
            // ⛔ HIS NEW MARK, AND THE PLUS IS NOT DECORATION — owner, 2026-09-11: "when you use
            // this inside the circle add a + icon, that means add". The same stacked-cards drawing
            // the tab bar now wears, plus the sign that turns "stories" into "add a story". Without
            // it this button and the tab beside it are the same picture meaning two different
            // things, which is the one thing the note above was already protecting against.
            //
            // ⚠️ THE PLUS IS AN OVERLAY, NOT A SECOND ASSET. Knocking it out of the artwork would
            // mean a third SVG to keep in step with the other two by hand, and a hole in a template
            // image has to be real geometry rather than a white shape — the trap written up on
            // `ic_stories_fill`. A `plus` laid on the corner takes the same template tint, so it
            // cannot drift in colour, and it needs no background disc of its own: the glass behind
            // this button is not a colour this file knows.
            //
            // ⚠️ BOTTOM-TRAILING AND OUTSIDE THE MARK'S OWN BOX. The offset pushes it clear of the
            // lower card's corner so the two shapes read as separate rather than as one smudge, and
            // `.heavy` keeps it legible at eleven points against a filled drawing.
            Image("ic_stories_stack_fill").renderingMode(.template).resizable().scaledToFit()
                .frame(width: 22, height: 22)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .heavy))
                        .offset(x: 4, y: 3)
                }
        }
    }

    @ViewBuilder private var notificationsButton: some View {
        NavigationLink(value: GlowRoute.notifications) {
            // ⛔ THE APP'S OWN BELL — 2026-09-11 consistency pass. This was `Image(systemName:
            // "bell")`, an SF Symbol, sitting in the SAME toolbar as `addStoryButton`'s `ic_stories`
            // drawing a few points away: two icon families in one bar, which is exactly what he
            // means by the app feeling like several people made it. `ic_bell` already exists and is
            // already what the contact page's mute control uses.
            //
            // ⚠️ SIZED BY A `frame`, NOT BY `font`, and drawn as a template so it takes the tint —
            // an asset ignores `font` entirely. Same 22 as the `ic_stories` button beside it, which
            // is what makes the pair read as one bar. Both notes are written up on that button.
            Image("ic_bell").renderingMode(.template).resizable().scaledToFit()
                .frame(width: 22, height: 22)
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

    // MARK: - The grids' long press

    /// THE FRIENDS THIS PAGE SHOWS: everybody with a live story who has not been hidden.
    ///
    /// ⚠️ `prefsTick` IS READ HERE ON PURPOSE, and this is the property that read exists for.
    /// `StoryPrefs.isHidden` is a `UserDefaults` read behind a static, so hiding somebody publishes
    /// nothing at all — without a touch of the tick inside the filter itself, the person you just
    /// hid stays on the grid until some unrelated redraw takes them off. The archive page's
    /// `archivedStories` is the same three lines for the same reason.
    ///
    /// ⚠️ ONE FILTER, TWO GRIDS. The Friends section and the "All story friends" page both ask this,
    /// so a hide from either one takes effect on both.
    private var visibleFriends: [StoryGroup] {
        _ = prefsTick
        return StoriesRepository.shared.others.filter { !StoryPrefs.isHidden($0.authorUid) }
    }

    /// WHICH CARD ON A FRIENDS GRID IS UNDER THE FINGER, and what its menu says. Asked at press
    /// time, so it describes the grid as it stands rather than as it stood at layout — the same
    /// contract `StoriesRow.menuTarget` keeps for the strip.
    ///
    /// ⚠️ MY OWN CARD IS TESTED FIRST because it is drawn first, and under the SAME condition the
    /// grid draws it under. Testing it unconditionally would offer "Posted Stories" over a card
    /// that is not on the screen when I have posted nothing.
    ///
    /// ⚠️ `corner` IS PASSED IN BECAUSE THE SAME HELPER SERVES TWO SURFACES. The tab's friends grid
    /// draws its cards at the card's own 34; the pushed all-friends page draws them at the tile
    /// corner. The lift has to be cut with whichever the card under the finger was drawn with.
    /// ⚠️ `key` MAPS A GROUP ID TO THE KEY THE CARD ACTUALLY REGISTERED, and the pushed page passes
    /// its own. A press has to look under the same string the card filed itself under or it finds
    /// the other screen's card — see `openStoryFromRow`.
    private func friendsGridTarget(at p: CGPoint,
                                   corner: CGFloat = GlowStoryCardView.corner,
                                   key: (String) -> String = { $0 }) -> StoryMenuTarget? {
        if let mine = StoriesRepository.shared.mine, !mine.stories.isEmpty,
           let t = GlowCardPress.target(key(mine.id), at: p, actions: myStoryActions(mine),
                                        corner: corner) {
            return t
        }
        for g in visibleFriends {
            if let t = GlowCardPress.target(key(g.id), at: p, actions: friendActions(g),
                                            corner: corner) { return t }
        }
        return nil
    }

    /// The all-friends page's key namespace. The same shape the all-Glowing page already uses.
    private static func friendsPageKey(_ id: String) -> String { "friendspage-\(id)" }

    /// The same question for the Glowing grid.
    ///
    /// ⚠️ THE KEY IS `glow-<uid>`, NOT THE BARE UID, and it has to be the one the card registers or
    /// the lift photographs the wrong card — see the note at the grid itself, where the same string
    /// is built for `rectKey`.
    private func glowGridTarget(at p: CGPoint) -> StoryMenuTarget? {
        for c in (glowStories.state.value ?? []) {
            if let t = GlowCardPress.target("glow-\(c.person.id)", at: p,
                                            actions: glowActions(c.person)) { return t }
        }
        return nil
    }

    /// ⛔ THE STRIP'S OWN MENU FOR A FRIEND, WORD FOR WORD AND IN ITS ORDER — the rule the archive
    /// strip was already held to on 2026-08-25 ("why is it different, use the long press like it
    /// does the regular time"). The same person's card in the strip and on the grid must answer a
    /// hold the same way; the layout is the only thing that differs between them.
    private func friendActions(_ g: StoryGroup) -> [CMAction] {
        [CMAction(title: "Send Message", icon: "message") { openStoryChat(g) },
         CMAction(title: "Open Profile", icon: "person.crop.circle") { profileGroup = g },
         // The alert, not the hide: `StoryPrefs.setHidden` happens on the confirmation. See
         // `hideTarget`.
         CMAction(title: "Hide Stories", icon: "archivebox", destructive: true) { hideTarget = g }]
    }

    /// My own card's menu, the strip's again: the one action a card of my own stories offers that a
    /// tap does not, plus the compose the ⊕ on it already performs.
    private func myStoryActions(_ mine: StoryGroup) -> [CMAction] {
        // ⛔ "Posted Stories" OPENS THE PAGE, NOT THE VIEWER — owner, 2026-09-11: "when I click
        // Posted Stories it just opens the story; open my owner page posted stories, I already
        // have that page." It called `openStoryFromRow`, which is the story DOOR — the same thing
        // a plain tap on the card does, so the entry was a second name for the tap.
        //
        // ⚠️ `mine` IS STILL THE ARGUMENT, and only for the title. The page reads my own uid and
        // loads its own grid; passing the group's name keeps the header saying what the profile's
        // own "See All" makes it say.
        [CMAction(title: "Add Story", icon: "ic_stories") { composeStory() },
         CMAction(title: "Posted Stories", icon: "circle.dashed") {
             path.append(GlowRoute.postedStories(mine.name))
         }]
    }

    /// A GLOWING CARD'S MENU. A glower is somebody else with a live story, so it is the same two
    /// entries a friend's card offers — one hold, one answer, wherever the app draws a person's
    /// story.
    ///
    /// ⛔ NO "HIDE STORIES", AND THAT IS DELIBERATE RATHER THAN FORGOTTEN. `StoryPrefs.isHidden`
    /// filters `StoriesRepository.others` — the FRIENDS list — and nothing filters this grid, which
    /// comes from the glow relationship. The entry would leave the card exactly where it is while
    /// quietly taking the same person off Friends: an action that appears to fail where it is
    /// offered and works somewhere the person is not looking. If he asks for it, the fix is to
    /// filter this grid too, not to add the button on its own.
    private func glowActions(_ p: GlowPerson) -> [CMAction] {
        [CMAction(title: "Send Message", icon: "message") {
            // The same push `openStoryChat` makes; it takes a `StoryGroup` and a glow card has a
            // person, so the cid is built here from the same helper.
            path.append(ChatTarget(id: storyCid(p.id), name: p.name, photo: p.photoUrl))
         },
         // Exactly what the FACE on this card does, so one action cannot mean two things.
         CMAction(title: "Open Profile", icon: "person.crop.circle") {
            path.append(GlowRoute.profile(p.id, p.name, p.photoUrl ?? ""))
         }]
    }

    /// The hide alert's presentation, derived from `hideTarget` rather than kept beside it as a
    /// second flag — two pieces of state for one question is how an alert comes to be on screen
    /// with nobody to act on.
    private var hidePrompt: Binding<Bool> {
        Binding(get: { hideTarget != nil }, set: { if !$0 { hideTarget = nil } })
    }

    // MARK: - The doors

    /// Open a story from the row through `StoryDoor`: our screen, our gesture, our animation.
    ///
    /// `pinned: false` is what makes this door different from the chat list's ringed avatar: the
    /// viewer pages person to person, and the row has a card for whoever you paged to, so the
    /// anchor follows.
    /// ⚠️ `sourceKey` DEFAULTS TO THE GROUP'S ID AND THE PUSHED PAGE OVERRIDES IT — his report,
    /// 2026-09-09: closing a story returns to the right place from the friends strip, and does not
    /// from the all-friends page.
    ///
    /// ⛔ THE REGISTRY HOLDS ONE VIEW PER KEY. The tab's own friends grid and the pushed page both
    /// drew their cards under the bare `g.id`, and both are alive at once — a pushed page does not
    /// dismantle the root beneath it. Whichever registered last owned the key, so the story opened
    /// from the page flew back to the card on the TAB, which is behind it and usually off screen.
    /// The all-Glowing page was given a prefix of its own when it was built and does not have this;
    /// the all-friends page was not, and that asymmetry is the whole bug.
    ///
    /// ⛔ AND THE KEY IS PINNED WHENEVER THE PAGE GAVE US ONE. An unpinned door lets the viewer
    /// republish the source key as each person comes up, which is right for the STRIP — it scrolls
    /// itself to whoever is on screen, so the card to land on is always the freshly published one.
    /// A grid does not scroll to the active person, so paging past a friend whose card is below the
    /// fold would republish a key with no visible card behind it and the pull-down would go dead.
    /// The page hands us its own namespaced key precisely because its cards are all on one screen.
    private func openStoryFromRow(_ g: StoryGroup, sourceKey: String? = nil) {
        let others = StoriesRepository.shared.others.filter { !StoryPrefs.isHidden($0.authorUid) }
        StoryDoor.open(g, among: g.isMine ? [g] + others : others, from: sourceKey ?? g.id,
                       pinned: sourceKey != nil,
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
