import Foundation

/// The in-flight media sends, held so Cancel can actually CANCEL.
///
/// "Cancel Sending" used to call `repo.removePending` and nothing else: the bubble disappeared and
/// the upload Task kept running to the end, wrote the message document, and the photos appeared in
/// the chat a minute later anyway (owner 2026-08-05, on device). Nothing held the Task, so nothing
/// could stop it. This holds it.
///
/// Two levels, matching the two cancels the album bubble offers:
///  • the WHOLE message (`cancel`): the send task and every item upload under it are cancelled;
///    the storage tasks abort mid-flight (uploadEncrypted's cancellation handler calls
///    `StorageUploadTask.cancel()`), the send throws before its batch commit, and the caller
///    removes the bubble instead of marking it failed.
///  • ONE album item (`cancelItem`, the X on a tile): that item's upload aborts and the send loop
///    SKIPS it — the album ships without it, everything else unharmed. Keys are "clientId#index",
///    the same keys the per-item progress rings read.
///
/// ObservableObject so the album tiles can watch `cancelledItems` and dim an X'd tile the moment
/// it is cancelled, without waiting on the send loop to notice.
@MainActor
final class MediaSend: ObservableObject {
    static let shared = MediaSend()
    private init() {}

    private var sendTasks: [String: Task<Void, Error>] = [:]
    private var itemTasks: [String: Task<String, Error>] = [:]
    private var cancelledSends: Set<String> = []
    @Published private(set) var cancelledItems: Set<String> = []
    /// Items whose MAIN transfer has landed. The tiles read this to drop their ring the moment
    /// their own upload is done — the message stays `.sending` until the whole batch commits, and
    /// per-message state was all a tile had, so a finished photo kept spinning while its
    /// neighbours uploaded (owner's screenshot, 2026-08-05). Worse than spinning: its BYTES were
    /// gone from UploadProgress the moment it finished, so the ring fell back to the indeterminate
    /// spinner and looked stuck on purpose.
    @Published private(set) var doneItems: Set<String> = []

    /// Pure string math — callable from the send loops without hopping to the main actor.
    nonisolated static func itemKey(_ clientId: String, _ index: Int) -> String { "\(clientId)#\(index)" }

    // MARK: whole-message

    func register(_ clientId: String, _ task: Task<Void, Error>) { sendTasks[clientId] = task }

    /// Cancel the whole send: the outer task AND every item upload currently in flight under it.
    /// Both matter — cancelling only the outer task would leave the current item's own child task
    /// running (an unstructured Task does not inherit its awaiter's cancellation).
    func cancel(_ clientId: String) {
        cancelledSends.insert(clientId)
        sendTasks[clientId]?.cancel()
        for (key, t) in itemTasks where key.hasPrefix("\(clientId)#") { t.cancel() }
    }

    /// True when the failure the send path just caught was this user pressing Cancel — the caller
    /// then removes the bubble quietly instead of marking it failed.
    func wasCancelled(_ clientId: String) -> Bool { cancelledSends.contains(clientId) }

    /// The send finished, failed or was cleaned up: forget everything filed under its id.
    func finish(_ clientId: String) {
        sendTasks[clientId] = nil
        cancelledSends.remove(clientId)
        let prefix = "\(clientId)#"
        for key in itemTasks.keys where key.hasPrefix(prefix) { itemTasks[key] = nil }
        if cancelledItems.contains(where: { $0.hasPrefix(prefix) }) {
            cancelledItems = cancelledItems.filter { !$0.hasPrefix(prefix) }
        }
        if doneItems.contains(where: { $0.hasPrefix(prefix) }) {
            doneItems = doneItems.filter { !$0.hasPrefix(prefix) }
        }
        // ⚠️ AND THE BARE ID. An album item's key is "clientId#index" and the prefix above clears
        // those; a SINGLE photo or video files its done mark under the clientId itself, with no
        // "#", so the prefix never matched it. Without this a retry of the same bubble would find
        // the previous attempt's mark still standing and hide the ring for an upload that had not
        // started.
        doneItems.remove(clientId)
    }

    // MARK: one album item

    func registerItem(_ key: String, _ task: Task<String, Error>) { itemTasks[key] = task }
    func finishItem(_ key: String) { itemTasks[key] = nil }

    /// The item's MAIN transfer succeeded (a video's poster does not count — the clip is what the
    /// ring was filling with). The send loops call this at the one moment it becomes true.
    func markItemDone(_ key: String) { doneItems.insert(key) }
    func isItemDone(_ key: String) -> Bool { doneItems.contains(key) }

    func cancelItem(_ key: String) {
        cancelledItems.insert(key)
        itemTasks[key]?.cancel()
        itemTasks[key] = nil
    }

    func isItemCancelled(_ key: String) -> Bool { cancelledItems.contains(key) }
}
