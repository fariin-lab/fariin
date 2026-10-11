import SwiftUI

/// THE LIST LAYOUT OF THE STORIES TAB — owner, 2026-10-11, with his own screenshot: one person per
/// row, a tall picture on the left, name and time beside it, "Recent updates" over the friends.
///
/// ⛔ A SECOND LAYOUT, NOT A REPLACEMENT. The two-column grid (`GlowStoryCardView`) is untouched and
/// comes back by setting `AppFeatures.storyList` to false. His words: "do not delete, replace, or
/// destroy my original design".
///
/// ⚠️ THE PICTURE KEEPS HIS SIZE, ONLY THE NAME FOLLOWS THE REFERENCE APP. Its list uses a much
/// smaller picture; he said by name not to shrink to it. Measured off his screenshot at 63×91, then
/// "add 2" (2026-10-11 second pass) → 65×93.
struct StoryListRow: View {
    static let thumbSize = CGSize(width: 65, height: 93)
    /// ⛔ 14, CONTINUOUS — owner, 2026-10-11: "corners not smooth, use iOS 26 Apple corners". The
    /// continuous (squircle) curve at a slightly larger radius, the shape the system draws.
    static let corner: CGFloat = 14
    static let margin: CGFloat = 20
    static let rowSpacing: CGFloat = 24
    /// The author's face on the picture's bottom-right corner, ring included.
    static let face: CGFloat = 26
    static let ring: CGFloat = 2
    static let gap: CGFloat = 2

    let thumbUrl: String
    var blurThumb: String = ""
    let title: String
    let subtitle: String
    /// The face in the corner. nil photo still draws the initials face.
    var authorName: String = ""
    var authorPhoto: String? = nil
    var showsFace = true
    var seen = false
    /// ⛔ THE STACK — owner, 2026-10-11, as the reference app draws My Story with more than one
    /// story: the previous picture peeks out behind the newest one. Empty = no stack.
    var backThumbUrl: String = ""
    var backBlurThumb: String = ""
    /// The key the open/close morph and the long press look the picture up by — the group's id,
    /// the same string the grid card registers, so `openStoryFromRow` lands on it unchanged.
    var rectKey: String? = nil
    /// The camera circle on the right of my own row.
    var onCamera: (() -> Void)? = nil

    @Environment(\.colorScheme) private var scheme

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Self.corner, style: .continuous) }

    var body: some View {
        HStack(spacing: 18) {
            thumbStack
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
                // Owner 2026-10-11: the add-story mark, on Liquid Glass.
                Button(action: onCamera) {
                    Image("ic_new_story").renderingMode(.template).resizable().scaledToFit()
                        .frame(width: 22, height: 22)
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Add Story")
            }
        }
        .padding(.horizontal, Self.margin)
        .contentShape(Rectangle())
    }

    /// Back picture (if any) → front picture → face. The face hangs past the picture's corner, so
    /// it sits OUTSIDE the rect reporter: the morph and the lift fly the picture alone.
    private var thumbStack: some View {
        ZStack(alignment: .bottomTrailing) {
            if !backThumbUrl.isEmpty {
                // The reference app's stack: same card, a little shorter, nudged left and dimmed,
                // so it reads as "behind" rather than as a second story beside it.
                StoryImage(url: backThumbUrl, maxPixels: StoryImage.cardPixels, blurThumb: backBlurThumb)
                    .frame(width: Self.thumbSize.width, height: Self.thumbSize.height)
                    .overlay(Color.black.opacity(0.35))
                    .clipShape(shape)
                    .scaleEffect(0.88, anchor: .leading)
                    .offset(x: -9)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            thumb
            if showsFace { faceView.offset(x: 7, y: 5) }
        }
        .frame(width: Self.thumbSize.width, height: Self.thumbSize.height)
    }

    @ViewBuilder private var thumb: some View {
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

    /// The face with the same two rings the grid card's face wears: green→blue unseen, grey seen.
    /// A page-coloured gap between face and ring, as on the reference.
    private var faceView: some View {
        AvatarView(name: authorName, photoUrl: authorPhoto, size: Self.face)
            .padding(Self.gap + Self.ring)
            // Owner 2026-10-11: the gap is pure black in dark mode, pure white in light.
            .background(Circle().fill(scheme == .dark ? Color.black : Color.white))
            .overlay {
                Circle().strokeBorder(
                    seen
                        ? AnyShapeStyle(scheme == .dark ? Color(hex: 0x505052) : Color(hex: 0xCACACA))
                        : AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x34C76F), Color(hex: 0x3DA1FD)],
                                                       startPoint: .bottomLeading, endPoint: .topTrailing)),
                    lineWidth: seen ? 1.5 : Self.ring)
            }
            .allowsHitTesting(false)
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
