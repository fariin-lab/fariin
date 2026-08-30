import Foundation

/// ⚠️ TEMPORARY DIAGNOSTIC SINK — 2026-08-29, the re-entry jump. Delete this file, the `jlog` calls
/// in `NativeMessageList` and the Version-row long-press in `SettingsView` the moment the cause is
/// written down.
///
/// ⛔ WHY THIS EXISTS AT ALL, AND WHY `print` WAS NOT ENOUGH. The first attempt at this bug
/// (`b9ff9d0a`, reverted by a log cleanup) logged with `print` under `#if DEBUG`. There is no Mac on
/// this project, so the only build the owner can reproduce on is a TestFlight one — Release, where
/// `#if DEBUG` compiles the whole thing away, and where `print` has no console to reach anyway. The
/// instrumentation therefore ran on nobody's phone and the report came back a second time with the
/// cause still unknown. A diagnostic that cannot be read is not a diagnostic.
///
/// So: a ring buffer in memory, readable from inside the app (long-press Settings > Version), and
/// deliberately NOT `#if DEBUG`.
///
/// Bounded on purpose. Scrolling a chat produces a line per programmatic move, so this would grow
/// without a cap; 200 lines is several re-entries, which is more than one reproduction needs.
final class JumpLog {
    static let shared = JumpLog()
    private init() {}

    private let lock = NSLock()
    private var lines: [String] = []
    private static let cap = 200

    /// The clock matters as much as the text: the whole question is what moves the offset AFTER the
    /// landing, so the gap between two lines is part of the evidence.
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func append(_ line: String) {
        let entry = "\(Self.stamp.string(from: Date())) \(line)"
        lock.lock()
        lines.append(entry)
        if lines.count > Self.cap { lines.removeFirst(lines.count - Self.cap) }
        lock.unlock()
    }

    /// Newest last, the order they happened in — this is pasted into a chat and read top to bottom.
    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return lines.count
    }

    func clear() {
        lock.lock()
        lines.removeAll()
        lock.unlock()
    }
}
