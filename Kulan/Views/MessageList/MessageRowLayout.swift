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

/// The mosaic. Tile rects come from `MediaGroupLayout.solve`, the same solver the SwiftUI grid
/// used — it is a pure function over aspects, so there was nothing to port.
struct AlbumPlan {
    struct Tile {
        var rect: CGRect                // grid coordinates
        var playBadge: CGRect?
        var duration: CGRect?
        var durationAttr: NSAttributedString?
        var extraAttr: NSAttributedString?   // the "+N" that rides the last tile
        var ring: CGRect?
    }
    var grid: CGRect                    // bubble coordinates
    var tiles: [Tile]
    var caption: CGRect?
    var captionText: CGRect?
    var captionAttr: NSAttributedString?
    var captionMetaOnOwnLine: Bool
    var metaCapsule: CGRect?
}

/// A document row: the slot (a 44×58 page preview or a 26pt glyph), the name, the size.
struct FilePlan {
    var slot: CGRect                    // bubble coordinates
    var slotIsPreview: Bool
    var name: CGRect
    var nameAttr: NSAttributedString
    var size: CGRect
    var sizeAttr: NSAttributedString
    var spinner: CGRect?
}

/// A shared place. The map sits where a photo's picture sits — flush to the top and the sides —
/// with the words below it under the same background and the same clip. One bubble, not a card
/// inside a card.
struct LocationPlan {
    var map: CGRect                     // bubble coordinates
    var pin: CGRect
    var label: CGRect
    var labelAttr: NSAttributedString
    var chevron: CGRect
}

/// A shared contact: the avatar row, then a full-width "message" button under it.
struct ContactPlan {
    var avatar: CGRect
    var name: CGRect
    var nameAttr: NSAttributedString
    var chevron: CGRect
    var button: CGRect?
    var buttonLabel: CGRect?
    var buttonAttr: NSAttributedString?
}

/// A poll. Every rect is fixed; only the bars' FILL and the percentages change as votes land.
struct PollPlan {
    struct Option {
        var glyph: CGRect
        var label: CGRect
        var labelAttr: NSAttributedString
        var percent: CGRect             // the slot, right-aligned; the text is written live
        var track: CGRect
    }
    var question: CGRect
    var questionAttr: NSAttributedString
    var subtitle: CGRect
    var subtitleAttr: NSAttributedString
    var options: [Option]
    var total: CGRect                   // "N votes", written live
}

/// A capsule with a glyph and a word.
struct PillPlan {
    var glyph: CGRect                   // bubble coordinates
    var label: CGRect
    var labelAttr: NSAttributedString
    var symbol: String
    var busy: Bool
    var dimmed: Bool
}

/// A voice note. Every rect is fixed; only the waveform's progress and the disc's glyph change as
/// it plays, and neither is geometry.
struct VoicePlan {
    var disc: CGRect                    // bubble coordinates
    /// At rest: the whole column, because the speed pill is not drawn until the note is playing.
    var wave: CGRect
    /// While the speed pill is on screen: the same rect, shortened by the pill and its gap. Two
    /// rects rather than arithmetic in the view, so the plan still owns every number.
    var waveWithSpeed: CGRect
    var speedPill: CGRect
    var duration: CGRect
    var durationAttr: NSAttributedString
    var unreadDot: CGRect               // always reserved; the DOT itself is shown or hidden live
    var micGlyph: CGRect
}

/// The story-reply card that floats above a bubble. ROW coordinates — it is not inside the bubble.
struct StoryReplyPlan {
    var caption: CGRect
    var captionAttr: NSAttributedString
    var bar: CGRect?                    // the 5x140 accent bar beside the card
    var thumb: CGRect?                  // the 80x140 story picture
    var unavailable: CGRect?
    var unavailableAttr: NSAttributedString?
}

/// The OG card inside a text bubble. Rects are in BUBBLE coordinates.
struct LinkPreviewPlan {
    var card: CGRect
    var hero: CGRect?                   // an article's 170pt picture
    var avatar: CGRect?                 // a profile's 44pt round photo
    var title: CGRect
    var titleAttr: NSAttributedString
    var subtitle: CGRect?
    var subtitleAttr: NSAttributedString?
    var host: CGRect?
    var hostAttr: NSAttributedString?
    var divider: CGRect?
    var button: CGRect?
    var buttonLabel: CGRect?
    var buttonAttr: NSAttributedString?
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
    var albumPlan: AlbumPlan?
    var filePlan: FilePlan?
    var locationPlan: LocationPlan?
    var contactPlan: ContactPlan?
    var pollPlan: PollPlan?
    var linkPlan: LinkPreviewPlan?
    var storyReplyPlan: StoryReplyPlan?
    var voicePlan: VoicePlan?
    var pillPlan: PillPlan?
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
    /// The red (!) outside a failed send's bubble, in row coordinates. See `decorations`.
    var failBadge: CGRect?
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

}

enum MessageRowLayout {

    // Selection chrome, to the reference's numbers: a 24pt circle (`selectionViewWidth`) sitting at
    // the row's own leading margin, with their `messageStackSpacing` of 8 between it and the
    // content. Ours had a 4pt outer pad and a 10pt gap, so the whole row moved 38 instead of 32 and
    // the circle sat 4pt in from where theirs does.
    static let checkboxSize: CGFloat = 24
    private static let checkboxGap: CGFloat = 8
    /// How far the CONTENT moves over. Their `hInnerStackOffset`: the circle's width plus the gap.
    static var selectionShift: CGFloat { checkboxSize + checkboxGap }
    /// How far the CIRCLE itself travels on the way in and out — further than the content, because it
    /// starts fully outside the leading margin rather than at it. Their `selectionOffset`.
    static var checkboxTravel: CGFloat { BubbleMetrics.rowMargin + checkboxSize }
    /// Their `CVComponentMessage.selectionAnimationDuration`. One number for the row slide, the bar
    /// swap and the delay before the second pass takes the circle out of the cell — if they drift,
    /// the circle is either removed mid-slide or left parked on screen after it.
    static let selectionAnimationDuration: TimeInterval = 0.2

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

        // ⛔ THE SELECTION LANE EXISTS WHILE `selecting || wasSelecting`, exactly as theirs does.
        // Their whole build and measure of the selection column is guarded by
        // `isShowingSelectionUI || wasShowingSelectionUI`, so the lane is still there for the ONE
        // pass that slides the circle out, and gone on the next. Keying it on `selecting` alone is
        // what left the row no space to animate out through.
        let selectionUI = m.selecting || m.wasSelecting
        let shift = selectionUI ? selectionShift : 0
        // ⚠️ NO TRAILING INSET. Theirs puts a FLEXIBLE spacer between the selection column and an
        // outgoing bubble, so the bubble's right edge does not move at all when selection opens —
        // only its cap shrinks. Ours took 4pt off the trailing side as well, which walked every
        // outgoing bubble 4pt left on the way in and back again on the way out. Right-aligning to
        // `rowMargin + shift + contentW` lands the trailing edge exactly where it was.
        let contentX = BubbleMetrics.rowMargin + shift
        let contentW = max(1, width - BubbleMetrics.rowMargin * 2 - shift)

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
        if selectionUI {
            let cy = y + (contentHeight - checkboxSize) / 2
            checkbox = CGRect(x: BubbleMetrics.rowMargin, y: cy,
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

        // ⛔ THE FAILED BADGE'S LANE COMES OFF THE COLUMN, NOT OFF THE CAP — his screenshot,
        // 2026-08-27: the red (!) drawn on top of the bubble's trailing edge, over the timestamp.
        //
        // It used to come off `maxBubble` only (`columnW - failBadgeColumn`), which is the reference's
        // line `contentMaxWidth -= sendFailureBadgeSize + spacing` copied to the wrong place. Theirs is
        // a STACK: the badge is the last arranged subview, so the bubble's box genuinely ends where the
        // badge begins and every bubble in it is short by that much, whatever its content. Ours places
        // the bubble by right-aligning it to `columnX + columnW`, so a cap the bubble never reaches
        // changes nothing at all — and a two-word message like his never reaches it. Both ended up
        // right-aligned to the same edge and drew on top of each other.
        //
        // Taking it off the column instead reproduces the stack: every bubble kind below places itself
        // against `columnW`, so all of them step aside by exactly one badge plus its gap, and the cap
        // needs no separate subtraction because the column it clamps against is already short.
        let failBadgeColumn = b.showsFailedBadge ? BubbleMetrics.failBadge + BubbleMetrics.failBadgeGap : 0
        let columnW = max(1, availableWidth - avatarColumn - failBadgeColumn)

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

        // The story-reply card is measured with the tags and placed with them — it sits above the
        // bubble in the same column, and like them it pushes the bubble down.
        // The card pushes the bubble down before anything else is laid out. Placed later, by
        // `decorations`, once the bubble's own edges are known — the same two-step the sender name
        // and the Forwarded tag take, and for the same reason.
        if let sr = b.storyReply {
            y += storyReplyCardSize(sr, maxWidth: columnW).height + BubbleMetrics.senderNameGap
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

        // The OG card, when one travelled with the message. It is FULL-WIDTH inside the bubble —
        // it does not hug — so it always drives the bubble to the cap. Measured here because it
        // sits between the quote and the words and therefore contributes to the height.
        var linkCard: BubbleBody.LinkPreview?
        if case .text(let t) = b.body { linkCard = t.linkPreview }

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
        case .pill(let p):
            // The same capsule the tombstone wears: a glyph, a word, and no footer of its own —
            // except this one DOES carry the time, because a view-once photo is still a message.
            let glyphW: CGFloat = 20, gap: CGFloat = 8, hPadP: CGFloat = 15, vPadP: CGFloat = 11
            let attr = NSAttributedString(string: p.label, attributes: [
                .font: p.spent ? UIFont.italicSystemFont(ofSize: 15)
                               : UIFont.systemFont(ofSize: 15, weight: .medium),
                .foregroundColor: textColor.withAlphaComponent(p.spent ? 0.6 : 1)])
            let labelSize = lineSizeOf(attr, cap: maxContent)
            let metaAttrP = BubbleText.meta(b.meta, isMe: b.isMe, color: metaColor)
            let metaSizeP = BubbleText.lineSize(metaAttrP)
            let innerW = glyphW + gap + labelSize.width + gap + metaSizeP.width
            let bubbleWP = min(maxBubble, innerW + hPadP * 2)
            let rowH = max(glyphW, max(labelSize.height, metaSizeP.height))
            let bubbleHP = rowH + vPadP * 2
            let xP = b.isMe ? (columnX + columnW - bubbleWP) : columnX
            let rectP = CGRect(x: xP, y: y, width: bubbleWP, height: bubbleHP)
            var outP = BubblePlan(
                bubble: rectP, radii: .uniform(bubbleHP / 2), isCapsule: true,
                fill: b.fill, rim: b.rim,
                text: .zero,
                meta: CGRect(x: bubbleWP - hPadP - metaSizeP.width,
                             y: vPadP + (rowH - metaSizeP.height) / 2,
                             width: metaSizeP.width, height: metaSizeP.height),
                metaOnOwnLine: false, quote: nil, quoteInner: nil,
                bodyAttr: NSAttributedString(), links: [], textColor: textColor, metaColor: metaColor,
                tombstoneIcon: nil, mediaPlan: nil, albumPlan: nil, filePlan: nil,
                locationPlan: nil, contactPlan: nil, pollPlan: nil, linkPlan: nil,
                storyReplyPlan: nil, voicePlan: nil,
                pillPlan: PillPlan(
                    glyph: CGRect(x: hPadP, y: vPadP + (rowH - glyphW) / 2,
                                  width: glyphW, height: glyphW),
                    label: CGRect(x: hPadP + glyphW + gap, y: vPadP + (rowH - labelSize.height) / 2,
                                  width: labelSize.width, height: labelSize.height),
                    labelAttr: attr, symbol: p.symbol, busy: p.busy, dimmed: p.spent),
                avatar: nil, senderName: nil, senderNameAttr: nil, verifiedMark: nil,
                forwarded: nil, forwardedIcon: nil, reactions: [], reactionAttrs: [], reactionMine: [],
                failBadge: nil)
            let bottomP = decorations(b, plan: &outP, bubbleRect: rectP, columnX: columnX,
                                      columnW: columnW, originX: originX, topSpacing: topSpacing,
                                      senderNameAttr: senderNameAttr, senderNameSize: senderNameSize,
                                      forwardedSize: forwardedSize, forwardedIconW: forwardedIconW,
                                      y: rectP.maxY)
            return BubbleResult(plan: outP, totalHeight: bottomP)
        case .media(let m):
            // A media bubble is laid out entirely differently — the picture is flush to the
            // bubble's edges rather than inset by hPad/vPad, and the footer either joins the
            // caption row or floats on the picture. It gets its own function and returns here.
            return media(m, row: b, originX: originX, columnX: columnX, columnW: columnW,
                         maxBubble: maxBubble, textColor: textColor, metaColor: metaColor,
                         accent: accent, topSpacing: topSpacing, y: y,
                         senderNameAttr: senderNameAttr, senderNameSize: senderNameSize,
                         forwardedSize: forwardedSize, forwardedIconW: forwardedIconW)
        case .album(let a):
            return album(a, row: b, originX: originX, columnX: columnX, columnW: columnW,
                         maxBubble: maxBubble, textColor: textColor, metaColor: metaColor,
                         accent: accent, topSpacing: topSpacing, y: y,
                         senderNameAttr: senderNameAttr, senderNameSize: senderNameSize,
                         forwardedSize: forwardedSize, forwardedIconW: forwardedIconW)
        case .file(let f):
            return file(f, row: b, originX: originX, columnX: columnX, columnW: columnW,
                        maxBubble: maxBubble, textColor: textColor, metaColor: metaColor,
                        topSpacing: topSpacing, y: y,
                        senderNameAttr: senderNameAttr, senderNameSize: senderNameSize,
                        forwardedSize: forwardedSize, forwardedIconW: forwardedIconW)
        case .location(let l):
            return location(l, row: b, originX: originX, columnX: columnX, columnW: columnW,
                            maxBubble: maxBubble, textColor: textColor, metaColor: metaColor,
                            topSpacing: topSpacing, y: y,
                            senderNameAttr: senderNameAttr, senderNameSize: senderNameSize,
                            forwardedSize: forwardedSize, forwardedIconW: forwardedIconW)
        case .voice(let v):
            return voice(v, row: b, originX: originX, columnX: columnX, columnW: columnW,
                         maxBubble: maxBubble, textColor: textColor, metaColor: metaColor,
                         topSpacing: topSpacing, y: y,
                         senderNameAttr: senderNameAttr, senderNameSize: senderNameSize,
                         forwardedSize: forwardedSize, forwardedIconW: forwardedIconW)
        case .poll(let p):
            return poll(p, row: b, originX: originX, columnX: columnX, columnW: columnW,
                        maxBubble: maxBubble, textColor: textColor, metaColor: metaColor,
                        topSpacing: topSpacing, y: y,
                        senderNameAttr: senderNameAttr, senderNameSize: senderNameSize,
                        forwardedSize: forwardedSize, forwardedIconW: forwardedIconW)
        case .contact(let c):
            return contact(c, row: b, originX: originX, columnX: columnX, columnW: columnW,
                           maxBubble: maxBubble, textColor: textColor, metaColor: metaColor,
                           topSpacing: topSpacing, y: y,
                           senderNameAttr: senderNameAttr, senderNameSize: senderNameSize,
                           forwardedSize: forwardedSize, forwardedIconW: forwardedIconW)
        }

        let metaAttr = BubbleText.meta(b.meta, isMe: b.isMe, color: metaColor)
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
                mediaPlan: nil, albumPlan: nil, filePlan: nil, locationPlan: nil, contactPlan: nil, pollPlan: nil, linkPlan: nil, storyReplyPlan: nil, voicePlan: nil, pillPlan: nil,
                avatar: nil, senderName: nil, senderNameAttr: nil, verifiedMark: nil,
                forwarded: nil, forwardedIcon: nil, reactions: [], reactionAttrs: [], reactionMine: [],
                failBadge: nil)
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
        // A link card does not hug: it is drawn full-width, so it takes the bubble to the cap.
        if linkCard != nil { contentW = maxContent }
        contentW = min(maxContent, ceil(contentW))

        var innerY: CGFloat = vPad
        var quoteRect: CGRect?
        if quoteOuter.height > 0 {
            quoteRect = CGRect(x: hPad, y: innerY, width: contentW, height: quoteOuter.height)
            innerY += quoteOuter.height + 4                   // VStack spacing 4
        }

        var linkPlan: LinkPreviewPlan?
        if let card = linkCard {
            let (size, plan) = linkPreview(card, textColor: textColor, width: contentW)
            var placed = plan
            let rect = CGRect(x: hPad, y: innerY, width: contentW, height: size.height)
            placed.card = rect
            linkPlan = placed
            innerY += size.height + 4                   // VStack spacing 4
        }

        // Re-measure the body at the FINAL content width. With a quote driving the bubble wider the
        // text has more room than it was measured with, and a stale height would leave a gap under
        // the last line.
        // ⛔ A LONG MESSAGE IS DRAWN IN FULL. The 20-line "Read more" collapse tried here on
        // 2026-08-27 is REMOVED on his order the next day: it cut his messages in the middle and
        // the cut followed them into the long-press preview. A bubble is as tall as its words.
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
            // ⛔ A BORDERLESS BUBBLE'S FOOTER CANNOT USE THE OUTGOING COLOUR. `myMeta` is white at
            // 70% and exists for the blue fill; the jumbomoji branch above clears that fill and drops
            // the rim, so the footer was left drawing white on whatever the page is. In light mode
            // with no wallpaper the page is white — so every emoji-only message you send had no
            // visible timestamp and no visible send state at all.
            //
            // Incoming was fine by accident: `receivedMeta` is a system secondary label, which is
            // already surface-relative. This gives the outgoing side the same property when there is
            // no bubble under it. Theirs does the same thing for the same reason.
            bodyAttr: bodyAttr, links: links, textColor: textColor,
            metaColor: isJumbo ? BubblePalette.receivedMeta : metaColor,
            tombstoneIcon: nil, mediaPlan: nil, albumPlan: nil, filePlan: nil, locationPlan: nil, contactPlan: nil, pollPlan: nil, linkPlan: linkPlan, storyReplyPlan: nil, voicePlan: nil, pillPlan: nil,
            avatar: nil, senderName: nil, senderNameAttr: nil, verifiedMark: nil,
            forwarded: nil, forwardedIcon: nil, reactions: [], reactionAttrs: [], reactionMine: [],
            failBadge: nil)

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

        // ⛔ THE FAILED BADGE SITS OUTSIDE THE BUBBLE, ON THE TRAILING EDGE — his order, 2026-08-26:
        // "remove this text… make it like the reference's retry button", with a photograph of their
        // failed message. Read from their `CVComponentMessage`: the badge is the LAST subview of the
        // row's outer horizontal stack, so it lands past the bubble's trailing edge, and the bubble
        // is narrowed by the badge plus the stack's spacing to make room for it.
        //
        // Their numbers, used verbatim: a 24pt box, 8pt from the bubble (`messageStackSpacing`),
        // tinted `ows_accentRed` (0xF44336). Theirs also raises the badge off the row's bottom so
        // its centre lands on the last text line's axis; our footer IS that line, so the badge is
        // centred on the footer instead, which is the same intent expressed in our own geometry.
        //
        // ⚠️ NO TEXT — his instruction, twice ("no more text"). Theirs replaces the timestamp with
        // "Send Failed"; ours keeps the time. The badge is the whole of the message.
        if b.showsFailedBadge {
            // `plan.meta` is bubble-local; the badge lives in row coordinates like the avatar.
            let cy = plan.meta == .zero ? bubbleRect.maxY - BubbleMetrics.vPad - BubbleMetrics.failBadge / 2
                                        : bubbleRect.minY + plan.meta.midY
            // ⚠️ `columnW` STOPS AT THE BUBBLE'S TRAILING EDGE — the badge's own lane was taken out of
            // it up in `bubble(_:)`, which is what stops the two overlapping. So the badge is placed
            // FORWARD of that edge by the stack's spacing, and its far side lands back on the row's
            // real trailing margin. Reading `columnX + columnW - failBadge` here, as this line used
            // to, would now park it inside the bubble a second time.
            plan.failBadge = CGRect(x: columnX + columnW + BubbleMetrics.failBadgeGap,
                                    y: cy - BubbleMetrics.failBadge / 2,
                                    width: BubbleMetrics.failBadge, height: BubbleMetrics.failBadge)
            y = max(y, plan.failBadge!.maxY)
        }

        if let s = b.sender, s.showsAvatar {
            // Bottom-aligned with the COLUMN, not with the bubble — the row is an
            // `HStack(alignment: .bottom)` and the column's bottom edge is `y`, which by now
            // includes the reaction overhang and the retry line. Aligning to the bubble instead
            // would float the face above the badges on any reacted message.
            plan.avatar = CGRect(x: originX, y: y - BubbleMetrics.avatarSize,
                                width: BubbleMetrics.avatarSize, height: BubbleMetrics.avatarSize)
        }

        // Now the bubble's edges are known, the card and the two tags take their real positions.
        var tagY = topSpacing
        // The card is re-measured here rather than passed in, so EVERY bubble kind places it the
        // same way — a story reply can carry a photo or a voice note as easily as words, and a
        // parameter would have meant six call sites each remembering to hand it over.
        if let sr = b.storyReply {
            plan.storyReplyPlan = storyReplyPlan(sr, isMe: b.isMe, bubbleRect: bubbleRect,
                                                 columnW: columnW, top: tagY, maxWidth: columnW)
            tagY += storyReplyCardSize(sr, maxWidth: columnW).height + BubbleMetrics.senderNameGap
        }
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
        let metaAttr = BubbleText.meta(b.meta, isMe: b.isMe, color: metaColor)
        var plan = MediaPlan(media: mediaRect, caption: nil, captionText: nil, captionAttr: nil,
                             captionMetaOnOwnLine: false, metaCapsule: nil, duration: nil,
                             playBadge: nil, uploadRing: nil, kind: m.kind)
        var metaRect: CGRect

        if let caption = m.caption, !caption.text.isEmpty {
            let r = captionBlock(caption, meta: b.meta, metaAttr: metaAttr, row: b,
                                 textColor: textColor, accent: accent,
                                 bubbleW: bubbleW, top: innerY)
            plan.caption = r.block
            plan.captionText = r.text
            plan.captionAttr = r.attr
            plan.captionMetaOnOwnLine = r.metaOnOwnLine
            metaRect = r.meta
            innerY = r.block.maxY
        } else {
            let r = floatingMeta(metaAttr, over: mediaRect)
            plan.metaCapsule = r.capsule
            metaRect = r.text
        }

        if m.kind == .video {
            // ⚠️ NO PLAY BADGE WHILE IT UPLOADS. A play badge means "this is ready, tap it", which
            // is not true mid-send, and the badge and the ring are drawn at the centre of the same
            // rect — the album path has said so since it was written and this one did not, so a
            // sending video wore a ring on top of a play triangle.
            if !m.uploading {
                let side: CGFloat = min(box.width, box.height) * 0.28
                plan.playBadge = CGRect(x: mediaRect.midX - side / 2, y: mediaRect.midY - side / 2,
                                        width: side, height: side)
            }
            // The duration stays either way: it is true while it uploads and it sits in the corner.
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
            // 52, his number off the side-by-side (2026-08-27): 44 with an 8pt inset drew a 28pt
            // thread in the middle of a 250pt photo and he could barely see it. The disc is the
            // tap target as well as the indicator — see UploadRingView.
            let side: CGFloat = 52
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
            tombstoneIcon: nil, mediaPlan: plan, albumPlan: nil, filePlan: nil, locationPlan: nil, contactPlan: nil, pollPlan: nil, linkPlan: nil, storyReplyPlan: nil, voicePlan: nil, pillPlan: nil,
            avatar: nil, senderName: nil, senderNameAttr: nil, verifiedMark: nil,
            forwarded: nil, forwardedIcon: nil, reactions: [], reactionAttrs: [], reactionMine: [],
            failBadge: nil)

        let bottom = decorations(b, plan: &out, bubbleRect: bubbleRect, columnX: columnX,
                                 columnW: columnW, originX: originX, topSpacing: topSpacing,
                                 senderNameAttr: senderNameAttr, senderNameSize: senderNameSize,
                                 forwardedSize: forwardedSize, forwardedIconW: forwardedIconW, y: y)
        return BubbleResult(plan: out, totalHeight: bottom)
    }

    // ── An album bubble ──

    private static func album(_ a: BubbleBody.AlbumBody, row b: BubbleRow,
                              originX: CGFloat, columnX: CGFloat, columnW: CGFloat,
                              maxBubble: CGFloat, textColor: UIColor, metaColor: UIColor,
                              accent: UIColor, topSpacing: CGFloat, y startY: CGFloat,
                              senderNameAttr: NSAttributedString?, senderNameSize: CGSize,
                              forwardedSize: CGSize, forwardedIconW: CGFloat) -> BubbleResult {
        let y = startY
        let albumWidth = min(maxBubble, 300)
        // A SQUARE box: the width is the bubble's and the height only bounds the hand-tuned 2/3/4
        // arrangements, exactly as the reference bounds them.
        let sizes = a.tiles.map { CGSize(width: max(0.01, $0.aspect), height: 1) }
        let solved = MediaGroupLayout.solve(itemSizes: sizes,
                                            maxSize: CGSize(width: albumWidth, height: albumWidth))
        let bubbleW = min(maxBubble, max(1, solved.size.width))

        var innerY: CGFloat = 0
        var quoteRect: CGRect?
        var quoteInner: QuoteInnerPlan?
        if let q = b.quote {
            let (size, inner) = quoteSize(q, textColor: textColor,
                                          maxWidth: max(1, bubbleW - BubbleMetrics.hPad * 2))
            quoteInner = inner
            innerY = BubbleMetrics.vPad
            quoteRect = CGRect(x: BubbleMetrics.hPad, y: innerY,
                               width: bubbleW - BubbleMetrics.hPad * 2, height: size.height)
            innerY += size.height + 4
        }

        let grid = CGRect(x: 0, y: innerY, width: solved.size.width, height: solved.size.height)
        innerY = grid.maxY

        var tiles: [AlbumPlan.Tile] = []
        for (i, t) in solved.tiles.enumerated() {
            var tile = AlbumPlan.Tile(rect: t.rect, playBadge: nil, duration: nil,
                                      durationAttr: nil, extraAttr: nil, ring: nil)
            let model = a.tiles.indices.contains(t.index) ? a.tiles[t.index] : nil
            let isLast = i == solved.tiles.count - 1
            if a.extra > 0, isLast {
                tile.extraAttr = NSAttributedString(string: "+\(a.extra)", attributes: [
                    .font: UIFont.systemFont(ofSize: min(t.rect.width, t.rect.height) * 0.22, weight: .semibold),
                    .foregroundColor: UIColor.white])
            } else if model?.isVideo == true, !a.uploading {
                // A play badge means "this is ready, tap it", which is not true mid-upload — and
                // while the album uploads the tile shows its OWN ring instead.
                let side = min(t.rect.width, t.rect.height) * 0.28
                tile.playBadge = CGRect(x: t.rect.midX - side / 2, y: t.rect.midY - side / 2,
                                        width: side, height: side)
                if let d = model?.durationText {
                    let attr = NSAttributedString(string: d, attributes: [
                        .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
                        .foregroundColor: UIColor.white])
                    let s = lineSizeOf(attr)
                    tile.durationAttr = attr
                    tile.duration = CGRect(x: t.rect.minX + 5, y: t.rect.maxY - 5 - (s.height + 4),
                                           width: s.width + 12, height: s.height + 4)
                }
            }
            if a.uploading, a.extra == 0 || !isLast {
                // Same 52 as a single photo. A tile only goes smaller when the tile itself is
                // small, which is the case the halving rule is here for.
                let side = min(52, min(t.rect.width, t.rect.height) * 0.5)
                tile.ring = CGRect(x: t.rect.midX - side / 2, y: t.rect.midY - side / 2,
                                   width: side, height: side)
            }
            tiles.append(tile)
        }

        var plan = AlbumPlan(grid: grid, tiles: tiles, caption: nil, captionText: nil,
                             captionAttr: nil, captionMetaOnOwnLine: false, metaCapsule: nil)
        let metaAttr = BubbleText.meta(b.meta, isMe: b.isMe, color: metaColor)
        var metaRect: CGRect
        if let caption = a.caption, !caption.text.isEmpty {
            let r = captionBlock(caption, meta: b.meta, metaAttr: metaAttr, row: b,
                                 textColor: textColor, accent: accent,
                                 bubbleW: bubbleW, top: innerY)
            plan.caption = r.block
            plan.captionText = r.text
            plan.captionAttr = r.attr
            plan.captionMetaOnOwnLine = r.metaOnOwnLine
            metaRect = r.meta
            innerY = r.block.maxY
        } else {
            let r = floatingMeta(metaAttr, over: grid)
            plan.metaCapsule = r.capsule
            metaRect = r.text
        }

        let bubbleRect = CGRect(x: b.isMe ? (columnX + columnW - bubbleW) : columnX,
                                y: y, width: bubbleW, height: innerY)
        var out = BubblePlan(
            bubble: bubbleRect, radii: b.radii, isCapsule: false, fill: b.fill, rim: b.rim,
            text: .zero, meta: metaRect, metaOnOwnLine: plan.captionMetaOnOwnLine,
            quote: quoteRect, quoteInner: quoteInner,
            bodyAttr: NSAttributedString(), links: [], textColor: textColor, metaColor: metaColor,
            tombstoneIcon: nil, mediaPlan: nil, albumPlan: plan, filePlan: nil, locationPlan: nil, contactPlan: nil, pollPlan: nil, linkPlan: nil, storyReplyPlan: nil, voicePlan: nil, pillPlan: nil,
            avatar: nil, senderName: nil, senderNameAttr: nil, verifiedMark: nil,
            forwarded: nil, forwardedIcon: nil, reactions: [], reactionAttrs: [], reactionMine: [],
            failBadge: nil)
        let bottom = decorations(b, plan: &out, bubbleRect: bubbleRect, columnX: columnX,
                                 columnW: columnW, originX: originX, topSpacing: topSpacing,
                                 senderNameAttr: senderNameAttr, senderNameSize: senderNameSize,
                                 forwardedSize: forwardedSize, forwardedIconW: forwardedIconW,
                                 y: bubbleRect.maxY)
        return BubbleResult(plan: out, totalHeight: bottom)
    }

    // ── A file bubble ──

    private static func file(_ f: BubbleBody.FileBody, row b: BubbleRow,
                             originX: CGFloat, columnX: CGFloat, columnW: CGFloat,
                             maxBubble: CGFloat, textColor: UIColor, metaColor: UIColor,
                             topSpacing: CGFloat, y startY: CGFloat,
                             senderNameAttr: NSAttributedString?, senderNameSize: CGSize,
                             forwardedSize: CGSize, forwardedIconW: CGFloat) -> BubbleResult {
        let y = startY
        let hPad: CGFloat = 13, vPad: CGFloat = 10, gap: CGFloat = 10
        let hasPreview = f.localPreview != nil || !(f.previewUrl?.isEmpty ?? true)
        let slotSize = hasPreview ? CGSize(width: 44, height: 58) : CGSize(width: 26, height: 26)
        let maxContent = max(1, maxBubble - hPad * 2)

        let nameAttr = NSAttributedString(string: f.name, attributes: [
            .font: UIFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: textColor])
        let sizeAttr = NSAttributedString(string: f.sizeLabel, attributes: [
            .font: UIFont.systemFont(ofSize: 12),
            .foregroundColor: b.isMe ? UIColor.white.withAlphaComponent(0.8) : UIColor.secondaryLabel])
        let metaAttr = BubbleText.meta(b.meta, isMe: b.isMe, color: metaColor)
        let metaSize = BubbleText.lineSize(metaAttr)

        let textAvail = max(1, maxContent - slotSize.width - gap)
        let nameSize = lineSizeOf(nameAttr, cap: textAvail)
        let sizeSize = lineSizeOf(sizeAttr, cap: textAvail)
        let textW = max(nameSize.width, sizeSize.width)

        var quoteOuter: CGSize = .zero
        var quoteInner: QuoteInnerPlan?
        if let q = b.quote {
            let (size, inner) = quoteSize(q, textColor: textColor, maxWidth: maxContent)
            quoteOuter = size
            quoteInner = inner
        }

        let rowW = slotSize.width + gap + textW
        let contentW = min(maxContent, max(max(rowW, quoteOuter.width), metaSize.width))

        var innerY = vPad
        var quoteRect: CGRect?
        if quoteOuter.height > 0 {
            quoteRect = CGRect(x: hPad, y: innerY, width: contentW, height: quoteOuter.height)
            innerY += quoteOuter.height + 4
        }

        // The slot and the two lines are centred against each other, as the HStack centred them.
        let rowH = max(slotSize.height, nameSize.height + 2 + sizeSize.height)
        let slot = CGRect(x: hPad, y: innerY + (rowH - slotSize.height) / 2,
                          width: slotSize.width, height: slotSize.height)
        let textX = hPad + slotSize.width + gap
        let stackTop = innerY + (rowH - (nameSize.height + 2 + sizeSize.height)) / 2
        let namesW = max(1, contentW - slotSize.width - gap)
        let plan = FilePlan(
            slot: slot, slotIsPreview: hasPreview,
            name: CGRect(x: textX, y: stackTop, width: namesW, height: nameSize.height),
            nameAttr: nameAttr,
            size: CGRect(x: textX, y: stackTop + nameSize.height + 2, width: namesW, height: sizeSize.height),
            sizeAttr: sizeAttr,
            spinner: f.uploading ? slot : nil)
        innerY += rowH + 4

        let metaRect = CGRect(x: hPad + contentW - metaSize.width, y: innerY,
                              width: metaSize.width, height: metaSize.height)
        innerY += metaSize.height + vPad

        let bubbleW = contentW + hPad * 2
        let bubbleRect = CGRect(x: b.isMe ? (columnX + columnW - bubbleW) : columnX,
                                y: y, width: bubbleW, height: innerY)
        var out = BubblePlan(
            bubble: bubbleRect, radii: b.radii, isCapsule: false, fill: b.fill, rim: b.rim,
            text: .zero, meta: metaRect, metaOnOwnLine: true,
            quote: quoteRect, quoteInner: quoteInner,
            bodyAttr: NSAttributedString(), links: [], textColor: textColor, metaColor: metaColor,
            tombstoneIcon: nil, mediaPlan: nil, albumPlan: nil, filePlan: plan, locationPlan: nil, contactPlan: nil, pollPlan: nil, linkPlan: nil, storyReplyPlan: nil, voicePlan: nil, pillPlan: nil,
            avatar: nil, senderName: nil, senderNameAttr: nil, verifiedMark: nil,
            forwarded: nil, forwardedIcon: nil, reactions: [], reactionAttrs: [], reactionMine: [],
            failBadge: nil)
        let bottom = decorations(b, plan: &out, bubbleRect: bubbleRect, columnX: columnX,
                                 columnW: columnW, originX: originX, topSpacing: topSpacing,
                                 senderNameAttr: senderNameAttr, senderNameSize: senderNameSize,
                                 forwardedSize: forwardedSize, forwardedIconW: forwardedIconW,
                                 y: bubbleRect.maxY)
        return BubbleResult(plan: out, totalHeight: bottom)
    }

    // ── A voice note ──
    //
    // ⛔ THE WIDTH IS A CONSTANT AND THAT IS THE WHOLE POINT. The old bubble bloomed on first play,
    // and the cause was never the waveform: it was a greedy `Spacer` beside the footer, which
    // SwiftUI re-resolved toward the bubble cap on the reconfigure that fired when playback began.
    // Here nothing is flexible — every rect below is worked out from `maxBubble`, which the layout
    // knows before it measures anything, so the bubble is identical before, during and after
    // playback. ⚠️ It used to be derived from the note's DURATION instead; that was equally
    // constant and equally safe, and it is gone only because he chose a wider bubble on
    // 2026-08-27 — see the block inside `voice`.

    private static func voice(_ v: BubbleBody.VoiceBody, row b: BubbleRow,
                              originX: CGFloat, columnX: CGFloat, columnW: CGFloat,
                              maxBubble: CGFloat, textColor: UIColor, metaColor: UIColor,
                              topSpacing: CGFloat, y startY: CGFloat,
                              senderNameAttr: NSAttributedString?, senderNameSize: CGSize,
                              forwardedSize: CGSize, forwardedIconW: CGFloat) -> BubbleResult {
        let y = startY
        let hPad: CGFloat = 13, vPad: CGFloat = 7   // vPad 8 → 7 in the 2026-08-27 slimming
        // ⛔ FULL WIDTH — HIS ORDER, 2026-08-27, ON A SIDE-BY-SIDE HE SHOT HIMSELF. THIS REVERSES
        // THE 2026-08-24 DECISION RECORDED HERE, AND THE HISTORY IS KEPT BECAUSE IT HAS NOW FLIPPED
        // TWICE AND WILL BE ASKED AGAIN.
        //
        // 2026-08-24 morning: built flexible, every note a full max-width bubble, because the
        // reference genuinely is flexible — their `AudioMessageView.measure` declares the waveform
        // `CGSize(width: 0, …)` with only the height fixed. 2026-08-24 evening: he sent three shots
        // and chose the NARROW one, and this became `min(max, v.contentWidth)` = a fixed 224.
        //
        // 2026-08-27: he put our 0:09 note beside another messenger's 0:03 and asked why ours looks
        // short. It looks short because 224 is fixed and 98 of it is waveform. Theirs fills the
        // bubble. He has now seen the narrow build on a device for three days and chosen the wide
        // one with the comparison in front of him, which is the stronger signal of the two.
        //
        // ⚠️ The width is STILL A CONSTANT for a given row width, which is the property that stops
        // the bloom: it comes from `maxBubble`, which the layout already knows before measuring, and
        // NOT from playback state. What the pill's arrival changes is the waveform inside a bubble
        // that does not move — see `waveWithSpeed`.
        //
        // 2026-08-28, AND THIS IS THE THIRD SETTING: he sent the note with the width he wants drawn
        // on it in pen. Measured off that screenshot, his mark is at 274pt where the bubble was 308.
        // So it is no longer the full `maxBubble` — it is a FRACTION of it, which is the part that
        // differs from the 224 he rejected in August. A fraction narrows with the screen; a fixed
        // width does not, and standing still while the screen grew is what made a long note look
        // short beside another app's. See `VoiceMessageView.widthFraction`.
        let contentW = max(1, maxBubble * VoiceMessageView.widthFraction - hPad * 2)
        var innerY = vPad

        var quoteRect: CGRect?
        var quoteInner: QuoteInnerPlan?
        if let q = b.quote {
            let (size, inner) = quoteSize(q, textColor: textColor, maxWidth: contentW)
            quoteInner = inner
            // The quote FILLS the note's fixed column — the voice bubble is not free to hug, so a
            // content-sized quote would leave bare bubble to its right.
            quoteRect = CGRect(x: hPad, y: innerY, width: contentW, height: size.height)
            innerY += size.height + 4
        }

        let disc = VoiceMessageView.discSize
        let gap = VoiceMessageView.discGap
        let waveH = VoiceMessageView.waveHeight
        let speed = VoiceMessageView.speedSlot
        let columnStart = hPad + disc + gap
        let columnW2 = max(1, contentW - disc - gap)

        let durationAttr = NSAttributedString(string: v.durationText, attributes: [
            .font: UIFont.systemFont(ofSize: 11),
            .foregroundColor: textColor.withAlphaComponent(0.8)])
        let durH = lineSizeOf(durationAttr).height
        let durW = lineSizeOf(durationAttr).width

        // The column is the wave over the duration line; the disc is centred against the pair.
        let stackH = waveH + 6 + durH
        let contentH = max(VoiceMessageView.contentHeight, stackH)
        let stackTop = innerY + (contentH - stackH) / 2

        // ⛔ THE WAVE TAKES THE PILL'S SPACE WHEN THE PILL IS NOT THERE — his order, 2026-08-27:
        // "1x sits there always and takes another 40pt", against a reference that shows a speed
        // control only once you start playing. So the wave has TWO widths and the bubble has one:
        // the full column at rest, the column minus the pill while it plays. Nothing outside the
        // bubble moves either way, which is what makes a live swap safe here — the rule the unread
        // dot's note states is about the ROW's measured size, and that is untouched.
        let waveW = max(1, columnW2)
        let waveWithSpeedW = max(1, columnW2 - gap - speed)

        // ⛔ THE TIMESTAMP IS ANCHORED TO THE BUBBLE'S BOTTOM, exactly as the text bubble's footer
        // is — his order, 2026-08-26, after comparing the two side by side. `innerY + contentH` is
        // the content's bottom (the bubble's own `vPad` comes after), so `bottom - height - 1` is
        // the same expression the text path uses.
        //
        // ⚠️ An overlay, adding no height — which is the shape this bubble's own notes call the safe
        // one, because the row is pre-measured and anything that adds size here would bloom it.
        let metaAttr = BubbleText.meta(b.meta, isMe: b.isMe, color: metaColor)
        let metaSize = BubbleText.lineSize(metaAttr)
        let metaRect = CGRect(x: hPad + contentW - metaSize.width,
                              y: innerY + contentH - metaSize.height - 1,
                              width: metaSize.width, height: metaSize.height)
        // ⛔ THE DURATION SHARES THE TIMESTAMP'S LINE — his order, 2026-08-26, with a screenshot
        // of "0:11" sitting a line above "6:11 PM": "they should be aligned on the same horizontal
        // baseline; the timestamp is correct, fix the duration and icon position." It used to hang
        // 6pt under the wave as part of a centred stack, which is a different anchor from the
        // timestamp's whenever the 55pt floor is taller than the stack. Centred on the timestamp's
        // line now; the dot and the mic are centred on the duration, so they come with it. The
        // wave, the speed pill and the disc keep their places.
        let durY = metaRect.midY - durH / 2
        let plan = VoicePlan(
            disc: CGRect(x: hPad, y: innerY + (contentH - disc) / 2, width: disc, height: disc),
            wave: CGRect(x: columnStart, y: stackTop, width: waveW, height: waveH),
            waveWithSpeed: CGRect(x: columnStart, y: stackTop, width: waveWithSpeedW, height: waveH),
            speedPill: CGRect(x: columnStart + waveWithSpeedW + gap, y: stackTop + (waveH - 22) / 2,
                              width: speed, height: 22),
            duration: CGRect(x: columnStart, y: durY, width: durW, height: durH),
            durationAttr: durationAttr,
            // ⛔ THE DOT'S SLOT IS ALWAYS RESERVED, whether or not the dot is drawn — and the mic
            // never moves because of it. This is the rule the old bubble states about its own speed
            // pill and mic: the row is pre-measured before playback state arrives, so anything that
            // appears or disappears later would change a height that was already measured. The dot
            // is SHOWN or HIDDEN live by the view; the geometry is a constant.
            unreadDot: CGRect(x: columnStart + durW + 8,
                              y: durY + (durH - 7) / 2,
                              width: 7, height: 7),
            micGlyph: CGRect(x: columnStart + durW + 19,
                             y: durY + (durH - 10) / 2, width: 10, height: 10))
        innerY += contentH
        innerY += vPad

        let bubbleW = contentW + hPad * 2
        let bubbleRect = CGRect(x: b.isMe ? (columnX + columnW - bubbleW) : columnX,
                                y: y, width: bubbleW, height: innerY)
        var out = BubblePlan(
            bubble: bubbleRect, radii: b.radii, isCapsule: false, fill: b.fill, rim: b.rim,
            text: .zero, meta: metaRect, metaOnOwnLine: true,
            quote: quoteRect, quoteInner: quoteInner,
            bodyAttr: NSAttributedString(), links: [], textColor: textColor, metaColor: metaColor,
            tombstoneIcon: nil, mediaPlan: nil, albumPlan: nil, filePlan: nil,
            locationPlan: nil, contactPlan: nil, pollPlan: nil, linkPlan: nil,
            storyReplyPlan: nil, voicePlan: plan, pillPlan: nil,
            avatar: nil, senderName: nil, senderNameAttr: nil, verifiedMark: nil,
            forwarded: nil, forwardedIcon: nil, reactions: [], reactionAttrs: [], reactionMine: [],
            failBadge: nil)
        let bottom = decorations(b, plan: &out, bubbleRect: bubbleRect, columnX: columnX,
                                 columnW: columnW, originX: originX, topSpacing: topSpacing,
                                 senderNameAttr: senderNameAttr, senderNameSize: senderNameSize,
                                 forwardedSize: forwardedSize, forwardedIconW: forwardedIconW,
                                 y: bubbleRect.maxY)
        return BubbleResult(plan: out, totalHeight: bottom)
    }

    // ── The story-reply card ──

    private static let storyCardHeight: CGFloat = 140
    private static let storyCardWidth: CGFloat = 80

    private static func storyReplyCaption(_ sr: StoryReplyChrome) -> NSAttributedString {
        NSAttributedString(string: sr.caption, attributes: [
            .font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor.secondaryLabel])
    }

    private static func storyReplyCardSize(_ sr: StoryReplyChrome, maxWidth: CGFloat) -> CGSize {
        let caption = lineSizeOf(storyReplyCaption(sr), cap: maxWidth)
        guard !sr.unavailable, sr.thumbUrl?.isEmpty == false else {
            let attr = NSAttributedString(string: "Story unavailable", attributes: [
                .font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor.tertiaryLabel])
            let s = lineSizeOf(attr, cap: maxWidth)
            return CGSize(width: max(caption.width, s.width), height: caption.height + 5 + s.height)
        }
        let bar: CGFloat = 5, gap: CGFloat = 9
        return CGSize(width: max(caption.width, bar + gap + storyCardWidth),
                      height: caption.height + 5 + storyCardHeight)
    }

    /// Placed once the bubble's edges are known, like the sender name and the Forwarded tag.
    private static func storyReplyPlan(_ sr: StoryReplyChrome, isMe: Bool,
                                       bubbleRect: CGRect, columnW: CGFloat,
                                       top: CGFloat, maxWidth: CGFloat) -> StoryReplyPlan {
        let captionAttr = storyReplyCaption(sr)
        let captionSize = lineSizeOf(captionAttr, cap: maxWidth)
        // The column aligns the caption and the card to the sender's own side.
        let size = storyReplyCardSize(sr, maxWidth: maxWidth)
        let originX = isMe ? (bubbleRect.maxX - size.width) : bubbleRect.minX
        let captionX = isMe ? (bubbleRect.maxX - captionSize.width) : bubbleRect.minX
        let caption = CGRect(x: captionX, y: top, width: captionSize.width, height: captionSize.height)

        guard !sr.unavailable, sr.thumbUrl?.isEmpty == false else {
            let attr = NSAttributedString(string: "Story unavailable", attributes: [
                .font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor.tertiaryLabel])
            let s = lineSizeOf(attr, cap: maxWidth)
            let x = isMe ? (bubbleRect.maxX - s.width) : bubbleRect.minX
            return StoryReplyPlan(caption: caption, captionAttr: captionAttr,
                                  bar: nil, thumb: nil,
                                  unavailable: CGRect(x: x, y: caption.maxY + 5,
                                                      width: s.width, height: s.height),
                                  unavailableAttr: attr)
        }
        let bar: CGFloat = 5, gap: CGFloat = 9
        let cardTop = caption.maxY + 5
        // The accent bar sits on the OUTSIDE of the card — the side the bubble is on.
        let barX = isMe ? (originX + size.width - bar) : originX
        let thumbX = isMe ? originX : (originX + bar + gap)
        return StoryReplyPlan(
            caption: caption, captionAttr: captionAttr,
            bar: CGRect(x: barX, y: cardTop, width: bar, height: storyCardHeight),
            thumb: CGRect(x: thumbX, y: cardTop, width: storyCardWidth, height: storyCardHeight),
            unavailable: nil, unavailableAttr: nil)
    }

    // ── The OG card inside a text bubble ──

    /// Returns the card's size at `width`, and a plan whose rects are relative to the card's own
    /// origin. The caller places it and offsets.
    private static func linkPreview(_ p: BubbleBody.LinkPreview, textColor: UIColor,
                                    width: CGFloat) -> (CGSize, LinkPreviewPlan) {
        let pad: CGFloat = 10
        let inner = max(1, width - pad * 2)
        var y: CGFloat = 0

        switch p.shape {
        case .article:
            var hero: CGRect?
            if p.imageUrl != nil {
                // ⛔ 170, NOT 140. The reference card leads with a big photo and 140 read as a thin
                // strip beside it (his side-by-side).
                hero = CGRect(x: 0, y: 0, width: width, height: 170)
                y = 170
            }
            y += 8
            var titleRect = CGRect(x: pad, y: y, width: inner, height: 0)
            var titleAttr = NSAttributedString()
            if !p.title.isEmpty {
                titleAttr = NSAttributedString(string: p.title, attributes: [
                    .font: UIFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: textColor])
                let h = cappedHeight(titleAttr, width: inner, lines: 2)
                titleRect = CGRect(x: pad, y: y, width: inner, height: h)
                y += h + 2
            }
            var subtitle: CGRect?
            var subtitleAttr: NSAttributedString?
            if !p.desc.isEmpty {
                let attr = NSAttributedString(string: p.desc, attributes: [
                    .font: UIFont.systemFont(ofSize: 12),
                    .foregroundColor: textColor.withAlphaComponent(0.75)])
                let h = cappedHeight(attr, width: inner, lines: 2)
                subtitle = CGRect(x: pad, y: y, width: inner, height: h)
                subtitleAttr = attr
                y += h + 2
            }
            let hostAttr = NSAttributedString(string: p.host, attributes: [
                .font: UIFont.systemFont(ofSize: 11),
                .foregroundColor: textColor.withAlphaComponent(0.55)])
            let hostH = lineSizeOf(hostAttr, cap: inner).height
            let host = CGRect(x: pad, y: y, width: inner, height: hostH)
            y += hostH + 8

            return (CGSize(width: width, height: y),
                    LinkPreviewPlan(card: .zero, hero: hero, avatar: nil,
                                    title: titleRect, titleAttr: titleAttr,
                                    subtitle: subtitle, subtitleAttr: subtitleAttr,
                                    host: host, hostAttr: hostAttr,
                                    divider: nil, button: nil, buttonLabel: nil, buttonAttr: nil))

        case .profile, .profileUnavailable:
            // The two profile shapes share one layout and differ only in their words, so they share
            // a case. A binding cannot ride a multi-pattern case — only `.profile` carries a handle
            // — so it is read out below instead.
            var handleText = ""
            var unavailable = true
            if case .profile(let h) = p.shape { unavailable = false; handleText = h }

            let avatarSize: CGFloat = 44, gap: CGFloat = 10
            y = 10
            let textX = pad + avatarSize + gap
            let textW = max(1, width - textX - pad)
            let titleAttr = NSAttributedString(
                string: unavailable ? "Unavailable" : p.title,
                attributes: [.font: UIFont.systemFont(ofSize: 15, weight: .semibold),
                             .foregroundColor: textColor])
            let subAttr = NSAttributedString(
                string: unavailable ? "This account is no longer available"
                                    : (p.desc.isEmpty ? "@\(handleText)" : p.desc),
                attributes: [.font: UIFont.systemFont(ofSize: 13),
                             .foregroundColor: textColor.withAlphaComponent(0.75)])
            let tH = lineSizeOf(titleAttr, cap: textW).height
            let sH = lineSizeOf(subAttr, cap: textW).height
            let rowH = max(avatarSize, tH + 1 + sH)
            let stackTop = y + (rowH - (tH + 1 + sH)) / 2
            let avatar = CGRect(x: pad, y: y + (rowH - avatarSize) / 2,
                                width: avatarSize, height: avatarSize)
            let title = CGRect(x: textX, y: stackTop, width: textW, height: tH)
            let subtitle = CGRect(x: textX, y: stackTop + tH + 1, width: textW, height: sH)
            y += rowH + (unavailable ? 10 : 8)

            var divider: CGRect?
            var button: CGRect?
            var buttonLabel: CGRect?
            var buttonAttr: NSAttributedString?
            if !unavailable {
                divider = CGRect(x: 0, y: y, width: width, height: BubbleMetrics.hairline)
                y += BubbleMetrics.hairline
                let attr = NSAttributedString(string: "Send Message", attributes: [
                    .font: UIFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: textColor])
                let size = lineSizeOf(attr)
                let b = CGRect(x: 0, y: y, width: width, height: 40)
                button = b
                buttonAttr = attr
                buttonLabel = CGRect(x: b.midX - size.width / 2, y: b.midY - size.height / 2,
                                     width: size.width, height: size.height)
                y = b.maxY
            }

            return (CGSize(width: width, height: y),
                    LinkPreviewPlan(card: .zero, hero: nil, avatar: avatar,
                                    title: title, titleAttr: titleAttr,
                                    subtitle: subtitle, subtitleAttr: subAttr,
                                    host: nil, hostAttr: nil,
                                    divider: divider, button: button,
                                    buttonLabel: buttonLabel, buttonAttr: buttonAttr))
        }
    }

    /// The height of an attributed string clamped to `lines` — the card's title and description are
    /// both `lineLimit(2)`, and a plan that measured them unclamped would reserve room for a
    /// paragraph the label will never draw.
    private static func cappedHeight(_ s: NSAttributedString, width: CGFloat, lines: Int) -> CGFloat {
        let full = BubbleText.size(s, width: width).height
        let one = lineSizeOf(s, cap: width).height
        return min(full, one * CGFloat(lines))
    }

    // ── A poll ──

    private static func poll(_ p: BubbleBody.PollBody, row b: BubbleRow,
                             originX: CGFloat, columnX: CGFloat, columnW: CGFloat,
                             maxBubble: CGFloat, textColor: UIColor, metaColor: UIColor,
                             topSpacing: CGFloat, y startY: CGFloat,
                             senderNameAttr: NSAttributedString?, senderNameSize: CGSize,
                             forwardedSize: CGSize, forwardedIconW: CGFloat) -> BubbleResult {
        let y = startY
        let pad: CGFloat = 12
        let bubbleW = min(columnW, maxBubble * 0.9)
        let contentW = max(1, bubbleW - pad * 2)
        var innerY = pad

        var quoteRect: CGRect?
        var quoteInner: QuoteInnerPlan?
        if let q = b.quote {
            let (size, inner) = quoteSize(q, textColor: textColor, maxWidth: contentW)
            quoteInner = inner
            quoteRect = CGRect(x: pad, y: innerY, width: contentW, height: size.height)
            innerY += size.height + 8
        }

        let questionAttr = NSAttributedString(string: p.question, attributes: [
            .font: UIFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: textColor])
        let qSize = BubbleText.size(questionAttr, width: contentW)
        let question = CGRect(x: pad, y: innerY, width: contentW, height: qSize.height)
        innerY = question.maxY + 2

        let subtitleAttr = NSAttributedString(
            string: p.multiple ? "Select one or more" : "Select one",
            attributes: [.font: UIFont.systemFont(ofSize: 11),
                         .foregroundColor: textColor.withAlphaComponent(0.7)])
        let sSize = lineSizeOf(subtitleAttr, cap: contentW)
        let subtitle = CGRect(x: pad, y: innerY, width: contentW, height: sSize.height)
        innerY = subtitle.maxY + 12

        let glyphW: CGFloat = 16, gap: CGFloat = 8, percentW: CGFloat = 42, trackH: CGFloat = 6
        var options: [PollPlan.Option] = []
        for (i, opt) in p.options.enumerated() {
            let labelAttr = NSAttributedString(string: opt, attributes: [
                .font: UIFont.systemFont(ofSize: 15), .foregroundColor: textColor])
            let labelW = max(1, contentW - glyphW - gap - percentW - gap)
            let lSize = BubbleText.size(labelAttr, width: labelW)
            let rowH = max(glyphW, lSize.height)
            options.append(PollPlan.Option(
                glyph: CGRect(x: pad, y: innerY + (rowH - glyphW) / 2, width: glyphW, height: glyphW),
                label: CGRect(x: pad + glyphW + gap, y: innerY + (rowH - lSize.height) / 2,
                              width: labelW, height: lSize.height),
                labelAttr: labelAttr,
                percent: CGRect(x: pad + contentW - percentW, y: innerY + (rowH - 16) / 2,
                                width: percentW, height: 16),
                track: CGRect(x: pad, y: innerY + rowH + 5, width: contentW, height: trackH)))
            innerY += rowH + 5 + trackH
            if i < p.options.count - 1 { innerY += 12 }
        }
        innerY += 12

        let totalAttr = NSAttributedString(string: "0 votes", attributes: [
            .font: UIFont.systemFont(ofSize: 11), .foregroundColor: textColor.withAlphaComponent(0.7)])
        let tSize = lineSizeOf(totalAttr, cap: contentW)
        let total = CGRect(x: pad, y: innerY, width: contentW, height: tSize.height)
        innerY = total.maxY + 8

        let metaAttr = BubbleText.meta(b.meta, isMe: b.isMe, color: metaColor)
        let metaSize = BubbleText.lineSize(metaAttr)
        let metaRect = CGRect(x: pad + contentW - metaSize.width, y: innerY,
                              width: metaSize.width, height: metaSize.height)
        innerY = metaRect.maxY + pad

        let plan = PollPlan(question: question, questionAttr: questionAttr,
                            subtitle: subtitle, subtitleAttr: subtitleAttr,
                            options: options, total: total)
        let bubbleRect = CGRect(x: b.isMe ? (columnX + columnW - bubbleW) : columnX,
                                y: y, width: bubbleW, height: innerY)
        var out = BubblePlan(
            bubble: bubbleRect, radii: b.radii, isCapsule: false, fill: b.fill, rim: b.rim,
            text: .zero, meta: metaRect, metaOnOwnLine: true,
            quote: quoteRect, quoteInner: quoteInner,
            bodyAttr: NSAttributedString(), links: [], textColor: textColor, metaColor: metaColor,
            tombstoneIcon: nil, mediaPlan: nil, albumPlan: nil, filePlan: nil,
            locationPlan: nil, contactPlan: nil, pollPlan: plan, linkPlan: nil, storyReplyPlan: nil, voicePlan: nil, pillPlan: nil,
            avatar: nil, senderName: nil, senderNameAttr: nil, verifiedMark: nil,
            forwarded: nil, forwardedIcon: nil, reactions: [], reactionAttrs: [], reactionMine: [],
            failBadge: nil)
        let bottom = decorations(b, plan: &out, bubbleRect: bubbleRect, columnX: columnX,
                                 columnW: columnW, originX: originX, topSpacing: topSpacing,
                                 senderNameAttr: senderNameAttr, senderNameSize: senderNameSize,
                                 forwardedSize: forwardedSize, forwardedIconW: forwardedIconW,
                                 y: bubbleRect.maxY)
        return BubbleResult(plan: out, totalHeight: bottom)
    }

    // ── A shared place ──

    /// ⚠️ THE MAP'S HEIGHT IS STATED, NOT MEASURED. The row is planned before the snapshot exists,
    /// and a height that arrives with the picture is the bloom every note in this file warns about.
    static let locationMapHeight: CGFloat = 140

    private static func location(_ l: BubbleBody.LocationBody, row b: BubbleRow,
                                 originX: CGFloat, columnX: CGFloat, columnW: CGFloat,
                                 maxBubble: CGFloat, textColor: UIColor, metaColor: UIColor,
                                 topSpacing: CGFloat, y startY: CGFloat,
                                 senderNameAttr: NSAttributedString?, senderNameSize: CGSize,
                                 forwardedSize: CGSize, forwardedIconW: CGFloat) -> BubbleResult {
        let y = startY
        let bubbleW = min(columnW, maxBubble * 0.85)
        var innerY: CGFloat = 0
        var quoteRect: CGRect?
        var quoteInner: QuoteInnerPlan?
        if let q = b.quote {
            let (size, inner) = quoteSize(q, textColor: textColor,
                                          maxWidth: max(1, bubbleW - BubbleMetrics.hPad * 2))
            quoteInner = inner
            innerY = BubbleMetrics.vPad
            quoteRect = CGRect(x: BubbleMetrics.hPad, y: innerY,
                               width: bubbleW - BubbleMetrics.hPad * 2, height: size.height)
            innerY += size.height + 4
        }

        let map = CGRect(x: 0, y: innerY, width: bubbleW, height: locationMapHeight)
        innerY = map.maxY

        let pad: CGFloat = 12, gap: CGFloat = 10
        let labelAttr = NSAttributedString(string: l.label, attributes: [
            .font: UIFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: textColor])
        let pinW: CGFloat = 22, chevW: CGFloat = 14
        let labelH = lineSizeOf(labelAttr).height
        let rowH = max(pinW, labelH)
        let rowTop = innerY + pad
        let labelW = max(1, bubbleW - pad * 2 - pinW - gap - 6 - chevW)
        let plan = LocationPlan(
            map: map,
            pin: CGRect(x: pad, y: rowTop + (rowH - pinW) / 2, width: pinW, height: pinW),
            label: CGRect(x: pad + pinW + gap, y: rowTop + (rowH - labelH) / 2,
                          width: labelW, height: labelH),
            labelAttr: labelAttr,
            chevron: CGRect(x: bubbleW - pad - chevW, y: rowTop + (rowH - chevW) / 2,
                            width: chevW, height: chevW))

        let metaAttr = BubbleText.meta(b.meta, isMe: b.isMe, color: metaColor)
        let metaSize = BubbleText.lineSize(metaAttr)
        let metaRect = CGRect(x: bubbleW - pad - metaSize.width, y: rowTop + rowH + 8,
                              width: metaSize.width, height: metaSize.height)
        innerY = metaRect.maxY + pad

        let bubbleRect = CGRect(x: b.isMe ? (columnX + columnW - bubbleW) : columnX,
                                y: y, width: bubbleW, height: innerY)
        var out = BubblePlan(
            bubble: bubbleRect, radii: b.radii, isCapsule: false, fill: b.fill, rim: b.rim,
            text: .zero, meta: metaRect, metaOnOwnLine: true,
            quote: quoteRect, quoteInner: quoteInner,
            bodyAttr: NSAttributedString(), links: [], textColor: textColor, metaColor: metaColor,
            tombstoneIcon: nil, mediaPlan: nil, albumPlan: nil, filePlan: nil,
            locationPlan: plan, contactPlan: nil, pollPlan: nil, linkPlan: nil, storyReplyPlan: nil, voicePlan: nil, pillPlan: nil,
            avatar: nil, senderName: nil, senderNameAttr: nil, verifiedMark: nil,
            forwarded: nil, forwardedIcon: nil, reactions: [], reactionAttrs: [], reactionMine: [],
            failBadge: nil)
        let bottom = decorations(b, plan: &out, bubbleRect: bubbleRect, columnX: columnX,
                                 columnW: columnW, originX: originX, topSpacing: topSpacing,
                                 senderNameAttr: senderNameAttr, senderNameSize: senderNameSize,
                                 forwardedSize: forwardedSize, forwardedIconW: forwardedIconW,
                                 y: bubbleRect.maxY)
        return BubbleResult(plan: out, totalHeight: bottom)
    }

    // ── A shared contact ──

    private static func contact(_ c: BubbleBody.ContactBody, row b: BubbleRow,
                                originX: CGFloat, columnX: CGFloat, columnW: CGFloat,
                                maxBubble: CGFloat, textColor: UIColor, metaColor: UIColor,
                                topSpacing: CGFloat, y startY: CGFloat,
                                senderNameAttr: NSAttributedString?, senderNameSize: CGSize,
                                forwardedSize: CGSize, forwardedIconW: CGFloat) -> BubbleResult {
        let y = startY
        let bubbleW = min(columnW, maxBubble)
        let pad: CGFloat = 12, gap: CGFloat = 10, avatar: CGFloat = 44, chevW: CGFloat = 14
        var innerY: CGFloat = 0
        var quoteRect: CGRect?
        var quoteInner: QuoteInnerPlan?
        if let q = b.quote {
            let (size, inner) = quoteSize(q, textColor: textColor, maxWidth: max(1, bubbleW - pad * 2))
            quoteInner = inner
            innerY = pad
            quoteRect = CGRect(x: pad, y: innerY, width: bubbleW - pad * 2, height: size.height)
            innerY += size.height + 10
        } else {
            innerY = pad
        }

        let nameAttr = NSAttributedString(string: c.name, attributes: [
            .font: UIFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: textColor])
        let nameH = lineSizeOf(nameAttr).height
        let rowH = max(avatar, nameH)
        let nameW = max(1, bubbleW - pad * 2 - avatar - gap - 6 - chevW)
        var plan = ContactPlan(
            avatar: CGRect(x: pad, y: innerY + (rowH - avatar) / 2, width: avatar, height: avatar),
            name: CGRect(x: pad + avatar + gap, y: innerY + (rowH - nameH) / 2,
                         width: nameW, height: nameH),
            nameAttr: nameAttr,
            chevron: CGRect(x: bubbleW - pad - chevW, y: innerY + (rowH - chevW) / 2,
                            width: chevW, height: chevW),
            button: nil, buttonLabel: nil, buttonAttr: nil)
        innerY += rowH + 10

        let metaAttr = BubbleText.meta(b.meta, isMe: b.isMe, color: metaColor)
        let metaSize = BubbleText.lineSize(metaAttr)
        let metaRect = CGRect(x: bubbleW - pad - metaSize.width, y: innerY,
                              width: metaSize.width, height: metaSize.height)
        innerY = metaRect.maxY + 10

        if c.canMessage {
            let attr = NSAttributedString(string: "message", attributes: [
                .font: UIFont.systemFont(ofSize: 16, weight: .medium), .foregroundColor: textColor])
            let size = lineSizeOf(attr)
            let button = CGRect(x: pad, y: innerY, width: bubbleW - pad * 2, height: 40)
            plan.button = button
            plan.buttonAttr = attr
            plan.buttonLabel = CGRect(x: button.midX - size.width / 2,
                                      y: button.midY - size.height / 2,
                                      width: size.width, height: size.height)
            innerY = button.maxY
        }
        innerY += pad

        let bubbleRect = CGRect(x: b.isMe ? (columnX + columnW - bubbleW) : columnX,
                                y: y, width: bubbleW, height: innerY)
        var out = BubblePlan(
            bubble: bubbleRect, radii: b.radii, isCapsule: false, fill: b.fill, rim: b.rim,
            text: .zero, meta: metaRect, metaOnOwnLine: true,
            quote: quoteRect, quoteInner: quoteInner,
            bodyAttr: NSAttributedString(), links: [], textColor: textColor, metaColor: metaColor,
            tombstoneIcon: nil, mediaPlan: nil, albumPlan: nil, filePlan: nil,
            locationPlan: nil, contactPlan: plan, pollPlan: nil, linkPlan: nil, storyReplyPlan: nil, voicePlan: nil, pillPlan: nil,
            avatar: nil, senderName: nil, senderNameAttr: nil, verifiedMark: nil,
            forwarded: nil, forwardedIcon: nil, reactions: [], reactionAttrs: [], reactionMine: [],
            failBadge: nil)
        let bottom = decorations(b, plan: &out, bubbleRect: bubbleRect, columnX: columnX,
                                 columnW: columnW, originX: originX, topSpacing: topSpacing,
                                 senderNameAttr: senderNameAttr, senderNameSize: senderNameSize,
                                 forwardedSize: forwardedSize, forwardedIconW: forwardedIconW,
                                 y: bubbleRect.maxY)
        return BubbleResult(plan: out, totalHeight: bottom)
    }

    // ── Shared pieces of a media-ish bubble ──

    /// One line, capped. `lineSize` never wraps; this is for a label that truncates at a width.
    private static func lineSizeOf(_ s: NSAttributedString, cap: CGFloat = .greatestFiniteMagnitude) -> CGSize {
        let full = BubbleText.lineSize(s)
        return CGSize(width: min(cap, full.width), height: full.height)
    }

    private struct CaptionResult {
        var block: CGRect; var text: CGRect; var attr: NSAttributedString
        var metaOnOwnLine: Bool; var meta: CGRect
    }

    /// The caption under a picture or a mosaic: the media's full width, 12pt insets, and the same
    /// two footer branches the text bubble uses.
    private static func captionBlock(_ caption: BubbleBody.TextBody, meta: MetaChrome,
                                     metaAttr: NSAttributedString, row b: BubbleRow,
                                     textColor: UIColor, accent: UIColor,
                                     bubbleW: CGFloat, top: CGFloat) -> CaptionResult {
        let inset: CGFloat = 12
        let avail = max(1, bubbleW - inset * 2)
        let built = BubbleText.build(caption, meta: meta, isMe: b.isMe, textColor: textColor,
                                     accent: accent, textAvail: avail)
        let size = BubbleText.size(built.body, width: avail)
        let metaSize = BubbleText.lineSize(metaAttr)
        let textTop = top + 8
        var bottom = textTop + size.height
        let metaRect: CGRect
        if built.metaOnOwnLine {
            bottom += 2
            metaRect = CGRect(x: inset + avail - metaSize.width, y: bottom,
                              width: metaSize.width, height: metaSize.height)
            bottom += metaSize.height
        } else {
            metaRect = CGRect(x: inset + avail - metaSize.width, y: bottom - metaSize.height - 1,
                              width: metaSize.width, height: metaSize.height)
        }
        bottom += 10
        return CaptionResult(block: CGRect(x: 0, y: top, width: bubbleW, height: bottom - top),
                             text: CGRect(x: inset, y: textTop, width: avail, height: size.height),
                             attr: built.body, metaOnOwnLine: built.metaOnOwnLine, meta: metaRect)
    }

    /// The footer floating on a picture in its own dark capsule: 7pt padding inside, 7pt in from
    /// the picture's corner.
    private static func floatingMeta(_ attr: NSAttributedString,
                                     over rect: CGRect) -> (capsule: CGRect, text: CGRect) {
        let size = BubbleText.lineSize(attr)
        // ⚠️ THE HEIGHT COMES FROM THE FONT, NOT FROM THE MEASURED STRING. Anything the footer ever
        // carries — the tick today, whatever is added later — is drawn inside a text line, and a
        // line's height is a property of the font. Taking it from `boundingRect` meant one oversized
        // attachment could grow the pill on one side only, which is exactly the bug this pairs with
        // (see the tick's bounds in `BubbleText.meta`). Fixing that one alone would leave the door
        // open; taking the height from the font closes it.
        let lineH = ceil(BubbleMetrics.metaFont.lineHeight)
        let hPad: CGFloat = 7, vPad: CGFloat = 3
        let capsule = CGRect(x: rect.maxX - 7 - (size.width + hPad * 2),
                             y: rect.maxY - 7 - (lineH + vPad * 2),
                             width: size.width + hPad * 2, height: lineH + vPad * 2)
        // Centred on the capsule rather than offset from its corner, so the two cannot drift apart
        // if either padding is ever changed on its own.
        let text = CGRect(x: capsule.midX - size.width / 2,
                          y: capsule.midY - lineH / 2,
                          width: size.width, height: lineH)
        return (capsule, text)
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
        // ⚠️ 1.2, DOWN FROM 1.3 — his screenshot, 2026-08-27: a 9:16 photo fills most of the screen,
        // "make it zoom out but not too much, only slightly". This multiplier is the whole knob, and
        // because the comfort rule below ties the width to the height, moving it scales a tall photo
        // in both directions at once. At a 272pt max bubble it takes a 9:16 from 199 × 354 to
        // 184 × 326 — about 8% off, which is the "small number" he asked for rather than a resize.
        // Anything that does not reach `comfortW` (3:4, square, every landscape) is untouched either
        // way, so this moves the tall case only.
        let maxH = boxMax * 1.2
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

        // ⛔ THE SNIPPET RUNS TO TWO LINES NOW — his side-by-side, 2026-08-27: the reference app
        // shows two lines of the quoted message where ours cut it to one. A short quote keeps the
        // 38pt box exactly as before; only a snippet that actually wraps grows it by one line.
        let nameH = ceil(BubbleMetrics.quoteNameFont.lineHeight)
        let snippetLineH = ceil(BubbleMetrics.quoteTextFont.lineHeight)
        let snippetH = min(max(snippetLineH, BubbleText.size(snippetAttr, width: textW).height),
                           snippetLineH * 2)
        let stackH = nameH + 1 + snippetH
        let boxH = max(quoteBoxHeight, stackH)

        let outer = CGSize(width: min(maxWidth, ceil(fixed + textW)), height: boxH + vPad * 2)

        // Inner rects, in the quote box's own coordinates. Laid out against the FILLED width by the
        // caller; the text column takes whatever is left, which is how a filled quote keeps its
        // accent line, name and snippet put while only the box grows.
        var x = hPad
        let accent = CGRect(x: x, y: vPad, width: accentW, height: boxH)
        x += accentW + gap
        var thumb: CGRect?
        if thumbSize.width > 0 {
            thumb = CGRect(x: x, y: vPad + (boxH - thumbSize.height) / 2,
                           width: thumbSize.width, height: thumbSize.height)
            x += thumbSize.width + gap
        }
        // The pair is centred inside the box, with the VStack's 1pt spacing.
        let top = vPad + (boxH - stackH) / 2
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
        failBadge?.origin.y += dy
        for i in reactions.indices { reactions[i].origin.y += dy }
    }
}
