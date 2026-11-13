import SwiftUI
import UIKit

/// The chat list card itself (owner 2026-11-13; the rest of the feature is in ChatListCards.swift):
/// the app's liquid glass, inset 16 each side, radius 20 (a capsule when it is one line tall), an
/// optional 40pt picture on the left, title over up to three lines of subtitle, and on the right
/// the X, or an arrow for a card that cannot be closed but goes somewhere.
/// Title and subtitle take inline Markdown: bold, italic, links, emoji.
struct ChatCardView: View {
    let card: ChatCard
    let onTap: () -> Void
    let onClose: () -> Void
    /// The card's height changed after it was measured (its picture failed to load).
    var onResize: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            if let image = card.image { ChatCardPicture(url: image, onFail: onResize) }
            ChatCardText(card: card)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 16)
        .padding(.trailing, hasTrailing ? 40 : 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        // A tap gesture, not a Button: a Button would take the taps meant for links in the text.
        .onTapGesture(perform: onTap)
        .accessibilityAddTraits(.isButton)
        .overlay(alignment: .trailing) { trailing }
        .liquidGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
        // Links inside the text open the way the card's own link does.
        .environment(\.openURL, OpenURLAction { url in ChatCards.open(url); return .handled })
        .tint(Color.fariinAction)
    }

    private var hasTrailing: Bool { card.dismissible || card.link != nil }

    @ViewBuilder private var trailing: some View {
        if card.dismissible {
            Button(action: onClose) { trailingGlyph("xmark") }
                .buttonStyle(.plain)
                .padding(.trailing, 4)
                .accessibilityLabel("Close")
        } else if card.link != nil {
            trailingGlyph("chevron.right")
                .padding(.trailing, 4)
                .allowsHitTesting(false)   // the whole card is the tap
        }
    }

    private func trailingGlyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 20, height: 20)
            .padding(8)   // the extra hit area around the glyph
            .contentShape(Rectangle())
    }
}

/// Title and subtitle, each read as inline Markdown; the raw text when it does not parse.
private struct ChatCardText: View {
    let card: ChatCard

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Self.styled(card.title))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if !card.subtitle.isEmpty {
                Text(Self.styled(card.subtitle))
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func styled(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

/// The card's picture: 40 x 40, radius 10, from the app's image cache, downloaded into it when
/// missing. A soft grey square while loading; a failed load removes the slot.
private struct ChatCardPicture: View {
    let url: String
    let onFail: () -> Void
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        if !failed {
            ZStack {
                Color.gray.opacity(0.18)
                if let image { Image(uiImage: image).resizable().scaledToFill() }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .task(id: url) { await load() }
        }
    }

    private func load() async {
        if let hit = await DiskImageCache.shared.image(for: url) { image = hit; return }
        if let u = URL(string: url),
           let got = try? await URLSession.shared.data(from: u),
           (got.1 as? HTTPURLResponse)?.statusCode == 200,
           let ui = UIImage(data: got.0) {
            DiskImageCache.shared.store(ui, data: got.0, for: url)
            guard !Task.isCancelled else { return }
            image = ui
            return
        }
        guard !Task.isCancelled else { return }
        failed = true
        onFail()
    }
}
