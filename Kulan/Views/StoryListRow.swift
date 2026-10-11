import SwiftUI

/// THE LIST LAYOUT OF THE STORIES TAB — owner, 2026-10-11, with his own screenshot: one person per
/// row, a tall picture on the left, name and time beside it, "Recent updates" over the friends.
///
/// ⛔ A SECOND LAYOUT, NOT A REPLACEMENT. The two-column grid (`GlowStoryCardView`) is untouched and
/// comes back by setting `AppFeatures.storyList` to false. His words: "do not delete, replace, or
/// destroy my original design".
///
/// ⚠️ THE PICTURE KEEPS HIS SIZE, ONLY THE CORNER AND THE NAME FOLLOW THE REFERENCE APP. Its list
/// uses a much smaller picture; he said by name not to shrink to it. `thumbSize` is measured off his
/// screenshot (148×213 px on a 924 px-wide shot of a 393 pt screen).
struct StoryListRow: View {
    static let thumbSize = CGSize(width: 63, height: 91)
    static let corner: CGFloat = 12          // the reference app's thumbnail corner
    static let margin: CGFloat = 20
    static let rowSpacing: CGFloat = 24

    let thumbUrl: String
    var blurThumb: String = ""
    let title: String
    let subtitle: String
    /// The key the open/close morph and the long press look the picture up by — the group's id,
    /// the same string the grid card registers, so `openStoryFromRow` lands on it unchanged.
    var rectKey: String? = nil
    /// The camera circle on the right of my own row.
    var onCamera: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 16) {
            thumb
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))   // the reference app's name size
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let onCamera {
                Button(action: onCamera) {
                    Image(systemName: "camera")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(.primary)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color(uiColor: .secondarySystemFill)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add Story")
            }
        }
        .padding(.horizontal, Self.margin)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var thumb: some View {
        let shape = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
        Group {
            if thumbUrl.isEmpty {
                // No story yet: the same tile shape, holding a plus, so the row does not change
                // shape when the first story lands.
                shape.fill(Color(uiColor: .secondarySystemFill))
                    .overlay(Image(systemName: "plus").font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.secondary))
            } else {
                StoryImage(url: thumbUrl, maxPixels: StoryImage.cardPixels, blurThumb: blurThumb)
            }
        }
        .frame(width: Self.thumbSize.width, height: Self.thumbSize.height)
        .clipShape(shape)
        .modifier(MediaRectReporter(id: rectKey ?? "", scope: .storyRow, cornerRadius: Self.corner))
    }

    /// "10h ago" — the wording on his screenshot.
    static func ago(_ d: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(d)))
        if s < 60 { return "Just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86_400 { return "\(s / 3600)h ago" }
        return "\(s / 86_400)d ago"
    }
}
