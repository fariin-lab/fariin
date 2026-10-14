import Foundation
import UIKit
import CallKit
import FirebaseAuth
import FirebaseFirestore

/// ⛔ THE BLACK BOX FOR "THE APP GOES DEAD UNTIL I RELAUNCH IT" — owner, 2026-10-13, 7th report
/// (09-27, 10-08, 10-10, 10-11, 10-13 x3). Every fix so far came from reading code; the exact point
/// inside Firebase where the connection sticks has never been SEEN, because the phone that hits it is
/// his and there is no Mac here to read its console. So the phone writes down what happened.
///
/// Never on screen (his order 2026-09-28). A small text file in Application Support, kept to the last
/// `maxBytes`. When a stall is noticed the file is flagged; the next time a signed-in session starts
/// with a working connection (normally right after the relaunch that healed it), the file goes to
/// `users/{uid}/diag/{id}` and the flag clears. An upload that fails leaves both for next time.
///
/// What it answers, at the moment of a stall (`snapshot`): does a CACHE read still answer (if not,
/// the Firestore client itself is stuck, not the network), are writes still unconfirmed, what the
/// call state is against what iOS says, and whether the app was on screen. Plus every recovery step
/// and App Check timings, so the next report is evidence, not a guess.
enum DiagLog {
    private static let queue = DispatchQueue(label: "DiagLog")
    private static let maxBytes = 60_000
    private static let pendingKey = "diagLog.uploadPending"
    @MainActor private static var uploading = false

    private static var fileURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("diag.log")
    }

    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// One line, timestamped. Cheap and safe from any thread.
    static func add(_ line: String) {
        let text = "\(stamp.string(from: Date())) \(line)\n"
        queue.async {
            guard let url = fileURL else { return }
            // Appended, not rewritten: the story trace (2026-10-14) writes dozens of lines a second
            // around a landing, and reading and rewriting 60 KB for each was needless disk work.
            // The file is cut back to its tail once it has grown to twice the cap.
            var appended = false
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                if (try? h.seekToEnd()) != nil, (try? h.write(contentsOf: Data(text.utf8))) != nil {
                    appended = true
                    let size = (try? h.offset()).map { Int($0) } ?? 0
                    if size <= maxBytes * 2 { return }
                }
            }
            var data = (try? Data(contentsOf: url)) ?? Data()
            if !appended { data.append(Data(text.utf8)) }
            if data.count > maxBytes { data = data.suffix(maxBytes) }
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    /// Something worth reading happened (a slow story landing, say): flag the file and send it in a
    /// few seconds, rather than waiting for the next launch's connection probe.
    static func flagForUpload(after seconds: TimeInterval = 3) {
        UserDefaults.standard.set(true, forKey: pendingKey)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let uid = Auth.auth().currentUser?.uid else { return }
            uploadIfPending(uid: uid)
        }
    }

    /// Launch line: which build this process is, so episodes can be told apart.
    static func launched() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        add("LAUNCH \(version) (\(build)) iOS \(UIDevice.current.systemVersion)")
    }

    /// A stall was noticed: record the state that tells "client stuck" from "network stuck", and flag
    /// the file for upload. The cache read gets 3s; Firestore answers it from disk in milliseconds
    /// unless its own worker is wedged.
    @MainActor static func snapshot(_ reason: String) {
        UserDefaults.standard.set(true, forKey: pendingKey)
        let appState: String
        switch UIApplication.shared.applicationState {
        case .active: appState = "active"
        case .inactive: appState = "inactive"
        default: appState = "background"
        }
        let systemCalls = CXCallObserver().calls.filter { !$0.hasEnded }.count
        add("STALL \(reason) app=\(appState) callState=\(CallService.shared.state) systemCalls=\(systemCalls)")
        guard let uid = Auth.auth().currentUser?.uid else { add("  no user"); return }
        let began = Date()
        let answered = Once()
        Task {
            do {
                _ = try await Firestore.firestore().collection("users").document(uid).getDocument(source: .cache)
                if answered.claim() { add("  cache read answered in \(ms(since: began))ms") }
            } catch {
                if answered.claim() { add("  cache read failed in \(ms(since: began))ms: \(error.localizedDescription)") }
            }
        }
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if answered.claim() { add("  cache read DID NOT ANSWER in 3s (Firestore client stuck)") }
        }
        let writes = Once()
        Task {
            try? await Firestore.firestore().waitForPendingWrites()
            if writes.claim() { add("  pending writes confirmed in \(ms(since: began))ms") }
        }
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if writes.claim() { add("  pending writes still unconfirmed after 3s") }
        }
    }

    /// Send the file if a stall flagged it. Called when a signed-in session starts its connection
    /// probe; a failure (offline, rule not live yet) keeps the file and the flag for next time.
    @MainActor static func uploadIfPending(uid: String) {
        guard UserDefaults.standard.bool(forKey: pendingKey), !uploading else { return }
        uploading = true
        queue.async {
            let text = fileURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
            Task { @MainActor in
                defer { uploading = false }
                guard !text.isEmpty else {
                    UserDefaults.standard.set(false, forKey: pendingKey)
                    return
                }
                let info = Bundle.main.infoDictionary
                do {
                    try await Firestore.firestore().collection("users").document(uid)
                        .collection("diag").document().setData([
                            "text": text,
                            "build": info?["CFBundleVersion"] as? String ?? "?",
                            "ios": UIDevice.current.systemVersion,
                            "at": FieldValue.serverTimestamp(),
                        ])
                    UserDefaults.standard.set(false, forKey: pendingKey)
                    // Start the file over, so the next upload carries only what came after.
                    queue.async { if let url = fileURL { try? FileManager.default.removeItem(at: url) } }
                    add("UPLOADED previous log")
                } catch {
                    add("upload failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private static func ms(since date: Date) -> Int { Int(Date().timeIntervalSince(date) * 1000) }

    /// First caller wins; for racing an answer against a deadline.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}
