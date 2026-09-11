import SwiftUI

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
        case all, friends, custom, glowers
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .friends: return "My Friends"
            case .custom: return "Custom"
            case .glowers: return "Glowers"
            }
        }
        /// What it means in one line, his "the filtering behaviour should be clear and easy to
        /// understand" — shown under the option rather than left to be guessed.
        var explain: String {
            switch self {
            case .all: return "Every story you have posted that is still live"
            case .friends: return "Stories visible to your friends"
            case .custom: return "Stories shared with a custom audience"
            case .glowers: return "Stories shared with your Glowers"
            }
        }
        /// ⚠️ MATCHES THE STORY'S OWN LABEL. "everyone" is deliberately counted as a friends-visible
        /// story here: an Everyone story reaches every chat you have accepted AND the profile, so
        /// hiding it from the My Friends filter would be a lie about who can see it.
        func matches(_ audience: String) -> Bool {
            switch self {
            case .all: return true
            case .friends: return audience == "friends" || audience == "everyone"
            case .custom: return audience == "custom"
            case .glowers: return audience == "glowers"
            }
        }
    }

    @State private var loader = PostedStoriesLoader()
    /// The person, for the door below. Fetched with the page rather than passed in, because this
    /// screen can be reached with nothing but a uid.
    @State private var person: UserProfile?
    @State private var filter: Filter = .all
    @State private var showFilters = false
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
        content
            .navigationBarTitleDisplayMode(.inline)
            // A pushed page is not a tab — see the note in `GlowNotificationsView`.
            .toolbar(.hidden, for: .tabBar)
            .toolbar {
                // ⛔ THE FILTER IS THE TITLE — his reference: "Posted stories ⌄", a menu hanging off
                // the heading rather than an icon in the corner. That is better than my first pass
                // for a reason worth keeping: the title then always says WHICH set you are looking
                // at, so a filtered page cannot be mistaken for the whole list. A corner icon puts
                // the state somewhere you have to go looking for.
                ToolbarItem(placement: .principal) {
                    Menu {
                        Picker("Filter", selection: $filter) {
                            ForEach(Filter.allCases) { f in
                                // The sentence rides along inside the menu row, so the explanation
                                // he asked for survives losing the sheet.
                                Text(f == .all ? f.title : "\(f.title) — \(f.explain)").tag(f)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(filter == .all ? "Posted stories" : filter.title)
                                .font(.headline)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            .task {
                await loader.load(uid: uid)
                await loader.loadViewCounts(isMe: isMe)
                if !isMe, person == nil { person = await ProfileStore.shared.fetch(uid) }
            }
    }

    /// Open this person's story set. The same two doors the profile's rail uses, and for the same
    /// reason — see `GlowProfileView.openPosted`.
    private func open() {
        if isMe {
            guard let mine = StoriesRepository.shared.mine, !mine.stories.isEmpty else { return }
            StoryDoor.open(mine, among: [mine], from: mine.id, pinned: true, deliveredToMe: true)
        } else {
            let p = GlowPerson(id: uid,
                               name: person?.name ?? title,
                               handle: person?.handle ?? "",
                               photoUrl: person?.photoUrl)
            Task { await GlowStoryOpen.open(p) }
        }
    }

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
            let rows = all.filter { filter.matches($0.audience) }
            if rows.isEmpty {
                // ⚠️ TWO DIFFERENT EMPTIES, AND THEY MUST READ DIFFERENTLY. No stories at all is a
                // fact about the account; no stories THROUGH THIS FILTER is a fact about the
                // filter, and offering "Show all" is the way out of a corner the person filtered
                // themselves into.
                if all.isEmpty {
                    ContentUnavailableView("No live stories", systemImage: "photo.on.rectangle.angled",
                                           description: Text("Stories disappear after 24 hours."))
                } else {
                    ContentUnavailableView {
                        Label("Nothing in \(filter.title)", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text(filter.explain)
                    } actions: {
                        Button("Show All") { filter = .all }.buttonStyle(.borderedProminent)
                    }
                }
            } else {
                ScrollView {
                    // Row spacing is the SAME gutter as the columns, so the air between two cards
                    // reads the same in both directions — the rule the Glowing grid already
                    // follows.
                    LazyVGrid(columns: columns, spacing: PostedGrid.gap) {
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
                        ForEach(rows) { s in
                            PostedStoryTile(story: s) { open() }
                        }
                    }
                    // The tiles run close to the screen's edges in his image, so the margin matches
                    // the gap between them rather than the wide inset a two-column grid takes.
                    .padding(.horizontal, PostedGrid.margin)
                    .padding(.top, 8)
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
                ForEach(PostedStoriesView.Filter.allCases) { f in
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
    static let gap: CGFloat = 4
    static let margin: CGFloat = 8
    /// Smaller than the story cards' own 34, because a tile is about a third of the width and a
    /// 34pt arc on something this narrow eats the picture. 16 is his concept's corner measured the
    /// same way as the gap above.
    /// ⛔ 12, DOWN FROM 16 — owner, 2026-09-11: "it is using the wrong rounded corners". Measured
    /// the same way as the gap above: in his concept the arc is about a tenth of a tile's width,
    /// and with the tiles now ~135 wide that is 13, where 16 was read off a wider tile. The tiles
    /// grew when the gaps shrank, so holding 16 would have made them rounder relative to the
    /// picture, not merely unchanged.
    ///
    /// ⚠️ THE PROFILE'S CARD FOLLOWS THIS. `PostedTile.corner` reads it, so a story keeps its shape
    /// when he taps See All — which was the point of putting the number here in the first place.
    static let corner: CGFloat = 12
}
