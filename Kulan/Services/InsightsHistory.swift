import Foundation
import FirebaseFirestore

// ===== The Insights history, as the app reads it =====
//
// The server keeps two collections under the account (`functions-insights` in the private repo):
// `insightsDaily/{YYYY-MM-DD}`, one document per UTC day with any activity, and
// `insightsStories/{storyId}`, one record per story that outlives the story. This file reads them
// and turns them into a report for a period. The owner's order, 2026-09-30: "start saving the
// necessary history from the day we deploy it ... trends, comparisons, growth, story performance".
//
// ⚠️ NOTHING HERE WRITES, AND NOTHING HERE CAN. Both collections are closed to every client write
// in firestore.rules; a number the phone could write is a number the phone could invent.
//
// ⚠️ HISTORY STARTS THE DAY THE FUNCTIONS WERE DEPLOYED. Before that day there are no documents,
// and the report says so rather than drawing zeros for days nobody counted.

/// One UTC day of one account. A day with no document is a day of zeros, not an unknown.
struct InsightsDay: Equatable {
    let day: String
    var storyViews = 0
    /// Added minus removed that day, so it can be negative; sums are floored at zero.
    var storyReactions = 0
    var storiesPosted = 0
    /// People who opened this profile that day, one per person (2026-10-03, `insightsProfileViewed`).
    var profileViews = 0
    var glowersGained = 0
    var glowersLost = 0
    var glowingGained = 0
    var glowingLost = 0
    /// Views by UTC hour, 0 to 23.
    var viewHours: [Int: Int] = [:]
}

/// The record of one story, kept after the story itself has expired.
struct InsightsStoryRecord: Identifiable, Equatable {
    let id: String
    var createdAt: Date
    var isVideo: Bool
    var audience: String
    var views: Int
    var reactions: Int
    var ended: Bool
    var blurThumb: String
}

enum InsightsPeriod: Int, CaseIterable, Identifiable {
    case week = 7
    case month = 28
    case quarter = 90

    var id: Int { rawValue }
    var title: String { "Last \(rawValue) days" }
}

/// A figure for this period beside the same figure for the period before it.
///
/// ⛔ THE REFERENCE APP'S RULE, which is the whole of its statistics maths: change is current minus
/// previous, and the percentage is that change over the previous figure ONLY when the previous
/// figure is above zero. With nothing to compare against there is no percentage at all, not a
/// made-up one. `previous` is nil here when the earlier period is not fully inside the history.
struct InsightsDelta: Equatable {
    let current: Double
    let previous: Double?

    var change: Double? { previous.map { current - $0 } }
    var percent: Double? {
        guard let previous, previous > 0 else { return nil }
        return (current - previous) / previous
    }
}

struct InsightsPoint: Identifiable, Equatable {
    let date: Date
    let value: Int
    var id: Date { date }
}

struct InsightsAudienceShare: Identifiable, Equatable {
    let audience: String
    let views: Int
    var id: String { audience }
}

/// UTC day arithmetic. The server names a day by its UTC date, so the app must count the same way
/// or a view at 01:00 in Mogadishu lands on a different day here than it did there.
enum InsightsCalendar {
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        return c
    }()

    static func startOfDay(_ date: Date) -> Date { utc.startOfDay(for: date) }

    static func key(_ date: Date) -> String {
        let c = utc.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func date(_ key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func adding(_ days: Int, to date: Date) -> Date {
        utc.date(byAdding: .day, value: days, to: date) ?? date
    }
}

/// Everything the Insights page shows for one period. Built from plain values, with no database
/// and no clock of its own, so the same inputs always give the same report.
struct InsightsReport: Equatable {
    let period: InsightsPeriod
    /// First and last day of the period, UTC midnights.
    let start: Date
    let end: Date
    /// The first day the history holds, or nil when it holds nothing yet.
    let firstDay: Date?

    let views: InsightsDelta
    let reactions: InsightsDelta
    let posted: InsightsDelta
    let profileViews: InsightsDelta
    let viewsPerStory: InsightsDelta
    let glowersNet: InsightsDelta
    let gainedDelta: InsightsDelta
    let lostDelta: InsightsDelta

    let glowersGained: Int
    let glowersLost: Int
    let glowingGained: Int
    let glowingLost: Int

    let viewsByDay: [InsightsPoint]
    let glowersByDay: [InsightsPoint]
    let topStories: [InsightsStoryRecord]
    /// The UTC hour with the most views in the period, once there are enough views to mean it.
    let bestHourUTC: Int?
    let audiences: [InsightsAudienceShare]
    /// Every recorded day of the period with all its figures, for the charts that follow whichever
    /// headline is picked (2026-10-03 redesign). Days before the history began are left out.
    let recordedDays: [InsightsDayRow]
    /// Views in the period by UTC hour, 0 to 23.
    let hoursUTC: [Int: Int]
    /// Every story of the period, newest first, for the Content tab's own sorting.
    let periodStories: [InsightsStoryRecord]

    /// True once the history reaches back past the start of this period.
    var coversPeriod: Bool { firstDay.map { $0 <= start } ?? false }
    var hasHistory: Bool { firstDay != nil }

    /// How many stories the "top stories" list holds at most.
    static let topCount = 10
    /// Under this many views an "hour with the most views" is noise.
    static let bestHourMinimum = 10

    static func build(period: InsightsPeriod,
                      today: Date,
                      days: [InsightsDay],
                      stories: [InsightsStoryRecord],
                      firstDay: String?,
                      glowersNow: Int) -> InsightsReport {
        let length = period.rawValue
        let end = InsightsCalendar.startOfDay(today)
        let start = InsightsCalendar.adding(-(length - 1), to: end)
        let previousStart = InsightsCalendar.adding(-length, to: start)
        let afterEnd = InsightsCalendar.adding(1, to: end)
        let first = firstDay.flatMap(InsightsCalendar.date)
        // Compared only when the WHOLE earlier period was being recorded. A history that starts
        // halfway through it would make every figure look like growth.
        let compared = first.map { $0 <= previousStart } ?? false

        let byKey = Dictionary(days.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        func window(from: Date) -> [(date: Date, day: InsightsDay)] {
            (0..<length).map { offset -> (date: Date, day: InsightsDay) in
                let date = InsightsCalendar.adding(offset, to: from)
                let key = InsightsCalendar.key(date)
                return (date: date, day: byKey[key] ?? InsightsDay(day: key))
            }
        }
        let current = window(from: start)
        let previous = window(from: previousStart)

        func total(_ rows: [(date: Date, day: InsightsDay)], _ field: (InsightsDay) -> Int) -> Int {
            rows.reduce(0) { $0 + field($1.day) }
        }
        func delta(_ now: Double, _ before: Double) -> InsightsDelta {
            InsightsDelta(current: now, previous: compared ? before : nil)
        }
        func compare(_ field: (InsightsDay) -> Int) -> InsightsDelta {
            delta(Double(max(0, total(current, field))), Double(max(0, total(previous, field))))
        }

        let currentStories = stories.filter { $0.createdAt >= start && $0.createdAt < afterEnd }
        let previousStories = stories.filter { $0.createdAt >= previousStart && $0.createdAt < start }
        func average(_ rows: [InsightsStoryRecord]) -> Double {
            rows.isEmpty ? 0 : Double(rows.reduce(0) { $0 + $1.views }) / Double(rows.count)
        }

        let gained = total(current, { $0.glowersGained })
        let lost = total(current, { $0.glowersLost })
        let previousNet = total(previous, { $0.glowersGained }) - total(previous, { $0.glowersLost })

        // Only the days the history covers are drawn. A day before it is not a zero.
        let recorded = current.filter { row in first.map { row.date >= $0 } ?? false }
        let viewsByDay = recorded.map { InsightsPoint(date: $0.date, value: max(0, $0.day.storyViews)) }

        // The glower count on each day, walked back from today's live count: the count at the end
        // of a day is the next day's count without what the next day added and with what it lost.
        var running = glowersNow
        var glowerPoints: [InsightsPoint] = []
        for row in current.reversed() {
            glowerPoints.append(InsightsPoint(date: row.date, value: max(0, running)))
            running = running - row.day.glowersGained + row.day.glowersLost
        }
        let glowersByDay = glowerPoints.reversed().filter { point in first.map { point.date >= $0 } ?? false }

        var hours: [Int: Int] = [:]
        for row in current {
            for (hour, count) in row.day.viewHours { hours[hour, default: 0] += count }
        }
        var bestHour: Int?
        if hours.values.reduce(0, +) >= bestHourMinimum {
            // The earlier hour wins a tie, so the answer does not move between two loads.
            bestHour = hours.max(by: { a, b in
                a.value != b.value ? a.value < b.value : a.key > b.key
            })?.key
        }

        var byAudience: [String: Int] = [:]
        for story in currentStories { byAudience[story.audience, default: 0] += story.views }
        let audiences = byAudience
            .map { InsightsAudienceShare(audience: $0.key, views: $0.value) }
            .sorted { $0.views != $1.views ? $0.views > $1.views : $0.audience < $1.audience }

        let top = currentStories.sorted { a, b in
            if a.views != b.views { return a.views > b.views }
            if a.reactions != b.reactions { return a.reactions > b.reactions }
            return a.createdAt > b.createdAt
        }

        return InsightsReport(
            period: period,
            start: start,
            end: end,
            firstDay: first,
            views: compare({ $0.storyViews }),
            reactions: compare({ $0.storyReactions }),
            posted: compare({ $0.storiesPosted }),
            profileViews: compare({ $0.profileViews }),
            viewsPerStory: delta(average(currentStories), average(previousStories)),
            glowersNet: delta(Double(gained - lost), Double(previousNet)),
            gainedDelta: compare({ $0.glowersGained }),
            lostDelta: compare({ $0.glowersLost }),
            glowersGained: gained,
            glowersLost: lost,
            glowingGained: total(current, { $0.glowingGained }),
            glowingLost: total(current, { $0.glowingLost }),
            viewsByDay: viewsByDay,
            glowersByDay: Array(glowersByDay),
            topStories: Array(top.prefix(topCount)),
            bestHourUTC: bestHour,
            audiences: audiences.count >= 2 ? audiences : [],
            recordedDays: recorded.map { InsightsDayRow(date: $0.date, day: $0.day) },
            hoursUTC: hours,
            periodStories: currentStories.sorted { $0.createdAt > $1.createdAt })
    }
}

/// One recorded day of a period: its UTC midnight and its figures.
struct InsightsDayRow: Identifiable, Equatable {
    let date: Date
    let day: InsightsDay
    var id: Date { date }
}

/// Reads the history once for the longest period and its comparison, so switching between 7, 28
/// and 90 days on the page is arithmetic and not another round trip.
@MainActor @Observable final class InsightsHistoryLoader {
    enum Phase: Equatable { case loading, loaded, failed }

    private(set) var phase: Phase = .loading
    private(set) var days: [InsightsDay] = []
    private(set) var stories: [InsightsStoryRecord] = []
    private(set) var firstDay: String?

    /// Two of the longest period: the period and the one it is compared with.
    private static var reach: Int { (InsightsPeriod.allCases.map(\.rawValue).max() ?? 90) * 2 }
    /// Far more stories than anybody posts in that reach; a ceiling, not an expectation.
    private static let storyLimit = 500

    func load() async {
        let uid = AuthService.shared.uid ?? ""
        guard !uid.isEmpty else { phase = .failed; return }
        if phase != .loaded { phase = .loading }
        let account = Firestore.firestore().collection("users").document(uid)
        let from = InsightsCalendar.adding(-(Self.reach - 1), to: InsightsCalendar.startOfDay(Date()))
        do {
            let daySnap = try await account.collection("insightsDaily")
                .whereField("day", isGreaterThanOrEqualTo: InsightsCalendar.key(from))
                .order(by: "day")
                .getDocuments()
            // The first day ever recorded, which may be older than the reach above. It is what
            // decides whether a period can be compared with the one before it.
            let firstSnap = try await account.collection("insightsDaily")
                .order(by: "day")
                .limit(to: 1)
                .getDocuments()
            let storySnap = try await account.collection("insightsStories")
                .whereField("createdAt", isGreaterThanOrEqualTo: Timestamp(date: from))
                .order(by: "createdAt", descending: true)
                .limit(to: Self.storyLimit)
                .getDocuments()
            days = daySnap.documents.map { Self.day($0.documentID, $0.data()) }
            firstDay = firstSnap.documents.first?.documentID
            stories = storySnap.documents.map { Self.story($0.documentID, $0.data()) }
            phase = .loaded
        } catch {
            // Keeps what is already on screen: a failed refresh must not blank a loaded page.
            if phase != .loaded { phase = .failed }
        }
    }

    private static func number(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }

    private static func day(_ id: String, _ data: [String: Any]) -> InsightsDay {
        var day = InsightsDay(day: id)
        day.storyViews = number(data["storyViews"])
        day.storyReactions = number(data["storyReactions"])
        day.storiesPosted = number(data["storiesPosted"])
        day.profileViews = number(data["profileViews"])
        day.glowersGained = number(data["glowersGained"])
        day.glowersLost = number(data["glowersLost"])
        day.glowingGained = number(data["glowingGained"])
        day.glowingLost = number(data["glowingLost"])
        if let hours = data["viewHours"] as? [String: Any] {
            for (key, value) in hours {
                if let hour = Int(key), (0..<24).contains(hour) { day.viewHours[hour] = number(value) }
            }
        }
        return day
    }

    private static func story(_ id: String, _ data: [String: Any]) -> InsightsStoryRecord {
        InsightsStoryRecord(
            id: id,
            createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date(),
            isVideo: (data["type"] as? String) == "video",
            audience: data["audience"] as? String ?? "friends",
            views: max(0, number(data["views"])),
            reactions: max(0, number(data["reactions"])),
            ended: data["ended"] as? Bool ?? false,
            blurThumb: data["blurThumb"] as? String ?? "")
    }
}
