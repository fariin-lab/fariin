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
    var onSignOut: () -> Void = {}

    private var profile = ProfileStore.shared
    // (No `StoriesRepository` property: `StoriesRow` is UIKit and observes the repository
    // itself, so a copy here would be a second subscription that changes nothing.)
    private var storyDoorState = StoryDoorState.shared
    private var storyBudget: StoriesService { StoriesService.shared }

    @State private var path = NavigationPath()
    @State private var profileGroup: StoryGroup?
    /// The server says this account may not post a story at all — see `AppLimits.storiesEnabled`.
    @State private var storiesOff = false
    @State private var storyLimitReached = false
    @AppStorage("storiesOptedOut") private var storiesOptedOut = false

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Stories")
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
                    StoriesRow(meName: profile.me?.name ?? "You", mePhoto: profile.me?.photoUrl,
                               // HOLD THE ROW STILL WHILE A STORY IS OPEN. Watching someone's last
                               // unseen story re-sorts the row live, so their card slid out from
                               // under the close before it could land on it.
                               freezeOrder: storyDoorState.isOpen,
                               onCompose: { composeStory() },
                               onOpen: { g in openStoryFromRow(g) },
                               onMessage: { g in openStoryChat(g) },
                               onProfile: { g in profileGroup = g },
                               onOpenUploading: { openUploadingStory() })
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
