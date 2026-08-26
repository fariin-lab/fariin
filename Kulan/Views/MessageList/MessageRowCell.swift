import UIKit

// ===== The cell =====
//
// One `MessageRowView` and nothing else. No hosting controller, no SwiftUI lifecycle, no
// re-measurement during scroll — the cell's whole job is to hand its view a model and a plan and
// put it at `contentView.bounds`.
//
// The taps a row answers are routed HERE rather than by a recogniser per element: a link, the reply
// quote, the reaction badges, the retry line, the selection circle, a group avatar and a sender
// name are all just rectangles in the plan, and hit-testing them in one place means a row with none
// of them installs no gesture machinery at all.

protocol MessageRowCellDelegate: AnyObject {
    func rowCell(_ cell: MessageRowCell, didTapLink url: URL)
    func rowCell(_ cell: MessageRowCell, didTapQuoteJumpTo id: String)
    func rowCell(_ cell: MessageRowCell, didTapStoryQuote id: String)
    func rowCellDidTapReactions(_ cell: MessageRowCell)
    func rowCellDidTapRetry(_ cell: MessageRowCell)
    func rowCellDidToggleSelection(_ cell: MessageRowCell)
    func rowCell(_ cell: MessageRowCell, didTapSender uid: String)
    func rowCellDidTapCallRow(_ cell: MessageRowCell)
    func rowCellDidTapPinNotice(_ cell: MessageRowCell, jumpTo id: String)
}

final class MessageRowCell: UICollectionViewCell {
    static let reuseId = "MessageRowCell"

    private let rowView = MessageRowView()
    private var tap: UITapGestureRecognizer!
    private var clockWork: DispatchWorkItem?

    weak var delegate: MessageRowCellDelegate?
    private(set) var rowId: String?
    private(set) var model: MessageRowModel?

    /// The box the list controller lifts for the long-press menu, hit-tests for the double tap, and
    /// translates for the reply swipe. A notice or a call row hands over its own box, not a hidden
    /// bubble still carrying the frame of the last row this cell drew.
    var previewBubble: UIView { rowView.liftTarget }

    /// The rect the long-press menu should lift, in window coordinates. Wider than the bubble when
    /// reactions hang off its corner: lifting the bubble alone slices the badge in half.
    var liftFrameInWindow: CGRect {
        var rect = rowView.liftTarget.frame
        if let p = rowView.plan, case .bubble(let b) = p.body, !b.reactions.isEmpty {
            rect = b.reactions.reduce(rect) { $0.union($1) }
        }
        return rowView.convert(rect, to: nil)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        contentView.addSubview(rowView)
        tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false   // the list's tap-to-dismiss-keyboard still gets its turn
        contentView.addGestureRecognizer(tap)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Configure

    func configure(_ m: MessageRowModel, plan: RowPlan, cid: String) {
        let previous = model
        rowId = m.id
        model = m
        rowView.frame = CGRect(origin: .zero, size: CGSize(width: plan.width, height: plan.height))

        // Entering or leaving selection mode SLIDES: the checkbox comes in from the leading edge and
        // the content moves over to make room, on the same 0.2s ease the toolbar uses.
        //
        // Gated to a cell that is already showing THIS row. Reconfigure and dequeue call the same
        // method, so without the id test a cell being recycled during a scroll would animate its way
        // from the last row's layout into this one's — motion out of nowhere, mid-scroll.
        let togglingSelection = previous?.id == m.id && previous?.selecting != m.selecting
        guard togglingSelection else {
            rowView.apply(m, plan: plan, cid: cid)
            scheduleClockRepaint()
            return
        }
        rowView.prepareSelectionEntry(entering: m.selecting, plan: plan)
        UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
            self.rowView.apply(m, plan: plan, cid: cid)
        }
        scheduleClockRepaint()
    }

    /// A geometry-neutral repaint — the tick upgraded, the time changed, the row was selected. Held
    /// to changes that cannot move anything, because a height-changing update has to go through the
    /// measured reload path or the bubble would repaint at a stale frame.
    func repaintMetaIfChanged(_ m: MessageRowModel, plan: RowPlan, cid: String) {
        guard let old = model, m != old else { return }
        guard sameGeometry(old, m) else { return }
        model = m
        // The tick's 0.25s cross-dissolve. A read receipt arriving is the commonest live change in a
        // chat, and snapping ✓ to ✓✓ reads as a glitch rather than as news — the SwiftUI meta faded
        // it and so did the UIKit cell this replaces.
        if tickChanged(old, m) {
            UIView.transition(with: rowView, duration: 0.25, options: [.transitionCrossDissolve]) {
                self.rowView.apply(m, plan: plan, cid: cid)
            }
        } else {
            rowView.apply(m, plan: plan, cid: cid)
        }
        rowView.animateDecorations(fromSelected: old.selected, fromHighlighted: old.highlighted)
        scheduleClockRepaint()
    }

    private func tickChanged(_ a: MessageRowModel, _ b: MessageRowModel) -> Bool {
        guard case .bubble(let x) = a.content, case .bubble(let y) = b.content else { return false }
        return x.meta.tick != y.meta.tick
    }

    /// Do these two models produce the same rects? Only the fields that cannot move anything are
    /// allowed to differ.
    private func sameGeometry(_ a: MessageRowModel, _ b: MessageRowModel) -> Bool {
        guard a.selecting == b.selecting, a.topSpacing == b.topSpacing,
              a.showsUnreadDivider == b.showsUnreadDivider, a.dateHeader == b.dateHeader else { return false }
        switch (a.content, b.content) {
        case (.bubble(let x), .bubble(let y)):
            return x.body == y.body && x.quote == y.quote && x.sender == y.sender
                && x.forwarded == y.forwarded && x.reactions.count == y.reactions.count
                && x.showsRetryRow == y.showsRetryRow
                && x.meta.edited == y.meta.edited && x.meta.timeText == y.meta.timeText
        default:
            return false
        }
    }

    /// The sending clock's grace window closes on a timer, not on a data change — so a send that is
    /// genuinely slow has to repaint itself once when the window expires. One scheduled repaint per
    /// pending row; nothing polls.
    private func scheduleClockRepaint() {
        clockWork?.cancel()
        clockWork = nil
        guard let remaining = rowView.pendingClockDeadline() else { return }
        let work = DispatchWorkItem { [weak self] in self?.rowView.refreshMeta() }
        clockWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining + 0.02, execute: work)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        clockWork?.cancel()
        clockWork = nil
        rowId = nil
        model = nil
        rowView.prepareForReuse()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The row view is sized from the plan, never from the cell: if the two ever disagree the
        // plan is right, and stretching the view to a stale cell frame is how content ends up
        // drawn at one size and measured at another.
        if rowView.frame.size != contentView.bounds.size, rowView.plan == nil {
            rowView.frame = contentView.bounds
        }
    }

    // MARK: - Taps

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard let m = model else { return }
        let p = g.location(in: rowView)

        if m.selecting {
            // In selection mode the whole row toggles — the checkbox is the affordance, not the
            // only target.
            delegate?.rowCellDidToggleSelection(self)
            return
        }
        if rowView.hitsCheckbox(p) {
            delegate?.rowCellDidToggleSelection(self)
            return
        }
        switch m.content {
        case .call:
            delegate?.rowCellDidTapCallRow(self)
            return
        case .notice(let n):
            if let target = n.tapTargetId, n.style == .pill {
                delegate?.rowCellDidTapPinNotice(self, jumpTo: target)
            }
            return
        case .bubble(let b):
            if rowView.hitsRetry(p), b.showsRetryRow {
                delegate?.rowCellDidTapRetry(self)
                return
            }
            if rowView.hitsReactions(p) {
                delegate?.rowCellDidTapReactions(self)
                return
            }
            if rowView.hitsQuote(p), let q = b.quote {
                // The quote's own anchor: a status quote flies the story out of THIS thumbnail, a
                // message quote jumps to the original.
                if q.isStatus { delegate?.rowCell(self, didTapStoryQuote: q.targetId) }
                else { delegate?.rowCell(self, didTapQuoteJumpTo: q.targetId) }
                return
            }
            if let s = b.sender, rowView.hitsAvatar(p) || rowView.hitsSenderName(p) {
                delegate?.rowCell(self, didTapSender: s.uid)
                return
            }
            if let url = rowView.link(at: p) {
                delegate?.rowCell(self, didTapLink: url)
                return
            }
        }
    }
}
