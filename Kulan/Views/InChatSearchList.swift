import SwiftUI
import UIKit

/// ⛔ IN-CHAT SEARCH "SHOW AS LIST" — owner 2026-10-14: "add Show as List; the page looks like the
/// reference's text search list; copy it, don't make mistakes".
///
/// Read off the reference app's source, not a screenshot:
///  · its list mode draws every result as a CHAT-LIST row of the MESSAGE (`ChatInlineSearchResults-
///    ListComponent` builds `ChatListItem(content: .peer(messages: [message], peer: author,
///    displayAsMessage: true))`): the author's photo, the author's name, the message's date with its
///    read ticks, and the text, newest first;
///  · tapping one navigates to that message in the chat and turns list mode off
///    (`navigateToMessage(... scrollPosition: .center(.bottom))` + `updatedDisplayHistoryFilterAsList(false)`).
/// The text is cut to start a little before the first match ("…" in front) so the match is visible
/// on one line, and every matched word is drawn in the primary colour on the secondary text.
struct InChatSearchRow: Identifiable {
    let id: String
    let name: String
    let photoUrl: String?
    let date: Date
    let text: String
    let outgoing: Bool
    let read: Bool
    let thumb: UIImage?
    /// A channel's row: its photo in the channel's shape (owner 2026-10-30).
    var squircle = false
}

struct InChatSearchList: View {
    let rows: [InChatSearchRow]          // newest first
    let terms: [String]
    var bottomInset: CGFloat
    var onSelect: (String) -> Void

    // Chat-list metrics (the reference's row: 60pt photo, 10pt gaps, 76pt rows).
    private static let avatar: CGFloat = 60
    private static let rowHeight: CGFloat = 76
    private static let leading: CGFloat = 16
    private static let gap: CGFloat = 10

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows) { row in
                    Button { onSelect(row.id) } label: { rowView(row) }
                        .buttonStyle(InChatSearchRowStyle())
                }
            }
        }
        .contentMargins(.bottom, bottomInset, for: .scrollContent)
        .scrollDismissesKeyboard(.immediately)
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    private func rowView(_ row: InChatSearchRow) -> some View {
        HStack(spacing: Self.gap) {
            AvatarView(name: row.name, photoUrl: row.photoUrl, size: Self.avatar)
                .avatarSquircle(row.squircle)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(row.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if row.outgoing { ticks(read: row.read) }
                    Text(Self.dateText(row.date))
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    if let thumb = row.thumb {
                        Image(uiImage: thumb).resizable().scaledToFill()
                            .frame(width: 20, height: 20)
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    }
                    Text(Self.snippet(row.text, terms: terms))
                        .font(.system(size: 16))
                        .lineLimit(1)
                }
            }
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color(.separator)).frame(height: 1 / UIScreen.main.scale)
                    .padding(.trailing, -Self.leading)
            }
        }
        .padding(.leading, Self.leading).padding(.trailing, Self.leading)
        .frame(height: Self.rowHeight)
        .contentShape(Rectangle())
    }

    /// One tick sent, two once read; blue when read, as on the chat list.
    private func ticks(read: Bool) -> some View {
        ZStack(alignment: .leading) {
            Image(systemName: "checkmark")
            if read { Image(systemName: "checkmark").offset(x: 5) }
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(read ? Color.accentColor : Color.secondary)
        .padding(.trailing, read ? 5 : 0)
    }

    /// The chat list's date rule: the time today, the weekday within the last week, the date before.
    static func dateText(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day,
           days < 7 {
            return d.formatted(.dateTime.weekday(.abbreviated))
        }
        return d.formatted(date: .numeric, time: .omitted)
    }

    /// The message on one line with its first match in view, matches in the primary colour.
    static func snippet(_ raw: String, terms: [String]) -> AttributedString {
        let text = raw.replacingOccurrences(of: "\n", with: " ")
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        var start = text.startIndex
        var prefix = ""
        let first = terms.compactMap { text.range(of: $0, options: options)?.lowerBound }.min()
        if let first, text.distance(from: text.startIndex, to: first) > 18 {
            // Back up a few characters, then to the start of that word.
            var s = text.index(first, offsetBy: -12, limitedBy: text.startIndex) ?? text.startIndex
            while s > text.startIndex, !text[text.index(before: s)].isWhitespace { s = text.index(before: s) }
            start = s
            prefix = "…"
        }
        let shown = prefix + String(text[start...])
        var out = AttributedString(shown)
        out.foregroundColor = Color.secondary
        for term in terms where !term.isEmpty {
            var from = shown.startIndex
            while let r = shown.range(of: term, options: options, range: from..<shown.endIndex) {
                if let a = Range(r, in: out) { out[a].foregroundColor = Color.primary }
                from = r.upperBound
            }
        }
        return out
    }
}

/// The row darkens while pressed, as a list row does.
private struct InChatSearchRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color(.systemGray5) : Color.clear)
    }
}
