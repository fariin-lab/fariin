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

// MARK: - Page

struct GroupStatsView: View {
    let cid: String
    let title: String

    @State private var stats: GroupStatsData?
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
            .task { if stats == nil { await load() } }
    }

    private var header: some View {
        VStack(spacing: 0) {
            Text("Statistics").font(.headline)
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    @ViewBuilder private var content: some View {
        if let stats {
            ScrollView { page(stats) }
        } else if let failure {
            errorView(failure)
        } else {
            ProgressView()
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
            stats = GroupStatsData(d)
            failure = nil
        } catch let e as NSError where e.domain == FunctionsErrorDomain {
            failure = Self.message(code: e.code)
        } catch {
            failure = Self.message(code: -1)
        }
    }

    private static func message(code: Int) -> String {
        switch code {
        case FunctionsErrorCode.permissionDenied.rawValue:
            return "Only the group's owner and admins can see statistics."
        case FunctionsErrorCode.failedPrecondition.rawValue:
            return "Statistics appear once the group is bigger."
        default:
            return "Couldn't load statistics. Check your connection and try again."
        }
    }
}

// MARK: - Cards

/// A rounded card with a title, the page's one container.
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
        VStack(alignment: .leading, spacing: 2) {
            Text(m.value.formatted())
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            if let d = Self.change(m) {
                Text(d.text).font(.caption.weight(.medium)).foregroundStyle(d.color)
            }
            Text(label).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "+12 (8%)" / "−3 (2%)" against the week before; nothing when that week is unknown or zero.
    private static func change(_ m: GroupStatsMetric) -> (text: String, color: Color)? {
        guard let prev = m.prev, prev > 0 else { return nil }
        let diff = m.value - prev
        let pct = Int((Double(abs(diff)) / Double(prev) * 100).rounded())
        if diff > 0 { return (text: "+\(diff.formatted()) (\(pct)%)", color: .green) }
        if diff < 0 { return (text: "\u{2212}\(abs(diff).formatted()) (\(pct)%)", color: .red) }
        return (text: "+0 (0%)", color: .secondary)
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
        if kind == .line, let first = names.first, let last = points.last(where: { $0.series == first }) {
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
            BarMark(x: .value("Time", b.label), y: .value("Messages", b.value))
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
