import SwiftUI
import Charts
import FirebaseFunctions

/// One live story on the Insights page, with the numbers the page ranks it by.
struct StoryInsight: Identifiable, Equatable {
    let story: PostedStory
    /// Nil while unknown — the row then draws a dash rather than a confident zero, the same rule
    /// `PostedStory.views` follows.
    var views: Int?
    var reactions: Int?
    var id: String { story.id }
}

/// The numbers for the stories that are LIVE NOW.
///
/// ⚠️ NOTHING HERE IS STORED. Every figure is the counter document or the viewer receipts the
/// Seen-by sheet already reads, added up, and it is gone when the story is. What happened over
/// days and weeks is `InsightsHistoryLoader`, which reads what the server wrote down.
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
    // all. Its third rule, every figure against the previous period, is `InsightsDelta`.

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


/// One country's share of my Glowers, as the server returns it.
struct InsightsCountryShare: Identifiable, Equatable {
    let country: String
    let percent: Int
    var id: String { country }
}

/// TOP COUNTRIES — owner, 2026-10-03: "use the country the app already records for each device".
/// Those records belong to other people and no client may read them, so the server counts them
/// (`insightsTopCountries` in `functions-insights`) and hands back shares only, never names. It
/// returns nothing until enough Glowers have a known country to say anything without pointing at
/// somebody.
@MainActor @Observable final class InsightsCountriesLoader {
    enum Phase: Equatable { case loading, loaded, failed }
    private(set) var phase: Phase = .loading
    private(set) var countries: [InsightsCountryShare] = []

    func load() async {
        if phase != .loaded { phase = .loading }
        do {
            let result = try await Functions.functions(region: "me-central1")
                .httpsCallable("insightsTopCountries").call()
            let data = result.data as? [String: Any] ?? [:]
            let rows = data["countries"] as? [[String: Any]] ?? []
            countries = rows.compactMap { row in
                guard let name = row["country"] as? String,
                      let percent = (row["percent"] as? NSNumber)?.intValue else { return nil }
                return InsightsCountryShare(country: name, percent: percent)
            }
            phase = .loaded
        } catch {
            if phase != .loaded { phase = .failed }
        }
    }
}

/// INSIGHTS — owner, 2026-09-30: one page for the story numbers and the glow counts, opened from
/// his own profile, backed by the server's daily history (7, 28 or 90 days, each figure against the
/// period before).
///
/// ⛔ THREE TABS — owner, 2026-10-03, with screenshots of two big apps' insights pages: "take the
/// experience, don't copy the UI". Overview (headline figures you tap to chart), Content (every
/// story of the period, sortable) and Audience (Glowers over time with gains and Unglows, top
/// countries, when stories are watched). Built from system parts: the tab switch is Apple's own
/// segmented control (`NativeSegments`), the charts are Swift Charts, the cards are grouped backgrounds.
///
/// ⚠️ NO GENDER. He asked for "man or women"; the app has never asked anybody, so there is no data,
/// and a chart of guesses would be a lie stated as a fact. Offered as an optional profile question.
struct GlowInsightsView: View {
    let stories: PostedStoriesLoader
    /// Whose lists the two glow rows open — the same title the profile's own stats card passes.
    var title: String = ""
    /// The account's own @handle, for `alwaysOpen`.
    var handle: String = ""

    /// Explicit, for the private-stored-property rule — see the note in `GlowProfileView`.
    init(stories: PostedStoriesLoader, title: String = "", handle: String = "") {
        self.stories = stories
        self.title = title
        self.handle = handle
    }

    enum Tab: Int, CaseIterable {
        case overview, content, audience
        var title: String {
            switch self {
            case .overview: return "Overview"
            case .content: return "Content"
            case .audience: return "Audience"
            }
        }
    }

    /// The headline figures on Overview. Tapping one charts it below, day by day.
    enum Metric: CaseIterable, Identifiable {
        case views, profileViews, reactions, glowers, posted, perStory
        var id: Self { self }
        var title: String {
            switch self {
            case .views: return "Views"
            case .profileViews: return "Profile views"
            case .reactions: return "Reactions"
            case .glowers: return "Net Glowers"
            case .posted: return "Stories"
            case .perStory: return "Views per story"
            }
        }
    }

    enum StorySort: CaseIterable { case latest, views, reactions
        var title: String {
            switch self {
            case .latest: return "Latest"
            case .views: return "Views"
            case .reactions: return "Reactions"
            }
        }
    }

    enum GrowthView: CaseIterable { case overall, gained, unglows
        var title: String {
            switch self {
            case .overall: return "Overall"
            case .gained: return "Gained"
            case .unglows: return "Unglows"
            }
        }
    }

    @State private var loader = GlowInsightsLoader()
    @State private var history = InsightsHistoryLoader()
    @State private var countries = InsightsCountriesLoader()
    @State private var period: InsightsPeriod = .month
    @State private var tab: Tab = .overview
    @State private var metric: Metric = .views
    @State private var sort: StorySort = .latest
    @State private var growth: GrowthView = .overall
    private var glow = GlowService.shared

    private var live: [PostedStory] { stories.state.value ?? [] }
    /// Re-runs the load when a story is posted or expires while the page is open.
    private var liveKey: String { live.map(\.id).joined(separator: ",") }

    /// ⛔ LOCKED UNDER 100 GLOWERS — owner, 2026-09-30: "Insights are available after reaching 100
    /// followers". Counted from my own live glow set, the same number the profile's stats card
    /// shows, so the two can never disagree about which side of the line the account is on.
    ///
    /// ⚠️ THE LOCK IS ON THE PAGE, NOT ON THE HISTORY. The server records every account from the
    /// day it is deployed, so an account that reaches 100 opens onto its past, not onto nothing.
    static let glowersNeeded = 100

    /// Accounts whose Insights are never locked, at any Glower count (owner, 2026-09-30:
    /// "dont lock insights this user @realwarya"). ⚠️ Keyed by handle: if this account ever
    /// changes its username, update the name here.
    static let alwaysOpen: Set<String> = ["realwarya"]

    /// The one answer both the profile card and this page use.
    static func isUnlocked(glowers: Int, handle: String) -> Bool {
        alwaysOpen.contains(handle.lowercased()) || glowers >= glowersNeeded
    }

    private var unlocked: Bool { Self.isUnlocked(glowers: glow.displayGlowers.count, handle: handle) }

    private var report: InsightsReport {
        InsightsReport.build(period: period,
                             today: Date(),
                             days: history.days,
                             stories: history.stories,
                             firstDay: history.firstDay,
                             glowersNow: glow.displayGlowers.count)
    }

    var body: some View {
        Group {
            if unlocked { insights(report) } else { locked }
        }
        .navigationTitle("Insights")
        .navigationBarTitleDisplayMode(.inline)
        // A pushed page is not a tab — see the note in `GlowNotificationsView`.
        .toolbar(.hidden, for: .tabBar)
        // Nothing is read for a locked page; crossing the line while it is open starts the load.
        .task(id: unlocked ? liveKey : "locked") {
            if unlocked { await loader.load(live) }
        }
        .task(id: unlocked) {
            if unlocked {
                await history.load()
                await countries.load()
            }
        }
    }

    private func insights(_ report: InsightsReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                tabSwitch
                switch tab {
                case .overview: overviewTab(report)
                case .content: contentTab(report)
                case .audience: audienceTab(report)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .refreshable {
            await history.load()
            await loader.load(live)
            await countries.load()
        }
        // (No "28 days" button in the bar any more — owner, 2026-10-03: "remove that side, put it
        // in the header". The period is chosen beside the period's own heading, `periodHeader`.)
    }

    /// Apple's own segmented control — owner, 2026-10-03: "make it real Apple liquid glass". See
    /// the note on `GlowPeopleListView.tabs`; the same control at the same 46pt.
    private var tabSwitch: some View {
        NativeSegments(titles: Tab.allCases.map(\.title),
                       selected: Binding(get: { tab.rawValue }, set: { tab = Tab(rawValue: $0) ?? .overview }))
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .padding(.top, 8)
    }

    /// The sentence is his; the bar under it says how far there is to go.
    private var locked: some View {
        let count = glow.displayGlowers.count
        return ContentUnavailableView {
            Label("Insights", systemImage: "lock.fill")
        } description: {
            Text("Insights are available after reaching \(Self.glowersNeeded) Glowers.")
        } actions: {
            VStack(spacing: 8) {
                ProgressView(value: Double(min(count, Self.glowersNeeded)),
                             total: Double(Self.glowersNeeded))
                    .frame(maxWidth: 220)
                Text("\(count) of \(Self.glowersNeeded) Glowers")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Shared pieces

    /// A titled card: the grouped page's own background, rounded the way its sections are.
    private func card<Content: View>(_ title: String? = nil, footer: String? = nil,
                                     @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title).font(.headline)
            }
            content()
            if let footer, !footer.isEmpty {
                Text(footer).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// The history's own state, shared by every tab: loading, failed, or nothing recorded yet.
    @ViewBuilder private func historyGate<Content: View>(_ report: InsightsReport,
                                                          @ViewBuilder _ content: () -> Content) -> some View {
        switch history.phase {
        case .loading:
            card { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 20) }
        case .failed:
            card {
                Text("Could not load your history").foregroundStyle(.secondary)
                Button("Try Again") { Task { await history.load() } }
            }
        case .loaded:
            if report.hasHistory {
                content()
            } else {
                card(footer: "Your history starts with your next story view or Glow. Trends and comparisons appear here as the days add up.") {
                    Text("Nothing has been recorded yet.").foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The period's heading IS its picker: tap "Last 28 days ⌄" to choose 7, 28 or 90.
    private func periodHeader(_ report: InsightsReport) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Menu {
                Picker("Period", selection: $period) {
                    ForEach(InsightsPeriod.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(period.title).font(.title2.weight(.bold))
                    Image(systemName: "chevron.down").font(.subheadline.weight(.bold))
                }
                .foregroundStyle(.primary)
            }
            Text("\(Self.dayText(report.start)) to \(Self.dayText(report.end))")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    // MARK: - Overview

    @ViewBuilder private func overviewTab(_ report: InsightsReport) -> some View {
        periodHeader(report)
        historyGate(report) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Metric.allCases) { m in metricTile(m, report) }
                }
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
            card(metric.title, footer: overviewFooter(report)) {
                metricChart(report)
            }
        }
        liveCard
    }

    private func delta(_ m: Metric, _ report: InsightsReport) -> InsightsDelta {
        switch m {
        case .views: return report.views
        case .profileViews: return report.profileViews
        case .reactions: return report.reactions
        case .glowers: return report.glowersNet
        case .posted: return report.posted
        case .perStory: return report.viewsPerStory
        }
    }

    private func metricTile(_ m: Metric, _ report: InsightsReport) -> some View {
        let d = delta(m, report)
        let selected = m == metric
        let value = m == .glowers ? Self.signed(d.current)
                  : (m == .perStory ? Self.average(d.current) : Self.amount(d.current))
        return Button {
            withAnimation(.smooth(duration: 0.25)) { metric = m }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(m.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Text(value).font(.title2.weight(.bold)).monospacedDigit().foregroundStyle(.primary)
                if let change = Self.deltaText(d) {
                    Text(change.text).font(.footnote.weight(.medium))
                        .foregroundStyle(change.color).monospacedDigit()
                } else {
                    Text(" ").font(.footnote)
                }
            }
            .frame(width: 132, alignment: .leading)
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// One bar per recorded day for the picked figure. Views per story has no per-day value of its
    /// own, so it charts views, which is what it is made of.
    @ViewBuilder private func metricChart(_ report: InsightsReport) -> some View {
        let rows = report.recordedDays
        if rows.count >= 2 {
            Chart(rows) { row in
                let value: Int = {
                    switch metric {
                    case .views, .perStory: return max(0, row.day.storyViews)
                    case .profileViews: return max(0, row.day.profileViews)
                    case .reactions: return row.day.storyReactions
                    case .glowers: return row.day.glowersGained - row.day.glowersLost
                    case .posted: return row.day.storiesPosted
                    }
                }()
                BarMark(x: .value("Day", Self.chartDate(row.date), unit: .day),
                        y: .value(metric.title, value))
                    .foregroundStyle(value < 0 ? Color.red.gradient : Color.accentColor.gradient)
                    .cornerRadius(3)
            }
            .frame(height: 180)
        } else {
            Text("The chart appears after a second day of history.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    /// Says plainly why a figure has no comparison under it, and since when the numbers count.
    private func overviewFooter(_ report: InsightsReport) -> String {
        guard let first = report.firstDay else { return "" }
        let since = "Your history starts on \(Self.dayText(first, year: true))."
        if report.views.previous != nil {
            return "Each figure is compared with the \(period.rawValue) days before."
        }
        if report.coversPeriod {
            return "\(since) Comparison with the \(period.rawValue) days before appears once the history is that long."
        }
        return "\(since) These figures count from that day."
    }

    // MARK: - Live now

    @ViewBuilder private var liveCard: some View {
        if stories.state.isLoading {
            card("Live now") { ProgressView().frame(maxWidth: .infinity) }
        } else if stories.state.isFailed {
            card("Live now") { Text("Could not load stories").foregroundStyle(.secondary) }
        } else if live.isEmpty {
            card("Live now") { Text("You have no live stories.").foregroundStyle(.secondary) }
        } else if !GlowInsightsLoader.receiptsOn {
            card("Live now", footer: "Turn on view receipts in Settings > Stories to see who views your stories.") {
                Text("Story views are turned off.").foregroundStyle(.secondary)
            }
        } else {
            // ⛔ TAPPABLE — owner, 2026-10-03: "the names shown in Insights should be tappable and
            // work". Live now opens the stories it counts.
            NavigationLink { postedStories } label: {
                card("Live now", footer: "The stories that are live at this moment. Viewers are different people across all of them.") {
                    liveSummary
                }
            }
            .buttonStyle(.plain)
        }
    }

    /// Where a story figure leads: my own Posted stories, the page that opens each one.
    private var postedStories: some View {
        PostedStoriesView(uid: AuthService.shared.uid ?? "", isMe: true, title: title)
    }

    private var liveSummary: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 16) {
            GridRow {
                stat("Story views", loader.totalViews.map(GlowCount.short), nil)
                stat("Viewers", loader.viewers.map(GlowCount.short), nil)
            }
            GridRow {
                stat("Reactions", loader.totalReactions.map(GlowCount.short), nil)
                stat("Live stories", GlowCount.short(live.count), nil)
            }
            GridRow {
                stat("Views per story", loader.viewsPerStory.map(Self.average), nil)
                stat("Reaction rate", loader.reactionRate.map { String(format: "%.0f%%", $0 * 100) }, nil)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder private func contentTab(_ report: InsightsReport) -> some View {
        periodHeader(report)
        Picker("Sort", selection: $sort) {
            ForEach(StorySort.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        if history.phase == .loaded, report.hasHistory {
            let rows = sorted(report.periodStories)
            if rows.isEmpty {
                card {
                    ContentUnavailableView("No stories in this period",
                                           systemImage: "rectangle.stack",
                                           description: Text("Stories you post in the last \(period.rawValue) days appear here with their views and reactions."))
                }
            } else {
                card {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, record in
                        if i > 0 { Divider() }
                        NavigationLink { postedStories } label: { recordRow(record) }
                            .buttonStyle(.plain)
                    }
                }
            }
        } else if !loader.rows.isEmpty {
            // No history yet: the live stories are what there is to rank.
            card("Live stories") {
                ForEach(Array(loader.rows.enumerated()), id: \.element.id) { i, row in
                    if i > 0 { Divider() }
                    storyRow(thumb: .url(row.story.thumbUrl),
                             isVideo: row.story.isVideo,
                             detail: "\(row.story.createdAt.formatted(.relative(presentation: .named))) · \(Self.audience(row.story.audience))",
                             views: row.views,
                             reactions: row.reactions)
                }
            }
        } else {
            historyGate(report) { EmptyView() }
        }
    }

    private func sorted(_ rows: [InsightsStoryRecord]) -> [InsightsStoryRecord] {
        switch sort {
        case .latest: return rows.sorted { $0.createdAt > $1.createdAt }
        case .views: return rows.sorted { $0.views != $1.views ? $0.views > $1.views : $0.createdAt > $1.createdAt }
        case .reactions: return rows.sorted { $0.reactions != $1.reactions ? $0.reactions > $1.reactions : $0.createdAt > $1.createdAt }
        }
    }

    // MARK: - Audience

    @ViewBuilder private func audienceTab(_ report: InsightsReport) -> some View {
        periodHeader(report)
        card {
            VStack(alignment: .leading, spacing: 4) {
                Text("Glowers").font(.headline)
                Text(GlowCount.short(glow.displayGlowers.count))
                    .font(.system(size: 40, weight: .bold)).monospacedDigit()
                if report.hasHistory, let change = Self.deltaText(report.glowersNet) {
                    Text("\(change.text) against the \(period.rawValue) days before")
                        .font(.subheadline).foregroundStyle(change.color)
                }
            }
            NavigationLink {
                GlowPeopleListView(side: .glowers, title: title)
            } label: {
                valueRow("See your Glowers", "")
            }
            .foregroundStyle(.primary)
        }
        historyGate(report) {
            card("Glower growth") {
                Picker("Growth", selection: $growth) {
                    ForEach(GrowthView.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                growthChart(report)
                HStack {
                    // Gained opens the Glowers it added to. Unglows has no list on purpose: who
                    // stopped glowing you is not shown anywhere in the app.
                    NavigationLink {
                        GlowPeopleListView(side: .glowers, title: title)
                    } label: {
                        growthFigure("Gained", "+\(GlowCount.short(report.glowersGained))", .green)
                    }
                    .buttonStyle(.plain)
                    growthFigure("Unglows", "−\(GlowCount.short(report.glowersLost))", .red)
                    growthFigure("Net", Self.signed(Double(report.glowersGained - report.glowersLost)), .primary)
                }
            }
        }
        countriesCard
        historyGate(report) { activeTimesCard(report) }
        card {
            NavigationLink {
                GlowPeopleListView(side: .glowing, title: title)
            } label: {
                valueRow("Glowing", GlowCount.short(glow.displayGlowing.count))
            }
            .foregroundStyle(.primary)
        }
    }

    private func growthFigure(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.bold)).monospacedDigit().foregroundStyle(color)
            Text(label).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func growthChart(_ report: InsightsReport) -> some View {
        switch growth {
        case .overall:
            if report.glowersByDay.count >= 2 {
                Chart(report.glowersByDay) { point in
                    LineMark(x: .value("Day", Self.chartDate(point.date)),
                             y: .value("Glowers", point.value))
                        .interpolationMethod(.monotone)
                    AreaMark(x: .value("Day", Self.chartDate(point.date)),
                             y: .value("Glowers", point.value))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Color.accentColor.opacity(0.12).gradient)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 170)
            } else {
                Text("The chart appears after a second day of history.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        case .gained, .unglows:
            let gained = growth == .gained
            Chart(report.recordedDays) { row in
                BarMark(x: .value("Day", Self.chartDate(row.date), unit: .day),
                        y: .value(growth.title, gained ? row.day.glowersGained : row.day.glowersLost))
                    .foregroundStyle((gained ? Color.green : Color.red).gradient)
                    .cornerRadius(3)
            }
            .frame(height: 170)
        }
    }

    @ViewBuilder private var countriesCard: some View {
        card("Top countries",
             footer: "From the approximate country of each Glower's phone. Shown once enough Glowers have one, so nobody can be pointed at.") {
            switch countries.phase {
            case .loading:
                ProgressView().frame(maxWidth: .infinity)
            case .failed:
                Text("Could not load countries").foregroundStyle(.secondary)
                Button("Try Again") { Task { await countries.load() } }
            case .loaded:
                if countries.countries.isEmpty {
                    Text("Not enough Glowers with a known country yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(countries.countries) { c in shareBar(c.country, c.percent) }
                }
            }
        }
    }

    private func shareBar(_ label: String, _ percent: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                Spacer()
                Text("\(percent)%").font(.subheadline.weight(.semibold)).monospacedDigit()
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.tertiarySystemFill))
                    Capsule().fill(Color.accentColor.gradient)
                        .frame(width: max(4, g.size.width * CGFloat(percent) / 100))
                }
            }
            .frame(height: 8)
        }
        .accessibilityElement(children: .combine)
    }

    /// Views by three-hour block on the phone's own clock. The server keeps UTC hours.
    private func localBlocks(_ hoursUTC: [Int: Int]) -> [(label: String, views: Int)] {
        var blocks = [Int](repeating: 0, count: 8)
        let midnight = InsightsCalendar.startOfDay(Date())
        for (hour, views) in hoursUTC {
            let local = Calendar.current.component(.hour, from: midnight.addingTimeInterval(TimeInterval(hour) * 3600))
            blocks[local / 3] += views
        }
        let labels = ["12a", "3a", "6a", "9a", "12p", "3p", "6p", "9p"]
        return labels.indices.map { (label: labels[$0], views: blocks[$0]) }
    }

    @ViewBuilder private func activeTimesCard(_ report: InsightsReport) -> some View {
        let total = report.hoursUTC.values.reduce(0, +)
        card("When your stories are watched",
             footer: "On your phone's time zone (\(TimeZone.current.abbreviation() ?? TimeZone.current.identifier)).") {
            if total < InsightsReport.bestHourMinimum {
                Text("Not enough views in this period yet.").foregroundStyle(.secondary)
            } else {
                Chart(localBlocks(report.hoursUTC), id: \.label) { block in
                    BarMark(x: .value("Time", block.label), y: .value("Views", block.views))
                        .foregroundStyle(Color.accentColor.gradient)
                        .cornerRadius(6)
                }
                .chartYAxis(.hidden)
                .frame(height: 160)
                if let hour = report.bestHourUTC {
                    valueRow("Most views around", Self.hourText(hour))
                }
            }
        }
    }

    /// "+3" or "−3"; a zero has no sign.
    private static func signed(_ value: Double) -> String {
        let n = Int(value.rounded())
        if n == 0 { return "0" }
        return (n > 0 ? "+" : "−") + GlowCount.short(abs(n))
    }

    // MARK: - Rows

    private func stat(_ label: String, _ value: String?, _ delta: InsightsDelta?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value ?? "–")
                .font(.title2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.primary)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let delta, let change = Self.deltaText(delta) {
                Text(change.text)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(change.color)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func valueRow(_ label: String, _ value: String,
                          change: (text: String, color: Color)? = nil) -> some View {
        HStack {
            Text(label)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(value)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if let change {
                    Text(change.text)
                        .font(.footnote)
                        .foregroundStyle(change.color)
                        .monospacedDigit()
                }
            }
        }
    }

    /// Where a row's small picture comes from: a live story still has its thumbnail, an expired
    /// one has only the blurred cover its record kept, and some have neither.
    private enum Thumb {
        case url(String)
        case blur(String)
        case missing
    }

    private func recordRow(_ record: InsightsStoryRecord) -> some View {
        let liveStory = live.first { $0.id == record.id }
        let liveCount = loader.rows.first { $0.id == record.id }
        let thumb: Thumb
        if let liveStory {
            thumb = Thumb.url(liveStory.thumbUrl)
        } else {
            thumb = record.blurThumb.isEmpty ? Thumb.missing : Thumb.blur(record.blurThumb)
        }
        let state = liveStory != nil ? "Live" : Self.dayText(record.createdAt, utc: false)
        // A live story's counter is the fresher of the two while it is live.
        return storyRow(thumb: thumb,
                        isVideo: record.isVideo,
                        detail: "\(state) · \(Self.audience(record.audience))",
                        views: max(record.views, liveCount?.views ?? 0),
                        reactions: max(record.reactions, liveCount?.reactions ?? 0))
    }

    private func storyRow(thumb: Thumb, isVideo: Bool, detail: String,
                          views: Int?, reactions: Int?) -> some View {
        HStack(spacing: 12) {
            // The box decides the shape and the picture fills it — see `PostedStoryTile.tile`.
            Color.clear
                .frame(width: Self.thumbWidth, height: Self.thumbWidth / GlowStoryCardView.aspect)
                .overlay { thumbnail(thumb, isVideo: isVideo) }
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(isVideo ? "Video story" : "Photo story")
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Label(views.map(GlowCount.short) ?? "–", systemImage: "eye.fill")
                    .foregroundStyle(.primary)
                Label(reactions.map(GlowCount.short) ?? "–", systemImage: "heart.fill")
                    .foregroundStyle(.secondary)
            }
            .labelStyle(.titleAndIcon)
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func thumbnail(_ thumb: Thumb, isVideo: Bool) -> some View {
        switch thumb {
        case .url(let url):
            StoryImage(url: url).scaledToFill()
        case .blur(let base64):
            if let data = Data(base64Encoded: base64), let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                placeholder(isVideo: isVideo)
            }
        case .missing:
            placeholder(isVideo: isVideo)
        }
    }

    private func placeholder(isVideo: Bool) -> some View {
        ZStack {
            Color.secondary.opacity(0.15)
            Image(systemName: isVideo ? "video.fill" : "photo.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Words and numbers

    private static let thumbWidth: CGFloat = 40

    /// One decimal while it is small enough to matter, the usual short count after that.
    private static func average(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f", value) : GlowCount.short(Int(value.rounded()))
    }

    /// A whole number as a count, anything else as an average.
    private static func amount(_ value: Double) -> String {
        value == value.rounded() ? GlowCount.short(Int(value)) : average(value)
    }

    /// "+12 (8%)" in green, "−3 (25%)" in red, or nothing when there is no earlier period to
    /// compare with. The percentage is absent when the earlier figure was zero — see `InsightsDelta`.
    private static func deltaText(_ delta: InsightsDelta) -> (text: String, color: Color)? {
        guard let change = delta.change else { return nil }
        if change == 0 { return (text: "No change", color: Color.secondary) }
        var text = (change > 0 ? "+" : "−") + amount(abs(change))
        if let percent = delta.percent {
            text += String(format: " (%.0f%%)", abs(percent) * 100)
        }
        return (text: text, color: change > 0 ? Color.green : Color.red)
    }

    /// A UTC day moved to its own noon, so it reads as the same calendar date in any time zone
    /// the phone can be in. The server's days are UTC days; a chart or a label must not show the
    /// day before because the phone is west of Greenwich.
    private static func chartDate(_ utcDay: Date) -> Date {
        utcDay.addingTimeInterval(12 * 60 * 60)
    }

    private static func dayText(_ date: Date, year: Bool = false, utc: Bool = true) -> String {
        let shown = utc ? chartDate(date) : date
        return year ? shown.formatted(.dateTime.day().month(.abbreviated).year())
                    : shown.formatted(.dateTime.day().month(.abbreviated))
    }

    /// A UTC hour as the phone's own clock reads it: "9 PM".
    private static func hourText(_ utcHour: Int) -> String {
        let today = InsightsCalendar.startOfDay(Date())
        let moment = today.addingTimeInterval(TimeInterval(utcHour) * 60 * 60)
        return moment.formatted(.dateTime.hour())
    }

    /// The names the Posted stories filter uses for the same four audiences.
    private static func audience(_ label: String) -> String {
        switch label {
        case "everyone": return "Everyone"
        case "glowers": return "Glowers"
        case "custom": return "Custom"
        default: return "My Chats"
        }
    }
}
