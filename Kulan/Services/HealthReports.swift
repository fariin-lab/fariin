import Foundation
import MetricKit

/// ⛔ WHAT iOS ITSELF SAW GO WRONG — owner 2026-10-21. MetricKit hands the app, on a later launch,
/// the crashes, hangs, CPU and disk-write exceptions and slow launches iOS recorded for it, plus a
/// daily summary. Each one becomes a `Telemetry` event: crash critical, hang error, the rest warning,
/// the daily summary info.
///
/// Only machine facts leave the phone: exception type/code/signal, iOS's termination reason, the
/// build and iOS version the report came from, and the top 40 frames of the call stack as
/// "binary +0xoffset binary-uuid" (no symbols, no memory contents). Symbolicated later against the
/// build's dSYM.
final class HealthReports: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = HealthReports()
    private var started = false

    /// Once, after `Telemetry.start()` (AppDelegate).
    func start() {
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(self)
    }

    // MARK: - MXMetricManagerSubscriber

    func didReceive(_ payloads: [MXMetricPayload]) {
        for p in payloads { Self.daily(p) }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for p in payloads {
            p.crashDiagnostics?.forEach { Self.crash($0) }
            p.hangDiagnostics?.forEach { Self.hang($0) }
            p.cpuExceptionDiagnostics?.forEach { Self.cpu($0) }
            p.diskWriteExceptionDiagnostics?.forEach { Self.diskWrites($0) }
            p.appLaunchDiagnostics?.forEach { Self.launch($0) }
        }
    }

    // MARK: - Diagnostics

    private static func crash(_ d: MXCrashDiagnostic) {
        var detail = base(d)
        if let v = d.exceptionType { detail["exception"] = v.stringValue }
        if let v = d.exceptionCode { detail["errcode"] = v.stringValue }
        if let v = d.signal { detail["signal"] = v.stringValue }
        if let r = d.terminationReason { detail["termination"] = r }
        // The exception's NAME and CLASS only; its composed message can quote app data.
        if let r = d.exceptionReason { detail["objc_exc"] = "\(r.exceptionName) \(r.className)" }
        detail.merge(frames(d.callStackTree)) { a, _ in a }
        let code = "crash_sig\(d.signal?.stringValue ?? "x")_exc\(d.exceptionType?.stringValue ?? "x")"
        Telemetry.record(.critical, component: "metrickit", code: code, detail: detail, dedupe: false)
    }

    private static func hang(_ d: MXHangDiagnostic) {
        var detail = base(d)
        detail["hang_ms"] = ms(d.hangDuration)
        detail.merge(frames(d.callStackTree)) { a, _ in a }
        Telemetry.record(.error, component: "metrickit", code: "hang", detail: detail, dedupe: false)
    }

    private static func cpu(_ d: MXCPUExceptionDiagnostic) {
        var detail = base(d)
        detail["cpu_ms"] = ms(d.totalCPUTime)
        detail["sampled_ms"] = ms(d.totalSampledTime)
        detail.merge(frames(d.callStackTree)) { a, _ in a }
        Telemetry.record(.warning, component: "metrickit", code: "cpu_exception", detail: detail, dedupe: false)
    }

    private static func diskWrites(_ d: MXDiskWriteExceptionDiagnostic) {
        var detail = base(d)
        detail["writes_mb"] = String(Int(d.totalWritesCaused.converted(to: .megabytes).value))
        detail.merge(frames(d.callStackTree)) { a, _ in a }
        Telemetry.record(.warning, component: "metrickit", code: "disk_write_exception", detail: detail, dedupe: false)
    }

    private static func launch(_ d: MXAppLaunchDiagnostic) {
        var detail = base(d)
        detail["launch_ms"] = ms(d.launchDuration)
        detail.merge(frames(d.callStackTree)) { a, _ in a }
        Telemetry.record(.warning, component: "metrickit", code: "slow_launch", detail: detail, dedupe: false)
    }

    // MARK: - Daily summary

    private static func daily(_ p: MXMetricPayload) {
        let meta: MXMetaData? = p.metaData
        var d: [String: String] = ["app_build": meta?.applicationBuildVersion ?? "?",
                                   "app_os": meta?.osVersion ?? "?"]
        if let m = p.memoryMetrics {
            d["peak_mb"] = String(Int(m.peakMemoryUsage.converted(to: .megabytes).value))
        }
        if let e = p.applicationExitMetrics {
            let f = e.foregroundExitData, b = e.backgroundExitData
            d["fg_normal"] = String(f.cumulativeNormalAppExitCount)
            d["fg_memory"] = String(f.cumulativeMemoryResourceLimitExitCount)
            d["fg_watchdog"] = String(f.cumulativeAppWatchdogExitCount)
            d["fg_abnormal"] = String(f.cumulativeAbnormalExitCount)
            d["fg_badaccess"] = String(f.cumulativeBadAccessExitCount)
            d["fg_illegal"] = String(f.cumulativeIllegalInstructionExitCount)
            d["bg_normal"] = String(b.cumulativeNormalAppExitCount)
            d["bg_memory"] = String(b.cumulativeMemoryResourceLimitExitCount)
            d["bg_pressure"] = String(b.cumulativeMemoryPressureExitCount)
            d["bg_cpu"] = String(b.cumulativeCPUResourceLimitExitCount)
            d["bg_watchdog"] = String(b.cumulativeAppWatchdogExitCount)
            d["bg_abnormal"] = String(b.cumulativeAbnormalExitCount)
            d["bg_badaccess"] = String(b.cumulativeBadAccessExitCount)
            d["bg_illegal"] = String(b.cumulativeIllegalInstructionExitCount)
            d["bg_lockedfile"] = String(b.cumulativeSuspendedWithLockedFileExitCount)
            d["bg_tasktimeout"] = String(b.cumulativeBackgroundTaskAssertionTimeoutExitCount)
        }
        Telemetry.record(.info, component: "metrickit", code: "daily", detail: d, dedupe: false)
    }

    // MARK: - Helpers

    /// The build and iOS the report came from (may be older than the running build).
    private static func base(_ d: MXDiagnostic) -> [String: String] {
        let meta: MXMetaData? = d.metaData
        return ["app_build": meta?.applicationBuildVersion ?? "?", "app_os": meta?.osVersion ?? "?"]
    }

    private static func ms(_ m: Measurement<UnitDuration>) -> String {
        String(Int(m.converted(to: .milliseconds).value))
    }

    /// The top 40 frames, f00 = the innermost. For a crash, the thread iOS blames; for a sampled
    /// tree (hang, CPU), the heaviest path through it.
    private static func frames(_ tree: MXCallStackTree) -> [String: String] {
        guard let obj = try? JSONSerialization.jsonObject(with: tree.jsonRepresentation()) as? [String: Any],
              let stacks = obj["callStacks"] as? [[String: Any]] else { return [:] }
        let stack = stacks.first(where: { ($0["threadAttributed"] as? Bool) == true }) ?? stacks.first
        var frame = (stack?["callStackRootFrames"] as? [[String: Any]])?.max(by: { samples($0) < samples($1) })
        var out: [String: String] = [:]
        var i = 0
        while let f = frame, i < 40 {
            let name = f["binaryName"] as? String ?? "?"
            let offset = (f["offsetIntoBinaryTextSegment"] as? NSNumber)?.uint64Value ?? 0
            let uuid = f["binaryUUID"] as? String ?? ""
            out[String(format: "f%02d", i)] = "\(name) +0x\(String(offset, radix: 16)) \(uuid)"
            i += 1
            frame = (f["subFrames"] as? [[String: Any]])?.max(by: { samples($0) < samples($1) })
        }
        return out
    }

    private static func samples(_ f: [String: Any]) -> Int {
        (f["sampleCount"] as? NSNumber)?.intValue ?? 0
    }
}
