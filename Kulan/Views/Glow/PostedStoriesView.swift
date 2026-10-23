import SwiftUI
import UIKit

/// POSTED STORIES, FULL PAGE — his requirement 6: a header, a Filter button top right, and filter
/// options for My Friends / Custom / Glowers.
///
/// ⚠️ THE FILTER IS OVER THE AUDIENCE A STORY WAS POSTED TO, which is a fact frozen onto the story
/// at post time and never recomputed — the same `audience` label the author's own header shows.
/// That is what makes the filter honest: it groups by what was actually chosen when the story went
/// out, not by who happens to be a glower today. Changing your glow list cannot re-file an old
/// story, for the same reason editing a list cannot reach one.
struct PostedStoriesView: View {
    let uid: String
    var isMe: Bool = false
    var title: String = ""

    /// Explicit, for the private-stored-property rule - see the note in GlowProfileView.
    init(uid: String, isMe: Bool = false, title: String = "") {
        self.uid = uid; self.isMe = isMe; self.title = title
    }

    /// The audiences a story can have been posted to, as the filter offers them. `everyone` is
    /// included because it exists and a filter that cannot show one of the four would hide stories
    /// with no way to find them; his three named ones are the rest.
    enum Filter: String, CaseIterable, Identifiable {
        /// ⛔ HIS ORDER — owner, 2026-09-11: "All posted stories / My friends / Glowers / all
        /// Custom". Glowers ahead of Custom is his, not alphabetical.
        /// `oneTime` last: owner, 2026-10-11, "add a once view option" — a View once story was filed
        /// under My Chats with nothing to tell it apart.
        case all, friends, glowers, custom, oneTime
        var id: String { rawValue }
        /// The filters the menu offers. Glowers goes with the Glow feature (owner, 2026-10-11:
        /// "I hid that feature, why is it still showing").
        static var shown: [Filter] { AppFeatures.glow ? allCases : allCases.filter { $0 != .glowers } }
        /// ⛔ THE WHOLE LABEL, AND NOTHING ELSE — owner, 2026-09-11: "the posted stories texts, fix
        /// please, users feel confused, just make it minimalist".
        ///
        /// ⚠️ THE MENU CARRIED THE EXPLANATION TOO. Each row read "My Friends — Stories visible to
        /// your friends", which wrapped onto three lines and turned a four-item filter into a wall
        /// of prose the width of the screen. The sentence was added so the filter would explain
        /// itself; it is still doing that where it belongs — see `explain`, which the EMPTY STATE
        /// shows, at the moment somebody actually needs to know why a filter found nothing.
        var title: String {
            switch self {
            case .all: return "All posted stories"
            case .friends: return "My Chats"
            case .glowers: return "Glowers"
            case .custom: return "All Custom"
            // The words the story's own header uses for it (`storyAudienceTitle`).
            case .oneTime: return "View once"
            }
        }
        /// What it means in one line, his "the filtering behaviour should be clear and easy to
        /// understand" — shown under the option rather than left to be guessed.
        var explain: String {
            switch self {
            case .all: return "Every story you have posted that is still live"
            case .friends: return "Stories visible to everyone you chat with"
            case .custom: return "Stories shared with a custom audience"
            case .glowers: return "Stories shared with your Glowers"
            case .oneTime: return "Stories each person can watch once"
            }
        }
        /// ⚠️ MATCHES THE STORY'S OWN LABEL. "everyone" is deliberately counted as a friends-visible
        /// story here: an Everyone story reaches every chat you have accepted AND the profile, so
        /// hiding it from the My Friends filter would be a lie about who can see it.
        func matches(_ s: PostedStory) -> Bool {
            let audience = s.audience
            switch self {
            case .all: return true
            case .friends: return audience == "friends" || audience == "everyone"
            case .custom: return audience == "custom"
            case .glowers: return audience == "glowers"
            case .oneTime: return s.oneTime == true
            }
        }
    }

    /// One folder of the All view: an audience and its stories, newest first as `rows` already is.
    struct PostedFolder: Identifiable {
        let id: String
        let name: String
        /// The audience kind: "everyone" | "friends" | "glowers" | "custom".
        let kind: String
        var rows: [PostedStory]
    }

    /// Stories grouped by the audience they were posted to. A custom list is named by what it was
    /// called when the story went out (`StoryPrefs.audienceName`, kept on this phone), so two lists
    /// are two folders; a custom story whose name this phone never saw goes under "Custom".
    /// The Share Story sheet's audience badge, scaled from its 40pt to 28pt with the same
    /// proportions: Everyone wears my own face, My Chats the orange people circle, a custom list my
    /// folder drawing on grey, Glowers the glow mark.
    @ViewBuilder static func folderBadge(_ kind: String) -> some View {
        let d: CGFloat = 28
        if kind == "everyone" {
            AvatarView(name: ProfileStore.shared.me?.name ?? "You",
                       photoUrl: ProfileStore.shared.me?.photoUrl, size: d)
        } else {
            ZStack {
                Circle().fill((kind == "custom" ? Color.gray : kind == "glowers" ? Color.primary : Color.orange).gradient)
                if kind == "custom" {
                    Image("ic_story_folder_fill").renderingMode(.template).resizable().scaledToFit()
                        .frame(width: d * 23 / 40, height: d * 23 / 40)
                        .foregroundStyle(.white)
                } else if kind == "glowers" {
                    GlowStyle.mark(d * 23 / 40).foregroundStyle(Color(.systemBackground))
                } else {
                    Image(systemName: "person.2.fill").font(.system(size: d * 17 / 40, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: d, height: d)
        }
    }

    /// `mergeCustom`: every custom list in ONE "Custom" folder. The All filter asks for that, and
    /// All Custom does not, so that one is where the lists are told apart (owner, 2026-10-11).
    static func folders(_ rows: [PostedStory], mergeCustom: Bool = false) -> [PostedFolder] {
        var out: [PostedFolder] = []
        var at: [String: Int] = [:]
        for s in rows {
            let name: String
            // The folder's kind. ⚠️ An audience word this page does not know is My Chats, the same
            // default every reader of the label uses, and it joins THAT folder: keyed by the raw word,
            // it opened a second "My Chats" heading (owner's screenshot, 2026-10-11).
            var kind = s.audience
            if s.oneTime == true {
                // A View once story gets its own folder, whoever it went to (owner, 2026-10-11).
                kind = "oneTime"
                name = "View once"
            } else {
                switch s.audience {
                case "everyone": name = "Everyone"
                case "friends":  name = "My Chats"
                case "glowers":  name = "Glowers"
                case "group":    name = "Group Stories"
                case "custom":   name = mergeCustom ? "Custom"
                                     : (StoryAudienceStore.shared.storyName(s.id)
                                        ?? StoryPrefs.audienceName(storyId: s.id) ?? "Custom")
                default:         name = "My Chats"; kind = "friends"
                }
            }
            let key = kind + ":" + name
            if let i = at[key] { out[i].rows.append(s) }
            else { at[key] = out.count; out.append(PostedFolder(id: key, name: name, kind: kind, rows: [s])) }
        }
        return out
    }

    /// One posted story's tile, with its tap, its select tick and its hold menu. One builder for
    /// the flat grid and for the folders, so the two cannot drift.
    @ViewBuilder private func postedTile(_ s: PostedStory) -> some View {
        // ⛔ THE CELL OPENS THE STORY — owner, 2026-09-02: "when I click a story
        // it is not opening". Same omission as the profile's rail: the tile was
        // drawn and never wired to anything.
        // ⛔ `PostedStoryTile`, THE PROFILE'S OWN TILE — owner, 2026-09-11: "the
        // views count is pointing centre of the image". This page had a SECOND tile
        // of its own, `PostedStoryGridTile`, drawn from the same description, and
        // the two disagreed about one thing: the profile's stacks its badge in a
        // `ZStack(alignment: .bottomLeading)` and this one laid it on with
        // `.overlay(alignment: .bottomLeading)` carrying TWO conditional children —
        // a scrim that fills the height and a label. The label came out centred.
        //
        // The profile's card has always drawn it in the right corner, which is the
        // proof of which of the two forms to keep. So the duplicate is gone rather
        // than repaired: the design pass on 2026-09-11 had already named these two
        // as the same tile at different sizes, and one tile cannot drift from
        // itself. It brings its own Button, so the wrapper here goes with it.
        PostedStoryTile(story: s, rectKey: Self.tileKey(s.id)) {
            // In select mode the tap CHOOSES rather than opens. Two meanings
            // for one gesture, told apart by the mode the bar is announcing.
            if editing { withAnimation(.snappy(duration: 0.18)) { toggle(s.id) } }
            else { openStory(s) }
        }
        .overlay(alignment: .topLeading) {
            if editing { tick(on: selected.contains(s.id)) }
        }
        // ⛔ THE HOLD MENU — owner, 2026-09-11: "when I long press show a
        // context menu: Edit viewers, Share, Delete". Mine only, and off in
        // select mode: a hold while ticking is a hold on a thing that is
        // already being chosen for one of these very actions.
        .contextMenu {
            if isMe, !editing, let full = myStory(s.id) {
                Button { editViewersFor = full } label: {
                    Label("Edit Viewers", systemImage: "person.2")
                }
                // ⛔ AND NOT EVERY STORY MAY BE PASSED ON — his spec,
                // 2026-09-11. `StoryShareRights` is the one place that answers
                // it, so this menu, the story viewer's footer and anything added
                // later cannot disagree. Here it is my own story, so what it
                // rules out is the pair of flags that say "do not copy this":
                // one-time, and capture-protected.
                if StoryShareRights.allows(full) {
                    Button {
                        // The story's address, not the storage file's — see
                        // `shareSelected` for what that used to hand out.
                        // The app's own share sheet: chats to send it to, and Copy Link
                        // (owner, 2026-10-11 — which is why there is no Copy Story Link row).
                        if let u = URL(string: KulanApp.storyLink(id: full.id)) {
                            sendLink = StoryLinkPayload(url: u)
                        }
                    } label: {
                        Label { Text("Share") } icon: { Image("ic_link_share").renderingMode(.template) }
                    }
                }
                Button(role: .destructive) {
                    selected = [s.id]
                    confirmDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    @State private var loader = PostedStoriesLoader()
    /// The person, for the door below. Fetched with the page rather than passed in, because this
    /// screen can be reached with nothing but a uid.
    @State private var person: UserProfile?
    @State private var filter: Filter = .all
    @State private var showFilters = false
    /// ⛔ SELECT MODE — owner, 2026-09-11: "add a new button on the right called Edit; when I click
    /// Edit show a checkmark on every story, and when I select, the bottom shows three buttons:
    /// Share, the selected count, and Delete… so a user can delete more stories at one time."
    ///
    /// ⚠️ MINE ONLY, and not as a policy decision — there is nothing here another person's stories
    /// could do. Delete and Edit Viewers are the author's alone (the rules refuse both), and the
    /// full media a share would carry only exists locally for my own stories. The button is not
    /// drawn at all on somebody else's page rather than drawn and refused.
    @State private var editing = false
    /// Story ids, not indices: this grid re-sorts under a filter change and a story can expire out
    /// from under the selection while it is open.
    @State private var selected: Set<String> = []
    @State private var confirmDelete = false
    @State private var deleting = false
    /// The system share sheet's payload, held rather than built inline so the sheet has something
    /// stable to present. Identifiable through its own wrapper — an array is not.
    @State private var shareURLs: ShareURLs?
    /// One story's link, for the app's own share sheet (the hold menu's Share).
    @State private var sendLink: StoryLinkPayload?
    /// One story whose audience is being edited, from the long-press menu.
    @State private var editViewersFor: Story?
    @Environment(\.dismiss) private var dismiss

    /// ⛔ THE APP'S OWN STORY GRID, NOT A FOURTH ONE — owner, 2026-09-05, item 17: "Posted stories
    /// page: redesign exactly like the image (grid + view counts)." What was here was a mosaic with
    /// square corners on a 3pt gutter, so the same picture came out at one shape here and another
    /// on every other story grid.
    ///
    /// ⚠️ COMPUTED, NOT A STORED `let` WITH A DEFAULT. A stored property's initialiser runs outside
    /// the view's main-actor context, and these Glow screens have already failed the compiler three
    /// times on exactly that class of mistake. `GlowStoriesGridView` builds its columns inside
    /// `body` for the same reason; this is the same thing with a name.
    ///
    /// ⛔ THREE ACROSS, ON HIS CONCEPT IMAGE OF THIS PAGE — 2026-09-09, "make it exactly like this
    /// image". An earlier pass this same day put two here to match the Glowing grid, which was the
    /// honest guess before the picture arrived; the picture settles it at three, with the tighter
    /// gap and side margin that three columns need to breathe.
    ///
    /// ⚠️ This is deliberately NOT `GlowStoryCardView.gutter`. That 16 is the air between two
    /// person-cards on a two-column grid; at three columns it takes a third of the row.
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: PostedGrid.gap),
              count: PostedGrid.columns)
    }

    private typealias PostedGrid = StoryTileGrid

    var body: some View {
        // ⛔ ONE STABLE VIEW UNDER THE BAR (owner, 2026-10-11: "first seconds the title and Edit are
        // not appearing"). `content` swaps loading -> loaded, and with the toolbar on it the title
        // menu and Edit were torn down and rebuilt in that swap, blank for the first moments. On a
        // ZStack that never changes they are installed once, with the push.
        ZStack { content }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationBarTitleDisplayMode(.inline)
            // A pushed page is not a tab — see the note in `GlowNotificationsView`.
            .toolbar(.hidden, for: .tabBar)
            // ⛔ NO BLUR UNDER THE SELECT BAR (owner, 2026-10-12, his screenshot with the band over
            // the My Chats row circled: "remove the blur"). The bar's own ground and the soft edge
            // the grid blurs into under it both go; the count pill and the bin sit straight on the
            // page.
            .toolbarBackground(.hidden, for: .bottomBar)
            .scrollEdgeEffectHidden(true, for: .bottom)
            .toolbar {
                // ⛔ THE FILTER IS THE TITLE — his reference: "Posted stories ⌄", a menu hanging off
                // the heading rather than an icon in the corner. That is better than my first pass
                // for a reason worth keeping: the title then always says WHICH set you are looking
                // at, so a filtered page cannot be mistaken for the whole list. A corner icon puts
                // the state somewhere you have to go looking for.
                ToolbarItem(placement: .principal) {
                    Menu {
                        Picker("Filter", selection: $filter) {
                            ForEach(Filter.shown) { f in
                                // The sentence rides along inside the menu row, so the explanation
                                // he asked for survives losing the sheet.
                                Text(f.title).tag(f)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            // The filter's own word, always — "All posted stories" IS the title
                            // now (owner, 2026-09-11), so the page no longer needs a second name
                            // for the unfiltered case.
                            Text(filter.title)
                                .font(.headline)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            .toolbar {
                // ⛔ THE SYSTEM'S OWN BOTTOM BAR — owner, 2026-09-11: "the bottom, make it real
                // Apple iOS 26 design for the name, not custom".
                //
                // ⚠️ IT WAS A HAND-ROLLED `HStack` IN A `safeAreaInset` with `.background(.bar)`,
                // which is a copy of a bottom bar rather than one: its own padding, its own idea of
                // where the safe area ends, and none of the material, height or item spacing the
                // system gives a real one. A `bottomBar` placement IS the control, so it inherits
                // all of that and follows whatever iOS 26 does with it.
                //
                // His order is unchanged — Share, the count, Delete — and `Spacer()` between items
                // is how a toolbar group is told to push them apart.
                if isMe, editing {
                    // ⛔ NO SHARE BUTTON (owner, 2026-10-12: "remove Share button completely"). A
                    // blank item of the bin's width keeps the count in the middle of the screen.
                    ToolbarItem(placement: .bottomBar) {
                        Color.clear.frame(width: 44, height: 44)
                    }
                    .sharedBackgroundVisibility(.hidden)
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                    // ⛔ THE COUNT AS A BUTTON-SHAPED PILL (owner, 2026-10-12: "selected count make
                    // button"), on its OWN glass rather than the toolbar's: in one group with the
                    // bin, iOS 26 squeezed the label to "Se-lec…" (his 2026-10-11 report). Its own
                    // capsule at a fixed size cannot be squeezed, and the widest label still reserves
                    // the room so the bin does not move as the count changes.
                    ToolbarItem(placement: .bottomBar) {
                        ZStack {
                            Text("Select Stories").hidden()
                            Text(selected.isEmpty ? "Select Stories" : "\(selected.count) Selected")
                                .foregroundStyle(selected.isEmpty ? .secondary : .primary)
                        }
                        .font(.headline)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 18)
                        // ⛔ THE BIN'S HEIGHT (owner, 2026-10-12: "use the height the delete button
                        // is using, don't touch width"). The bottom bar's glass button is 44pt tall;
                        // 10pt of padding on a headline left the pill visibly shorter beside it.
                        .frame(height: 44)
                        .liquidGlass(Capsule())
                    }
                    .sharedBackgroundVisibility(.hidden)
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) {
                        Button { confirmDelete = true } label: {
                            if deleting { ProgressView() }
                            else { Image(systemName: "trash") }
                        }
                        .tint(.red)
                        .disabled(selected.isEmpty || deleting)
                    }
                }
                if isMe {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(editing ? "Done" : "Edit") {
                            withAnimation(.snappy(duration: 0.22)) {
                                editing.toggle()
                                // Leaving select mode drops the selection rather than remembering
                                // it: a tick still standing when he comes back names stories he
                                // chose for an action he already walked away from.
                                if !editing { selected.removeAll() }
                            }
                        }
                        .tint(.primary)
                    }
                }
            }

            .alert("Delete \(selected.count) \(selected.count == 1 ? "story" : "stories")?",
                   isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) { Task { await deleteSelected() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This cannot be undone. People who already saw them keep what they saw.")
            }
            .sheet(item: $shareURLs) { SystemShareSheet(items: $0.urls) }
            .sheet(item: $sendLink) { SendContactSheet(contactText: $0.url.absoluteString) }
            .sheet(item: $editViewersFor) { story in
                // The same sheet the viewer's own "Edit Viewers" raises, with the same completion —
                // one door, so a story's audience cannot be edited two different ways.
                ShareStorySheet(editing: story, onPosted: {
                    Task {
                        loader.invalidate()
                        await loader.load(uid: uid, force: true)
                        await loader.loadViewCounts(isMe: isMe)
                    }
                })
            }
            .task {
                await loader.load(uid: uid)
                await loader.loadViewCounts(isMe: isMe)
                if !isMe, person == nil { person = await ProfileStore.shared.fetch(uid) }
            }
    }

    // ⛔ `selectionBar` IS GONE — 2026-09-11. It was a hand-rolled HStack in a `safeAreaInset`
    // standing in for a bottom bar; the real one is a `ToolbarItemGroup(placement: .bottomBar)` in
    // the toolbar above. Do not build a second one.

    /// The tick his sketch puts on every story in select mode. Filled when chosen, a hollow ring
    /// when not — the same pair `StoryTick` draws in the audience pickers, restated here because a
    /// tile needs it over a photograph and therefore needs a shadow the list version never does.
    private func tick(on: Bool) -> some View {
        Image(systemName: on ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 22))
            // ⛔ `.blue` LITERALLY, AND `.palette` ALWAYS — owner, 2026-09-11: "make the select
            // checkmark blue".
            //
            // ⚠️ IT WAS `Color.accentColor`, WHICH IS THE TRAP `StoryTick` ALREADY WRITES UP one
            // file away: this app's accent is `Color.primary`, so on a dark screen it resolves to
            // WHITE — a white tick on a white disc, which is the blank circle with no checkmark in
            // his screenshot. Selection is the one place in the app that keeps the system blue, for
            // exactly this reason, and the audience pickers have done so since 2026-08-09.
            //
            // ⚠️ `.palette` ON BOTH STATES, not only the ticked one. With two styles handed to a
            // monochrome symbol the second is ignored, which is harmless — but switching rendering
            // mode with the state is a second thing to keep in step for no gain. A hollow `circle`
            // has one layer and takes the first style either way.
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, on ? AnyShapeStyle(Color.blue) : AnyShapeStyle(.clear))
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .padding(8)
    }

    /// The full `Story` behind a tile, for the actions that need more than the public mirror
    /// carries. Only my own page can answer it — `StoriesRepository.mine` is this account's own
    /// stories with their media urls and their audiences, where `PostedStory` is the mirror and
    /// deliberately holds neither.
    private func myStory(_ id: String) -> Story? {
        guard isMe else { return nil }
        return StoriesRepository.shared.mine?.stories.first { $0.id == id }
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    /// ⚠️ ONE AT A TIME, AND THE FAILURES ARE NOT SWALLOWED. `deleteStory` answers whether the
    /// server took it; a batch that reports success while half of it stayed up is worse than one
    /// that stops. Whatever did go leaves the selection, so a retry only re-sends what is left.
    private func deleteSelected() async {
        deleting = true
        // ⛔ SIX AT A TIME, NOT ONE BY ONE (owner, 2026-10-12: "deleting selected stories takes a long
        // time"). Each delete is several round trips (the mirror, the media, the document), and 28 of
        // them in a row was minutes. They are independent, so they run side by side, at most six in
        // flight so a large selection does not open dozens of connections at once. Each one is still
        // the same careful single delete, and only the ones that succeeded leave the selection.
        let ids = Array(selected)
        await withTaskGroup(of: (String, Bool).self) { group in
            var next = 0
            func addNext() {
                guard next < ids.count else { return }
                let id = ids[next]; next += 1
                group.addTask { (id, await StoriesService.shared.deleteStory(id)) }
            }
            for _ in 0..<min(6, ids.count) { addNext() }
            while let (id, ok) = await group.next() {
                if ok { selected.remove(id) }
                addNext()
            }
        }
        deleting = false
        loader.invalidate()
        await loader.load(uid: uid, force: true)
        await loader.loadViewCounts(isMe: isMe)
        if selected.isEmpty { editing = false }
    }

    /// ⛔ THE STORY'S OWN ADDRESS, NOT THE FILE'S — owner, 2026-09-11, with what this was putting on
    /// his clipboard pasted in full: a firebasestorage.googleapis.com URL two hundred characters
    /// long carrying a download token. "Please make it a simple link, use my domain."
    ///
    /// ⚠️ THE UGLINESS WAS THE SMALLER HALF OF IT. That address is the FILE: the token on the end is
    /// permanent and unauthenticated, so anybody it reaches can fetch the picture for ever, with no
    /// account, after the story has expired and after it has been deleted. See `KulanApp.storyLink`.
    private func shareSelected() {
        let urls = selected.compactMap { myStory($0) }
            .filter { StoryShareRights.allows($0) }
            .compactMap { URL(string: KulanApp.storyLink(id: $0.id)) }
        guard !urls.isEmpty else { return }
        shareURLs = ShareURLs(urls: urls)
    }

    /// This page's own key namespace for a tile's rectangle. Its own, and not the bare story id,
    /// because the profile card behind See All draws the SAME stories a few points away — two
    /// screens filing one id would make the flight land on whichever of them registered last. The
    /// friends page and the Glowing page each carry their own prefix for exactly this reason.
    /// ⛔ `openStory`, NOT `open` — and the name is the fix, not a preference. As `open(_:)` this
    /// resolved to POSIX `open(_:_:)` from Darwin, which is a global visible in every Swift file:
    /// the compiler reported "cannot convert PostedStory to UnsafePointer<CChar>", which is C's
    /// file-opening path argument. A one-argument member called `open` on a View is a trap the next
    /// person would fall into too.
    ///
    /// ⛔ THE TILE THAT WAS TAPPED IS THE ONE IT FLIES OUT OF — owner, 2026-09-11: "when I click the
    /// image the story is not opening from that position, and scroll down to go back does not
    /// return to that position".
    ///
    /// ⚠️ THIS TOOK NO ARGUMENT AT ALL. Every tile on the page called one function and handed the
    /// flight `mine.id` — the key of the chat row's card, on a screen that is not even visible. So
    /// the source rectangle resolved to something off-screen or to nothing, and both the open and
    /// the close fell back to the plain presentation, whichever tile was pressed. The story that
    /// played was right; the movement was always wrong.
    private func openStory(_ story: PostedStory) {
        if isMe {
            guard let mine = StoriesRepository.shared.mine, !mine.stories.isEmpty else { return }
            // ⛔ AND THE STORY THAT WAS TAPPED IS THE ONE THAT PLAYS — his report, 2026-09-16:
            // "when i click story always is opening first story, show me the one i click".
            //
            // ⚠️ THE EARLIER FIX ON THIS LINE WAS ABOUT THE FLIGHT, NOT THE CONTENT. `tileKey`
            // made the viewer fly out of the right tile, and the note above still claims "the story
            // that played was right" — it was not. Handing over the whole group says which PERSON to
            // open, and the item inside it was then chosen by first-unseen-else-first, which on a
            // page of already-posted stories is almost always the first tile. `startStoryId` is the
            // missing half.
            StoryDoor.open(mine, among: [mine], from: Self.tileKey(story.id),
                           startStoryId: story.id,
                           pinned: true, deliveredToMe: true)
        } else {
            let p = GlowPerson(id: uid,
                               name: person?.name ?? title,
                               handle: person?.handle ?? "",
                               photoUrl: person?.photoUrl)
            Task { await GlowStoryOpen.open(p, from: Self.tileKey(story.id)) }
        }
    }

    private static func tileKey(_ storyId: String) -> String { "postedpage-\(storyId)" }

    @ViewBuilder private var content: some View {
        switch loader.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView {
                Label("Could not load stories", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Try Again") {
                    loader.invalidate()
                    Task { await loader.load(uid: uid, force: true); await loader.loadViewCounts(isMe: isMe) }
                }
                .buttonStyle(.borderedProminent)
            }
        case .loaded(let all):
            let rows = all.filter { filter.matches($0) }
            if rows.isEmpty {
                // ⚠️ TWO DIFFERENT EMPTIES, AND THEY MUST READ DIFFERENTLY. No stories at all is a
                // fact about the account; no stories THROUGH THIS FILTER is a fact about the
                // filter, and offering "Show all" is the way out of a corner the person filtered
                // themselves into.
                if all.isEmpty {
                    // ⛔ THE MESSAGE REQUESTS EMPTY PAGE'S LAYOUT — owner 2026-10-16: "use the story
                    // icon, and exactly the size and font of No message requests". The app's own
                    // Stories icon at 44, title 17 semibold, line 15 secondary (MessageRequestsView
                    // `emptyLine`), instead of the system's photo glyph and sizes.
                    VStack(spacing: 10) {
                        Image("ic_stories_stack")   // the Settings Stories icon (owner 2026-10-16)
                            .renderingMode(.template)
                            .resizable().scaledToFit()
                            .frame(width: 44, height: 44)
                            .foregroundStyle(.primary)
                            .padding(.bottom, 4)
                        Text("No live stories")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text("Stories disappear after 24 hours.")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label("Nothing in \(filter.title)", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text(filter.explain)
                    } actions: {
                        // Owner 2026-10-11: in dark mode the app's white tint made this a white pill
                        // with white words. Grey, with the label readable in both modes, and named
                        // for what it does.
                        Button("Clear Filter") { filter = .all }
                            .buttonStyle(.borderedProminent)
                            .tint(Color(uiColor: .systemGray))
                            .foregroundStyle(.white)
                    }
                }
            } else {
                ScrollView {
                    // Row spacing is the SAME gutter as the columns, so the air between two cards
                    // reads the same in both directions — the rule the Glowing grid already
                    // follows.
                    // ⛔ FOLDERS — owner, 2026-10-11: "show all posted stories together, but each in its own
                    // folder, with the folder's name above it". My own page, the All filter: one block
                    // per audience (Everyone, My Chats, each custom list by its own name), in the order
                    // their newest story was posted. Anyone else's page, or a single filter, stays one
                    // grid: who another person posted to is not mine to see.
                    // ...and "All Custom" the same way, one folder per custom list (owner, same day).
                    // (owner, later the same day: All shows the custom lists as one "Custom" folder;
                    // All Custom is where each list gets its own.)
                    let folders = isMe && (filter == .all || filter == .custom)
                        ? Self.folders(rows, mergeCustom: filter == .all) : []
                    if !folders.isEmpty {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(folders) { f in
                                // ⛔ THE AUDIENCE'S OWN BADGE BEFORE ITS NAME — owner, 2026-10-11:
                                // "show the Everyone, custom and My Chats icons, now it looks
                                // confusing". The same badges the Share Story sheet draws
                                // (`StoryAudienceRow.badge`), at heading size.
                                HStack(spacing: 10) {
                                    // Text only (owner, 2026-10-11, later: "remove icons"). The
                                    // badge stays defined in `folderBadge` should it come back.
                                    // 17, the Stories list's own headings (My Story, Recent
                                    // Stories, Viewed Stories) — owner, 2026-10-11.
                                    Text(f.name)
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                }
                                    .padding(.horizontal, PostedGrid.margin + 6)
                                    // The first heading sits just under the bar (owner, 2026-10-11:
                                    // "top header has more empty space"); the rest keep their air.
                                    .padding(.top, f.id == folders.first?.id ? 4 : 18)
                                    .padding(.bottom, 10)
                                LazyVGrid(columns: columns, spacing: PostedGrid.gap) {
                                    ForEach(f.rows) { s in postedTile(s) }
                                }
                                .padding(.horizontal, PostedGrid.margin)
                            }
                        }
                    } else {
                        LazyVGrid(columns: columns, spacing: PostedGrid.gap) {
                            ForEach(rows) { s in postedTile(s) }
                        }
                        // The tiles sit tight against each other and the PAGE keeps its edge — see the
                        // note on `StoryTileGrid.margin` for why those are two separate numbers.
                        .padding(.horizontal, PostedGrid.margin)
                        .padding(.top, 8)
                    }
                }
                .refreshable {
                    await loader.load(uid: uid, force: true)
                    await loader.loadViewCounts(isMe: isMe)
                }
            }
        }
    }
}

/// The filter sheet. Rows rather than a segmented control, because each one carries a sentence
/// explaining what it shows — which is his requirement, and does not fit in a segment.
private struct FilterSheet: View {
    @Binding var selection: PostedStoriesView.Filter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(PostedStoriesView.Filter.shown) { f in
                    Button {
                        selection = f
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.title).font(.headline).foregroundStyle(.primary)
                                Text(f.explain).font(.subheadline).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            if selection == f {
                                Image(systemName: "checkmark")
                                    .font(.headline).foregroundStyle(GlowStyle.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.font(.headline)
                }
            }
        }
    }
}

/// The system share sheet's payload. `.sheet(item:)` needs something `Identifiable` and an array
/// is not one, so the urls travel in a box with an identity of their own. A fresh box per share
/// means presenting twice in a row cannot be swallowed as "the same item".
private struct ShareURLs: Identifiable {
    let id = UUID()
    let urls: [URL]
}

// ⛔ `PostedStoryGridTile` IS GONE — 2026-09-11. It was this page's own copy of the profile's
// `PostedStoryTile`, and the copy had the badge bug: `.overlay(alignment:)` over two conditional
// children centred the count instead of putting it in the corner. The page uses the profile's tile
// now, which has always drawn it correctly. Do not reintroduce a second one; the geometry both of
// them read lives on `StoryTileGrid` below.

/// ⛔ THE STORY TILE GRID, IN ONE PLACE — his concept images of the posted stories page and of the
/// all-friends page, 2026-09-09, and his instruction that the second should look like the first:
/// "cards and corners it will be same like page posted stories".
///
/// Two pages draw this now and a third card borrows the corner, so the numbers live here rather
/// than three times over. `GlowStoryCardView` holds the other grid, the two-column one with a
/// person's name and face on every card; this is the tighter three-column one for plain tiles.
enum StoryTileGrid {
    static let columns: Int = 3
    /// ⛔ MEASURED OFF HIS CONCEPT, 2026-09-09, against a screenshot of ours beside it: "spaces and
    /// corners make it exactly like image 2". In his picture the gap between two tiles is about a
    /// ninth of a tile's width, which on three columns of a 430pt screen is 12, and the page's own
    /// side margin is a little wider than the gap at 14. Ours were both 6, which is what made the
    /// grid read as one block rather than as tiles.
    /// ⛔ TIGHTER AGAIN — owner, 2026-09-11, with his concept beside a screenshot of ours: "the
    /// card space is big, fix". This REVERSES the 12/14 set two days earlier off the same image,
    /// and the measurement is why: that pass read the gap as about a ninth of a tile's width, and
    /// on the picture he sent this time it is nearer a thirtieth — the tiles almost touch, and the
    /// grid reads as one sheet of pictures rather than as separate cards. 4 and 8 put it there on a
    /// three-column 430pt screen.
    ///
    /// ⚠️ THE MARGIN STAYS WIDER THAN THE GAP, which is the one part of the earlier note that held
    /// up: the page's edge needs more air than two tiles need from each other, or the outer column
    /// looks cropped.
    ///
    /// ⛔ THE MARGIN IS 20 AND THE GAP STAYS 4 — owner, 2026-09-11: "posted stories cards, space
    /// between angles and cards looks small". The two numbers moved together last time and only one
    /// of them was wrong: he wants the TILES tight against each other (that is what "the card space
    /// is big" bought) and the PAGE to have an edge. At 8 the outer columns read as cropped against
    /// the screen, which is exactly what he photographed.
    ///
    /// 20 was not a fresh guess. It was `GlowStoryCardView.margin`, which is `StoryRowMetrics.hPad`,
    /// the single left edge he asked every Stories surface to share on 2026-09-02.
    ///
    /// ⛔ 12 AND 6, HIS OWN NUMBERS — owner, 2026-09-11, after asking what the two were and being
    /// told 20 and 4: "make screen angel and card space between like 12pt, and also space between
    /// cards make 6pt".
    ///
    /// ⚠️ SO THIS PAGE NO LONGER SHARES THE STORIES EDGE, deliberately, and that is the part worth
    /// knowing. The note above argued for 20 on the grounds that one left edge should run down every
    /// Stories surface; he has now measured this page on its own and chosen 12. A three-column grid
    /// of tiles is not the same object as a two-column grid of person-cards, and he is the one
    /// looking at both. `GlowStoryCardView.margin` stays at 20 for the pages that draw those cards —
    /// do not "restore consistency" by dragging either number back to the other.
    ///
    /// ⚠️ THE MARGIN IS STILL WIDER THAN THE GAP (12 against 6), which is the one rule that has held
    /// through every revision of these two: the page's edge needs more air than two tiles need from
    /// each other, or the outer column reads as cropped.
    static let gap: CGFloat = 6
    static let margin: CGFloat = 12
    /// Smaller than the story cards' own 34, because a tile is about a third of the width and a
    /// 34pt arc on something this narrow eats the picture. 16 is his concept's corner measured the
    /// same way as the gap above.
    /// ⛔ 24 — AS ROUND AS A GLOWING CARD, MEASURED RATHER THAN GUESSED. Owner, 2026-09-11, after
    /// seeing 12 on his phone: "make the card more rounded, use the iOS 26 corners, give it rounded
    /// corners like you gave the Glowing story."
    ///
    /// ⚠️ THE ANSWER IS A RATIO, NOT A NUMBER, because the two cards are not the same width. A
    /// Glowing card is 34 on a two-column card of 187 (`GlowStoryCardView`, margin 20 and gutter
    /// 16 on a 430pt screen) — 0.182 of its own width. These tiles are three across at 135, so the
    /// same roundness is 135 × 0.182 = 24.6. Copying the literal 34 would have put an arc a quarter
    /// of the tile wide on something half the size and eaten the picture, which is the trap the
    /// note this replaces was written about in the other direction.
    ///
    /// ⚠️ TWO PASSES GOT THIS WRONG BEFORE, AND BOTH WERE MEASURED OFF A CONCEPT IMAGE: 16 read off
    /// a wider tile, then 12 when the tiles were widened and the gaps closed. What settles it is not
    /// another reading of the picture but the card he pointed AT — this page and the Glowing grid
    /// now round by the same fraction of their own width, so they read as one family at two sizes.
    ///
    /// ⚠️ `.continuous` EVERYWHERE THIS IS USED, which is the iOS 26 part of his ask and was already
    /// true: every clip that reads this number passes `style: .continuous`, so the arc is Apple's
    /// squircle rather than a circular quarter-turn. Do not swap one for a plain `cornerRadius`.
    ///
    /// ⚠️ THE PROFILE'S CARD FOLLOWS THIS. `PostedTile.corner` reads it, so a story keeps its shape
    /// when he taps See All — which was the point of putting the number here in the first place.
    static let corner: CGFloat = 24
}
