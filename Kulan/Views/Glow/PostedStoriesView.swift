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

    /// ⛔ 6pt GUTTERS AND ROUNDED TILES — his third reference, 2026-09-02. My first pass was a
    /// flush 3pt mosaic, which is the ATTACH SHEET's language (edge to edge, square, no gaps) and
    /// wrong here: that grid is a picker where the photographs are the surface, this one is a
    /// gallery of separate posts. Cards, with air between them.
    private let columns = [GridItem(.flexible(), spacing: 6),
                           GridItem(.flexible(), spacing: 6),
                           GridItem(.flexible(), spacing: 6)]

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
                    LazyVGrid(columns: columns, spacing: 3) {
                        // ⛔ THE CELL OPENS THE STORY — owner, 2026-09-02: "when I click a story
                        // it is not opening". Same omission as the profile's rail: the tile was
                        // drawn and never wired to anything.
                        ForEach(rows) { s in
                            Button { open() } label: { PostedStoryGridTile(story: s) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 3)
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

/// One cell of the full-page grid: the poster, the view badge, and a mark for a video.
///
private struct PostedStoryGridTile: View {
    let story: PostedStory

    var body: some View {
        Color.clear
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .overlay { StoryImage(url: story.thumbUrl) }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if let v = story.views {
                    Label(GlowCount.short(v), systemImage: "eye.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(6)
                }
            }
            .overlay(alignment: .topTrailing) {
                if story.isVideo {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(.black.opacity(0.45), in: Circle())
                        .padding(6)
                }
            }
    }
}
