import Foundation
import UIKit
import Darwin

/// ⛔ MEASURE BEFORE FIXING — owner 2026-10-21 ("make Kulan as fast as the reference apps; use
/// measurements, not guesses"). There is no Mac here to run Instruments on his phone, so the phone
/// writes its own numbers into the hidden diagnostic log (`DiagLog`, never on screen) and sends it
/// once a launch has run a few minutes. Lines start with "PERF#" so they read apart from the rest.
///
/// What it records, and nothing else:
///   · launch milestones, in ms since the PROCESS started (the kernel's start time, so the time iOS
///     spends before our first line counts too): `PerfTrace.mark("chatlist_first_rows")`.
///   · main-thread stalls of 250 ms or more (a background watchdog pings the main queue).
///   · memory: the footprint iOS judges us by, every 5 minutes and on every memory warning.
/// Cheap: one timer on a utility queue, one dictionary of first-seen marks.
enum PerfTrace {
    private static let queue = DispatchQueue(label: "PerfTrace", qos: .utility)
    private static var started = false
    private static var marked = Set<String>()
    private static var lastHangLog = Date.distantPast

    /// When iOS started this process, from the kernel (ms since 1970). Nil if it cannot be read.
    private static let processStartMs: Double? = {
        var kinfo = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &kinfo, &size, nil, 0) == 0 else { return nil }
        let t = kinfo.kp_proc.p_un.__p_starttime
        return Double(t.tv_sec) * 1000 + Double(t.tv_usec) / 1000
    }()

    private static func sinceStart() -> Int {
        guard let s = processStartMs else { return -1 }
        return Int(Date().timeIntervalSince1970 * 1000 - s)
    }

    /// The footprint iOS uses for its memory limit (MB).
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }

    /// Called once at launch (KulanApp). Starts the stall watchdog and the memory sampler, and sends
    /// the log after a few minutes of use so each launch reports once.
    static func start() {
        queue.async {
            guard !started else { return }
            started = true
            DiagLog.add("PERF# launch process_ms=\(sinceStart()) mem_mb=\(footprintMB())")
            watchdog()
            memorySampler()
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil, queue: nil) { _ in
            DiagLog.add("PERF# memory_warning mem_mb=\(footprintMB())")
            Telemetry.event(.warning, component: "perf", code: "memory_warning", detail: ["mb": String(footprintMB())])   // owner 2026-10-21
        }
        DiagLog.flagForUpload(after: 240)
    }

    /// A milestone, logged the first time it is reached in this process.
    static func mark(_ name: String) {
        queue.async {
            guard marked.insert(name).inserted else { return }
            DiagLog.add("PERF# \(name) process_ms=\(sinceStart())")
        }
    }

    /// A timed span the caller measured itself (ms), logged every time.
    static func span(_ name: String, ms: Int) {
        DiagLog.add("PERF# \(name) ms=\(ms)")
    }

    // Every 500 ms: post a ping to the main queue and see how long it takes to run. 250 ms or more is
    // a visible freeze (a dropped scroll, a late tap). At most one line every 2 s, so a long freeze is
    // one line, not forty.
    private static func watchdog() {
        let sent = Date()
        DispatchQueue.main.async {
            let lag = Int(Date().timeIntervalSince(sent) * 1000)
            // Only on screen: a suspended app's main queue "lags" by the whole time it was away.
            if lag >= 250, UIApplication.shared.applicationState == .active {
                queue.async {
                    guard Date().timeIntervalSince(lastHangLog) > 2 else { return }
                    lastHangLog = Date()
                    DiagLog.add("PERF# main_stall ms=\(lag)")
                    if lag >= 1000 { Telemetry.event(.warning, component: "perf", code: "main_stall", detail: ["ms": String(lag)]) }   // owner 2026-10-21
                }
            }
            queue.asyncAfter(deadline: .now() + 0.5) { watchdog() }
        }
    }

    private static func memorySampler() {
        queue.asyncAfter(deadline: .now() + 300) {
            DiagLog.add("PERF# mem_mb=\(footprintMB())")
            memorySampler()
        }
    }
}
