import SwiftUI
import Charts
import FirebaseFunctions

// GROUP STATISTICS (owner 2026-10-26). Pushed from the group's page (GroupInfoView › Statistics) for
// the owner and admins of a big enough group. Layout follows the reference app's group statistics:
// an Overview of four figures against the week before, day charts for the last 30 days, the busiest
// hours and weekdays in the phone's own time zone, the members' languages, and three top-10 lists.
// Everything comes from the `groupStats` callable in one read; no message text ever reaches the phone,
// only counts. The contract is the server's (functions-groups `groupStats`).

// MARK: - Data

struct GroupStatsMetric {
    var value = 0
    /// The week before. nil = unknown, so no change is shown.
    var prev: Int?
}

struct GroupStatsPerson: Identifiable {
    let id: String
    let name: String
    let photoUrl: String?
    let detail: String
}

struct GroupStatsLanguage: Identifiable {
    let index: Int
    let code: String
    let count: Int
    var id: String { code + "-\(index)" }

    static let palette: [Color] = [.fariinBlue, .teal, .orange, .purple, .pink,
                                   .green, .yellow, .indigo, .mint, .brown, .gray]
    var color: Color { Self.palette[index % Self.palette.count] }

    var name: String {
        switch code {
        case "other": return "Other"
        case "", "unknown", "und": return "Unknown"
        default:
            return Locale.current.localizedString(forLanguageCode: code)?
                .capitalized(with: Locale.current) ?? code.uppercased()
        }
    }
}

/// One bar or point of a day chart.
struct GroupStatsPoint: Identifiable {
    let id: String
    let date: Date
    let series: String
    let value: Int
}

/// One bar of the hours / weekdays charts.
struct GroupStatsBin: Identifiable {
    let id: Int
    let label: String
    let value: Int
}

struct GroupStatsData {
    var now = Date()
    var since: Date?
    var days: [Date] = []
    var members = GroupStatsMetric()
    var messagesMetric = GroupStatsMetric()
    var viewers = GroupStatsMetric()
    var posters = GroupStatsMetric()
    var growth: [Int] = []
    var joined: [Int] = []
    var left: [Int] = []
    var srcLink: [Int] = []
    var srcPublic: [Int] = []
    var srcAdded: [Int] = []
    var srcRequest: [Int] = []
    var messages: [Int] = []
    var deleted: [Int] = []
    var banned: [Int] = []
    var hours: [GroupStatsBin] = []
    var weekdays: [GroupStatsBin] = []
    var languages: [GroupStatsLanguage] = []
    var topPosters: [GroupStatsPerson] = []
    var topAdmins: [GroupStatsPerson] = []
    var topInviters: [GroupStatsPerson] = []

    /// Defensive: a missing key is zeros, never a failure.
    init(_ d: [String: Any]) {
        typealias P = GroupStatsParse
        now = P.date(ms: d["now"]) ?? Date()
        since = P.date(ms: d["since"])
        days = P.days(d["days"])
        let n = days.count

        let o = P.dict(d["overview"])
        members = P.metric(o["members"])
        messagesMetric = P.metric(o["messages"])
        viewers = P.metric(o["viewers"])
        posters = P.metric(o["posters"])

        growth = P.ints(d["growth"], count: n)
        joined = P.ints(d["joined"], count: n)
        left = P.ints(d["left"], count: n)
        let s = P.dict(d["sources"])
        srcLink = P.ints(s["link"], count: n)
        srcPublic = P.ints(s["public"], count: n)
        srcAdded = P.ints(s["added"], count: n)
        srcRequest = P.ints(s["request"], count: n)
        messages = P.ints(d["messages"], count: n)
        let a = P.dict(d["actions"])
        deleted = P.ints(a["deleted"], count: n)
        banned = P.ints(a["banned"], count: n)

        let local = P.localHourOfWeek(P.ints(d["hourOfWeekUTC"], count: 168))
        hours = P.hourBins(local)
        weekdays = P.weekdayBins(local)

        var langs: [GroupStatsLanguage] = []
        for item in (d["languages"] as? [Any] ?? []) {
            guard let m = item as? [String: Any] else { continue }
            let count = P.int(m["count"])
            guard count > 0 else { continue }
            langs.append(GroupStatsLanguage(index: langs.count, code: (m["code"] as? String ?? "").lowercased(), count: count))
        }
        languages = langs

        topPosters = P.people(d["topPosters"]) { m in
            let c = P.int(m["messages"]), avg = P.int(m["avgChars"])
            return "\(c.formatted()) \(c == 1 ? "message" : "messages") · avg \(avg.formatted()) chars"
        }
        topAdmins = P.people(d["topAdmins"]) { m in
            "\(P.int(m["deleted"]).formatted()) deleted · \(P.int(m["banned"]).formatted()) removed"
        }
        topInviters = P.people(d["topInviters"]) { m in
            "\(P.int(m["invited"]).formatted()) invited"
        }
    }

    /// Day points for a chart, one series per name, one point per day.
    func points(_ series: [(name: String, values: [Int])]) -> [GroupStatsPoint] {
        var out: [GroupStatsPoint] = []
        for s in series {
            for (i, day) in days.enumerated() {
                let v = i < s.values.count ? s.values[i] : 0
                out.append(GroupStatsPoint(id: "\(s.name)-\(i)", date: day, series: s.name, value: v))
            }
        }
        return out
    }
}

/// `[String: Any]` reading for the callable's reply (Functions hands back NSDictionary / NSNumber).
enum GroupStatsParse {
    static func int(_ v: Any?) -> Int {
        if let n = v as? NSNumber { return n.intValue }
        if let i = v as? Int { return i }
        return 0
    }

    static func optInt(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return n.intValue }
        return v as? Int
    }

    /// A figure that may come as Int or Double (a channel's per-post means); nil when absent or null.
    static func optDouble(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        return nil
    }

    static func dict(_ v: Any?) -> [String: Any] { v as? [String: Any] ?? [:] }

    static func ints(_ v: Any?, count: Int) -> [Int] {
        var out = (v as? [Any] ?? []).map { int($0) }
        if out.count > count { out = Array(out.suffix(count)) }
        while out.count < count { out.insert(0, at: 0) }
        return out
    }

    static func date(ms v: Any?) -> Date? {
        guard let n = v as? NSNumber, n.doubleValue > 0 else { return nil }
        return Date(timeIntervalSince1970: n.doubleValue / 1000)
    }

    static func metric(_ v: Any?) -> GroupStatsMetric {
        let m = dict(v)
        return GroupStatsMetric(value: int(m["value"]), prev: optInt(m["prev"]))
    }

    /// "yyyy-MM-dd" read as a LOCAL day, so the axis shows the same date the server named.
    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func days(_ v: Any?) -> [Date] {
        var out: [Date] = []
        for item in (v as? [Any] ?? []) {
            if let s = item as? String, let d = dayParser.date(from: s) { out.append(d) }
        }
        if !out.isEmpty { return out }
        // No dates sent: the 30 days ending today.
        let today = Calendar.current.startOfDay(for: Date())
        return (0..<30).reversed().compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: today) }
    }

    /// One "yyyy-MM-dd" (a channel chart row's `d`, the period's `from` / `to`).
    static func day(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        return dayParser.date(from: s)
    }

    static func people(_ v: Any?, detail: ([String: Any]) -> String) -> [GroupStatsPerson] {
        var out: [GroupStatsPerson] = []
        for item in (v as? [Any] ?? []) {
            guard let m = item as? [String: Any] else { continue }
            let uid = m["uid"] as? String ?? "row\(out.count)"
            var photo = m["photoUrl"] as? String
            if photo?.isEmpty == true { photo = nil }
            out.append(GroupStatsPerson(id: uid, name: m["name"] as? String ?? "", photoUrl: photo, detail: detail(m)))
        }
        return out
    }

    /// The server's 168 UTC hours (index = weekday*24 + hour, 0 = Sunday) moved into the phone's own
    /// time zone. Whole hours only; a half-hour zone rounds down.
    static func localHourOfWeek(_ utc: [Int]) -> [Int] {
        var out = Array(repeating: 0, count: 168)
        guard utc.count == 168 else { return out }
        let shift = Int((Double(TimeZone.current.secondsFromGMT()) / 3600).rounded(.down))
        for i in 0..<168 {
            let j = ((i + shift) % 168 + 168) % 168
            out[j] += utc[i]
        }
        return out
    }

    static func hourBins(_ week: [Int]) -> [GroupStatsBin] {
        var sums = Array(repeating: 0, count: 24)
        for (i, v) in week.enumerated() { sums[i % 24] += v }
        return sums.enumerated().map { GroupStatsBin(id: $0.offset, label: "\($0.offset)", value: $0.element) }
    }

    /// Monday first, as the reference app shows them.
    static func weekdayBins(_ week: [Int]) -> [GroupStatsBin] {
        var sums = Array(repeating: 0, count: 7)
        for (i, v) in week.enumerated() { sums[min(i / 24, 6)] += v }
        let symbols = Calendar.current.shortWeekdaySymbols   // index 0 = Sunday
        return [1, 2, 3, 4, 5, 6, 0].map { d in
            GroupStatsBin(id: d, label: d < symbols.count ? symbols[d] : "\(d)", value: sums[d])
        }
    }
}

// MARK: - Channel data

// CHANNEL STATISTICS (owner 2026-10-29). The same `groupStats` callable answers `kind: "channel"` for
// a channel, in the shape of the reference app's channel page: an Overview of followers and per-post /
// per-story means, day charts, views by hour, and the recent posts. A figure the server has no data for
// comes as null and its tile or chart is left out; nothing here is made up.

/// One Overview tile, ready to draw.
struct GroupStatsChannelTile: Identifiable {
    let id: String
    let value: String
    let change: (text: String, color: Color)?
}

/// One row of Recent Posts: a channel post or a channel story.
struct GroupStatsPost: Identifiable {
    let id: String
    let isStory: Bool
    let at: Date?
    let preview: String
    let thumb: String?
    let views: Int?
    let reactions: Int?
    let shares: Int?
}

struct GroupStatsChannelData {
    var from: Date?
    var to: Date?
    var tiles: [GroupStatsChannelTile] = []
    var growth: [GroupStatsPoint] = []
    var followers: [GroupStatsPoint] = []
    var notifications: [GroupStatsPoint] = []
    var hours: [GroupStatsBin] = []
    var interactions: [GroupStatsPoint] = []
    var emojiNames: [String] = []
    var emoji: [GroupStatsPoint] = []
    var storyNames: [String] = []
    var stories: [GroupStatsPoint] = []
    var recentPosts: [GroupStatsPost] = []

    /// Defensive like the group's: a missing or null key leaves its part out, never a failure.
    init(_ d: [String: Any]) {
        typealias P = GroupStatsParse
        from = P.day(d["from"])
        to = P.day(d["to"])
        tiles = Self.tiles(P.dict(d["overview"]))

        let c = P.dict(d["charts"])
        growth = Self.series(c["growth"], [(key: "followers", name: "Followers")])
        followers = Self.series(c["followers"], [(key: "joined", name: "Joined"), (key: "left", name: "Left")])
        notifications = Self.series(c["notifications"], [(key: "muted", name: "Muted"), (key: "unmuted", name: "Unmuted")])
        interactions = Self.series(c["interactions"], [(key: "views", name: "Views"), (key: "reactions", name: "Reactions")])

        // Views by hour: 24 UTC hours moved into the phone's time zone, as the group's Top Hours.
        let utc = (c["viewsByHour"] as? [Any] ?? []).map { P.int($0) }
        if utc.count == 24 {
            hours = P.hourBins(P.localHourOfWeek(utc + Array(repeating: 0, count: 144)))
        }

        (emojiNames, emoji) = Self.emojiSeries(c["reactionsByEmoji"])

        // Story shares only when any story was shared, so an all-zero line doesn't crowd the chart.
        let rows = c["stories"] as? [Any] ?? []
        let shared = rows.contains { P.int(P.dict($0)["reposts"]) > 0 }
        var keys: [(key: String, name: String)] = [(key: "views", name: "Views"), (key: "reactions", name: "Reactions")]
        if shared { keys.append((key: "reposts", name: "Shares")) }
        stories = Self.series(rows, keys)
        storyNames = stories.isEmpty ? [] : keys.map { $0.name }

        recentPosts = Self.posts(d["recentPosts"])
    }

    /// The reference app's eight tiles in its order. A null figure, or a zero with no change, is left out.
    private static func tiles(_ o: [String: Any]) -> [GroupStatsChannelTile] {
        typealias P = GroupStatsParse
        var out: [GroupStatsChannelTile] = []
        func add(_ label: String, _ v: Any?) {
            let m = P.dict(v)
            guard let now = P.optDouble(m["now"]) else { return }
            let change = GroupStatsTile.change(now, P.optDouble(m["prev"]))
            if now == 0 && change == nil { return }
            out.append(GroupStatsChannelTile(id: label, value: GroupStatsTile.number(now), change: change))
        }
        add("Followers", o["followers"])
        // The share of followers who have not muted the channel; no change line, as the reference app.
        let n = P.dict(o["enabledNotifications"])
        if let part = P.optDouble(n["part"]), let total = P.optDouble(n["total"]), total > 0, part > 0 {
            let pct = Int((part / total * 100).rounded())
            out.append(GroupStatsChannelTile(id: "Enabled Notifications", value: "\(pct)%", change: nil))
        }
        add("Views Per Post", o["viewsPerPost"])
        add("Views Per Story", o["viewsPerStory"])
        add("Shares Per Post", o["sharesPerPost"])
        add("Shares Per Story", o["sharesPerStory"])
        add("Reactions Per Post", o["reactionsPerPost"])
        add("Reactions Per Story", o["reactionsPerStory"])
        return out
    }

    /// Day rows `{ d, key: n, ... }` as chart points, one series per key. No rows, no points.
    private static func series(_ v: Any?, _ keys: [(key: String, name: String)]) -> [GroupStatsPoint] {
        typealias P = GroupStatsParse
        var out: [GroupStatsPoint] = []
        for (i, item) in (v as? [Any] ?? []).enumerated() {
            let row = P.dict(item)
            guard let day = P.day(row["d"]) else { continue }
            // A day from before the server started counting (`counted: false`, 2026-10-29 audit E11)
            // is left out, so the growth line is not drawn as history it does not have.
            if (row["counted"] as? Bool) == false { continue }
            for k in keys {
                out.append(GroupStatsPoint(id: "\(k.name)-\(i)", date: day, series: k.name, value: P.int(row[k.key])))
            }
        }
        return out
    }

    /// Reactions by emoji, stacked: the ten most used each get a colour, the rest go in "Other".
    private static func emojiSeries(_ v: Any?) -> (names: [String], points: [GroupStatsPoint]) {
        typealias P = GroupStatsParse
        var rows: [(day: Date, counts: [String: Int])] = []
        var totals: [String: Int] = [:]
        for item in (v as? [Any] ?? []) {
            let row = P.dict(item)
            guard let day = P.day(row["d"]) else { continue }
            var counts: [String: Int] = [:]
            for (e, n) in P.dict(row["counts"]) {
                let c = P.int(n)
                guard c > 0 else { continue }
                counts[e] = c
                totals[e, default: 0] += c
            }
            rows.append((day: day, counts: counts))
        }
        let ranked = totals.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { $0.key }
        guard !ranked.isEmpty else { return (names: [], points: []) }
        let top = Array(ranked.prefix(10))
        let names = ranked.count > top.count ? top + ["Other"] : top
        var points: [GroupStatsPoint] = []
        for (i, r) in rows.enumerated() {
            for name in names {
                let value = name == "Other"
                    ? r.counts.filter { !top.contains($0.key) }.reduce(0) { $0 + $1.value }
                    : (r.counts[name] ?? 0)
                points.append(GroupStatsPoint(id: "\(name)-\(i)", date: r.day, series: name, value: value))
            }
        }
        return (names: names, points: points)
    }

    private static func posts(_ v: Any?) -> [GroupStatsPost] {
        typealias P = GroupStatsParse
        var out: [GroupStatsPost] = []
        for item in (v as? [Any] ?? []) {
            guard let m = item as? [String: Any] else { continue }
            var thumb = m["thumb"] as? String
            if thumb?.isEmpty == true { thumb = nil }
            out.append(GroupStatsPost(id: m["id"] as? String ?? "post\(out.count)",
                                      isStory: (m["kind"] as? String) == "story",
                                      at: P.date(ms: m["at"]),
                                      preview: m["preview"] as? String ?? "",
                                      thumb: thumb,
                                      views: P.optInt(m["views"]),
                                      reactions: P.optInt(m["reactions"]),
                                      shares: P.optInt(m["shares"])))
        }
        return out
    }
}

// MARK: - Page

struct GroupStatsView: View {
    let cid: String
    let title: String
    /// A channel gets the channel's words (owner 2026-10-29); the reply's `kind` decides which page draws.
    var isChannel = false

    @State private var stats: GroupStatsData?
    @State private var channel: GroupStatsChannelData?
    @State private var failure: String?

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Statistics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { header }
            }
            .task { if stats == nil && channel == nil { await load() } }
    }

    private var header: some View {
        VStack(spacing: 0) {
            Text("Statistics").font(.headline)
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    @ViewBuilder private var content: some View {
        if let channel {
            ScrollView { channelPage(channel) }
        } else if let stats {
            ScrollView { page(stats) }
        } else if let failure {
            errorView(failure)
        } else {
            // The page's own shape while it loads, not a spinner (owner 2026-10-26).
            ScrollView { GroupStatsSkeleton() }.scrollDisabled(true)
        }
    }

    private func page(_ s: GroupStatsData) -> some View {
        VStack(spacing: 16) {
            GroupStatsOverviewCard(stats: s)
            chartsSection(s)
            activitySection(s)
            listsSection(s)
            if let since = s.since {
                Text("Counting started \(since.formatted(date: .abbreviated, time: .omitted))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Channel page (owner 2026-10-29)

    /// The reference app's channel page: Overview, the charts the server filled, then Recent Posts.
    /// None of the group's member sections; the same cards and charts as the group page.
    private func channelPage(_ s: GroupStatsChannelData) -> some View {
        VStack(spacing: 16) {
            // Nothing at all to show: said, not a blank page (owner 2026-10-29 audit U14).
            if Self.isEmpty(s) {
                Text("No activity in the last 30 days yet. Numbers show here once the channel gets follows and views.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16).padding(.top, 40)
            }
            if !s.tiles.isEmpty { GroupStatsChannelOverviewCard(stats: s) }
            channelFollowerCharts(s)
            channelViewCharts(s)
            if !s.recentPosts.isEmpty { GroupStatsPostsCard(title: "Recent Posts", posts: s.recentPosts) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder private func channelFollowerCharts(_ s: GroupStatsChannelData) -> some View {
        if !s.growth.isEmpty {
            GroupStatsDayChart(title: "Growth", kind: .line,
                               names: ["Followers"], colors: [Color.fariinBlue], points: s.growth)
        }
        if !s.followers.isEmpty {
            GroupStatsDayChart(title: "Followers", kind: .bars,
                               names: ["Joined", "Left"], colors: [Color.fariinBlue, Color.orange], points: s.followers)
        }
        if !s.notifications.isEmpty {
            GroupStatsDayChart(title: "Notifications", kind: .bars,
                               names: ["Muted", "Unmuted"], colors: [Color.fariinBlue, Color.orange], points: s.notifications)
        }
    }

    @ViewBuilder private func channelViewCharts(_ s: GroupStatsChannelData) -> some View {
        if !s.hours.isEmpty {
            GroupStatsBinsCard(title: "Views by Hours", bins: s.hours,
                               axisValues: ["0", "6", "12", "18"],
                               caption: Self.busiestHour(s.hours), valueName: "Views")
        }
        if !s.interactions.isEmpty {
            GroupStatsDayChart(title: "Views and Reactions", kind: .line,
                               names: ["Views", "Reactions"], colors: [Color.fariinBlue, Color.orange],
                               points: s.interactions, showsNow: false)
        }
        if !s.emoji.isEmpty {
            GroupStatsDayChart(title: "Reactions", kind: .bars, names: s.emojiNames,
                               colors: Self.emojiColors(s.emojiNames.count), points: s.emoji)
        }
        if !s.stories.isEmpty {
            GroupStatsDayChart(title: "Story Views and Reactions", kind: .line, names: s.storyNames,
                               colors: Self.storyColors(s.storyNames.count),
                               points: s.stories, showsNow: false)
        }
    }

    private static func isEmpty(_ s: GroupStatsChannelData) -> Bool {
        s.tiles.isEmpty && s.growth.isEmpty && s.followers.isEmpty && s.notifications.isEmpty
            && s.hours.isEmpty && s.interactions.isEmpty && s.emoji.isEmpty && s.stories.isEmpty
            && s.recentPosts.isEmpty
    }

    /// The languages ring's palette, one colour per emoji in order.
    private static func emojiColors(_ n: Int) -> [Color] {
        let p = GroupStatsLanguage.palette
        return (0..<n).map { p[$0 % p.count] }
    }

    private static func storyColors(_ n: Int) -> [Color] {
        let p: [Color] = [Color.fariinBlue, Color.orange, Color.teal]
        return Array(p.prefix(n))
    }

    // MARK: Group page

    @ViewBuilder private func chartsSection(_ s: GroupStatsData) -> some View {
        GroupStatsDayChart(title: "Growth", kind: .line,
                           names: ["Members"], colors: [Color.fariinBlue],
                           points: s.points([(name: "Members", values: s.growth)]))
        GroupStatsDayChart(title: "Members", kind: .bars,
                           names: ["Joined", "Left"], colors: [Color.fariinBlue, Color.orange],
                           points: s.points([(name: "Joined", values: s.joined), (name: "Left", values: s.left)]))
        GroupStatsDayChart(title: "New Members by Source", kind: .bars,
                           names: ["Link", "Public", "Added", "Request"],
                           colors: [Color.fariinBlue, Color.teal, Color.orange, Color.purple],
                           points: s.points([(name: "Link", values: s.srcLink), (name: "Public", values: s.srcPublic),
                                             (name: "Added", values: s.srcAdded), (name: "Request", values: s.srcRequest)]))
        GroupStatsDayChart(title: "Messages", kind: .bars,
                           names: ["Messages"], colors: [Color.fariinBlue],
                           points: s.points([(name: "Messages", values: s.messages)]))
        GroupStatsDayChart(title: "Actions", kind: .bars,
                           names: ["Deleted", "Removed"], colors: [Color.fariinBlue, Color.orange],
                           points: s.points([(name: "Deleted", values: s.deleted), (name: "Removed", values: s.banned)]))
    }

    @ViewBuilder private func activitySection(_ s: GroupStatsData) -> some View {
        GroupStatsBinsCard(title: "Top Hours", bins: s.hours,
                           axisValues: ["0", "6", "12", "18"],
                           caption: Self.busiestHour(s.hours))
        GroupStatsBinsCard(title: "Weekdays", bins: s.weekdays,
                           axisValues: s.weekdays.map(\.label),
                           caption: Self.busiestDay(s.weekdays))
        if !s.languages.isEmpty {
            GroupStatsLanguagesCard(langs: s.languages)
        }
    }

    @ViewBuilder private func listsSection(_ s: GroupStatsData) -> some View {
        if !s.topPosters.isEmpty { GroupStatsPeopleCard(title: "Top Members", people: s.topPosters) }
        if !s.topAdmins.isEmpty { GroupStatsPeopleCard(title: "Top Admins", people: s.topAdmins) }
        if !s.topInviters.isEmpty { GroupStatsPeopleCard(title: "Top Inviters", people: s.topInviters) }
    }

    private static func busiestHour(_ bins: [GroupStatsBin]) -> String {
        guard let top = bins.max(by: { $0.value < $1.value }), top.value > 0 else { return "Your local time" }
        return "Busiest at " + String(format: "%02d:00", top.id)
    }

    private static func busiestDay(_ bins: [GroupStatsBin]) -> String {
        guard let top = bins.max(by: { $0.value < $1.value }), top.value > 0 else { return "Your local time" }
        return "Busiest on " + top.label
    }

    private func errorView(_ text: String) -> some View {
        VStack(spacing: 14) {
            Text(text)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                failure = nil
                Task { await load() }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.fariinBlue)
        }
        .padding(32)
    }

    private func load() async {
        do {
            let r = try await Functions.functions(region: "me-central1")
                .httpsCallable("groupStats").call(["cid": cid])
            let d = r.data as? [String: Any] ?? [:]
            if (d["kind"] as? String) == "channel" {
                channel = GroupStatsChannelData(d)
            } else {
                stats = GroupStatsData(d)
            }
            failure = nil
        } catch let e as NSError where e.domain == FunctionsErrorDomain {
            failure = Self.message(code: e.code, channel: isChannel)
        } catch {
            failure = Self.message(code: -1, channel: isChannel)
        }
    }

    private static func message(code: Int, channel: Bool) -> String {
        switch code {
        case FunctionsErrorCode.permissionDenied.rawValue:
            return channel ? "Only the channel's owner and admins can see statistics."
                           : "Only the group's owner and admins can see statistics."
        case FunctionsErrorCode.failedPrecondition.rawValue:
            if channel {
                return "Statistics appear once this channel has \(AppLimits.shared.channelStatsMinFollowers) followers."
            }
            return "Statistics appear once the group is bigger."
        default:
            return "Couldn't load statistics. Check your connection and try again."
        }
    }
}

// MARK: - Cards

/// A rounded card with a title, the page's one container.
/// The loading page: the overview card's four tiles, a chart card and a list card, in the real cards'
/// frames, so nothing jumps when the figures land.
struct GroupStatsSkeleton: View {
    var body: some View {
        VStack(spacing: 16) {
            card {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 18) {
                    GridRow { tile; tile }
                    GridRow { tile; tile }
                }
            }
            card { SkeletonBlock(height: 180, radius: 12) }
            card {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(0..<4, id: \.self) { _ in
                        HStack(spacing: 12) {
                            SkeletonCircle(size: 32)
                            SkeletonBlock(width: 140, height: 12)
                            Spacer()
                            SkeletonBlock(width: 36, height: 12)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityLabel("Loading statistics")
    }

    private var tile: some View {
        VStack(alignment: .leading, spacing: 8) {
            SkeletonBlock(width: 64, height: 22)
            SkeletonBlock(width: 96, height: 11)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SkeletonBlock(width: 110, height: 16)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

struct GroupStatsCard<Content: View>: View {
    let title: String
    var trailing: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

struct GroupStatsOverviewCard: View {
    let stats: GroupStatsData

    var body: some View {
        GroupStatsCard(title: "Overview", trailing: period) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 18) {
                GridRow {
                    tile("Members", stats.members)
                    tile("Messages", stats.messagesMetric)
                }
                GridRow {
                    tile("Viewing Members", stats.viewers)
                    tile("Posting Members", stats.posters)
                }
            }
        }
    }

    /// "Oct 19 – Oct 26": the week the figures cover.
    private var period: String {
        let end = stats.now
        let start = Calendar.current.date(byAdding: .day, value: -7, to: end) ?? end
        let style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        return start.formatted(style) + " \u{2013} " + end.formatted(style)
    }

    private func tile(_ label: String, _ m: GroupStatsMetric) -> some View {
        GroupStatsTile(label: label, value: m.value.formatted(),
                       change: GroupStatsTile.change(Double(m.value), m.prev.map { Double($0) }))
    }
}

/// One Overview figure: the number, its change against the period before, and its name. Shared by the
/// group's and the channel's Overview (owner 2026-10-29), so both look the same.
struct GroupStatsTile: View {
    let label: String
    let value: String
    let change: (text: String, color: Color)?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            if let d = change {
                Text(d.text).font(.caption.weight(.medium)).foregroundStyle(d.color)
            }
            Text(label).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A whole number as before; a channel's mean keeps one decimal at most ("412.5").
    nonisolated static func number(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(0...1)))
    }

    /// "+12 (8%)" / "−3 (2%)" against the period before; nothing when that period is unknown or zero.
    nonisolated static func change(_ value: Double, _ prev: Double?) -> (text: String, color: Color)? {
        guard let prev, prev > 0 else { return nil }
        let diff = value - prev
        let pct = Int((abs(diff) / prev * 100).rounded())
        if diff > 0 { return (text: "+\(number(diff)) (\(pct)%)", color: .green) }
        if diff < 0 { return (text: "\u{2212}\(number(abs(diff))) (\(pct)%)", color: .red) }
        return (text: "+0 (0%)", color: .secondary)
    }
}

/// The channel's Overview: the group card and tiles, two to a row, only the tiles the server filled.
struct GroupStatsChannelOverviewCard: View {
    let stats: GroupStatsChannelData

    var body: some View {
        GroupStatsCard(title: "Overview", trailing: period) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 18) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow { cells(row) }
                }
            }
        }
    }

    private var rows: [[GroupStatsChannelTile]] {
        stride(from: 0, to: stats.tiles.count, by: 2).map { Array(stats.tiles[$0..<min($0 + 2, stats.tiles.count)]) }
    }

    @ViewBuilder private func cells(_ row: [GroupStatsChannelTile]) -> some View {
        ForEach(row) { t in
            GroupStatsTile(label: t.id, value: t.value, change: t.change)
        }
        if row.count == 1 { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
    }

    /// "Sep 30 – Oct 29": the days the server counted.
    private var period: String? {
        guard let from = stats.from, let to = stats.to else { return nil }
        let style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        return from.formatted(style) + " \u{2013} " + to.formatted(style)
    }
}

/// Thirty days as a line or stacked bars. Touch and drag picks a day and the caption shows its values.
struct GroupStatsDayChart: View {
    enum Kind { case line, bars }

    let title: String
    let kind: Kind
    let names: [String]
    let colors: [Color]
    let points: [GroupStatsPoint]
    /// A line of counts that are not a running total (a channel's views and reactions) shows the
    /// period's totals, not "Now" (owner 2026-10-29).
    var showsNow = true

    @State private var selected: Date?

    var body: some View {
        GroupStatsCard(title: title) {
            VStack(alignment: .leading, spacing: 10) {
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if kind == .line { styled(lineChart) } else { styled(barChart) }
            }
        }
    }

    private var selectedDay: Date? {
        guard let s = selected else { return nil }
        return points.first { Calendar.current.isDate($0.date, inSameDayAs: s) }?.date
    }

    private func value(_ name: String, on day: Date) -> Int {
        points.first { $0.series == name && $0.date == day }?.value ?? 0
    }

    private func total(_ name: String) -> Int {
        points.reduce(0) { $0 + ($1.series == name ? $1.value : 0) }
    }

    private var caption: String {
        let style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        if let day = selectedDay {
            let parts = names.map { n in
                names.count > 1 ? "\(n) \(value(n, on: day).formatted())" : value(n, on: day).formatted()
            }
            return day.formatted(style) + ": " + parts.joined(separator: " · ")
        }
        if kind == .line, showsNow, let first = names.first, let last = points.last(where: { $0.series == first }) {
            return "Now \(last.value.formatted())"
        }
        let parts = names.map { n in
            names.count > 1 ? "\(n) \(total(n).formatted())" : total(n).formatted()
        }
        return "Last 30 days: " + parts.joined(separator: " · ")
    }

    private var lineChart: some View {
        Chart {
            ForEach(points) { p in
                LineMark(x: .value("Day", p.date, unit: .day), y: .value("Count", p.value))
                    .foregroundStyle(by: .value("Series", p.series))
                    .interpolationMethod(.monotone)
            }
            if let day = selectedDay {
                RuleMark(x: .value("Day", day, unit: .day))
                    .foregroundStyle(Color.secondary.opacity(0.35))
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
    }

    private var barChart: some View {
        Chart {
            ForEach(points) { p in
                BarMark(x: .value("Day", p.date, unit: .day), y: .value("Count", p.value))
                    .foregroundStyle(by: .value("Series", p.series))
                    .cornerRadius(2)
            }
            if let day = selectedDay {
                RuleMark(x: .value("Day", day, unit: .day))
                    .foregroundStyle(Color.secondary.opacity(0.35))
            }
        }
    }

    private func styled<V: View>(_ chart: V) -> some View {
        chart
            .chartForegroundStyleScale(domain: names, range: colors)
            .chartLegend(names.count > 1 ? Visibility.visible : Visibility.hidden)
            .chartXSelection(value: $selected)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 7)) {
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .frame(height: names.count > 1 ? 200 : 180)
    }
}

/// Bars over fixed labels: the 24 hours or the 7 weekdays, in local time.
struct GroupStatsBinsCard: View {
    let title: String
    let bins: [GroupStatsBin]
    let axisValues: [String]
    let caption: String
    /// What a bar counts: messages for a group, views for a channel (owner 2026-10-29).
    var valueName = "Messages"

    var body: some View {
        GroupStatsCard(title: title) {
            VStack(alignment: .leading, spacing: 10) {
                Text(caption).font(.footnote).foregroundStyle(.secondary)
                chart
            }
        }
    }

    private var chart: some View {
        Chart(bins) { b in
            BarMark(x: .value("Time", b.label), y: .value(valueName, b.value))
                .foregroundStyle(Color.fariinBlue.gradient)
                .cornerRadius(2)
        }
        .chartXAxis {
            AxisMarks(values: axisValues)
        }
        .frame(height: 160)
    }
}

/// The members' phone languages as a ring, with the legend beside it.
struct GroupStatsLanguagesCard: View {
    let langs: [GroupStatsLanguage]

    private var total: Int { max(1, langs.reduce(0) { $0 + $1.count }) }

    var body: some View {
        GroupStatsCard(title: "Languages") {
            HStack(alignment: .center, spacing: 18) {
                donut.frame(width: 130, height: 130)
                legend
            }
        }
    }

    private var donut: some View {
        Chart(langs) { l in
            SectorMark(angle: .value("Members", l.count), innerRadius: .ratio(0.62), angularInset: 1.5)
                .cornerRadius(3)
                .foregroundStyle(l.color)
        }
        .chartLegend(.hidden)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(langs) { l in
                legendRow(l)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func legendRow(_ l: GroupStatsLanguage) -> some View {
        let pct = Int((Double(l.count) * 100 / Double(total)).rounded())
        return HStack(spacing: 8) {
            Circle().fill(l.color).frame(width: 8, height: 8)
            Text(l.name).font(.subheadline).lineLimit(1)
            Spacer(minLength: 4)
            Text(verbatim: "\(pct)%").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

/// A top-10 list: face, name, and what they did.
struct GroupStatsPeopleCard: View {
    let title: String
    let people: [GroupStatsPerson]

    var body: some View {
        GroupStatsCard(title: title) {
            VStack(spacing: 0) {
                ForEach(Array(people.enumerated()), id: \.element.id) { i, p in
                    if i > 0 { Divider().padding(.leading, 48) }
                    row(p)
                }
            }
        }
    }

    private func row(_ p: GroupStatsPerson) -> some View {
        HStack(spacing: 12) {
            AvatarView(name: p.name, photoUrl: p.photoUrl, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name.isEmpty ? "Member" : p.name).font(.body).lineLimit(1)
                Text(p.detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }
}

/// A channel's Recent Posts (owner 2026-10-29): the people list's rows, with the post's picture (or a
/// plain mark) where the face would be, and what it got.
struct GroupStatsPostsCard: View {
    let title: String
    let posts: [GroupStatsPost]

    var body: some View {
        GroupStatsCard(title: title) {
            VStack(spacing: 0) {
                ForEach(Array(posts.enumerated()), id: \.element.id) { i, p in
                    if i > 0 { Divider().padding(.leading, 48) }
                    row(p)
                }
            }
        }
    }

    private func row(_ p: GroupStatsPost) -> some View {
        HStack(spacing: 12) {
            thumb(p)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.preview.isEmpty ? (p.isStory ? "Story" : "Post") : p.preview).font(.body).lineLimit(1)
                Text(Self.detail(p)).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder private func thumb(_ p: GroupStatsPost) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if let s = p.thumb, let url = URL(string: s) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                shape.fill(Color(uiColor: .tertiarySystemFill))
            }
            .frame(width: 36, height: 36)
            .clipShape(shape)
        } else {
            shape.fill(Color(uiColor: .tertiarySystemFill))
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: p.isStory ? "circle.dashed" : "text.alignleft")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
        }
    }

    /// "Oct 28 · 412 views · 12 reactions · 3 shares": only what the server counted.
    private static func detail(_ p: GroupStatsPost) -> String {
        var parts: [String] = []
        if let at = p.at { parts.append(at.formatted(.dateTime.month(.abbreviated).day())) }
        if let v = p.views { parts.append("\(v.formatted()) \(v == 1 ? "view" : "views")") }
        if let r = p.reactions { parts.append("\(r.formatted()) \(r == 1 ? "reaction" : "reactions")") }
        if let s = p.shares { parts.append("\(s.formatted()) \(s == 1 ? "share" : "shares")") }
        return parts.joined(separator: " \u{00B7} ")
    }
}
