import XCTest
import UIKit
@testable import Kulan

// The story-reply card and the reply under it, laid out by the real `MessageRowLayout.plan`.
// Owner 2026-10-13: "sometimes a big gap between the reply and its story preview". The card must sit
// the same distance above its bubble whether or not a date pill or the unread line is over the row.
@MainActor
final class StoryReplyLayoutTests: XCTestCase {

    private func row(isMe: Bool, dateHeader: Bool, unread: Bool) -> MessageRowModel {
        let reply = StoryReplyChrome(storyId: "s1", authorId: isMe ? "them" : "me",
                                     caption: isMe ? "You replied to their story" : "Abdi replied to your story",
                                     thumbUrl: "https://example.invalid/t.jpg", anchorKey: "storyreply-m1",
                                     unavailable: false, opens: true)
        let bubble = BubbleRow(isMe: isMe, body: .jumbomoji("🔥"), fill: isMe ? .solid(0x007AFF) : .received,
                               radii: .cluster(isMe: isMe, first: true, last: true),
                               meta: MetaChrome(timeText: "9:01 AM", edited: false, tick: .read,
                                                bornAt: nil, expiresAt: nil),
                               sender: nil, quote: nil, storyReply: reply, forwarded: false, reactions: [],
                               showsFailedBadge: false, rim: false, canSwipeToReply: true,
                               opensOnTap: false, canDoubleTapReact: true)
        let pill = NoticeRow(text: "Today", symbol: nil, style: .pill, tapTargetId: nil,
                             onWallpaper: false, wallpaperBlur: nil)
        return MessageRowModel(id: "m1", dateHeader: dateHeader ? pill : nil, showsUnreadDivider: unread,
                               content: .bubble(bubble), topSpacing: 8, selecting: false,
                               wasSelecting: false, selected: false, selectionTint: 0,
                               highlighted: false, onWallpaper: false, wallpaperBlur: nil)
    }

    /// Card bottom to bubble top, and caption top to row content top.
    private func geometry(_ m: MessageRowModel) throws -> (gap: CGFloat, captionY: CGFloat, headerBottom: CGFloat) {
        let p = MessageRowLayout.plan(m, width: 393)
        guard case .bubble(let b) = p.body else { throw XCTSkip("not a bubble plan") }
        let sr = try XCTUnwrap(b.storyReplyPlan)
        let thumb = try XCTUnwrap(sr.thumb)
        let headerBottom = max(p.dateHeader?.capsule.maxY ?? 0, p.divider?.label.maxY ?? 0)
        return (b.bubble.minY - thumb.maxY, sr.caption.minY, headerBottom)
    }

    func testCardStaysOnItsBubbleUnderADatePillOrUnreadLine() throws {
        for isMe in [false, true] {
            let plain = try geometry(row(isMe: isMe, dateHeader: false, unread: false))
            for (header, unread) in [(true, false), (false, true), (true, true)] {
                let g = try geometry(row(isMe: isMe, dateHeader: header, unread: unread))
                let what = "isMe=\(isMe) date=\(header) unread=\(unread)"
                // Same gap as the row with nothing above it.
                XCTAssertEqual(g.gap, plain.gap, accuracy: 0.5, "card-to-bubble gap changed: \(what)")
                // And the card is below the pill / line, never drawn over it.
                XCTAssertGreaterThanOrEqual(g.captionY, g.headerBottom, "caption overlaps the header: \(what)")
            }
            XCTAssertLessThan(plain.gap, 20, "card-to-bubble gap is large even with nothing above (isMe=\(isMe))")
        }
    }
}
