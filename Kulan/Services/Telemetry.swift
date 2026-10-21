import Foundation
import UIKit
import Network
import CryptoKit
import FirebaseAuth
import FirebaseFunctions
import FirebaseCrashlytics

/// ⛔ PRODUCTION MONITORING, APP SIDE — owner 2026-10-21. `DiagLog` only reaches us when a phone is
/// flagged; this reaches us from every phone, but carries FAR less: a severity, a component, a short
/// code, and a fixed set of facts about the phone. It goes to the `telemetryIngest` callable
/// (functions-admin, me-central1), which stores it for the admin panel.
///
/// ⛔ PRIVACY, AND IT IS THE WHOLE DESIGN:
///   · component and code are cut down to [a-z0-9_.-]; detail keys must be on `allowedKeys` or they
///     are dropped; every detail value is cut to 300 characters.
///   · values are scrubbed: URL query strings and fragments removed, e-mail addresses, @handles,
///     phone-like digit runs and long token-like strings (keys, tokens, uids) replaced.
///   · callers pass CODES, never message text, names, usernames, e-mails, phone numbers, tokens or
///     keys. Error codes go through `code(_:)`, never `localizedDescription`.
///   · the account is a SALTED HASH of the uid (`uidHash`), never the uid or e-mail. The install id
///     is a random UUID made on first use and lost on uninstall.
///
/// Buffer: at most 500 events, in memory and in Application Support/telemetry.json, dropped after
/// 3 days. Critical and error go up about 10s after the first one; the rest every hour and when the
/// app goes to the background. A failed upload backs off (30s doubling, at most an hour).
/// Every event is also one line in the hidden DiagLog: `TEL# sev comp code`.
enum Telemetry {
    enum Severity: String, Codable { case critical, error, warning, info }

    /// The only detail keys that leave the phone. Anything else is dropped. f00...f39 are MetricKit
    /// stack frames (binary name, offset, binary uuid): machine data, not scrubbed for numbers.
    static let frameKeys: Set<String> = Set((0..<40).map { String(format: "f%02d", $0) })
    static let allowedKeys: Set<String> = frameKeys.union([
        "where", "reason", "stage", "kind", "attempt", "ms", "mb", "count", "errcode", "domain",
        "exception", "signal", "termination", "objc_exc", "app_build", "app_os",
        "hang_ms", "cpu_ms", "sampled_ms", "writes_mb", "launch_ms", "peak_mb",
        "fg_normal", "fg_memory", "fg_watchdog", "fg_abnormal", "fg_badaccess", "fg_illegal",
        "bg_normal", "bg_memory", "bg_pressure", "bg_cpu", "bg_watchdog", "bg_abnormal",
        "bg_badaccess", "bg_illegal", "bg_lockedfile", "bg_tasktimeout", "test",
    ])

    struct Event: Codable {
        let id: String
        let ts: Int64
        let sev: String
        let comp: String
        let code: String
        let build: String
        let os: String
        let model: String
        let net: String
        let state: String
        let mem: Int
        let lowPower: Bool
        let install: String
        let uh: String
        let detail: [String: String]

        var payload: [String: Any] {
            ["id": id, "ts": ts, "sev": sev, "comp": comp, "code": code, "build": build, "os": os,
             "model": model, "net": net, "state": state, "mem": mem, "lowPower": lowPower,
             "install": install, "uh": uh, "detail": detail]
        }
    }

    // MARK: - State (all of it touched only on `queue`)

    private static let queue = DispatchQueue(label: "Telemetry", qos: .utility)
    private static let maxEvents = 500
    private static let maxAgeMs: Int64 = 3 * 24 * 3600 * 1000
    private static let batchSize = 100
    private static var buffer: [Event] = []
    private static var loaded = false
    private static var savePending = false
    private static var lastSeen: [String: Date] = [:]
    private static var urgentScheduled = false
    private static var uploading = false
    private static var failures = 0
    private static var nextAllowed = Date.distantPast
    private static var net = "unknown"
    private static var appState = "launching"
    private static var uidHash = ""
    private static var crashReady = false
    private static var started = false
    private static var hourly: DispatchSourceTimer?
    private static let monitor = NWPathMonitor()
    private static var authHandle: AuthStateDidChangeListenerHandle?

    private static let build: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    private static let os: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }()
    /// e.g. "iPhone16,2". Never the device's name.
    private static let model: String = {
        var u = utsname()
        uname(&u)
        return withUnsafeBytes(of: &u.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }()
    private static let installId: String = {
        let key = "telemetry.installId"
        if let s = UserDefaults.standard.string(forKey: key), !s.isEmpty { return s }
        let s = UUID().uuidString.lowercased()
        UserDefaults.standard.set(s, forKey: key)
        return s
    }()

    private static var fileURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("telemetry.json")
    }

    // MARK: - Public

    /// One event. Safe from any thread. The same severity+component+code is kept once a minute, so a
    /// failure that repeats on every render cannot flood the buffer.
    static func event(_ severity: Severity, component: String, code: String,
                      detail: [String: String] = [:]) {
        record(severity, component: component, code: code, detail: detail, dedupe: true)
    }

    /// For MetricKit: each diagnostic is its own report, so no once-a-minute folding.
    static func record(_ severity: Severity, component: String, code: String,
                       detail: [String: String], dedupe: Bool) {
        let now = Date()
        let comp = token(component, 40), c = token(code, 80)
        let clean = scrub(detail)
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let mem = PerfTrace.footprintMB()
        queue.async {
            loadIfNeeded()
            let key = "\(severity.rawValue)|\(comp)|\(c)"
            if dedupe {
                if let last = lastSeen[key], now.timeIntervalSince(last) < 60 { return }
                if lastSeen.count > 300 { lastSeen.removeAll() }
                lastSeen[key] = now
            }
            let e = Event(id: UUID().uuidString.lowercased(),
                          ts: Int64(now.timeIntervalSince1970 * 1000),
                          sev: severity.rawValue, comp: comp, code: c,
                          build: build, os: os, model: model, net: net, state: appState,
                          mem: mem, lowPower: lowPower, install: installId, uh: uidHash, detail: clean)
            buffer.append(e)
            if buffer.count > maxEvents { buffer.removeFirst(buffer.count - maxEvents) }
            scheduleSave()
            let line = "TEL# \(severity.rawValue) \(comp) \(c)"
            DiagLog.add(line)
            if crashReady { Crashlytics.crashlytics().log(line) }
            if severity == .critical || severity == .error { scheduleUrgent() }
        }
    }

    /// A short, content-free code for an error: "<domain>_<number>", e.g. "firfirestore_7".
    static func code(_ error: Error) -> String {
        let ns = error as NSError
        var d = ns.domain.split(separator: ".").last.map(String.init) ?? ns.domain
        for suffix in ["ErrorDomain", "Domain"] where d.hasSuffix(suffix) { d = String(d.dropLast(suffix.count)) }
        return "\(token(d, 30))_\(ns.code)"
    }

    /// Salted, one-way, and the same on every phone the account uses, so the owner can look a person
    /// up by hashing their uid the same way, while the stored value names nobody.
    static func hashUid(_ uid: String) -> String {
        guard !uid.isEmpty else { return "" }
        let digest = SHA256.hash(data: Data(("kulan.telemetry.v1:" + uid).utf8))
        return digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    /// Once, right after `FirebaseApp.configure()` (AppDelegate).
    static func start() {
        guard Thread.isMainThread else { DispatchQueue.main.async { start() }; return }
        guard !started else { return }
        started = true

        // Crashlytics: collection on, the phone's facts as keys, the account as the salted hash only.
        let c = Crashlytics.crashlytics()
        c.setCrashlyticsCollectionEnabled(true)
        c.setCustomValue(build, forKey: "build")
        c.setCustomValue(os, forKey: "ios")
        c.setCustomValue(model, forKey: "model")
        c.setCustomValue(ProcessInfo.processInfo.isLowPowerModeEnabled, forKey: "low_power")
        c.setCustomValue(PerfTrace.footprintMB(), forKey: "memory_mb")
        c.setCustomValue(installId, forKey: "install")
        queue.async { crashReady = true }

        authHandle = Auth.auth().addStateDidChangeListener { _, user in
            let h = hashUid(user?.uid ?? "")
            Crashlytics.crashlytics().setUserID(h)
            queue.async {
                uidHash = h
                if !h.isEmpty, !buffer.isEmpty { scheduleUrgentIfNeeded() }
            }
        }

        monitor.pathUpdateHandler = { path in
            let n: String
            if path.status != .satisfied { n = "none" }
            else if path.usesInterfaceType(.wifi) { n = "wifi" }
            else if path.usesInterfaceType(.cellular) { n = "cellular" }
            else if path.usesInterfaceType(.wiredEthernet) { n = "wired" }
            else { n = "other" }
            net = n   // this handler runs on `queue`
            Crashlytics.crashlytics().setCustomValue(n, forKey: "network")
        }
        monitor.start(queue: queue)

        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            queue.async { appState = "active" }
        }
        nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            queue.async { appState = "inactive" }
        }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            queue.async { appState = "background" }
            MainActor.assumeIsolated { uploadInBackground() }
        }
        nc.addObserver(forName: NSNotification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: nil) { _ in
            Crashlytics.crashlytics().setCustomValue(ProcessInfo.processInfo.isLowPowerModeEnabled, forKey: "low_power")
        }
        nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { _ in
            Crashlytics.crashlytics().setCustomValue(PerfTrace.footprintMB(), forKey: "memory_mb")
        }

        queue.async {
            loadIfNeeded()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 3600, repeating: 3600, leeway: .seconds(60))
            t.setEventHandler {
                Crashlytics.crashlytics().setCustomValue(PerfTrace.footprintMB(), forKey: "memory_mb")
                upload()
            }
            t.resume()
            hourly = t
            scheduleUrgentIfNeeded()
        }
    }

    // MARK: - Upload

    private static func isUrgent(_ e: Event) -> Bool { e.sev == Severity.critical.rawValue || e.sev == Severity.error.rawValue }

    /// On `queue`. Debounced: the first urgent event starts a 10s clock, later ones ride along.
    private static func scheduleUrgent() {
        guard !urgentScheduled else { return }
        urgentScheduled = true
        queue.asyncAfter(deadline: .now() + 10) {
            urgentScheduled = false
            upload()
        }
    }

    private static func scheduleUrgentIfNeeded() {
        if buffer.contains(where: isUrgent) { scheduleUrgent() }
    }

    /// Leaving the app: everything goes, inside a short background allowance. Main thread.
    @MainActor private static func uploadInBackground() {
        let hold = BackgroundHold()
        hold.id = UIApplication.shared.beginBackgroundTask(withName: "telemetry") {
            MainActor.assumeIsolated { hold.end() }
        }
        queue.async { saveNow(); upload() }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            hold.end()
        }
    }

    private final class BackgroundHold: @unchecked Sendable {
        var id = UIBackgroundTaskIdentifier.invalid
        @MainActor func end() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }

    /// On `queue`. Oldest first, 100 at a time. Signed out: kept for later (the callable needs a
    /// signed-in caller).
    private static func upload() {
        loadIfNeeded()
        prune()
        guard !uploading, !buffer.isEmpty, !uidHash.isEmpty, Date() >= nextAllowed else { return }
        let batch = Array(buffer.prefix(batchSize))
        let ids = Set(batch.map { $0.id })
        let body: [String: Any] = ["events": batch.map { $0.payload }]
        uploading = true
        Task {
            let ok: Bool
            do {
                _ = try await Functions.functions(region: "me-central1")
                    .httpsCallable("telemetryIngest").call(body)
                ok = true
            } catch {
                ok = false
            }
            queue.async {
                uploading = false
                if ok {
                    buffer.removeAll { ids.contains($0.id) }
                    failures = 0
                    nextAllowed = .distantPast
                    scheduleSave()
                    if batch.count == batchSize, !buffer.isEmpty { queue.async { upload() } }
                } else {
                    failures += 1
                    let delay = min(3600, 30 * pow(2, Double(min(failures - 1, 7))))
                    nextAllowed = Date().addingTimeInterval(delay)
                    if buffer.contains(where: isUrgent) {
                        queue.asyncAfter(deadline: .now() + delay + 1) { upload() }
                    }
                }
            }
        }
    }

    // MARK: - Disk

    private static func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let url = fileURL, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([Event].self, from: data) {
            buffer = saved + buffer
        }
        prune()
    }

    /// Drop events older than 3 days and keep the newest 500.
    private static func prune() {
        let cutoff = Int64(Date().timeIntervalSince1970 * 1000) - maxAgeMs
        buffer.removeAll { $0.ts < cutoff }
        if buffer.count > maxEvents { buffer.removeFirst(buffer.count - maxEvents) }
    }

    private static func scheduleSave() {
        guard !savePending else { return }
        savePending = true
        queue.asyncAfter(deadline: .now() + 1) { saveNow() }
    }

    private static func saveNow() {
        savePending = false
        guard let url = fileURL, let data = try? JSONEncoder().encode(buffer) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: - Scrubbing

    private static let tokenChars = Set("abcdefghijklmnopqrstuvwxyz0123456789_.-")

    private static func token(_ s: String, _ max: Int) -> String {
        let t = String(s.lowercased().filter { tokenChars.contains($0) }.prefix(max))
        return t.isEmpty ? "unknown" : t
    }

    private static func scrub(_ detail: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in detail where allowedKeys.contains(k) {
            out[k] = frameKeys.contains(k) ? String(v.prefix(300)) : clean(v)
        }
        return out
    }

    /// Strips what must never leave the phone, then cuts to 300 characters.
    static func clean(_ value: String) -> String {
        var s = value
        let rules: [(String, String)] = [
            (#"([A-Za-z][A-Za-z0-9+.\-]*://[^\s?#]*)[?#]\S*"#, "$1"),          // URL query / fragment
            (#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, "[email]"),  // e-mail
            (#"(?<![A-Za-z0-9])@[A-Za-z0-9_.]{2,}"#, "[handle]"),               // @username
            (#"\+?\d[\d \-]{7,}\d"#, "[num]"),                                   // phone-like digit runs
            (#"[A-Za-z0-9_\-+/=]{24,}"#, "[redacted]"),                          // tokens, keys, uids
        ]
        for (pattern, replacement) in rules {
            s = s.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return String(s.prefix(300))
    }
}
