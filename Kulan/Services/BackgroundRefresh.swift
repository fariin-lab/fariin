import Foundation
import BackgroundTasks
import FirebaseAuth
import FirebaseFirestore

/// ⛔ BACKGROUND APP REFRESH — owner, 2026-10-17: "I missed Background App Refresh" (the row in
/// iOS Settings > Fariin, which iOS shows only for an app that declares `fetch`). REVERSES the
/// 2026-09-24 "no background refresh" decision on his word; large messengers all carry the row.
///
/// What it really does: when iOS grants a slot, read the newest chat-list rows from the SERVER once.
/// Firestore writes them into its disk cache, so the chat list's first frame on the next open is
/// already current instead of waiting on the listener. One query, the list's own, no listener left
/// running. iOS decides when (and whether) this runs; the user's switch in Settings turns it off.
enum BackgroundRefresh {
    static let taskId = "com.kulan.messenger.native.refresh"
    /// The same window the chat list opens with; more would spend reads on rows nobody scrolls to.
    private static let rows = 30

    /// Must run before `didFinishLaunching` returns (BGTaskScheduler's rule).
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskId, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            handle(task)
        }
    }

    /// Asks for the next slot. Called on going to the background; asking again replaces the old ask.
    static func schedule() {
        let req = BGAppRefreshTaskRequest(identifier: taskId)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule()   // keep the chain going whatever this run's outcome
        guard let uid = Auth.auth().currentUser?.uid else { task.setTaskCompleted(success: true); return }
        let work = Task {
            let ok = (try? await FirestoreHub.db.collection("conversations")
                .whereField("users", arrayContains: uid)
                .order(by: "updatedAt", descending: true)
                .limit(to: rows)
                .getDocuments(source: .server)) != nil
            task.setTaskCompleted(success: ok)
        }
        // iOS ends the slot when it likes; stop cleanly rather than be killed mid-read.
        task.expirationHandler = { work.cancel(); task.setTaskCompleted(success: false) }
    }
}
