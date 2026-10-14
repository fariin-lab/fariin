import Foundation
import StoryUI

/// ⛔ THE STORY PLAYER'S TIMELINE GOES INTO THE HIDDEN LOG — owner 2026-10-14, "the next person's
/// video starts late", his recording of that day's build showing about 0.3 s of still picture after
/// the cube lands (0.9 s the build before). Six fixes before this one were written from code alone,
/// because the phone never recorded what its player was doing at the landing: `StoryVideoTrace` had
/// the trace points and nothing listening. Now every line goes to `DiagLog` with the time since the
/// last landing, and a landing that takes longer than `slowLanding` from "turn landed" to the clip's
/// first moving frame flags the log for upload (`users/{uid}/diag`), so the next report is a
/// timeline rather than a guess. Nothing on screen, as with the rest of the log (his 2026-09-28 rule).
enum StoryTraceBridge {
    private static let lock = NSLock()
    private static var landedAt: Date?
    private static var armed = false
    /// A prepared clip on a local file starts in about 10 ms; the reference app within a frame.
    private static let slowLanding: TimeInterval = 0.15

    static func install() {
        StoryVideoTrace.sink = { line in
            let now = Date()
            lock.lock()
            if line == "turn landed" { landedAt = now; armed = true }
            let since = landedAt.map { Int(now.timeIntervalSince($0) * 1000) }
            var slow: Int?
            if armed, line.contains("clock moving"), let ms = since {
                armed = false
                if Double(ms) > slowLanding * 1000 { slow = ms }
            }
            lock.unlock()
            DiagLog.add("story: \(line)\(since.map { " +\($0)ms" } ?? "")")
            if let slow {
                DiagLog.add("story: SLOW LANDING \(slow)ms from turn landed to the first moving frame")
                DiagLog.flagForUpload()
            }
        }
    }
}
