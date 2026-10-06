import UIKit

/// One plan per (row, width), computed once and handed to both the height pass and the draw pass.
///
/// The list asks for a row's height while laying out, and asks again for its rects a moment later
/// when the cell is configured. Recomputing would be wasted work on every frame of a scroll — and,
/// worse, it would reopen the door this whole directory closes: two computations that could return
/// different answers. Here the second caller gets the same value object the first one did.
///
/// The entry is keyed by row id and validated by comparing the MODEL, not a signature string. A
/// signature is a guess about which fields matter; `==` is the truth, and `MessageRowModel` is
/// Equatable precisely so this check can be exact.
final class RowPlanStore {
    private struct Entry {
        var model: MessageRowModel
        var width: CGFloat
        /// The text size the plan's fonts were built at. A plan is only true at that size.
        var textSize: UIContentSizeCategory
        var plan: RowPlan
        /// When this plan was last asked for, for least-recently-used eviction.
        var lastUse: Int
    }

    private var entries: [String: Entry] = [:]
    /// owner audit 2026-10-06 chat #86: this was 400 entries dropped in INSERTION order, below the
    /// message window (500, up to 800 while paging), and the newest rows are planned first after an
    /// open, so a page of history evicted exactly the rows next to the reader and scrolling back
    /// re-planned them on the main thread. Now above the window's high-water mark, and a hit counts
    /// as a use, so the rows being read are the last to go.
    private var useClock = 0
    private let capacity: Int

    init(capacity: Int = 1000) { self.capacity = capacity }

    /// ⛔ ONE STORE PER CHAT, KEPT BETWEEN OPENS — owner, 2026-09-28: "opening a chat takes too
    /// long… the reference app opens almost immediately". Each list controller made its own store,
    /// so leaving a chat threw every plan away and the next open laid out every loaded row again
    /// (TextKit, on the main thread) inside the SwiftUI update that starts the push: up to 200 rows
    /// before the slide could begin. The reference app measures its first window off the main
    /// thread and only one screen of it. Here the cheapest correct half of that: a reopen finds its
    /// plans. Reuse is exact, not a guess, because `plan(for:)` only returns an entry whose MODEL
    /// and width are equal to the one asked for; anything that changed is laid out again.
    /// Twelve chats, least recently opened dropped first, the same bound as `RenderedHeightStore`.
    static func forChat(_ cid: String) -> RowPlanStore { ChatStores.shared.store(cid) }

    private final class ChatStores {
        static let shared = ChatStores()
        private var byCid: [String: RowPlanStore] = [:]
        private var order: [String] = []
        private let maxChats = 12

        func store(_ cid: String) -> RowPlanStore {
            order.removeAll { $0 == cid }
            order.append(cid)
            if let s = byCid[cid] { return s }
            let s = RowPlanStore()
            byCid[cid] = s
            if order.count > maxChats { byCid.removeValue(forKey: order.removeFirst()) }
            return s
        }
    }

    func plan(for model: MessageRowModel, width: CGFloat) -> RowPlan {
        let textSize = BubbleMetrics.contentSizeCategory
        if let hit = entries[model.id], hit.width == width, hit.textSize == textSize, hit.model == model {
            useClock += 1
            entries[model.id]?.lastUse = useClock
            return hit.plan
        }
        let plan = MessageRowLayout.plan(model, width: width)
        seed(model, width: width, plan: plan)
        return plan
    }

    /// A plan computed somewhere else, for this exact model and width: the first open lays its
    /// window out on a background queue and hands the results in here, so the main thread's own
    /// `plan(for:)` finds them instead of laying the rows out again.
    func seed(_ model: MessageRowModel, width: CGFloat, plan: RowPlan) {
        useClock += 1
        // Stamped with the text size it was planned at (audit C8: text follows the system size).
        entries[model.id] = Entry(model: model, width: width,
                                  textSize: BubbleMetrics.contentSizeCategory, plan: plan,
                                  lastUse: useClock)
        if entries.count > capacity { evictLeastRecentlyUsed() }
    }

    /// Drops the least recently used tenth in one pass, so a window that keeps growing past the
    /// capacity (deep history is never trimmed) pays for a sort once per hundred new rows, not per row.
    private func evictLeastRecentlyUsed() {
        let excess = entries.count - capacity + capacity / 10
        guard excess > 0 else { return }
        let victims = entries.sorted { $0.value.lastUse < $1.value.lastUse }.prefix(excess).map(\.key)
        for id in victims { entries.removeValue(forKey: id) }
    }

    /// A width change invalidates every row at once — a rotation, or an iPad split view resizing
    /// the list. Nothing measured at the old width can be trusted. A text-size change does too.
    func invalidateAll() {
        entries.removeAll()
    }
}
