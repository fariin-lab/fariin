import SwiftUI
import Photos
import UIKit

// THE EDIT PHOTO PAGE — his redesign, 2026-09-02: "when I click edit photo I see a small sheet;
// redesign it, show a full page like image 2, exactly like that".
//
// His reference: ✕ / "Edit Photo" / ✓ across the top, the picture large in the middle wearing a
// remove badge, one "Choose a Photo" button under it, then Recents and Emoji.
//
// ⛔ THE SHEET DECIDES, IT DOES NOT DO. Unchanged from the small version and the one rule on this
// screen that must not be relaxed: every action is recorded here and run by the presenter in
// `onDismiss`. Presenting a camera, a photo picker or an alert from inside a sheet that is still
// dismissing is the "nothing happens" bug this app has been bitten by twice, and the note at the top
// of BottomActionSheet.swift says so in as many words.
//
// ⛔ THE PAGE TAKES ITS COLOUR FROM THE PHOTOGRAPH — his instruction, same message: "this page uses
// the profile colour… don't forget, the background must use the photo colour; when the user doesn't
// have a photo use the normal colour". `ProfilePalette` is the same extractor `ContactInfoView` and
// the Glow profile use, so all three agree about what colour a person is.

enum ProfilePhotoAction {
    case camera     // Apple's camera, to take a new one
    case library    // Apple's photo picker, to choose one
    case remove     // no picture, back to the letter
    /// A photograph the page resolved itself, from Recents. It goes to the SAME cropper a chosen one
    /// does — one framing path, so only one of them can be wrong.
    case image(UIImage)
    /// An emoji drawn onto a coloured disc. Already square and already centred, so it skips the
    /// cropper: there is nothing to frame and asking would be a step that can only make it worse.
    case emoji(UIImage)
}

struct ProfilePhotoSheet: View {
    let name: String
    /// The saved picture. Nil while a removal is pending, so the page shows what you are about to
    /// have rather than what you just asked to get rid of.
    let photoUrl: String?
    /// A picked-but-not-yet-saved photo wins over the saved one, for the same reason.
    let pendingImage: UIImage?
    let canRemove: Bool
    @Binding var action: ProfilePhotoAction?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var palette: ProfilePalette.Result?
    @State private var recents: [UIImage] = []

    private let circle: CGFloat = 190

    /// The page's ground. His rule, stated twice in one message: the photo's colour when there is a
    /// photo, the ordinary background when there is not.
    private var pageColor: Color {
        palette.map { Color($0.page) } ?? Color(.systemBackground)
    }

    /// White on a colour, label on the ordinary background — because `pageColor` is a photograph's
    /// tone in one case and the system's surface in the other, and one foreground cannot serve both.
    private var ink: Color { palette == nil ? Color(.label) : .white }

    var body: some View {
        ZStack {
            pageColor.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    header
                    photo
                        .overlay(alignment: .topTrailing) { removeBadge }
                        .padding(.top, 26)
                    choosePhotoButton
                        .padding(.top, 24)
                    recentsSection
                    emojiSection
                    Color.clear.frame(height: 28)
                }
            }
        }
        // A photograph's tone is a dark ground; the ordinary background keeps the phone's own scheme.
        .environment(\.colorScheme, palette == nil ? scheme : .dark)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .task { await load() }
    }

    // MARK: - Chrome

    private var header: some View {
        ZStack {
            Text("Edit Photo").font(.headline).foregroundStyle(ink)
            HStack {
                glyphButton("xmark") { dismiss() }
                Spacer(minLength: 0)
                // ⚠️ ✓ IS "DONE", NOT "APPLY". Every pick on this page already closes it and hands
                // the presenter the action, so by the time this is reachable there is nothing left
                // to commit — and the real commit is Save on the screen behind, which is the rule
                // his own "don't update the profile image without save" set.
                glyphButton("checkmark") { dismiss() }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private func glyphButton(_ system: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: system)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(ink)
                .frame(width: 44, height: 44)
                .liquidGlass(Circle(), interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var photo: some View {
        Group {
            if let pendingImage {
                Image(uiImage: pendingImage).resizable().scaledToFill()
                    .frame(width: circle, height: circle)
                    .clipShape(Circle())
            } else {
                AvatarView(name: name, photoUrl: photoUrl, size: circle)
            }
        }
        .frame(width: circle, height: circle)
    }

    /// ⛔ A MINUS, NOT AN ✕ — his reference draws a "−" on the picture. The two read differently and
    /// the difference is right: ✕ next to a ✕ in the corner of the same screen is two closes, while
    /// a minus is plainly "take this away".
    @ViewBuilder private var removeBadge: some View {
        if canRemove {
            Button { choose(.remove) } label: {
                Image(systemName: "minus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ink)
                    .frame(width: 40, height: 40)
                    .liquidGlass(Circle(), interactive: true)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: 8)
            .accessibilityLabel("Remove photo")
        }
    }

    /// ⛔ A MENU, NOT TWO BUTTONS — his instruction: "when the user clicks Choose a Photo show a
    /// context menu: camera, photo library". The old page carried both as separate capsules; one
    /// button and a menu is his reference and it is also the honest shape, since the two are the
    /// same decision made two ways.
    private var choosePhotoButton: some View {
        Menu {
            Button { choose(.camera) } label: { Label("Camera", systemImage: "camera") }
            Button { choose(.library) } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
        } label: {
            Text("Choose a Photo")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(ink)
                .frame(height: 52)
                .padding(.horizontal, 30)
                .liquidGlass(Capsule(), interactive: true)
                .contentShape(Capsule())
        }
    }

    // MARK: - Recents

    /// ⚠️ SILENT WHEN THERE IS NOTHING TO SHOW. No photo access, or an empty library, draws no
    /// heading at all — a "Recents" label over a blank strip is a section that looks broken rather
    /// than one that is empty.
    @ViewBuilder private var recentsSection: some View {
        if !recents.isEmpty {
            sectionTitle("Recents")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(Array(recents.enumerated()), id: \.offset) { _, img in
                        Button { choose(.image(img)) } label: {
                            Image(uiImage: img).resizable().scaledToFill()
                                .frame(width: 76, height: 76)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.top, 12)
        }
    }

    // MARK: - Emoji

    @ViewBuilder private var emojiSection: some View {
        sectionTitle("Emoji")
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 4),
                  spacing: 16) {
            // The first cell opens the system keyboard's whole set. Drawn as a face on a neutral
            // disc so it reads as one more choice rather than a control among pictures.
            ForEach(Self.emoji, id: \.0) { pair in
                Button { choose(.emoji(Self.render(pair.0, on: pair.1))) } label: {
                    ZStack {
                        Circle().fill(Color(pair.1))
                        Text(pair.0).font(.system(size: 34))
                    }
                    .frame(height: 76)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private func sectionTitle(_ t: String) -> some View {
        HStack {
            Text(t).font(.system(size: 20, weight: .bold)).foregroundStyle(ink)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 26)
    }

    /// The set from his reference, each on the disc colour it wears there.
    ///
    /// ⚠️ STATED RATHER THAN GENERATED. A hash of the character would give a stable colour with no
    /// list to keep, and it would also give some of these a colour that fights the glyph — a yellow
    /// face on yellow. These are read off his screenshot.
    private static let emoji: [(String, UIColor)] = [
        ("😂", UIColor(red: 0.85, green: 0.45, blue: 0.75, alpha: 1)),
        ("❤️", UIColor(red: 0.22, green: 0.55, blue: 0.92, alpha: 1)),
        ("😍", UIColor(red: 0.22, green: 0.55, blue: 0.92, alpha: 1)),
        ("😒", UIColor(red: 0.36, green: 0.72, blue: 0.86, alpha: 1)),
        ("👌", UIColor(red: 0.45, green: 0.33, blue: 0.22, alpha: 1)),
        ("☺️", UIColor(red: 0.24, green: 0.66, blue: 0.62, alpha: 1)),
        ("😊", UIColor(red: 0.22, green: 0.55, blue: 0.92, alpha: 1)),
        ("😘", UIColor(red: 0.32, green: 0.66, blue: 0.40, alpha: 1)),
        ("😭", UIColor(red: 0.48, green: 0.36, blue: 0.78, alpha: 1)),
        ("😩", UIColor(red: 0.90, green: 0.40, blue: 0.32, alpha: 1)),
        ("💕", UIColor(red: 0.78, green: 0.66, blue: 0.50, alpha: 1)),
        ("🔥", UIColor(red: 0.90, green: 0.55, blue: 0.20, alpha: 1)),
    ]

    /// Draw an emoji onto a filled disc at avatar resolution.
    ///
    /// ⚠️ 512, NOT THE 76 IT IS SHOWN AT. This image becomes the profile picture, so it is rendered
    /// once at the size every other avatar in the app is stored at rather than at the size of the
    /// button that was tapped — a 76pt disc blown up to a poster header is exactly the kind of soft
    /// picture this screen exists to avoid.
    private static func render(_ emoji: String, on colour: UIColor, size: CGFloat = 512) -> UIImage {
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        return UIGraphicsImageRenderer(size: rect.size).image { ctx in
            colour.setFill()
            ctx.cgContext.fillEllipse(in: rect)
            let font = UIFont.systemFont(ofSize: size * 0.52)
            let attrs: [NSAttributedString.Key: Any] = [.font: font]
            let s = NSString(string: emoji)
            let bounds = s.size(withAttributes: attrs)
            s.draw(at: CGPoint(x: (size - bounds.width) / 2,
                               y: (size - bounds.height) / 2),
                   withAttributes: attrs)
        }
    }

    // MARK: - Loading

    private func load() async {
        if let url = photoUrl, !url.isEmpty {
            if let hit = ProfilePalette.cached(for: url) {
                palette = hit
            } else {
                palette = await ProfilePalette.resolve(url: url)
            }
        }
        recents = await Self.recentImages()
    }

    /// The newest few pictures, as decoded thumbnails.
    ///
    /// ⚠️ READ-ONLY AND SILENT. It never ASKS for photo access — the picker does that, at the moment
    /// somebody actually reaches for the library. Prompting on the way into this page would put a
    /// system alert in front of a screen most people open to press one emoji.
    private static func recentImages(_ count: Int = 8) async -> [UIImage] {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return [] }
        let f = PHFetchOptions()
        f.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        f.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        f.fetchLimit = count
        let result = PHAsset.fetchAssets(with: f)
        guard result.count > 0 else { return [] }

        let manager = PHImageManager.default()
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.isNetworkAccessAllowed = true
        opts.isSynchronous = false

        var out: [UIImage] = []
        for i in 0..<result.count {
            let asset = result.object(at: i)
            let img: UIImage? = await withCheckedContinuation { cont in
                var resumed = false
                manager.requestImage(for: asset,
                                     targetSize: CGSize(width: 300, height: 300),
                                     contentMode: .aspectFill,
                                     options: opts) { image, info in
                    // ⚠️ `.opportunistic` CALLS BACK TWICE and a continuation may only resume once.
                    // `.highQualityFormat` above is one callback, and this guard is the belt for the
                    // day somebody changes that line without reading this one.
                    guard !resumed else { return }
                    let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    guard !degraded || image == nil else { return }
                    resumed = true
                    cont.resume(returning: image)
                }
            }
            if let img { out.append(img) }
        }
        return out
    }

    private func choose(_ a: ProfilePhotoAction) {
        action = a
        dismiss()
    }
}
