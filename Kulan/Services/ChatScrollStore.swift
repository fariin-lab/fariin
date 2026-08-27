import Foundation

// ⛔ WHERE EACH CHAT WAS LAST BEING READ — the reference app's `lastVisibleInteraction`, in our shape.
//
// Theirs keeps two things per conversation: the id of the last visible interaction, and how much of
// that row was on screen (`onScreenPercentage`). On open, their scroll priority is focus message →
// unread indicator → **last visible interaction, restored to the same on-screen position**. Ours had
// the first two and stopped, so every re-entry to a long chat lost your place.
//
// ⚠️ IT IS ON DISK NOW, AND THAT IS A DELIBERATE CHANGE OF MIND. This file used to say the in-memory
// lifetime WAS the feature: reopen within a session and you land where you were, kill the app and you
// land at the newest. That is not what theirs does — theirs persists, so a cold launch still puts you
// back — and the owner asked for their behaviour exactly. `UserDefaults` rather than the message
// database because this is view state, not conversation data: it is small, per-chat, disposable, and
// losing it costs a reader one scroll.
//
// Main-actor only (written from the list controller's settle points).
struct ChatReadingPosition: Equatable, Codable {
    /// The row the reader was looking at — `Message.rowId`, which is `clientId ?? id` and therefore
    /// stable across launches, unlike an index or an offset.
    let rowId: String
    /// How far that row's top sat below the top of the visible area when we looked, in points. Their
    /// `onScreenPercentage` expressed the same idea as a fraction of the row; points survive a row
    /// whose height changes between sessions just as well and need no second lookup to apply.
    let offsetFromTop: CGFloat
}

final class ChatScrollStore {
    static let shared = ChatScrollStore()
    private init() {}

    /// A small in-memory mirror so a read during scrolling never touches `UserDefaults`.
    private var byCid: [String: ChatReadingPosition] = [:]
    private let defaults = UserDefaults.standard
    private static let keyPrefix = "chatReadingPosition."

    private func key(_ cid: String) -> String { Self.keyPrefix + cid }

    func save(_ cid: String, _ position: ChatReadingPosition) {
        guard byCid[cid] != position else { return }
        byCid[cid] = position
        if let data = try? JSONEncoder().encode(position) {
            defaults.set(data, forKey: key(cid))
        }
    }

    /// ⛔ CLEARED WHEN THE READER IS AT THE NEWEST MESSAGE, not saved as "bottom". A chat you left at
    /// the bottom should open at the bottom, and that is what having no stored position already
    /// means — storing a sentinel for it would be a second way to say the same thing, and the two
    /// could disagree.
    func clear(_ cid: String) {
        guard byCid[cid] != nil || defaults.object(forKey: key(cid)) != nil else { return }
        byCid.removeValue(forKey: cid)
        defaults.removeObject(forKey: key(cid))
    }

    func position(for cid: String) -> ChatReadingPosition? {
        if let cached = byCid[cid] { return cached }
        guard let data = defaults.data(forKey: key(cid)),
              let decoded = try? JSONDecoder().decode(ChatReadingPosition.self, from: data) else { return nil }
        byCid[cid] = decoded
        return decoded
    }
}

// Reference box so per-row onAppear/onDisappear can update the visible-id set WITHOUT invalidating
// the SwiftUI body on every scroll tick (the same non-invalidating-box trick used elsewhere for
// gesture-adjacent flags). Reset per ThreadView instance.
final class VisibleRowsBox {
    var ids: Set<String> = []
    // Debounce for persisting the reading position: rows fire onAppear for EVERY row that scrolls in
    // (and the list keeps an extra viewport pre-rendered), so saving per-appearance meant an O(n) scan
    // plus a store write on every scroll tick — main-thread churn during exactly the frames that need
    // headroom. One trailing save 0.5s after the last appearance is just as durable.
    var persistWork: DispatchWorkItem?
}
