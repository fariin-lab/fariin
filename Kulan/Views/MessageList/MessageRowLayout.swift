import UIKit

// ===== ONE plan per row: the height the list measures AND the rects the cell draws =====
//
// ⛔ THE RULE THIS FILE EXISTS TO ENFORCE. Before the migration a row was measured by rendering the
// SwiftUI bubble into an off-screen `UIHostingController` and asking its size, then rendered again
// inside a `UIHostingConfiguration` at a slightly different proposed width, on a different layout
// clock. Every "the bubble is clipped", "the text ellipsises with room below it", "the gap under
// this row is wrong" report came out of those two passes disagreeing.
//
// Here there is one pass. `plan(_:width:)` returns a RowPlan; the list's height is `plan.height`
// and the cell's layout is `plan`'s rects. They cannot disagree because they are the same value.
//
// Everything is in ROW coordinates unless a comment says otherwise.

struct QuoteInnerPlan {
    var accent: CGRect
    var thumb: CGRect?
    var name: CGRect
    var snippet: CGRect
    var nameAttr: NSAttributedString
    var snippetAttr: NSAttributedString
}

/// Where a photo/video/gif bubble's parts go, in BUBBLE coordinates.
///
/// The media wears the bubble's own corners and sits flush against them — no inset — and the
/// caption, when there is one, is flush below it under the SAME background and the same clip. One
/// bubble, never two.
struct MediaPlan {
    var media: CGRect
    /// The caption block, with its 12pt insets already applied to `captionText`.
    var caption: CGRect?
    var captionText: CGRect?
    var captionAttr: NSAttributedString?
    var captionMetaOnOwnLine: Bool
    /// The footer. On a captioned bubble it lives in the caption row like any other meta; on a bare
    /// photo it floats on the picture in its own dark capsule, which is why it has a background
    /// rect of its own.
    var metaCapsule: CGRect?
    var duration: CGRect?               // a video's "0:42" badge
    var playBadge: CGRect?              // a video's play glyph
    var uploadRing: CGRect?
    var kind: BubbleBody.MediaBody.Kind
}

struct BubblePlan {
    var bubble: CGRect                  // the bubble's own frame, row coordinates
    var radii: BubbleRadii
    /// A true capsule, with CIRCULAR ends. Not the same shape as a continuous corner at half the
    /// height — a squircle that far round reads as a lozenge, and the tombstone is a capsule in the
    /// design precisely so it does not read as a bubble.
    var isCapsule: Bool = false
    var fill: BubbleFill
    var rim: Bool

    // Inside the bubble
    var text: CGRect
    var meta: CGRect
    var metaOnOwnLine: Bool
    var quote: CGRect?                  // bubble coordinates
    var quoteInner: QuoteInnerPlan?
    var bodyAttr: NSAttributedString
    var links: [BubbleText.LinkRun]
    var textColor: UIColor
    var metaColor: UIColor
    var tombstoneIcon: CGRect?          // the slashed circle on a deleted-message capsule
    var mediaPlan: MediaPlan?           // set only for a photo/video/gif bubble

    // Outside the bubble, row coordinates
    var avatar: CGRect?
    var senderName: CGRect?
    var senderNameAttr: NSAttributedString?
    var verifiedMark: CGRect?
    var forwarded: CGRect?
    var forwardedIcon: CGRect?
    var reactions: [CGRect]             // one per chip, row coordinates
    var reactionAttrs: [NSAttributedString]
    var reactionMine: [Bool]
    var retry: CGRect?
}

struct NoticePlan {
    var capsule: CGRect
    var text: CGRect                    // capsule coordinates
    var attr: NSAttributedString
    var style: NoticeRow.Style
    var onWallpaper: Bool
    var wallpaperBlur: WallpaperBlurState?
}

struct DividerPlan {
    var leftLine: CGRect
    var label: CGRect
    var rightLine: CGRect
    var attr: NSAttributedString
}

struct CallPlan {
    var bubble: CGRect
    var disc: CGRect                    // bubble coordinates
    var status: CGRect
    var detail: CGRect
    var statusAttr: NSAttributedString
    var detailAttr: NSAttributedString
    var symbol: String
    var iconColor: UIColor
    var discColor: UIColor
    var fill: BubbleFill
    var rim: Bool
}

enum RowBodyPlan {
    case bubble(BubblePlan)
    case notice(NoticePlan)
    case call(CallPlan)
}

struct RowPlan {
    var width: CGFloat
    var height: CGFloat
    var dateHeader: NoticePlan?
    var divider: DividerPlan?
    var body: RowBodyPlan
    var checkbox: CGRect?

    /// The bubble's own outline in row coordinates — the context-menu lift and the swipe both need
    /// to know where the bubble actually is, not where the row is.
    var liftRect: CGRect {
        switch body {
        case .bubble(let b): return b.bubble
        case .notice(let n): return n.capsule
        case .call(let c): return c.bubble
        }
    }
}

enum MessageRowLayout {

    // Selection chrome: a 24pt circle, 10pt from the content, inside 4pt of horizontal padding.
    private static let checkboxSize: CGFloat = 24
    private static let checkboxGap: CGFloat = 10
    private static let checkboxPad: CGFloat = 4
    static var selectionShift: CGFloat { checkboxPad + checkboxSize + checkboxGap }

    // ── The entry point ──

    static func plan(_ m: MessageRowModel, width: CGFloat) -> RowPlan {
        let width = max(1, width)
        var y: CGFloat = 0

        // The day separator and the unread divider stack ABOVE the row's own content, in that
        // order — the same shape the SwiftUI row had, which is what keeps row ids stable.
        var header: NoticePlan?
        if let d = m.dateHeader {
            var p = notice(d, width: width)
            p.capsule.origin.y += y + 8                       // .padding(.vertical, 8)
            y += p.capsule.height + 16
            header = p
        }
        var divider: DividerPlan?
        if m.showsUnreadDivider {
            var p = unreadDivider(width: width)
            p.leftLine.origin.y += y + 8
            p.label.origin.y += y + 8
            p.rightLine.origin.y += y + 8
            y += p.label.height + 16                          // .padding(.vertical, 8)
            divider = p
        }

        // Selection insets the content and narrows it; the checkbox is centred on the content.
        let shift = m.selecting ? selectionShift : 0
        let trailingInset = m.selecting ? checkboxPad : 0
        let contentX = BubbleMetrics.rowMargin + shift
        let contentW = max(1, width - BubbleMetrics.rowMargin * 2 - shift - trailingInset)

        var body: RowBodyPlan
        var contentHeight: CGFloat

        switch m.content {
        case .bubble(let b):
            var p = bubble(b, originX: contentX, availableWidth: contentW, rowWidth: width,
                           topSpacing: m.topSpacing)
            contentHeight = p.totalHeight
            p.plan.offsetVertically(by: y)
            body = .bubble(p.plan)
        case .notice(let n):
            var p = notice(n, width: width)
            p.capsule.origin.y += y + 6
            contentHeight = p.capsule.height + 12             // .padding(.vertical, 6)
            body = .notice(p)
        case .call(let c):
            var p = call(c, originX: contentX, availableWidth: contentW, rowWidth: width)
            p.bubble.origin.y += y + 8                        // .padding(.top, 8)
            contentHeight = p.bubble.height + 8
            body = .call(p)
        }

        // The checkbox is centred against the row's content, not the whole row: with a date header
        // above, centring on the row would float it into the separator.
        var checkbox: CGRect?
        if m.selecting {
            let cy = y + (contentHeight - checkboxSize) / 2
            checkbox = CGRect(x: BubbleMetrics.rowMargin + checkboxPad, y: cy,
                              width: checkboxSize, height: checkboxSize)
        }

        return RowPlan(width: width, height: y + contentHeight,
                       dateHeader: header, divider: divider, body: body, checkbox: checkbox)
    }

    // ── The bubble ──

    private struct BubbleResult { var plan: BubblePlan; var totalHeight: CGFloat }

    private static func bubble(_ b: BubbleRow, originX: CGFloat, availableWidth: CGFloat,
                               rowWidth: CGFloat, topSpacing: CGFloat) -> BubbleResult {
        let textColor: UIColor = b.isMe ? BubblePalette.myText : BubblePalette.receivedText
        let metaColor: UIColor = b.isMe ? BubblePalette.myMeta : BubblePalette.receivedMeta
        // The group-mention tint. `.accentColor` in the SwiftUI bubble, which in this app is
        // `.primary` — see the note on BubblePalette.accent.
        let accent = BubblePalette.accent

        // The avatar column exists for the whole cluster so the bubbles stay aligned; only the last
        // bubble of a run actually draws a face into it.
        let avatarColumn: CGFloat = b.sender != nil ? BubbleMetrics.avatarSize + BubbleMetrics.avatarGap : 0
        let columnX = originX + (b.isMe ? 0 : avatarColumn)
        let columnW = max(1, availableWidth - avatarColumn)

        // 72% of the LIST's width, then clamped by whatever the column actually has. On a phone the
        // two are the same number; in Stage Manager they are not.
        let maxBubble = min(BubbleMetrics.maxBubbleWidth(in: rowWidth), columnW)
        let hPad = BubbleMetrics.hPad, vPad = BubbleMetrics.vPad
        let maxContent = max(1, maxBubble - hPad * 2)

        var y = topSpacing

        // ── The two tags above the bubble ──
        //
        // ⚠️ THEY ARE MEASURED NOW AND POSITIONED LATER, once the bubble's own edges are known.
        // The SwiftUI column was a VStack whose width was its widest child — almost always the
        // bubble — so `.padding(.trailing, 12)` on the Forwarded tag meant "12 from the BUBBLE's
        // trailing edge", not from the screen's. Placing it against the full row width instead
        // parked it out at the margin, far from the message it belongs to.

        var senderNameAttr: NSAttributedString?
        var senderNameSize: CGSize = .zero
        if let s = b.sender, s.showsName {
            let attr = NSAttributedString(string: s.name, attributes: [
                .font: BubbleMetrics.senderNameFont,
                .foregroundColor: BubblePalette.senderColor(s.colorSeed)])
            senderNameAttr = attr
            senderNameSize = BubbleText.size(attr, width: maxContent)
            y += senderNameSize.height + BubbleMetrics.senderNameGap
        }

        var forwardedSize: CGSize = .zero
        var forwardedIconW: CGFloat = 0
        if b.forwarded {
            // The glyph's real width, not a guess: an SF Symbol at 9pt is not a square, and a
            // hard-coded box would leave the word sitting at the wrong distance from it.
            let icon = UIImage(systemName: "arrowshape.turn.up.right.fill",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 9))
            forwardedIconW = ceil(icon?.size.width ?? 11)
            let h = ceil(BubbleMetrics.forwardedFont.lineHeight)
            let w = ceil(("Forwarded" as NSString)
                .size(withAttributes: [.font: BubbleMetrics.forwardedFont]).width)
            forwardedSize = CGSize(width: forwardedIconW + 3 + w, height: h)
            y += h + BubbleMetrics.senderNameGap
        }

        // ── Inside the bubble ──

        var quoteOuter: CGSize = .zero
        var quoteInner: QuoteInnerPlan?
        if let q = b.quote {
            let (size, inner) = quoteSize(q, textColor: textColor, maxWidth: maxContent)
            quoteOuter = size
            quoteInner = inner
        }

        // The body, measured at the width the text actually wraps in.
        var bodyAttr = NSAttributedString()
        var links: [BubbleText.LinkRun] = []
        var metaOwnLine = false
        var bodySize: CGSize = .zero
        var isTombstone = false
        var isJumbo = false

        switch b.body {
        case .text(let t):
            let built = BubbleText.build(t, meta: b.meta, isMe: b.isMe, textColor: textColor,
                                         accent: accent, textAvail: maxContent)
            bodyAttr = built.body
            links = built.links
            metaOwnLine = built.metaOnOwnLine
            bodySize = BubbleText.size(bodyAttr, width: maxContent)
        case .jumbomoji(let glyphs):
            isJumbo = true
            let count = glyphs.filter { !$0.isWhitespace }.count
            let font = BubbleText.jumbomojiFont(max(1, min(5, count)))
            bodyAttr = NSAttributedString(string: glyphs, attributes: [.font: font, .foregroundColor: textColor])
            bodySize = BubbleText.size(bodyAttr, width: maxContent)
            metaOwnLine = true      // the emoji never shares its line with the footer
        case .tombstone(let words):
            isTombstone = true
            bodyAttr = NSAttributedString(string: words, attributes: [
                .font: UIFont.italicSystemFont(ofSize: 15),
                .foregroundColor: (b.isMe ? UIColor.white.withAlphaComponent(0.72)
                                          : UIColor.secondaryLabel.withAlphaComponent(0.85))])
            bodySize = BubbleText.size(bodyAttr, width: max(1, maxContent - 18))
        case .media(let m):
            // A media bubble is laid out entirely differently — the picture is flush to the
            // bubble's edges rather than inset by hPad/vPad, and the footer either joins the
            // caption row or floats on the picture. It gets its own function and returns here.
            return media(m, row: b, originX: originX, columnX: columnX, columnW: columnW,
                         maxBubble: maxBubble, textColor: textColor, metaColor: metaColor,
                         accent: accent, topSpacing: topSpacing, y: y,
                         senderNameAttr: senderNameAttr, senderNameSize: senderNameSize,
                         forwardedSize: forwardedSize, forwardedIconW: forwardedIconW)
        }

        let metaAttr = BubbleText.meta(b.meta, isMe: b.isMe, color: metaColor, showClock: true)
        let metaSize = BubbleText.lineSize(metaAttr)

        // A tombstone is a capsule with its own insets and no footer at all — a notice has no
        // delivery state to report.
        if isTombstone {
            let iconW: CGFloat = 14
            let innerW = iconW + 6 + bodySize.width
            let bubbleW = min(maxBubble, innerW + 28)
            let bubbleH = bodySize.height + 16
            let x = b.isMe ? (columnX + columnW - bubbleW) : columnX
            let rect = CGRect(x: x, y: y, width: bubbleW, height: bubbleH)
            var plan = BubblePlan(
                bubble: rect, radii: .uniform(bubbleH / 2), isCapsule: true, fill: b.fill, rim: b.rim,
                text: CGRect(x: 14 + iconW + 6, y: 8, width: bubbleW - 28 - iconW - 6, height: bodySize.height),
                meta: .zero, metaOnOwnLine: false, quote: nil, quoteInner: nil,
                bodyAttr: bodyAttr, links: [], textColor: textColor, metaColor: metaColor,
                tombstoneIcon: CGRect(x: 14, y: (bubbleH - iconW) / 2, width: iconW, height: iconW),
                mediaPlan: nil,
                avatar: nil, senderName: nil, senderNameAttr: nil, verifiedMark: nil,
                forwarded: nil, forwardedIcon: nil, reactions: [], reactionAttrs: [], reactionMine: [],
                retry: nil)
            if let s = b.sender, s.showsAvatar {
                plan.avatar = CGRect(x: originX, y: rect.maxY - BubbleMetrics.avatarSize,
                                     width: BubbleMetrics.avatarSize, height: BubbleMetrics.avatarSize)
            }
            // A tombstone carries neither an edited tag nor a Forwarded one — the notice replaced
            // the message — but a group sender's name still sits above it, so the run reads
            // correctly. Positioned against the capsule's own edge, like every other tag.
            if let attr = senderNameAttr {
                plan.senderName = CGRect(x: rect.minX + 12, y: topSpacing,
                                         width: senderNameSize.width, height: senderNameSize.height)
                plan.senderNameAttr = attr
                if b.sender?.verified == true {
                    plan.verifiedMark = CGRect(x: rect.minX + 12 + senderNameSize.width + 4,
                                               y: topSpacing + (senderNameSize.height - 11) / 2,
                                               width: 11, height: 11)
                }
            }
            return BubbleResult(plan: plan, totalHeight: rect.maxY)
        }

        // The bubble hugs the WIDEST part — usually the body, but a long quote widens it. Then the
        // quote FILLS that hugged width (the reference app's own model): measure natural, render
        // filled, so a one-character reply never collapses into a tiny box above a wide message.
        var contentW = max(bodySize.width, quoteOuter.width)
        // On its own line the footer is a real row, so it can drive the bubble wider than the words
        // do — a two-character message from me still has to fit "12:34 ✓✓".
        if metaOwnLine { contentW = max(contentW, metaSize.width) }
        contentW = min(maxContent, ceil(contentW))

        var innerY: CGFloat = vPad
        var quoteRect: CGRect?
        if quoteOuter.height > 0 {
            quoteRect = CGRect(x: hPad, y: innerY, width: contentW, height: quoteOuter.height)
            innerY += quoteOuter.height + 4                   // VStack spacing 4
        }

        // Re-measure the body at the FINAL content width. With a quote driving the bubble wider the
        // text has more room than it was measured with, and a stale height would leave a gap under
        // the last line.
        let finalBodySize = BubbleText.size(bodyAttr, width: contentW)
        let textRect = CGRect(x: hPad, y: innerY, width: contentW, height: finalBodySize.height)
        innerY += finalBodySize.height

        var metaRect: CGRect
        if metaOwnLine {
            innerY += 2                                       // VStack(alignment: .trailing, spacing: 2)
            metaRect = CGRect(x: hPad + contentW - metaSize.width, y: innerY,
                              width: metaSize.width, height: metaSize.height)
            innerY += metaSize.height
        } else {
            // Overlaid bottom-trailing on the gap the reservation left in the last line.
            metaRect = CGRect(x: hPad + contentW - metaSize.width,
                              y: innerY - metaSize.height - 1,
                              width: metaSize.width, height: metaSize.height)
        }

        let bubbleW = contentW + hPad * 2
        let bubbleH = innerY + vPad
        let bubbleX = b.isMe ? (columnX + columnW - bubbleW) : columnX
        let bubbleRect = CGRect(x: bubbleX, y: y, width: bubbleW, height: bubbleH)
        y = bubbleRect.maxY

        var plan = BubblePlan(
            bubble: bubbleRect,
            radii: isJumbo ? .uniform(0) : b.radii,
            isCapsule: false,
            fill: isJumbo ? .clear : b.fill,                  // a jumbomoji bubble keeps its box and drops its fill
            rim: isJumbo ? false : b.rim,
            text: textRect, meta: metaRect, metaOnOwnLine: metaOwnLine,
            quote: quoteRect, quoteInner: quoteInner,
            bodyAttr: bodyAttr, links: links, textColor: textColor, metaColor: metaColor,
            tombstoneIcon: nil, mediaPlan: nil,
            avatar: nil, senderName: nil, senderNameAttr: nil, verifiedMark: nil,
            forwarded: nil, forwardedIcon: nil, reactions: [], reactionAttrs: [], reactionMine: [],
            retry: nil)

        // Reactions, the retry line, the avatar and the two tags are the same for every bubble
        // kind, so they are placed in ONE function. A media bubble that grew its own copy would be
        // a second set of numbers to keep in step, and this row already has a history of two paths
        // drifting apart.
        y = decorations(b, plan: &plan, bubbleRect: bubbleRect, columnX: columnX, columnW: columnW,
                        originX: originX, topSpacing: topSpacing, senderNameAttr: senderNameAttr,
                        senderNameSize: senderNameSize, forwardedSize: forwardedSize,
                        forwardedIconW: forwardedIconW, y: y)
        return BubbleResult(plan: plan, totalHeight: y)
    }


    /// The parts every bubble kind shares, placed once: the reaction badges, the retry line, the
    /// group avatar, the sender name and the Forwarded tag. Returns the column's new bottom edge.
    ///
    /// ⚠️ The two tags are positioned HERE, against the bubble's own edges, because only the caller
    /// knows where the bubble ended up. `senderNameSize` and `forwardedSize` were measured before
    /// the bubble was laid out (they push it down); this is where they are finally placed.
    private static func decorations(_ b: BubbleRow, plan: inout BubblePlan, bubbleRect: CGRect,
                                    columnX: CGFloat, columnW: CGFloat, originX: CGFloat,
                                    topSpacing: CGFloat, senderNameAttr: NSAttributedString?,
                                    senderNameSize: CGSize, forwardedSize: CGSize,
                                    forwardedIconW: CGFloat, y startY: CGFloat) -> CGFloat {
        var y = startY
        // Reactions hang OFF the bubble's edge, overlapping the corner they belong to — a badge
        // floating in the gap between two bubbles belongs to neither.
                if !b.reactions.isEmpty {
            let shown = Array(b.reactions.prefix(3))
            let extra = b.reactions.count - shown.count
            var chips: [(NSAttributedString, Bool)] = shown.map { chip in
                let s = NSMutableAttributedString(string: chip.emoji, attributes: [
                    .font: UIFont.systemFont(ofSize: 14)])
                if chip.count > 1 {
                    s.append(NSAttributedString(string: " \(chip.count)", attributes: [
                        .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
                        .foregroundColor: chip.mine ? BubblePalette.accent : UIColor.secondaryLabel]))
                }
                return (s, chip.mine)
            }
            if extra > 0 {
                chips.append((NSAttributedString(string: "+\(extra)", attributes: [
                    .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: UIColor.secondaryLabel]), false))
            }
            var widths: [CGFloat] = []
            var height: CGFloat = 0
            for (attr, _) in chips {
                let s = BubbleText.size(attr, width: .greatestFiniteMagnitude)
                widths.append(s.width + 12)                   // .padding(.horizontal, 6)
                height = max(height, s.height + 6)            // .padding(.vertical, 3)
            }
            let total = widths.reduce(0, +) + CGFloat(max(0, chips.count - 1)) * 4
            // Offset x ±10 from the bubble's own edge, y +13 below its bottom.
            var cx = b.isMe ? (bubbleRect.maxX - 10 - total) : (bubbleRect.minX + 10)
            let cy = bubbleRect.maxY + BubbleMetrics.reactionOverhang - height
            for (i, w) in widths.enumerated() {
                plan.reactions.append(CGRect(x: cx, y: cy, width: w, height: height))
                plan.reactionAttrs.append(chips[i].0)
                plan.reactionMine.append(chips[i].1)
                cx += w + 4
            }
            // Reserve the overhang so the badge cannot collide with the next bubble. Reserve less
            // than it hangs and they touch; reserve more and there is a gap nothing draws into.
            y += BubbleMetrics.reactionOverhang
        }

        if b.showsRetryRow {
            let font = UIFont.systemFont(ofSize: 11, weight: .medium)
            let attr = NSAttributedString(string: "Not delivered. Tap to retry", attributes: [.font: font])
            let s = BubbleText.size(attr, width: columnW)
            let w = s.width + 16                              // the leading arrow glyph
            let x = b.isMe ? (columnX + columnW - w) : columnX
            plan.retry = CGRect(x: x, y: y + 1 + BubbleMetrics.senderNameGap, width: w, height: s.height)
            y = plan.retry!.maxY
        }

        if let s = b.sender, s.showsAvatar {
            // Bottom-aligned with the COLUMN, not with the bubble — the row is an
            // `HStack(alignment: .bottom)` and the column's bottom edge is `y`, which by now
            // includes the reaction overhang and the retry line. Aligning to the bubble instead
            // would float the face above the badges on any reacted message.
            plan.avatar = CGRect(x: originX, y: y - BubbleMetrics.avatarSize,
                                width: BubbleMetrics.avatarSize, height: BubbleMetrics.avatarSize)
        }

        // Now the bubble's edges are known, the two tags can take their real positions.
        var tagY = topSpacing
        if senderNameAttr != nil {
            plan.senderName = CGRect(x: bubbleRect.minX + 12, y: tagY,
                                    width: senderNameSize.width, height: senderNameSize.height)
            if b.sender?.verified == true {
                plan.verifiedMark = CGRect(x: bubbleRect.minX + 12 + senderNameSize.width + 4,
                                      y: tagY + (senderNameSize.height - 11) / 2, width: 11, height: 11)
            }
            tagY += senderNameSize.height + BubbleMetrics.senderNameGap
        }
        if b.forwarded {
            let x = b.isMe ? (bubbleRect.maxX - 12 - forwardedSize.width) : (bubbleRect.minX + 12)
            plan.forwardedIcon = CGRect(x: x, y: tagY + (forwardedSize.height - 9) / 2,
                                       width: forwardedIconW, height: 9)
            plan.forwarded = CGRect(x: x + forwardedIconW + 3, y: tagY,
                                   width: forwardedSize.width - forwardedIconW - 3,
                                   height: forwardedSize.height)
        }

        plan.senderNameAttr = senderNameAttr
        return y
    }

    // ── A photo / video / gif bubble ──

    /// ⚠️ THE CAPTION GETS THE WHOLE BUBBLE. Every media caption used to be
    /// `HStack { Text; Spacer; meta }`, and an HStack reserves its siblings' width for the FULL
    /// HEIGHT of the row — so the timestamp cut ~70pt off EVERY line of the caption, not just the
    /// last one. On a long caption that reads as a bubble with a tall empty column down its right
    /// side. It uses the same two branches the text bubble does, for the same reasons: the
    /// invisible trailing reservation when the footer fits on the last line, and a real row of its
    /// own when it does not.
    private static func media(_ m: BubbleBody.MediaBody, row b: BubbleRow,
                              originX: CGFloat, columnX: CGFloat, columnW: CGFloat,
                              maxBubble: CGFloat, textColor: UIColor, metaColor: UIColor,
                              accent: UIColor, topSpacing: CGFloat, y startY: CGFloat,
                              senderNameAttr: NSAttributedString?, senderNameSize: CGSize,
                              forwardedSize: CGSize, forwardedIconW: CGFloat) -> BubbleResult {
        var y = startY
        let box = mediaBox(m, maxBubbleWidth: maxBubble)
        let bubbleW = min(maxBubble, box.width)

        // The quote sits ABOVE the picture, inset like the text bubble's, in its own band.
        var quoteRect: CGRect?
        var quoteInner: QuoteInnerPlan?
        var innerY: CGFloat = 0
        if let q = b.quote {
            let (size, inner) = quoteSize(q, textColor: textColor,
                                          maxWidth: max(1, bubbleW - BubbleMetrics.hPad * 2))
            quoteInner = inner
            innerY = BubbleMetrics.vPad
            quoteRect = CGRect(x: BubbleMetrics.hPad, y: innerY,
                               width: bubbleW - BubbleMetrics.hPad * 2, height: size.height)
            innerY += size.height + 4
            _ = size
        }

        // The picture, flush to the bubble's own edges.
        let mediaRect = CGRect(x: 0, y: innerY, width: bubbleW, height: box.height)
        innerY = mediaRect.maxY

        // The footer: in the caption row when there is a caption, floating on the picture when not.
        let metaAttr = BubbleText.meta(b.meta, isMe: b.isMe, color: metaColor, showClock: true)
        var plan = MediaPlan(media: mediaRect, caption: nil, captionText: nil, captionAttr: nil,
                             captionMetaOnOwnLine: false, metaCapsule: nil, duration: nil,
                             playBadge: nil, uploadRing: nil, kind: m.kind)
        var metaRect: CGRect

        if let caption = m.caption, !caption.text.isEmpty {
            let inset: CGFloat = 12
            let avail = max(1, bubbleW - inset * 2)
            let built = BubbleText.build(caption, meta: b.meta, isMe: b.isMe, textColor: textColor,
                                         accent: accent, textAvail: avail)
            let size = BubbleText.size(built.body, width: avail)
            let metaSize = BubbleText.lineSize(metaAttr)
            let top = innerY + 8
            plan.captionAttr = built.body
            plan.captionMetaOnOwnLine = built.metaOnOwnLine
            plan.captionText = CGRect(x: inset, y: top, width: avail, height: size.height)
            var bottom = top + size.height
            if built.metaOnOwnLine {
                bottom += 2
                metaRect = CGRect(x: inset + avail - metaSize.width, y: bottom,
                                  width: metaSize.width, height: metaSize.height)
                bottom += metaSize.height
            } else {
                metaRect = CGRect(x: inset + avail - metaSize.width,
                                  y: bottom - metaSize.height - 1,
                                  width: metaSize.width, height: metaSize.height)
            }
            bottom += 10
            plan.caption = CGRect(x: 0, y: innerY, width: bubbleW, height: bottom - innerY)
            innerY = bottom
        } else {
            // The floating capsule: 7pt padding inside it, 7pt in from the picture's corner.
            let metaSize = BubbleText.lineSize(metaAttr)
            let capsule = CGRect(x: mediaRect.maxX - 7 - (metaSize.width + 14),
                                 y: mediaRect.maxY - 7 - (metaSize.height + 6),
                                 width: metaSize.width + 14, height: metaSize.height + 6)
            plan.metaCapsule = capsule
            metaRect = CGRect(x: capsule.minX + 7, y: capsule.minY + 3,
                              width: metaSize.width, height: metaSize.height)
        }

        if m.kind == .video {
            let side: CGFloat = min(box.width, box.height) * 0.28
            plan.playBadge = CGRect(x: mediaRect.midX - side / 2, y: mediaRect.midY - side / 2,
                                    width: side, height: side)
            if let d = m.durationText {
                let attr = NSAttributedString(string: d, attributes: [
                    .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: UIColor.white])
                let s = BubbleText.size(attr, width: box.width)
                plan.duration = CGRect(x: mediaRect.minX + 5, y: mediaRect.minY + 5,
                                       width: s.width + 12, height: s.height + 4)
            }
        }
        if m.uploading {
            let side: CGFloat = 44
            plan.uploadRing = CGRect(x: mediaRect.midX - side / 2, y: mediaRect.midY - side / 2,
                                     width: side, height: side)
        }

        let bubbleH = innerY
        let bubbleX = b.isMe ? (columnX + columnW - bubbleW) : columnX
        let bubbleRect = CGRect(x: bubbleX, y: y, width: bubbleW, height: bubbleH)
        y = bubbleRect.maxY

        var out = BubblePlan(
            bubble: bubbleRect, radii: b.radii, isCapsule: false, fill: b.fill, rim: b.rim,
            text: .zero, meta: metaRect, metaOnOwnLine: plan.captionMetaOnOwnLine,
            quote: quoteRect, quoteInner: quoteInner,
            bodyAttr: NSAttributedString(), links: [], textColor: textColor, metaColor: metaColor,
            tombstoneIcon: nil, mediaPlan: plan,
            avatar: nil, senderName: nil, senderNameAttr: nil, verifiedMark: nil,
            forwarded: nil, forwardedIcon: nil, reactions: [], reactionAttrs: [], reactionMine: [],
            retry: nil)

        let bottom = decorations(b, plan: &out, bubbleRect: bubbleRect, columnX: columnX,
                                 columnW: columnW, originX: originX, topSpacing: topSpacing,
                                 senderNameAttr: senderNameAttr, senderNameSize: senderNameSize,
                                 forwardedSize: forwardedSize, forwardedIconW: forwardedIconW, y: y)
        return BubbleResult(plan: out, totalHeight: bottom)
    }

    // ── Media boxes ──
    //
    // Three rules, kept apart on purpose. Every constant here was tuned against a report, and the
    // comments say which — a "simplification" that merges them undoes several fixes at once.

    /// A VIDEO's and a GIF's box: the natural aspect inside 240 × 340, never a forced square.
    static func displayBox(width: Double?, height: Double?) -> CGSize {
        let maxW: CGFloat = 240, maxH: CGFloat = 340
        guard let w = width, let h = height, w > 0, h > 0 else {
            return CGSize(width: 220, height: 220)
        }
        let aspect = CGFloat(w / h)
        var dw = maxW, dh = dw / aspect
        if dh > maxH { dh = maxH; dw = dh * aspect }
        return CGSize(width: dw, height: dh)
    }

    /// A VIDEO's box: `displayBox` plus the photo path's caption min-width floor.
    ///
    /// ⚠️ Without the floor a portrait video (aspect ~0.46 → ~157pt wide) forced its caption to
    /// 157pt, so a long caption wrapped at roughly one word per line and the bubble became absurdly
    /// tall. The photo path always applied this floor; video never did.
    static func videoBox(_ m: BubbleBody.MediaBody, maxBubbleWidth: CGFloat) -> CGSize {
        var s = displayBox(width: m.pixelWidth, height: m.pixelHeight)
        guard let caption = m.caption, !caption.text.isEmpty else { return s }
        let boxMax = min(maxBubbleWidth, 350)
        let textW = (caption.text as NSString)
            .size(withAttributes: [.font: BubbleMetrics.bodyFont]).width + 24   // 2 × 12pt insets
        s.width = min(boxMax, max(s.width, textW))
        return s
    }

    /// A PHOTO's box. The aspect is clamped to [0.35, 2.857]; the caption reserves only a MIN-WIDTH
    /// floor, so it never stretches or distorts the picture beyond that; tiny originals never
    /// upscale; and the box caps at 350.
    static func photoBox(_ m: BubbleBody.MediaBody, maxBubbleWidth: CGFloat) -> CGSize {
        let boxMax = min(maxBubbleWidth, 350)
        let aspect: CGFloat = {
            guard let w = m.pixelWidth, let h = m.pixelHeight, w > 0, h > 0 else { return 1 }
            return min(max(CGFloat(w / h), 0.35), 2.857)
        }()
        // The caption floor is MEASURED AT 17, the size the caption actually renders at. It used to
        // measure at 15, so every floor came out ~12% short and a caption that would have fitted on
        // one line wrapped early, leaving dead space at the end of the line.
        let hasCaption = !(m.caption?.text.isEmpty ?? true)
        let minW: CGFloat = hasCaption
            ? min(boxMax, (m.caption!.text as NSString)
                .size(withAttributes: [.font: BubbleMetrics.bodyFont]).width + 24)
            : 0
        // ⛔ A PORTRAIT PHOTO MAY RUN TALLER THAN THE BOX IS WIDE. `h = boxMax` pinned every image's
        // height to the WIDTH cap, so the taller the picture the narrower the bubble: a phone
        // screenshot at 9:19.5 came out about 140pt across — a stamp.
        //
        // ⚠️ AND THE EXTRA HEIGHT IS EARNED, NOT GIVEN TO EVERY PORTRAIT. The rule is WIDTH, not
        // orientation: start at the height every image has always had, and only grow one that would
        // otherwise be too NARROW to read. `comfortW` is the width a 9:16 has at the 1.3 cap, so
        // 9:16 lands on exactly the approved size, anything taller is capped there, anything between
        // ramps smoothly, and 3:4, square and every landscape ratio are left exactly as they were.
        let maxH = boxMax * 1.3
        let comfortW = maxH * (9.0 / 16.0)
        var h = boxMax
        var w = h * aspect
        if w < comfortW {
            h = min(maxH, comfortW / aspect)
            w = h * aspect
        }
        w = max(w, minW)
        if w > boxMax { w = boxMax; h = w / aspect }
        // Anti-upscale: never enlarge a tiny original, but never drop below 150pt either.
        if let sw = m.pixelWidth, let sh = m.pixelHeight {
            let srcShort = CGFloat(min(sw, sh)), dispShort = min(w, h)
            if dispShort > srcShort, dispShort > 150 {
                let f = max(150, srcShort) / dispShort
                w *= f; h *= f
            }
        }
        return CGSize(width: w.rounded(), height: h.rounded())
    }

    /// The box for whichever kind this is.
    static func mediaBox(_ m: BubbleBody.MediaBody, maxBubbleWidth: CGFloat) -> CGSize {
        switch m.kind {
        case .photo: return photoBox(m, maxBubbleWidth: maxBubbleWidth)
        case .video: return videoBox(m, maxBubbleWidth: maxBubbleWidth)
        case .gif:   return displayBox(width: m.pixelWidth, height: m.pixelHeight)
        }
    }

    // ── The reply quote ──
    //
    // ONE HEIGHT, ALWAYS — only the width varies. The accent line is a shape with only a width, and
    // a shape accepts any height offered, so the whole box used to stretch to absorb whatever slack
    // the body left behind (a quote rendering three times taller than its neighbour). 38 is the
    // tallest thing it ever holds (the story thumbnail), so nothing clips.
    private static let quoteBoxHeight: CGFloat = 38
    private static let quoteMinTextWidth: CGFloat = 150

    private static func quoteSize(_ q: QuoteChrome, textColor: UIColor,
                                  maxWidth: CGFloat) -> (CGSize, QuoteInnerPlan) {
        let fg = textColor
        let nameAttr = NSAttributedString(string: q.authorLine, attributes: [
            .font: BubbleMetrics.quoteNameFont, .foregroundColor: fg.withAlphaComponent(0.9)])
        let snippetAttr = NSAttributedString(string: q.snippet, attributes: [
            .font: BubbleMetrics.quoteTextFont, .foregroundColor: fg.withAlphaComponent(0.75)])

        var thumbSize: CGSize = .zero
        switch q.thumb {
        case .none: break
        case .story: thumbSize = CGSize(width: 30, height: 38)
        case .media, .gif: thumbSize = CGSize(width: 34, height: 34)
        }

        let hPad: CGFloat = 8, vPad: CGFloat = 5, gap: CGFloat = 7, accentW: CGFloat = 3
        let fixed = hPad * 2 + accentW + gap + (thumbSize.width > 0 ? thumbSize.width + gap : 0)
        let textAvail = max(1, maxWidth - fixed)
        let nameW = BubbleText.size(nameAttr, width: textAvail).width
        let snippetW = BubbleText.size(snippetAttr, width: .greatestFiniteMagnitude).width
        // The 150pt floor: a one-character quote never renders as a tiny box, even in a bubble with
        // no wide body to stretch to.
        let textW = min(textAvail, max(quoteMinTextWidth, max(nameW, snippetW)))

        let outer = CGSize(width: min(maxWidth, ceil(fixed + textW)), height: quoteBoxHeight + vPad * 2)

        // Inner rects, in the quote box's own coordinates. Laid out against the FILLED width by the
        // caller; the text column takes whatever is left, which is how a filled quote keeps its
        // accent line, name and snippet put while only the box grows.
        var x = hPad
        let accent = CGRect(x: x, y: vPad, width: accentW, height: quoteBoxHeight)
        x += accentW + gap
        var thumb: CGRect?
        if thumbSize.width > 0 {
            thumb = CGRect(x: x, y: vPad + (quoteBoxHeight - thumbSize.height) / 2,
                           width: thumbSize.width, height: thumbSize.height)
            x += thumbSize.width + gap
        }
        let nameH = ceil(BubbleMetrics.quoteNameFont.lineHeight)
        let snippetH = ceil(BubbleMetrics.quoteTextFont.lineHeight)
        // The two lines are centred as a pair inside the fixed 38, with the VStack's 1pt spacing.
        let stackH = nameH + 1 + snippetH
        let top = vPad + (quoteBoxHeight - stackH) / 2
        let name = CGRect(x: x, y: top, width: max(1, outer.width - hPad - x), height: nameH)
        let snippet = CGRect(x: x, y: top + nameH + 1, width: name.width, height: snippetH)

        return (outer, QuoteInnerPlan(accent: accent, thumb: thumb, name: name, snippet: snippet,
                                      nameAttr: nameAttr, snippetAttr: snippetAttr))
    }

    // ── Notices: the day separator, a system event, a pin notice ──

    private static func notice(_ n: NoticeRow, width: CGFloat) -> NoticePlan {
        let attr: NSMutableAttributedString
        switch n.style {
        case .pill:
            attr = NSMutableAttributedString()
            if let symbol = n.symbol, let img = UIImage(systemName: symbol,
                                                        withConfiguration: UIImage.SymbolConfiguration(pointSize: 11)) {
                let a = NSTextAttachment()
                a.image = img.withTintColor(.label, renderingMode: .alwaysOriginal)
                a.bounds = CGRect(x: 0, y: -1, width: img.size.width, height: img.size.height)
                attr.append(NSAttributedString(attachment: a))
            }
            attr.append(NSAttributedString(string: n.text, attributes: [
                .font: BubbleMetrics.noticeFont, .foregroundColor: UIColor.label]))
        case .unsupported:
            attr = NSMutableAttributedString(string: n.text, attributes: [
                .font: UIFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: UIColor.secondaryLabel])
        }

        switch n.style {
        case .pill:
            let hPad: CGFloat = 12, vPad: CGFloat = 5
            let avail = max(1, width - BubbleMetrics.rowMargin * 2 - hPad * 2)
            let size = BubbleText.size(attr, width: avail)
            let capsuleW = size.width + hPad * 2
            let capsuleH = size.height + vPad * 2
            let rect = CGRect(x: (width - capsuleW) / 2, y: 0, width: capsuleW, height: capsuleH)
            return NoticePlan(capsule: rect,
                              text: CGRect(x: hPad, y: vPad, width: size.width, height: size.height),
                              attr: attr, style: .pill,
                              onWallpaper: n.onWallpaper, wallpaperBlur: n.wallpaperBlur)
        case .unsupported:
            let hPad: CGFloat = 14, vPad: CGFloat = 10
            let boxMax: CGFloat = 300
            let avail = min(boxMax, width - BubbleMetrics.rowMargin * 2) - hPad * 2
            let size = BubbleText.size(attr, width: max(1, avail - 23))   // the leading glyph + gap
            let boxW = min(boxMax, size.width + 23 + hPad * 2)
            let boxH = size.height + vPad * 2
            let rect = CGRect(x: (width - boxW) / 2, y: 0, width: boxW, height: boxH)
            return NoticePlan(capsule: rect,
                              text: CGRect(x: hPad + 23, y: vPad, width: size.width, height: size.height),
                              attr: attr, style: .unsupported,
                              onWallpaper: n.onWallpaper, wallpaperBlur: n.wallpaperBlur)
        }
    }

    private static func unreadDivider(width: CGFloat) -> DividerPlan {
        let attr = NSAttributedString(string: "Unread Messages", attributes: [
            .font: BubbleMetrics.noticeFont, .foregroundColor: BubblePalette.accent])
        let size = BubbleText.size(attr, width: width)
        let inset = BubbleMetrics.rowMargin
        let gap: CGFloat = 8
        let lineW = max(0, (width - inset * 2 - size.width - gap * 2) / 2)
        let midY = size.height / 2
        return DividerPlan(
            leftLine: CGRect(x: inset, y: midY, width: lineW, height: 1),
            label: CGRect(x: inset + lineW + gap, y: 0, width: size.width, height: size.height),
            rightLine: CGRect(x: inset + lineW + gap + size.width + gap, y: midY, width: lineW, height: 1),
            attr: attr)
    }

    // ── The call row ──
    //
    // The width is not a number: `max(titleWidth, labelsWidth) + disc + insets`, with a floor. A
    // fixed width leaves a stretch of empty bubble to the right of a short label, which is exactly
    // what reads as "long".

    private static func call(_ c: CallRow, originX: CGFloat, availableWidth: CGFloat,
                             rowWidth: CGFloat) -> CallPlan {
        let statusAttr = NSAttributedString(string: c.status, attributes: [
            .font: UIFont.systemFont(ofSize: 16, weight: .semibold),
            .foregroundColor: c.mine ? UIColor.white : UIColor.label])
        let detailAttr = NSAttributedString(string: c.detail, attributes: [
            .font: UIFont.systemFont(ofSize: 13),
            .foregroundColor: c.mine ? UIColor.white.withAlphaComponent(0.75) : UIColor.secondaryLabel])

        let discSize: CGFloat = 34
        let hPad: CGFloat = 14, gap: CGFloat = 11
        let statusW = BubbleText.size(statusAttr, width: .greatestFiniteMagnitude).width
        let detailW = BubbleText.size(detailAttr, width: .greatestFiniteMagnitude).width
        let textW = max(122, max(statusW, detailW))           // 122 + 28 padding = 150 at its narrowest
        let ceiling = min(availableWidth, rowWidth * 0.7)
        let bubbleW = min(ceiling, hPad * 2 + discSize + gap + textW)
        let bubbleH: CGFloat = 60
        let x = c.mine ? (originX + availableWidth - bubbleW) : originX

        let disc = CGRect(x: hPad, y: (bubbleH - discSize) / 2, width: discSize, height: discSize)
        let textX = hPad + discSize + gap
        let textW2 = max(1, bubbleW - textX - hPad)
        let statusH = ceil(UIFont.systemFont(ofSize: 16, weight: .semibold).lineHeight)
        let detailH = ceil(UIFont.systemFont(ofSize: 13).lineHeight)
        let stackH = statusH + 2 + detailH
        let top = (bubbleH - stackH) / 2

        let iconColor: UIColor = c.missedIncoming ? .systemRed : (c.mine ? .white : BubblePalette.accent)
        let discColor: UIColor = c.mine ? UIColor.white.withAlphaComponent(0.22)
            : (c.missedIncoming ? UIColor.systemRed.withAlphaComponent(0.14)
                                : BubblePalette.accent.withAlphaComponent(0.14))

        return CallPlan(
            bubble: CGRect(x: x, y: 0, width: bubbleW, height: bubbleH),
            disc: disc,
            status: CGRect(x: textX, y: top, width: textW2, height: statusH),
            detail: CGRect(x: textX, y: top + statusH + 2, width: textW2, height: detailH),
            statusAttr: statusAttr, detailAttr: detailAttr, symbol: c.symbol,
            iconColor: iconColor, discColor: discColor, fill: c.fill, rim: c.rim)
    }
}

extension BubblePlan {
    /// Shift every rect that lives in ROW coordinates down by `dy`. Rects inside the bubble (text,
    /// meta, quote) are in bubble coordinates and must not move.
    mutating func offsetVertically(by dy: CGFloat) {
        guard dy != 0 else { return }
        bubble.origin.y += dy
        avatar?.origin.y += dy
        senderName?.origin.y += dy
        verifiedMark?.origin.y += dy
        forwarded?.origin.y += dy
        forwardedIcon?.origin.y += dy
        retry?.origin.y += dy
        for i in reactions.indices { reactions[i].origin.y += dy }
    }
}
