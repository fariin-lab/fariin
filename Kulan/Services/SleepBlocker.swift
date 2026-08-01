import UIKit

// Ref-counted "keep the screen awake" manager (a device sleep manager): recording a long voice
// note or listening to one must not let the phone auto-lock, but the idle timer must never be left
// disabled once nothing needs it. Each holder adds/removes a reason; the timer is disabled only
// while ≥1 reason is held. Main-thread only (UIApplication requirement).
@MainActor
final class SleepBlocker {
    static let shared = SleepBlocker()
    private init() {}

    private var reasons = Set<String>()

    func add(_ reason: String) {
        reasons.insert(reason)
        UIApplication.shared.isIdleTimerDisabled = true
    }
    func remove(_ reason: String) {
        reasons.remove(reason)
        if reasons.isEmpty { UIApplication.shared.isIdleTimerDisabled = false }
    }
}
