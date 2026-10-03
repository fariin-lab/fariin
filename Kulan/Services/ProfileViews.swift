import Foundation
import FirebaseFunctions

/// PROFILE VIEWS — owner, 2026-10-03: "add a profile view count" to Insights. Opening somebody
/// else's profile tells the server once (`insights:insightsProfileViewed`), which adds one to that
/// person's day, a count and never a name. The server already counts one per person per day; this
/// only stops the same screen from asking again every time it reappears in one run of the app.
@MainActor enum ProfileViews {
    private static var told = Set<String>()

    static func record(_ uid: String) {
        let me = AuthService.shared.uid ?? ""
        guard !uid.isEmpty, !me.isEmpty, uid != me else { return }
        let key = uid + "|" + InsightsCalendar.key(Date())
        guard told.insert(key).inserted else { return }
        Task {
            _ = try? await Functions.functions(region: "me-central1")
                .httpsCallable("insightsProfileViewed").call(["uid": uid])
        }
    }
}
