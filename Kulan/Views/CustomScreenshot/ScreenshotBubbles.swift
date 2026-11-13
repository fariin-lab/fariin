import SwiftUI
import UIKit

// Customize screenshot (owner 2026-11-13): how one message is drawn in the picture.
//
// A simplified copy of the chat's bubble: the same fonts, corner sizes, side margins, colours and
// tick marks as the UIKit rows (`BubbleMetrics`, `BubblePalette`, `BubbleTicks`). It is SwiftUI so
// the same view can be shown in the editor and rendered offscreen to an image.

/// Where a row sits among its neighbours. Worked out from the rows that are still in the picture,
/// so removing a message moves its day pill and the sender's name to the next one, as the chat would.
struct ShotPlacement: Equatable {
    var showDay = true
    var showName = false
    var joinsPrev = false
    var joinsNext = false

    static func of(_ rows: [ShotMessage]) -> [ShotPlacement] {
        rows.indices.map { i in
            let m = rows[i]
            let prev: ShotMessage? = i > 0 ? rows[i - 1] : nil
            let next: ShotMessage? = i + 1 < rows.count ? rows[i + 1] : nil
            let showDay = prev?.day != m.day
            let joinsPrev = !showDay && sameRun(m, prev)
            return ShotPlacement(showDay: showDay,
                                 showName: m.senderName != nil && !joinsPrev,
                                 joinsPrev: joinsPrev,
                                 joinsNext: sameRun(m, next))
        }
    }

    /// Two bubbles from one person on one day are drawn as one block, as the chat draws them.
    private static func sameRun(_ m: ShotMessage, _ o: ShotMessage?) -> Bool {
        guard let o, o.day == m.day, o.kind != .system, m.kind != .system else { return false }
        return o.senderUid == m.senderUid
    }
}

/// One row of the picture: an optional day pill, then the message.
struct ShotRowView: View {
    let message: ShotMessage
    let look: ShotLook
    let place: ShotPlacement
    /// The width the row is laid out in: the screen for a saved picture, the card in the editor.
    let rowWidth: CGFloat
    var cover = ShotCover()
    /// Set in the editor only: the text becomes selectable and its menu hides words.
    var actions: ShotTextActions? = nil

    var body: some View {
        VStack(spacing: 6) {
            if place.showDay {
                ShotChip(text: message.day, look: look).padding(.vertical, 4)
            }
            content
        }
        .padding(.horizontal, BubbleMetrics.rowMargin)
        .padding(.bottom, place.joinsNext ? 2 : 8)
    }

    @ViewBuilder private var content: some View {
        if message.kind == .system {
            ShotChip(text: message.text, look: look, hidden: cover.whole)
                .frame(maxWidth: .infinity)
        } else {
            HStack(spacing: 0) {
                if message.isMe { Spacer(minLength: 0) }
                ShotBubble(message: message, look: look, place: place,
                           maxWidth: BubbleMetrics.maxBubbleWidth(in: rowWidth),
                           cover: cover, actions: actions)
                if !message.isMe { Spacer(minLength: 0) }
            }
        }
    }
}

/// A small centred capsule: day labels and group events.
struct ShotChip: View {
    let text: String
    let look: ShotLook
    var hidden = false

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(look.chipText)
            .multilineTextAlignment(.center)
            .opacity(hidden ? 0 : 1)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .overlay { if hidden { ShotDustView(color: look.chipText) } }
            .background(look.chipFill, in: Capsule())
    }
}

/// The bubble itself.
struct ShotBubble: View {
    let message: ShotMessage
    let look: ShotLook
    let place: ShotPlacement
    let maxWidth: CGFloat
    let cover: ShotCover
    let actions: ShotTextActions?

    private var textColor: Color { message.isMe ? .white : look.receivedText }
    private var metaColor: Color { message.isMe ? look.sentMeta : look.receivedMeta }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if let image = message.image { picture(image) }
            mainLine
        }
        .padding(.horizontal, BubbleMetrics.hPad - 3)
        .padding(.vertical, BubbleMetrics.vPad - 3)
        .background { fill }
        .frame(maxWidth: maxWidth, alignment: message.isMe ? .trailing : .leading)
    }

    @ViewBuilder private var fill: some View {
        let shape = UnevenRoundedRectangle(cornerRadii: radii, style: .continuous)
        if message.isMe {
            shape.fill(look.sentFill)
        } else {
            shape.fill(look.receivedFill)
        }
    }

    private var radii: RectangleCornerRadii {
        let big = BubbleMetrics.bigCorner, small = BubbleMetrics.smallCorner
        let top = place.joinsPrev ? small : big
        let bottom = place.joinsNext ? small : big
        return message.isMe
            ? RectangleCornerRadii(topLeading: big, bottomLeading: big, bottomTrailing: bottom, topTrailing: top)
            : RectangleCornerRadii(topLeading: top, bottomLeading: bottom, bottomTrailing: big, topTrailing: big)
    }

    @ViewBuilder private var header: some View {
        if place.showName, let name = message.senderName {
            Text(name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(BubblePalette.senderColor(message.senderUid)))
                .lineLimit(1)
        }
        if message.forwarded {
            Label("Forwarded", systemImage: "arrowshape.turn.up.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(metaColor)
        }
        if let replyText = message.replyText {
            ShotQuote(name: message.replyName ?? "", text: replyText, isMe: message.isMe,
                      look: look, hidden: cover.whole)
        }
    }

    private func picture(_ image: UIImage) -> some View {
        let w = min(maxWidth - BubbleMetrics.hPad * 2, 240)
        let ratio = image.size.width > 0 ? image.size.height / image.size.width : 1
        return Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: w, height: min(max(w * ratio, 80), 320))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .wholeCover(cover.whole, color: textColor)
    }

    /// The text (or a media chip) with the time and ticks on the same line, as the chat does it.
    private var mainLine: some View {
        HStack(alignment: .lastTextBaseline, spacing: BubbleMetrics.metaInlineGap) {
            bodyText
            meta
        }
    }

    @ViewBuilder private var bodyText: some View {
        switch message.kind {
        case .media(let symbol, let label):
            mediaLabel(symbol: symbol, label: label)
        default:
            if let actions, !cover.whole {
                ShotSelectableText(text: message.text, color: UIColor(textColor),
                                   dustColor: UIColor(textColor), cover: cover, actions: actions)
            } else {
                cover.text(message.text)
                    .font(Font(BubbleMetrics.bodyFont as CTFont))
                    .foregroundStyle(textColor)
                    .textRenderer(ShotDustRenderer(color: textColor))
                    .fixedSize(horizontal: false, vertical: true)
                    .wholeCover(cover.whole, color: textColor)
            }
        }
    }

    private func mediaLabel(symbol: String, label: String) -> some View {
        let caption = message.text.isEmpty ? label : message.text
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            if message.image == nil || !message.text.isEmpty {
                if message.text.isEmpty { Image(systemName: symbol) }
                Text(caption)
            }
        }
        .font(Font(BubbleMetrics.bodyFont as CTFont))
        .foregroundStyle(textColor)
        .wholeCover(cover.whole, color: textColor)
    }

    private var meta: some View {
        HStack(spacing: 3) {
            if message.edited { Text("edited") }
            Text(message.time, format: .dateTime.hour().minute())
            if let tick = BubbleTicks.image(message.tick) {
                Image(uiImage: tick).renderingMode(.template)
            }
        }
        .font(Font(BubbleMetrics.metaFont as CTFont))
        .foregroundStyle(metaColor)
        .lineLimit(1)
        .fixedSize()
    }
}

/// The quoted message above a reply.
private struct ShotQuote: View {
    let name: String
    let text: String
    let isMe: Bool
    let look: ShotLook
    let hidden: Bool

    var body: some View {
        let ink: Color = isMe ? .white : look.receivedText
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(ink.opacity(0.8)).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13, weight: .semibold))
                Text(text).font(.system(size: 13)).lineLimit(2).opacity(0.85)
            }
            .foregroundStyle(ink)
            .wholeCover(hidden, color: ink)
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(ink.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
    }
}

private extension View {
    /// Keeps the size (so the bubble keeps its shape) but draws dots instead of the content.
    func wholeCover(_ on: Bool, color: Color) -> some View {
        self.opacity(on ? 0 : 1)
            .overlay { if on { ShotDustView(color: color) } }
    }
}

/// The footer of every picture: "Fariin" on the left, the logo on the right, in the colour of the
/// incoming bubbles so it sits quietly on any background (owner 2026-11-13: always on).
struct ShotFooter: View {
    let look: ShotLook

    private var logo: UIImage? {
        UIImage(named: "LaunchLogo", in: nil,
                compatibleWith: UITraitCollection(userInterfaceStyle: look.dark ? .dark : .light))
    }

    var body: some View {
        HStack {
            Text("Fariin").font(.system(size: 16, weight: .bold))
            Spacer(minLength: 0)
            if let logo {
                Image(uiImage: logo)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
            }
        }
        .foregroundStyle(look.footerInk)
        .frame(height: ScreenshotExporter.footerHeight)
        .padding(.horizontal, 20)
    }
}
