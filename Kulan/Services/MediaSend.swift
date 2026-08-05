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
    }

    // MARK: one album item

    func registerItem(_ key: String, _ task: Task<String, Error>) { itemTasks[key] = task }
    func finishItem(_ key: String) { itemTasks[key] = nil }

    func cancelItem(_ key: String) {
        cancelledItems.insert(key)
        itemTasks[key]?.cancel()
        itemTasks[key] = nil
    }

    func isItemCancelled(_ key: String) -> Bool { cancelledItems.contains(key) }
}
