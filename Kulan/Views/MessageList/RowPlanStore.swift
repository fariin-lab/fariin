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
        var plan: RowPlan
    }

    private var entries: [String: Entry] = [:]
    /// Insertion order, so the store can drop the oldest rows instead of growing with the thread.
    private var order: [String] = []
    private let capacity: Int

    init(capacity: Int = 400) { self.capacity = capacity }

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
        if let hit = entries[model.id], hit.width == width, hit.model == model {
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
        if entries[model.id] == nil {
            order.append(model.id)
            if order.count > capacity {
                let drop = order.removeFirst()
                entries.removeValue(forKey: drop)
            }
        }
        entries[model.id] = Entry(model: model, width: width, plan: plan)
    }

    /// The cached plan without computing one — for the paths that only want to know where a bubble
    /// already is (the menu's lift rect, the swipe's arrow anchor) and must not do layout work.

    func invalidate(id: String) {
        entries.removeValue(forKey: id)
        order.removeAll { $0 == id }
    }

    /// A width change invalidates every row at once — a rotation, or an iPad split view resizing
    /// the list. Nothing measured at the old width can be trusted.
    func invalidateAll() {
        entries.removeAll()
        order.removeAll()
    }
}
