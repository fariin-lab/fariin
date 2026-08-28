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
    func rowCellDidTapMedia(_ cell: MessageRowCell)
    func rowCellDidTapPill(_ cell: MessageRowCell)
    func rowCell(_ cell: MessageRowCell, didTapAlbumTile index: Int)
    func rowCellDidTapFile(_ cell: MessageRowCell)
    func rowCellDidTapStoryReply(_ cell: MessageRowCell)
    func rowCellDidToggleVoice(_ cell: MessageRowCell)
    func rowCellDidTapLinkCard(_ cell: MessageRowCell)
    func rowCellDidTapLinkProfile(_ cell: MessageRowCell)
    func rowCellDidTapLocation(_ cell: MessageRowCell)
    func rowCellDidTapContactCard(_ cell: MessageRowCell)
    func rowCellDidTapContactMessage(_ cell: MessageRowCell)
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
        rowView.onVoicePlayToggle = { [weak self] in
            guard let self else { return }
            self.delegate?.rowCellDidToggleVoice(self)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Configure

    func configure(_ m: MessageRowModel, plan: RowPlan, cid: String) {
        let previous = model
        rowId = m.id
        model = m
        rowView.frame = CGRect(origin: .zero, size: CGSize(width: plan.width, height: plan.height))

        // ⛔ THE ANIMATION IS DECIDED BY THE MODEL, NOT BY WHAT THIS CELL DREW LAST.
        //
        // Theirs asks one question of the render state — `isShowingSelectionUI` against
        // `wasShowingSelectionUI` — and gets three answers: animate in, animate out, or neither.
        // Because both halves ride on the model, a cell that was dequeued fresh mid-transition
        // animates correctly too, and a cell that missed the transition entirely cannot be left in
        // the wrong state: the pass after the slide carries neither flag, and the row is rebuilt
        // without a selection lane at all.
        //
        // What this replaced compared against `previous` — the last model THIS cell instance was
        // configured with. A recycled cell has none, so it silently took the no-animation branch,
        // and a cell whose reconfigure was skipped never learned the mode had changed.
        let entering = m.selecting && !m.wasSelecting
        let leaving = !m.selecting && m.wasSelecting
        // The CONTENT's move is a layout change, so it is still gated to a cell already showing this
        // row: a recycled one would slide from the previous row's geometry, which is motion out of
        // nowhere mid-scroll. The circle's own slide is a layer animation and is safe either way.
        let sameRow = previous?.id == m.id
        guard entering || leaving else {
            rowView.apply(m, plan: plan, cid: cid)
            return
        }
        if sameRow {
            // Incoming rows move over; outgoing ones do not. That falls out of the geometry rather
            // than a direction test — theirs puts a flexible spacer between the selection lane and an
            // outgoing bubble, and `MessageRowLayout` now right-aligns to the same trailing edge in
            // both modes, so an outgoing row's rects simply do not change and there is nothing for
            // this animation to interpolate.
            UIView.animate(withDuration: MessageRowLayout.selectionAnimationDuration, delay: 0,
                           options: [.curveEaseInOut, .allowUserInteraction]) {
                self.rowView.apply(m, plan: plan, cid: cid)
            }
        } else {
            rowView.apply(m, plan: plan, cid: cid)
        }
        rowView.animateSelectionSlide(entering: entering)
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
    }

    private func tickChanged(_ a: MessageRowModel, _ b: MessageRowModel) -> Bool {
        guard case .bubble(let x) = a.content, case .bubble(let y) = b.content else { return false }
        return x.meta.tick != y.meta.tick
    }

    /// Do these two models produce the same rects? Only the fields that cannot move anything are
    /// allowed to differ.
    private func sameGeometry(_ a: MessageRowModel, _ b: MessageRowModel) -> Bool {
        // `wasSelecting` is as much a geometry input as `selecting` is: it is half of what decides
        // whether the row has a selection lane at all (see MessageRowLayout).
        guard a.selecting == b.selecting, a.wasSelecting == b.wasSelecting, a.topSpacing == b.topSpacing,
              a.showsUnreadDivider == b.showsUnreadDivider, a.dateHeader == b.dateHeader else { return false }
        switch (a.content, b.content) {
        case (.bubble(let x), .bubble(let y)):
            return x.body == y.body && x.quote == y.quote && x.sender == y.sender
                // ⚠️ The story card MUST be here. When a story expires the card collapses from a
                // 140pt picture to a one-line "Story unavailable", and nothing else in this
                // comparison changes — so without it the row repainted at its old frame and the
                // rows below it were laid out over the gap.
                && x.storyReply == y.storyReply
                && x.forwarded == y.forwarded && x.reactions.count == y.reactions.count
                && x.showsFailedBadge == y.showsFailedBadge
                && x.meta.edited == y.meta.edited && x.meta.timeText == y.meta.timeText
        default:
            return false
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
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
            // only target. Theirs suppresses every other tap handler here for the same reason.
            //
            // THE TICK IS WRITTEN ONTO THE VIEW FIRST, then the model is told. That is their
            // `handleTap`: `selectionView.isSelected = true`, then `selectionState.add(...)`. The
            // circle fills on the same frame as the finger instead of waiting for a model rebuild,
            // a signature re-hash and a reconfigure to come back round.
            rowView.setSelectedImmediately(!m.selected)
            model?.selected.toggle()
            delegate?.rowCellDidToggleSelection(self)
            return
        }
        // ⚠️ NO CHECKBOX TARGET OUTSIDE SELECTION MODE. The lane survives one pass past the exit so
        // the circle has somewhere to slide out through, and a tap landing in that 0.2s window used
        // to re-enter selection. Theirs gates on `isShowingSelectionUI` alone, which is `m.selecting`.
        switch m.content {
        case .call:
            // Only the bubble asks to call again; the empty row beside it is wallpaper (his
            // report, 2026-08-27) — see `hitsCallBubble`.
            if rowView.hitsCallBubble(p) { delegate?.rowCellDidTapCallRow(self) }
            return
        case .notice(let n):
            if let target = n.tapTargetId, n.style == .pill {
                delegate?.rowCellDidTapPinNotice(self, jumpTo: target)
            }
            return
        case .bubble(let b):
            // The failed badge IS the retry button, and it is tested first: it sits outside the
            // bubble, so it can never be confused with anything drawn inside one.
            if b.showsFailedBadge, rowView.hitsFailBadge(p) {
                delegate?.rowCellDidTapRetry(self)
                return
            }
            if rowView.hitsReactions(p) {
                delegate?.rowCellDidTapReactions(self)
                return
            }
            // The picture opens the viewer. Before the quote test, because a media bubble's quote
            // sits above the picture and the two rects never overlap.
            // A view-once pill opens the one-shot viewer; a pending placeholder opens nothing, and
            // the model says which by leaving `opens` false.
            if rowView.hitsPill(p) {
                if case .pill(let pill) = b.body, pill.opens {
                    delegate?.rowCellDidTapPill(self)
                }
                return
            }
            // THE X IN THE UPLOAD INDICATOR CANCELS THE TRANSFER, and it is asked before the
            // picture and before the tiles because it is drawn on top of both. A settled item
            // falls through to them on purpose: the indicator is gone by then and the tap is
            // somebody opening a photo that happens to have just finished.
            //
            // Straight to the service, the way the poll option votes: cancelling is a fact about
            // the in-flight upload, and nothing upstream holds a fresher copy of it. The bubble
            // itself is removed by `runRegisteredSend`, which already tells a cancel from a
            // failure.
            if rowView.hitsUploadRing(p), case .media(let media) = b.body, media.cancellable,
               let key = media.clientId, !MediaSend.shared.isItemDone(key) {
                MediaSend.shared.cancel(key)
                return
            }
            if let i = rowView.uploadRingTileIndex(at: p), case .album(let a) = b.body, a.cancellable,
               a.tiles.indices.contains(i), let key = a.tiles[i].uploadKey,
               !MediaSend.shared.isItemDone(key), !MediaSend.shared.isItemCancelled(key) {
                MediaSend.shared.cancelItem(key)
                return
            }
            if rowView.hitsMedia(p) {
                // Re-publish the rect from where the picture is RIGHT NOW. The one written when
                // this cell was configured is stale the moment the list scrolls, and a flight from
                // a stale rect leaves the photo out of its own bubble.
                rowView.refreshFlightRects()
                delegate?.rowCellDidTapMedia(self)
                return
            }
            if let tile = rowView.albumTileIndex(at: p) {
                rowView.refreshFlightRects()
                delegate?.rowCell(self, didTapAlbumTile: tile)
                return
            }
            if rowView.hitsStoryReply(p) {
                rowView.refreshFlightRects()
                delegate?.rowCellDidTapStoryReply(self)
                return
            }
            // The card's BUTTON before the card, for the same reason the contact card's is.
            if rowView.hitsLinkButton(p) {
                delegate?.rowCellDidTapLinkProfile(self)
                return
            }
            if rowView.hitsLinkCard(p) {
                delegate?.rowCellDidTapLinkCard(self)
                return
            }
            if let option = rowView.pollOptionIndex(at: p) {
                // Straight to the row: a vote is a toggle against the live selection, which only
                // the poll view holds. Nothing upstream would have a fresher copy.
                rowView.castPollVote(option: option)
                return
            }
            if rowView.hitsFile(p) {
                delegate?.rowCellDidTapFile(self)
                return
            }
            if rowView.hitsLocation(p) {
                delegate?.rowCellDidTapLocation(self)
                return
            }
            // The BUTTON before the card: it sits inside the card's own rect, so testing the card
            // first would swallow every tap on it.
            if rowView.hitsContactButton(p) {
                delegate?.rowCellDidTapContactMessage(self)
                return
            }
            if rowView.hitsContactCard(p) {
                delegate?.rowCellDidTapContactCard(self)
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
