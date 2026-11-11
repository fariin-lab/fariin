import Foundation
import UIKit
import Network
import OSLog
import os
import FirebaseFirestore
import CryptoKit

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
    /// Kept as SHA-256 of the uid (lowercase hex), so the app binary carries no real user ids
    /// (release audit 2026-11-10). To add an account, hash its uid the same way.
    private static let watched: Set<String> = [
        "413d3aee1a271d76b0059e70c5d34f96aff7221a5202884a335c7e6f8d01133b",   // @v
        "145df1ef52aa069ea7add19488709a73d13fe614f1e7db6e78df8fcf866561a7",   // @kream
    ]

    private static func hashed(_ uid: String) -> String {
        SHA256.hash(data: Data(uid.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static var startedFor: String?
    private static var monitor: NWPathMonitor?
    private static var tokens: [NSObjectProtocol] = []
    private static var lastPath = ""
    private static let started = Date()

    static func isWatched(_ uid: String?) -> Bool { uid.map { watched.contains(hashed($0)) } ?? false }

    /// Called whenever a signed-in session is (re)attached. Starts once per account per process.
    /// Test builds only (`DiagUpload.allowed`, debug or TestFlight): an App Store install never turns
    /// on Firebase's detailed log, and its black box is never sent anyway (release audit 2026-11-10).
    static func start(uid: String) {
        guard DiagUpload.allowed, startedFor != uid, watched.contains(hashed(uid)) else { return }
        startedFor = uid
        // Firebase's detailed log only in a local debug build (perf audit 2026-11-11, E6). It writes a
        // line for every watch-stream message, snapshot and write on Firestore's own worker queue, so
        // on a TestFlight phone it slowed every snapshot for the whole session, and those are the
        // phones lag is judged on. The reference app likewise keeps its network log off unless a
        // developer turns it on. TestFlight keeps the cheap NET# / POWER# / APP# lines below.
        #if DEBUG
        Firestore.enableLogging(true)
        DiagLog.add("CONNDIAG# on: detailed Firebase log, network and power changes")
        #else
        DiagLog.add("CONNDIAG# on: network and power changes (no Firebase log outside debug builds)")
        #endif

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
    /// ⛔ ONE READ AT A TIME, AND NOT AGAIN FOR TWO MINUTES (crash 2026-11-02, build 1087, watchdog
    /// 0x8BADF00D): every stall and wedge started its own scan of the process log, and six were found
    /// running at once on the utility threads. The phone ran hot ("thermal serious", 84% CPU) and the
    /// main thread missed the 10 s scene-update deadline. A second stall within the window adds
    /// nothing the first read did not already capture.
    nonisolated private static let gate = OSAllocatedUnfairLock(initialState: (busy: false, last: Date.distantPast))

    static func captureFirebaseLog(_ why: String, minutes: Double = 3) {
        // Outside a debug build Firebase's detailed log is off (see `start`), so there is nothing to copy.
        #if !DEBUG
        return
        #endif
        guard startedFor != nil else { return }
        let now = Date()
        let go = gate.withLock { s -> Bool in
            guard !s.busy, now.timeIntervalSince(s.last) > 120 else { return false }
            s = (true, now)
            return true
        }
        guard go else { DiagLog.add("FSLOG# \(why): skipped, a read ran in the last 2 min"); return }
        let since = max(started, now.addingTimeInterval(-minutes * 60))
        Task.detached(priority: .utility) {
            let lines = firebaseLines(since: since, max: 160)
            gate.withLock { $0.busy = false }
            DiagLog.add("FSLOG# \(why): \(lines.count) lines from Firebase's log")
            for l in lines { DiagLog.add("FSLOG# \(l)") }
        }
    }

    nonisolated private static func firebaseLines(since: Date, max: Int) -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return ["log store unavailable"] }
        let position = store.position(date: since)
        // The store filters, so the loop below no longer composes and drops every other line the
        // app logged in those minutes.
        let only = NSPredicate(format: "subsystem CONTAINS[c] 'firebase' OR category CONTAINS[c] 'firestore'")
        guard let entries = try? store.getEntries(at: position, matching: only) else { return ["log read failed"] }
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
