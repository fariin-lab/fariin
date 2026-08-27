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

    func plan(for model: MessageRowModel, width: CGFloat) -> RowPlan {
        if let hit = entries[model.id], hit.width == width, hit.model == model {
            return hit.plan
        }
        let plan = MessageRowLayout.plan(model, width: width)
        if entries[model.id] == nil {
            order.append(model.id)
            if order.count > capacity {
                let drop = order.removeFirst()
                entries.removeValue(forKey: drop)
            }
        }
        entries[model.id] = Entry(model: model, width: width, plan: plan)
        return plan
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
