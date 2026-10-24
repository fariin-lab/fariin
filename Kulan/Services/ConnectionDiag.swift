import Foundation
import UIKit
import Network
import OSLog
import FirebaseFirestore

/// ⛔ FINDING THE TRIGGER OF "DEAD UNTIL RESTART" (owner 2026-10-24, 10th report). The black box
/// (`DiagLog`) shows WHERE it sticks (Firebase's connection teardown, SDK #12522) but not WHAT starts
/// it. For the accounts that hit it most, this records what was going on around it:
///
/// - every network change (Wi-Fi / mobile / VPN / none, expensive, constrained), Low Power Mode, and
///   the app going to and from the background, as `NET#` / `POWER#` / `APP#` lines;
/// - Firebase's OWN detailed log (`Firestore.enableLogging`), which goes to the system log, and on a
///   stall or a stuck client the last few minutes of it are copied into the black box (`FSLOG#`), so
///   the seconds before the stick can be read off the uploaded file.
///
/// Only for `watched` accounts: the detailed Firebase log costs CPU and is noisy, and two very active
/// accounts are enough to see the pattern. Everyone else is untouched. Never on screen.
@MainActor
enum ConnectionDiag {
    /// @v (most episodes, iOS 27) and @kream (the owner's own; stuck once in a call on iOS 26.6).
    private static let watched: Set<String> = [
        "SVf0zxDVZzO8oLbGvM150QWgIWd2",   // @v
        "a74hUgOoNYOmxMDoNCWI4nO81xH3",   // @kream
    ]

    private static var startedFor: String?
    private static var monitor: NWPathMonitor?
    private static var tokens: [NSObjectProtocol] = []
    private static var lastPath = ""
    private static let started = Date()

    static func isWatched(_ uid: String?) -> Bool { uid.map { watched.contains($0) } ?? false }

    /// Called whenever a signed-in session is (re)attached. Starts once per account per process.
    static func start(uid: String) {
        guard watched.contains(uid), startedFor != uid else { return }
        startedFor = uid
        Firestore.enableLogging(true)
        DiagLog.add("CONNDIAG# on: detailed Firebase log, network and power changes")

        let m = NWPathMonitor()
        m.pathUpdateHandler = { path in
            let line = describe(path)
            Task { @MainActor in
                guard line != lastPath else { return }
                lastPath = line
                DiagLog.add("NET# \(line)")
            }
        }
        m.start(queue: DispatchQueue(label: "ConnectionDiag.path"))
        monitor = m

        let nc = NotificationCenter.default
        tokens.append(nc.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            DiagLog.add("POWER# lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled)")
        })
        tokens.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            DiagLog.add("APP# background")
        })
        tokens.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            DiagLog.add("APP# foreground")
        })
        DiagLog.add("POWER# lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled)")
    }

    /// A stall or a stuck client: copy the last `minutes` of Firebase's own log into the black box.
    /// Reads this process's log only (`OSLogStore`, no permission needed), off the main thread.
    static func captureFirebaseLog(_ why: String, minutes: Double = 3) {
        guard startedFor != nil else { return }
        let since = max(started, Date().addingTimeInterval(-minutes * 60))
        Task.detached(priority: .utility) {
            let lines = firebaseLines(since: since, max: 160)
            DiagLog.add("FSLOG# \(why): \(lines.count) lines from Firebase's log")
            for l in lines { DiagLog.add("FSLOG# \(l)") }
        }
    }

    nonisolated private static func firebaseLines(since: Date, max: Int) -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return ["log store unavailable"] }
        let position = store.position(date: since)
        guard let entries = try? store.getEntries(at: position) else { return ["log read failed"] }
        var out: [String] = []
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        for case let e as OSLogEntryLog in entries {
            let sub = e.subsystem.lowercased(), cat = e.category.lowercased()
            guard sub.contains("firebase") || cat.contains("firestore") else { continue }
            let msg = e.composedMessage.replacingOccurrences(of: "\n", with: " ")
            out.append("\(f.string(from: e.date)) \(String(msg.prefix(220)))")
        }
        return Array(out.suffix(max))
    }

    nonisolated private static func describe(_ p: NWPath) -> String {
        var kinds: [String] = []
        if p.usesInterfaceType(.wifi) { kinds.append("wifi") }
        if p.usesInterfaceType(.cellular) { kinds.append("cellular") }
        if p.usesInterfaceType(.wiredEthernet) { kinds.append("wired") }
        if p.usesInterfaceType(.other) { kinds.append("other") }
        // A VPN shows up as a tunnel interface (utun / ipsec) beside the real one.
        let vpn = p.availableInterfaces.contains { $0.name.hasPrefix("utun") || $0.name.hasPrefix("ipsec") }
        let status: String
        switch p.status {
        case .satisfied: status = "ok"
        case .unsatisfied: status = "none"
        case .requiresConnection: status = "waiting"
        @unknown default: status = "?"
        }
        return "\(status) \(kinds.isEmpty ? "-" : kinds.joined(separator: "+"))"
            + "\(vpn ? " vpn" : "")\(p.isExpensive ? " expensive" : "")\(p.isConstrained ? " lowdata" : "")"
    }
}
