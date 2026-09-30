import SwiftUI

/// One live story on the Insights page, with the numbers the page ranks it by.
struct StoryInsight: Identifiable, Equatable {
    let story: PostedStory
    /// Nil while unknown — the row then draws a dash rather than a confident zero, the same rule
    /// `PostedStory.views` follows.
    var views: Int?
    var reactions: Int?
    var id: String { story.id }
}

/// The numbers behind the Insights page.
///
/// ⚠️ NOTHING HERE IS NEW DATA — owner, 2026-09-30: "for this first version, use only numbers the
/// app already has". Every figure is the counter document or the viewer receipts the Seen-by sheet
/// already reads, added up. Anything measured over time (gained this week, against the previous
/// period, view time, profile views) needs a server function that keeps history, and is not here.
@MainActor @Observable final class GlowInsightsLoader {
    private(set) var rows: [StoryInsight] = []
    /// Different people across every live story. Nil while unknown, and nil when any story's
    /// receipts could not be read — a partial union would be a wrong number stated as a fact.
    private(set) var viewers: Int?

    private struct Fetched: Sendable {
        var views: Int?
        var reactions: Int?
        var viewerIds: [String]?
    }

    /// With receipts off both reads answer "nothing" by design (see `StoriesService.fetchViewers`),
    /// and the page has to say that rather than show a row of zeros.
    static var receiptsOn: Bool {
        UserDefaults.standard.object(forKey: "storyViewReceipts") as? Bool ?? true
    }

    func load(_ stories: [PostedStory]) async {
        // The counts the profile card already holds, so the page opens on numbers, not dashes.
        let known = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        rows = Self.ranked(stories.map { s in
            known[s.id] ?? StoryInsight(story: s, views: s.views, reactions: nil)
        })
        guard !stories.isEmpty, Self.receiptsOn else {
            viewers = nil
            return
        }
        // All at once, for the reason `PostedStoriesLoader.loadViewCounts` gives: the wait is the
        // slowest read, not the sum of them.
        var fetched = [Fetched?](repeating: nil, count: stories.count)
        await withTaskGroup(of: (Int, Fetched).self) { group in
            for (i, story) in stories.enumerated() {
                let id = story.id
                group.addTask {
                    // The counter is the true total; the receipts are what names the people, and
                    // they stand in for the counter on a story that has none.
                    let summary = await StoriesService.shared.fetchViewSummary(storyId: id)
                    let list = await StoriesService.shared.fetchViewers(storyId: id)
                    let counted = list.map { StoryViewSummary.counted(from: $0) }
                    return (i, Fetched(views: summary?.count ?? counted?.count,
                                       reactions: summary?.reactionCount ?? counted?.reactionCount,
                                       viewerIds: list?.map(\.id)))
                }
            }
            for await (i, f) in group { fetched[i] = f }
        }
        var updated: [StoryInsight] = []
        var people = Set<String>()
        var everyListRead = true
        for (i, story) in stories.enumerated() {
            let f = fetched[i]
            // A failed read keeps the number already on screen rather than blanking it.
            let old = known[story.id]
            updated.append(StoryInsight(story: story,
                                        views: f?.views ?? old?.views ?? story.views,
                                        reactions: f?.reactions ?? old?.reactions))
            if let ids = f?.viewerIds { people.formUnion(ids) } else { everyListRead = false }
        }
        rows = Self.ranked(updated)
        viewers = everyListRead ? people.count : nil
    }

    /// Most watched first; reactions break a tie, then the newer story.
    private static func ranked(_ rows: [StoryInsight]) -> [StoryInsight] {
        rows.sorted { a, b in
            let av = a.views ?? -1, bv = b.views ?? -1
            if av != bv { return av > bv }
            let ar = a.reactions ?? -1, br = b.reactions ?? -1
            if ar != br { return ar > br }
            return a.story.createdAt > b.story.createdAt
        }
    }

    var totalViews: Int? {
        let known = rows.compactMap(\.views)
        return known.isEmpty ? nil : known.reduce(0, +)
    }

    var totalReactions: Int? {
        let known = rows.compactMap(\.reactions)
        return known.isEmpty ? nil : known.reduce(0, +)
    }

    // ⛔ THE TWO DERIVED NUMBERS FOLLOW THE REFERENCE APP'S RULES — owner, 2026-09-30: "only get
    // the math logic, don't copy the design". Its headline figures are AVERAGES per story rather
    // than totals, and it never divides by a zero: a ratio with nothing under it is not shown at
    // all. Its third rule, every figure against the previous period, needs history the server
    // does not keep yet.

    /// Average views over the stories whose count is known.
    var viewsPerStory: Double? {
        let known = rows.compactMap(\.views)
        guard !known.isEmpty else { return nil }
        return Double(known.reduce(0, +)) / Double(known.count)
    }

    /// Reactions as a share of views. Nil with no views: nothing to be a share of.
    var reactionRate: Double? {
        guard let views = totalViews, views > 0, let reactions = totalReactions else { return nil }
        return Double(reactions) / Double(views)
    }
}

/// INSIGHTS — owner, 2026-09-30: one page for the story numbers and the glow counts, opened from
/// his own profile.
///
/// A plain grouped list, the same kind of page as the Glowers list it links to: the profile it is
/// pushed from is a coloured photograph, and the pages behind it are ordinary system pages.
struct GlowInsightsView: View {
    let stories: PostedStoriesLoader
    /// Whose lists the two glow rows open — the same title the profile's own stats card passes.
    var title: String = ""

    /// Explicit, for the private-stored-property rule — see the note in `GlowProfileView`.
    init(stories: PostedStoriesLoader, title: String = "") {
        self.stories = stories
        self.title = title
    }

    @State private var loader = GlowInsightsLoader()
    private var glow = GlowService.shared

    private var live: [PostedStory] { stories.state.value ?? [] }
    /// Re-runs the load when a story is posted or expires while the page is open.
    private var liveKey: String { live.map(\.id).joined(separator: ",") }

    var body: some View {
        List {
            storySections
            Section("Glow") {
                NavigationLink {
                    GlowPeopleListView(side: .glowers, title: title)
                } label: {
                    countRow("Glowers", glow.displayGlowers.count)
                }
                NavigationLink {
                    GlowPeopleListView(side: .glowing, title: title)
                } label: {
                    countRow("Glowing", glow.displayGlowing.count)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Insights")
        .navigationBarTitleDisplayMode(.inline)
        // A pushed page is not a tab — see the note in `GlowNotificationsView`.
        .toolbar(.hidden, for: .tabBar)
        .task(id: liveKey) { await loader.load(live) }
        .refreshable { await loader.load(live) }
    }

    // MARK: - Stories

    @ViewBuilder private var storySections: some View {
        if stories.state.isLoading {
            Section("Live stories") {
                ProgressView().frame(maxWidth: .infinity)
            }
        } else if stories.state.isFailed {
            Section("Live stories") {
                Text("Could not load stories").foregroundStyle(.secondary)
            }
        } else if live.isEmpty {
            Section("Live stories") {
                Text("You have no live stories. Post one to see its views here.")
                    .foregroundStyle(.secondary)
            }
        } else if !GlowInsightsLoader.receiptsOn {
            Section {
                Text("Story views are turned off.").foregroundStyle(.secondary)
            } header: {
                Text("Live stories")
            } footer: {
                Text("Turn on view receipts in Settings > Stories to see who views your stories.")
            }
        } else {
            Section {
                summary
            } header: {
                Text("Live stories")
            } footer: {
                Text("These numbers count the stories that are live now. A story leaves this page when it expires.")
            }
            Section("Top stories") {
                ForEach(loader.rows) { row in
                    storyRow(row)
                }
            }
        }
    }

    private var summary: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 16) {
            GridRow {
                stat("Story views", loader.totalViews.map(GlowCount.short))
                stat("Viewers", loader.viewers.map(GlowCount.short))
            }
            GridRow {
                stat("Reactions", loader.totalReactions.map(GlowCount.short))
                stat("Live stories", GlowCount.short(live.count))
            }
            GridRow {
                stat("Views per story", loader.viewsPerStory.map(Self.average))
                stat("Reaction rate", loader.reactionRate.map { String(format: "%.0f%%", $0 * 100) })
            }
        }
        .padding(.vertical, 6)
    }

    /// One decimal while it is small enough to matter, the usual short count after that.
    private static func average(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f", value) : GlowCount.short(Int(value.rounded()))
    }

    private func stat(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value ?? "–")
                .font(.title2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.primary)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func storyRow(_ row: StoryInsight) -> some View {
        HStack(spacing: 12) {
            // The box decides the shape and the picture fills it — see `PostedStoryTile.tile`.
            Color.clear
                .frame(width: Self.thumbWidth, height: Self.thumbWidth / GlowStoryCardView.aspect)
                .overlay { StoryImage(url: row.story.thumbUrl).scaledToFill() }
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(row.story.isVideo ? "Video story" : "Photo story")
                    .font(.body)
                    .foregroundStyle(.primary)
                Text("\(row.story.createdAt.formatted(.relative(presentation: .named))) · \(Self.audience(row.story.audience))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Label(row.views.map(GlowCount.short) ?? "–", systemImage: "eye.fill")
                    .foregroundStyle(.primary)
                Label(row.reactions.map(GlowCount.short) ?? "–", systemImage: "heart.fill")
                    .foregroundStyle(.secondary)
            }
            .labelStyle(.titleAndIcon)
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private static let thumbWidth: CGFloat = 40

    /// The names the Posted stories filter uses for the same four audiences.
    private static func audience(_ label: String) -> String {
        switch label {
        case "everyone": return "Everyone"
        case "glowers": return "Glowers"
        case "custom": return "Custom"
        default: return "My Chats"
        }
    }

    // MARK: - Glow

    private func countRow(_ label: String, _ count: Int) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(GlowCount.short(count))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}
