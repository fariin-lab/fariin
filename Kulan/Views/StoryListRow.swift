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
    static let thumbSize = CGSize(width: 69, height: 97)   // owner 2026-10-11: +4 more
    /// ⛔ 14, CONTINUOUS — owner, 2026-10-11: "corners not smooth, use iOS 26 Apple corners". The
    /// continuous (squircle) curve at a slightly larger radius, the shape the system draws.
    static let corner: CGFloat = 14
    static let margin: CGFloat = 20
    /// ⛔ THE GAP BETWEEN ROWS LIVES INSIDE EACH ROW NOW — owner, 2026-10-11: "long press works
    /// only on the image, make it the whole line". Half the old 24 above and below, so the row's
    /// press area is the full band between its neighbours and the page looks exactly the same.
    static let rowSpacing: CGFloat = 0
    static let rowPad: CGFloat = 12
    /// The corner the lifted row is cut with.
    static let pressCorner: CGFloat = 20
    /// The key the whole row registers for the long press. The picture keeps the group's own id
    /// for the open/close morph, so the two never collide.
    static func pressKey(_ id: String) -> String { "listrow-\(id)" }
    /// The author's face on the picture's bottom-right corner, ring included.
    static let face: CGFloat = 26
    static let ring: CGFloat = 2
    static let gap: CGFloat = 1   // owner 2026-10-11: thinner gap; face and ring unchanged

    let thumbUrl: String
    var blurThumb: String = ""
    let title: String
    let subtitle: String
    /// The face in the corner. nil photo still draws the initials face.
    var authorName: String = ""
    var authorPhoto: String? = nil
    var showsFace = true
    /// ⛔ NO STORY YET — owner, 2026-10-11, with a mockup: the tile shows MY profile picture and
    /// wears the + badge instead of the face. The badge is the grid card's own (black, white bold
    /// plus), not the reference's blue.
    var addBadge = false
    /// ⛔ A POST IN THE AIR — owner, 2026-10-11, "uploading is not happening": the picture being
    /// posted, dimmed, with a spinner over it. Before this the list had no uploading state at all.
    var isUploading = false
    var uploadingImage: UIImage? = nil
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
    /// The whole row's press key (`pressKey(_:)`). nil = no long press on this row.
    var pressKey: String? = nil

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
                // Owner 2026-10-11: his camera icon, on Liquid Glass.
                Button(action: onCamera) {
                    Image("ic_story_camera").renderingMode(.template).resizable().scaledToFit()   // owner 2026-10-11: his camera icon
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
        .padding(.vertical, Self.rowPad)
        .contentShape(Rectangle())
        .modifier(MediaRectReporter(id: pressKey ?? "", scope: .storyRow, cornerRadius: Self.pressCorner))
    }

    /// Back picture (if any) → front picture → face. The face hangs past the picture's corner, so
    /// it sits OUTSIDE the rect reporter: the morph and the lift fly the picture alone.
    private var thumbStack: some View {
        ZStack(alignment: .bottomTrailing) {
            if !backThumbUrl.isEmpty {
                // ⛔ THE REFERENCE APP'S STACK, FROM ITS SOURCE, NOT GUESSED — owner, 2026-10-11:
                // "go read the code, don't guess again". Its My Story cell, scaled by our height
                // (97 / 84) so our front picture keeps its own size:
                //   back    43×64, corner 6, rotated −0.18168878 rad, top inset 4, pinned leading,
                //           NOT dimmed; the container is 8 wider than the front, so the back
                //           starts 8 left of it
                //   divider 60×88, corner = the front's, page colour, 2 out on every side of the
                //           front, between the two, so the front reads as cut out of the back
                let k = Self.thumbSize.height / 84
                StoryImage(url: backThumbUrl, maxPixels: StoryImage.cardPixels, blurThumb: backBlurThumb)
                    .frame(width: 43 * k, height: 64 * k)
                    .clipShape(RoundedRectangle(cornerRadius: 6 * k, style: .continuous))
                    .rotationEffect(.radians(-0.18168878))
                    .frame(width: Self.thumbSize.width, height: Self.thumbSize.height, alignment: .topLeading)
                    .offset(x: -8 * k, y: 4 * k)
                RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                    .fill(scheme == .dark ? Color.black : Color.white)
                    .frame(width: Self.thumbSize.width + 4, height: Self.thumbSize.height + 4)
                    .offset(x: 2, y: 2)
            }
            thumb
            if addBadge { plusBadge.offset(x: 6, y: 6) }
            else if showsFace { faceView.offset(x: 7, y: 5) }
        }
        .frame(width: Self.thumbSize.width, height: Self.thumbSize.height)
    }

    @ViewBuilder private var thumb: some View {
        Group {
            if isUploading {
                // ⛔ NO SYSTEM SPINNER ON THE PICTURE — owner, 2026-10-11. The picture is shown as
                // it is; the app's own spinning arc runs on the face instead (see `faceRing`).
                if let uploadingImage { Image(uiImage: uploadingImage).resizable().scaledToFill() }
                else { Color(uiColor: .secondarySystemFill) }
            } else if thumbUrl.isEmpty, addBadge, let photo = authorPhoto, !photo.isEmpty {
                StoryImage(url: photo, maxPixels: StoryImage.cardPixels)
            } else if thumbUrl.isEmpty, addBadge {
                shape.fill(Color(uiColor: .secondarySystemFill))
                    .overlay(Image(systemName: "person.fill").font(.system(size: 26))
                        .foregroundStyle(.secondary))
            } else if thumbUrl.isEmpty {
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

    /// The grid card's ⊕: white bold plus on a black disc, edged in the page colour so it reads
    /// as sitting on top of the picture.
    private var plusBadge: some View {
        Image(systemName: "plus")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(Color.black, in: Circle())
            .padding(2)
            .background(Circle().fill(scheme == .dark ? Color.black : Color.white))
            .allowsHitTesting(false)
    }

    /// The face with the same two rings the grid card's face wears: green→blue unseen, grey seen.
    /// A page-coloured gap between face and ring, as on the reference.
    private var faceView: some View {
        AvatarView(name: authorName, photoUrl: authorPhoto, size: Self.face)
            .padding(Self.gap + Self.ring)
            // Owner 2026-10-11: the gap is pure black in dark mode, pure white in light.
            .background(Circle().fill(scheme == .dark ? Color.black : Color.white))
            .overlay { faceRing }
            .allowsHitTesting(false)
    }

    @State private var spin = false

    private var unseenGradient: LinearGradient {
        LinearGradient(colors: [Color(hex: 0x34C76F), Color(hex: 0x3DA1FD)],
                       startPoint: .bottomLeading, endPoint: .topTrailing)
    }

    /// The ring on the face. While a post is going up it is the app's own uploading arc — the
    /// strip's uploading card exactly (`UploadingAvatarRing`): trimmed to 0.72, round caps, one
    /// turn every 0.9s, linear — in the unseen ring's colours, owner 2026-10-11.
    @ViewBuilder private var faceRing: some View {
        if isUploading {
            Circle()
                .inset(by: Self.ring / 2)
                .trim(from: 0, to: 0.72)
                .stroke(unseenGradient, style: StrokeStyle(lineWidth: Self.ring, lineCap: .round))
                .rotationEffect(.degrees(spin ? 360 : 0))
                .onAppear {
                    withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true }
                }
                .onDisappear { spin = false }
        } else {
            Circle().strokeBorder(
                seen
                    ? AnyShapeStyle(scheme == .dark ? Color(hex: 0x505052) : Color(hex: 0xCACACA))
                    : AnyShapeStyle(unseenGradient),
                lineWidth: seen ? 1.5 : Self.ring)
        }
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
