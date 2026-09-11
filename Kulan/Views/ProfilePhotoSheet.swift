import SwiftUI
import Photos
import UIKit

// THE EDIT PHOTO PAGE — his redesign, 2026-09-02: "when I click edit photo I see a small sheet;
// redesign it, show a full page like image 2, exactly like that".
//
// His reference: ✕ / "Edit Photo" / ✓ across the top, the picture large in the middle wearing a
// remove badge, one "Add a Photo" button under it, then Recents. The button read "Choose a Photo"
// until 2026-09-05, when he renamed it; nothing about what it does changed. An Emoji section stood
// under Recents until 2026-09-11, when he asked for it to go — see the note where it was.
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
    ///
    /// ⚠️ NOTHING ON THIS PAGE PRODUCES IT ANY MORE — owner, 2026-09-11, took the emoji section off
    /// the sheet (the note where it stood explains). The case itself stays: SettingsView still
    /// handles it in the `onDismiss` switch, so deleting it here would only push the edit into
    /// another file to buy nothing.
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

    @State private var palette: ProfilePalette?
    @State private var recents: [UIImage] = []

    private let circle: CGFloat = 190

    /// One Recents suggestion. 76 is the size those circles have always been drawn at and it is not
    /// changing; it is named here rather than typed into the strip because the strip now puts it on
    /// the BOX the picture is poured into instead of on the picture, and a size that means "the
    /// tile" deserves to be said once.

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

    /// ⛔ A MENU, NOT TWO BUTTONS — his instruction, when this button was still called "Choose a
    /// Photo": "when the user clicks Choose a Photo show a context menu: camera, photo library".
    /// The old page carried both as separate capsules; one button and a menu is his reference and it
    /// is also the honest shape, since the two are the same decision made two ways.
    private var choosePhotoButton: some View {
        Menu {
            Button { choose(.camera) } label: { Label("Camera", systemImage: "camera") }
            Button { choose(.library) } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
        } label: {
            Text("Add a Photo")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(ink)
                // ⛔ 44, HIS NUMBER — 2026-09-02, with the button ringed. It was 52, which is a
                // primary-action height, and this is not the page's primary action: the picture
                // above it is, and Recents under it is another way to change it. (It read "Recents
                // and Emoji" until the emoji section was removed on 2026-09-11; 44 is his number
                // either way.) 44 is also Apple's touch floor, so it gives nothing up.
                .frame(height: 44)
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
            // ⛔ A GRID, NOT A ONE-ROW STRIP — owner, 2026-09-11, with both screenshots: "recent
            // images is one line and I see empty space at the bottom, make it like this" beside the
            // system sheet, which lays its suggestions out four to a row down the page.
            //
            // The strip was a horizontal `ScrollView` of fixed 76pt circles, so it used one row and
            // left the rest of the sheet blank while most of the pictures sat off the right edge
            // where nothing said they were there. Four flexible columns spend the width that was
            // being wasted and put every recent on screen at once.
            //
            // ⚠️ THE CIRCLE IS SIZED BY THE COLUMN NOW, NOT BY A CONSTANT. `aspectRatio(1, .fit)`
            // on the `Color.clear` takes the column's own width and squares it, so the circles grow
            // with the screen instead of staying 76 on every phone — which is why `recentThumb` is
            // gone rather than reused. The picture still pours into that square and is cut by the
            // same centred circle; that half is unchanged and its reasoning is below.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4),
                      spacing: 14) {
                ForEach(Array(recents.enumerated()), id: \.offset) { _, img in
                    Button { choose(.image(img)) } label: {
                        // ⛔ THE SQUARE IS THE BOX AND THE PICTURE POURS INTO IT — owner,
                        // 2026-09-11, off a screenshot of this strip beside his reference: ours
                        // were squashed, with white showing inside the circles, while every
                        // suggestion in his reference fills its circle edge to edge.
                        //
                        // What stood here put the frame on the IMAGE, so the picture's own shape
                        // drove the geometry and the circle was cut out of whatever that produced.
                        // It looks right for the big avatar above because that photograph has
                        // already been through the cropper and is square; a raw screenshot out of
                        // the library is 9:19.5 and is not. `Color.clear` takes the square FIRST,
                        // the picture is laid over it and can therefore only overflow it, and
                        // `clipShape` cuts the same centred circle out of every one of them. It is
                        // the pattern AttachRecentsStrip and the wallpaper tiles already use.
                        Color.clear
                            .aspectRatio(1, contentMode: .fit)
                            .overlay { Image(uiImage: img).resizable().scaledToFill() }
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
    }

    // MARK: - Emoji — GONE, AND NOT TO BE PUT BACK
    //
    // ⛔ NO EMOJI ON THIS PAGE — owner, 2026-09-11: "plz Remove emojis". An emoji section stood
    // here from 2026-09-05: the "Emoji" heading, a four-wide grid of the faces he had actually
    // reacted with, the `recentEmoji` reader over `ReactionRecents`, the `disc(for:)` rule that
    // coloured each one out of `AvatarPalette`, and the 512pt `render` that drew a face onto that
    // disc so it could be saved as a profile picture. All five are deleted, and the page is now the
    // picture, the button and Recents.
    //
    // It has now been asked for once and asked away once, so this note is the record: do not add it
    // back on a hunch or off a concept screenshot. `ReactionRecents` itself is untouched — it
    // belongs to the reaction bar, ThreadView writes it, and this page was only ever a reader of it.
    // `ProfilePhotoAction.emoji` is also untouched, for the reason given at the enum.

    /// The heading over Recents — and since the emoji block went on 2026-09-11, its only caller.
    ///
    /// ⛔ SMALLER AND LIGHTER THAN THE PAGE TITLE — owner, 2026-09-11, holding this page against his
    /// reference: our heading shouts. It was 20pt bold, which is BIGGER than "Edit Photo" at the top
    /// of the same screen (`.headline` — 17pt semibold), so a label for one strip outweighed the
    /// name of the page it sits on, and that is what made the strip read as a screen of its own.
    /// 15pt medium is under the title on both counts, size and weight, which is the order his
    /// reference draws the two in. The numbers are not free-floating: 15 and medium are chosen
    /// against that 17pt semibold title and only mean anything next to it.
    private func sectionTitle(_ t: String) -> some View {
        HStack {
            Text(t).font(.system(size: 15, weight: .medium)).foregroundStyle(ink)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 26)
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
    /// system alert in front of a screen somebody may well have opened only to look at their picture.
    /// (This line used to say "to press one emoji"; the emoji section went on 2026-09-11, the reason
    /// for not prompting did not.)
    private static func recentImages(_ count: Int = 12) async -> [UIImage] {
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
        // ⛔ THE SQUARE IS CUT HERE, NOT LEFT TO THE VIEW — owner, 2026-09-11, the second half of the
        // same report the strip above carries. The resize mode was never set, so it was `.none`, and
        // with `.none` Photos is free to ignore both the 300×300 asked for below and the `.aspectFill`
        // beside it and hand back the frame it already had: a 9:19.5 screenshot arrived a 9:19.5
        // screenshot, and every bit of the squaring was left to SwiftUI. `.exact` makes Photos do the
        // centre crop itself, at the size actually requested. The view still pours and clips — that
        // is the belt — but a thumbnail that is square on arrival cannot be letterboxed on the way in,
        // and cropping 300×300 out of a full frame is cheaper than carrying the full frame around.
        opts.resizeMode = .exact

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
