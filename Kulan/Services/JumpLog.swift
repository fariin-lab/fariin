import Foundation
import UIKit

/// ⚠️ TEMPORARY DIAGNOSTIC SINK — 2026-08-29, the re-entry jump and the row-cost measurement.
/// Delete this file, the `jlog` calls in `NativeMessageList`, the `[ROW]` timer and the
/// Version-row entry in `SettingsView` the moment both causes are written down.
///
/// ⛔ WHY THIS EXISTS AT ALL, AND WHY `print` WAS NOT ENOUGH. The first attempt at the jump
/// (`b9ff9d0a`, reverted by a log cleanup) logged with `print` under `#if DEBUG`. There is no Mac on
/// this project, so the only build the owner can reproduce on is a TestFlight one — Release, where
/// `#if DEBUG` compiles the whole thing away, and where `print` has no console to reach anyway. The
/// instrumentation therefore ran on nobody's phone and the report came back a second time with the
/// cause still unknown. A diagnostic that cannot be read is not a diagnostic.
///
/// ⛔ AND WHY IT IS ON DISK. Build 716 shipped this as a memory-only buffer and he reported "0
/// lines" after doing the steps in order. Memory-only cannot tell the two answers apart: nothing
/// logged, or the app was relaunched between the scroll and Settings and took the evidence with it.
/// iOS relaunches a backgrounded app whenever it likes, and it never says so. On disk, the question
/// does not arise: the log is whatever happened, in whatever order, across however many launches.
///
/// The `[BOOT]` line is the other half of that answer, and it is the one that matters most: a
/// working pipe can never report zero. If the row still says 0 lines after a launch, the fault is
/// in this file or in the row that reads it, and not in any of the instrumented code.
final class JumpLog {
    static let shared = JumpLog()

    private let lock = NSLock()
    private var lines: [String] = []
    private static let cap = 400

    /// Writes are coalesced onto this queue: `[ROW]` lines land during a scroll, which is the one
    /// moment that must not touch the file system on the main thread. The whole point of the log is
    /// to measure dropped frames, so the log itself must not cause any.
    private let io = DispatchQueue(label: "jumplog.io", qos: .utility)
    private var flushScheduled = false

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static var fileURL: URL? {
        let dirs = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        guard let dir = dirs.first else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("jumplog.txt")
    }

    private init() {
        if let url = Self.fileURL, let text = try? String(contentsOf: url, encoding: .utf8) {
            lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            if lines.count > Self.cap { lines.removeFirst(lines.count - Self.cap) }
        }
        // ⛔ THE PROOF LINE. Written before anything else can log, so the row's count is never zero
        // in a build where this file works at all. It also dates each launch, which is what separates
        // "this run" from the run before it once the log survives relaunches.
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
        append("[BOOT] build \(build)")
        // A backgrounded app can be killed without further notice; this is the last reliable moment.
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: nil) { [weak self] _ in
            self?.flushNow()
        }
    }

    func append(_ line: String) {
        let entry = "\(Self.stamp.string(from: Date())) \(line)"
        lock.lock()
        lines.append(entry)
        if lines.count > Self.cap { lines.removeFirst(lines.count - Self.cap) }
        let shouldSchedule = !flushScheduled
        flushScheduled = true
        lock.unlock()
        guard shouldSchedule else { return }
        io.asyncAfter(deadline: .now() + 2) { [weak self] in self?.flushNow() }
    }

    private func flushNow() {
        lock.lock()
        flushScheduled = false
        let text = lines.joined(separator: "\n")
        lock.unlock()
        guard let url = Self.fileURL else { return }
        io.async { try? text.write(to: url, atomically: true, encoding: .utf8) }
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

    /// ⚠️ CLEARING LEAVES A `[BOOT]` LINE BEHIND, ON PURPOSE. An empty log and a broken log look
    /// identical from the Settings row — that ambiguity is what cost build 716 — so the reset
    /// re-states which build is running rather than dropping to a bare zero.
    func clear() {
        lock.lock()
        lines.removeAll()
        lock.unlock()
        if let url = Self.fileURL { try? FileManager.default.removeItem(at: url) }
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
        append("[BOOT] build \(build) (log cleared)")
    }
}
