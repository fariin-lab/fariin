import SwiftUI
import UIKit
import Photos
import AVFoundation

// MARK: - Dark, including the parts SwiftUI does not own

/// Pin a whole PRESENTATION to dark — the UIKit chrome as well as the SwiftUI content.
///
/// `.environment(\.colorScheme, .dark)` is not enough and his screenshot is the proof: the picker
/// carried that pin already and still came up with a WHITE bar and a light segmented control over a
/// dark grid, on a light-mode phone. The reason is that those two are not SwiftUI. A NavigationStack
/// is a `UINavigationController` and a segmented `Picker` is a `UISegmentedControl`, and both resolve
/// their colours from the UIKit **trait collection**, which a SwiftUI environment value does not
/// touch. So the content went dark and the chrome stayed light — two themes at once, which is
/// exactly what he photographed.
///
/// `overrideUserInterfaceStyle` is the trait, and setting it on the presented view controller
/// cascades to every child controller and every subview under it. `StoryViewersSheetView` has done
/// precisely this since it was written, for precisely this reason — its search field and scroll
/// indicators came out light-on-light the same way.
///
/// Applied to the PRESENTED controller (climb to the top of this presentation's own chain) and not
/// to the window: this must darken the picker, not the app behind it.
private struct DarkPresentation: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { Probe() }
    func updateUIView(_ v: UIView, context: Context) { (v as? Probe)?.pin() }

    final class Probe: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            pin()
        }

        func pin() {
            guard window != nil else { return }
            var responder: UIResponder? = self
            while let cur = responder {
                if let vc = cur as? UIViewController {
                    // The top of THIS presentation, so a NavigationStack's own controller cannot be
                    // the one that gets pinned while the bar above it belongs to its parent.
                    var top = vc
                    while let p = top.parent { top = p }
                    if top.overrideUserInterfaceStyle != .dark { top.overrideUserInterfaceStyle = .dark }
                    return
                }
                responder = cur.next
            }
        }
    }
}

extension View {
    /// Every story surface is dark whatever the phone is set to (owner's standing rule). Both halves
    /// of that: the SwiftUI environment for our own views, and the UIKit trait for the chrome.
    func storyAlwaysDark() -> some View {
        environment(\.colorScheme, .dark)
            .background(DarkPresentation().frame(width: 0, height: 0).allowsHitTesting(false))
    }
}

// ADD STORY IS THE CAMERA (owner, 2026-08-03, with his reference shot: "when i click add story show
// this page this camera, old page remove"). The picker page that used to open first is now the
// LIBRARY behind the camera's bottom-left button, which is where every story camera keeps it.
//
// This type stays the flow's container because it owns every onward presentation — editor, video
// editor, text composer, audience sheet — and those must all hang off ONE view. The camera is simply
// its root now instead of a cover it raised.
//
//  • Camera: capture → StoryEditorView.
//  • CAMERA / TEXT switch → the text card on the same page → NEXT → audience sheet.
//  • Library button → the Photos / Albums grid, which is the only path that also takes VIDEO.
struct AddStorySheet: View {
    var onPosted: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var editorImage: EditorImage?
    @State private var editorVideo: EditorVideo?
    /// THE EDITOR FOR SOMETHING PICKED IN THE LIBRARY, presented FROM the library sheet rather than
    /// from this root — which is the whole of the fix below, and why these are separate from
    /// `editorImage` / `editorVideo`. Two covers cannot be bound to one item while both the root and
    /// the sheet are in the hierarchy; they would fight over who presents.
    @State private var libraryEditorImage: EditorImage?
    @State private var libraryEditorVideo: EditorVideo?
    @State private var shareTextStory: StoryShareData?     // finished text story → the audience sheet
    @State private var showLibrary = false

    var body: some View {
        StoryCameraView(
            onCapture: { d in if let ui = UIImage(data: d) { editorImage = EditorImage(ui) } },
            onClose: { dismiss() },
            // A recorded clip goes to the SAME editor a library video opens in, so a story filmed
            // here and a story picked from Photos are trimmed and captioned the same way.
            onVideo: { url in editorVideo = EditorVideo(url) },
            // TEXT is a mode of the camera page now, not a cover raised over it, so the finished
            // story arrives here already rendered and goes straight to the audience sheet.
            onTextStory: { d in shareTextStory = StoryShareData(data: d) },
            onLibrary: { showLibrary = true })
        // These two are the CAMERA's editors. A photo taken here closes back to the camera, which is
        // where it was taken. The library has its own pair, presented from the library itself.
        .fullScreenCover(item: $editorImage) { item in
            StoryEditorView(source: item.image, onPosted: { onPosted(); dismiss() })
        }
        .fullScreenCover(item: $editorVideo) { item in
            StoryVideoEditorView(url: item.url, onPosted: { onPosted(); dismiss() })
        }
        // THE PICKER DOES NOT CLOSE WHEN YOU PICK (owner 2026-08-04: "the media picker should not
        // close automatically after I select a photo… only close it when I tap the close button").
        //
        // It used to close itself, hold the picture in a `pending` slot, and open the editor from the
        // ROOT once the sheet had finished dismissing — because a cover asked for while the sheet
        // above it is still going down silently never appears. Closing the editor then had to raise
        // the picker all over again, from the bottom, as a brand new presentation. That is the slide
        // out and slide back in he is seeing, twice per picture.
        //
        // Presenting the editor from INSIDE the sheet removes the whole problem rather than timing
        // around it: the picker stays exactly where it is, the editor covers it, and closing the
        // editor reveals the picker still sitting there with its scroll position intact.
        .sheet(isPresented: $showLibrary) {
            StoryLibraryPicker(
                onImage: { ui in libraryEditorImage = EditorImage(ui) },
                onVideo: { url in libraryEditorVideo = EditorVideo(url) })
            .fullScreenCover(item: $libraryEditorImage) { item in
                StoryEditorView(source: item.image, onPosted: { onPosted(); dismiss() })
            }
            .fullScreenCover(item: $libraryEditorVideo) { item in
                StoryVideoEditorView(url: item.url, onPosted: { onPosted(); dismiss() })
            }
        }
        // Text story → audience sheet (was posting straight to "everyone", ignoring audience — M4).
        .sheet(item: $shareTextStory) { s in
            ShareStorySheet(image: s.data, onPosted: { onPosted(); dismiss() })
        }
    }

    struct EditorImage: Identifiable { let id = UUID(); let image: UIImage; init(_ i: UIImage) { image = i } }
    struct EditorVideo: Identifiable { let id = UUID(); let url: URL; init(_ u: URL) { url = u } }

}

// MARK: - The app's own media picker

/// The Photos/Albums grid behind the story camera's library button — ONE component now, because the
/// composers' + must open THIS and never Apple's PhotosPicker (owner 2026-08-05: "Never fall back to
/// Apple's Photo Picker"). It always offers BOTH photos and videos, whatever the post already holds,
/// and it does not close itself when you pick (owner rule): the host decides what a pick does, and
/// the X is the only thing that closes it.
struct StoryLibraryPicker: View {
    var onImage: (UIImage) -> Void
    var onVideo: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = PhotoGridStore()
    @State private var tab = 0                 // 0 = Photos, 1 = Albums
    @State private var openAlbum: AlbumInfo?
    @State private var loadingVideo = false   // brief spinner while a (possibly iCloud) video resolves
    @State private var tooLongVideo = false   // pick over the 10-minute ceiling

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 2), count: 4)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("Photos").tag(0)
                    Text("Albums").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16).padding(.vertical, 8)

                if tab == 0 { photosTab } else { albumsTab }
            }
            .navigationTitle("Add to Story")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "xmark") } } }
            .navigationDestination(item: $openAlbum) { album in albumGrid(album) }
            .overlay { if loadingVideo { ProgressView().controlSize(.large).tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(.black.opacity(0.35)) } }
            .alert("That video is too long", isPresented: $tooLongVideo) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Stories can be up to \(Limits.storyVideoPickSeconds / 60) minutes. Longer videos are posted as several stories, but this one is past the limit.")
            }
            // Asked for HERE, not on the camera: opening the camera should not raise a photo-library
            // permission prompt for a screen that is not showing the library yet.
            .task { store.load(); store.loadAlbums() }
        }
        // ALWAYS DARK, like every story surface (owner's standing rule). On the picker itself so
        // every presentation — the camera's library button and both editors' + — is dark without
        // each caller remembering.
        //
        // THE ENVIRONMENT VALUE ALONE WAS NOT ENOUGH and the comment that used to sit here said it
        // was. It claimed the environment is "what the chrome and controls actually read", and his
        // 2026-08-06 screenshot says otherwise: white bar, light segmented control, dark grid, all
        // at once. The bar and the control are UIKit and read the trait. See `storyAlwaysDark`.
        .storyAlwaysDark()
    }

    // MARK: - Photos tab
    private var photosTab: some View {
        ScrollView {
            // The Text card and the Camera tile are gone: the camera screen in front of this one owns
            // both, and offering them twice is how a picker turns back into a menu.
            LazyVGrid(columns: cols, spacing: 2) {
                ForEach(store.assets, id: \.localIdentifier) { asset in tile(asset) }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: - Albums tab
    private var albumsTab: some View {
        List(store.albums) { album in
            Button { openAlbum = album } label: {
                HStack(spacing: 12) {
                    if let cover = album.cover {
                        StoryThumb(asset: cover, store: store)
                            .frame(width: 54, height: 54).clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        RoundedRectangle(cornerRadius: 8).fill(Color(.systemGray5)).frame(width: 54, height: 54)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(album.title).foregroundStyle(.primary).lineLimit(1)
                        Text("\(album.count)").font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())   // whole row tappable (Spacer area too), not just the icons/text
            }
            .buttonStyle(.plain)
        }
        .listStyle(.plain)
        .overlay { if store.albums.isEmpty { ProgressView() } }
    }

    private func albumGrid(_ album: AlbumInfo) -> some View {
        ScrollView {
            LazyVGrid(columns: cols, spacing: 2) {
                ForEach(store.assets(in: album.collection), id: \.localIdentifier) { asset in tile(asset) }
            }
            .padding(.horizontal, 2)
        }
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func tile(_ asset: PHAsset) -> some View {
        StoryThumb(asset: asset, store: store)
            .aspectRatio(1, contentMode: .fill)
            .clipped()
            // Video tiles get the standard duration badge (bottom-right, like the system Photos app).
            .overlay(alignment: .bottomTrailing) {
                if asset.mediaType == .video {
                    Text(durationLabel(asset.duration))
                        .font(.caption2.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))
                        .padding(4)
                }
            }
            // The pick is handed to the HOST, and the grid stays where it is. In the create flow the
            // host raises an editor over this sheet; in the editors' add-more flow the host appends
            // the item and you can keep tapping. The resolve happens HERE with its spinner, because
            // an iCloud video can take a moment.
            .onTapGesture {
                if asset.mediaType == .video {
                    guard !loadingVideo else { return }
                    // TEN MINUTES IS THE CEILING (owner's spec). Under it, any length is fine — a
                    // long video becomes several 90-second stories on its own. Over it, say so
                    // BEFORE the iCloud download rather than after somebody waits for it.
                    guard asset.duration <= Double(Limits.storyVideoPickSeconds) + 1 else {
                        tooLongVideo = true
                        return
                    }
                    loadingVideo = true
                    Task {
                        let url = await store.videoURL(asset)
                        loadingVideo = false
                        if let url { onVideo(url) }
                    }
                } else {
                    Task {
                        if let ui = await store.fullImage(asset) { onImage(ui) }
                    }
                }
            }
    }

    private func durationLabel(_ s: TimeInterval) -> String {
        let t = Int(s.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// A grid thumbnail that loads its PHAsset image once (guarded against PhotoKit's double callback).
struct StoryThumb: View {
    let asset: PHAsset
    let store: PhotoGridStore
    @State private var image: UIImage?
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(.systemGray6)
                if let image { Image(uiImage: image).resizable().scaledToFill() }
            }
            .task {
                if image == nil {
                    let side = geo.size.width * UIScreen.main.scale
                    image = await store.thumbnail(asset, size: CGSize(width: side, height: side))
                }
            }
        }
    }
}

struct AlbumInfo: Identifiable, Hashable {
    let id: String
    let collection: PHAssetCollection
    let title: String
    let count: Int
    let cover: PHAsset?
    static func == (l: AlbumInfo, r: AlbumInfo) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

@MainActor
final class PhotoGridStore: ObservableObject {
    @Published var assets: [PHAsset] = []
    @Published var albums: [AlbumInfo] = []
    private let manager = PHCachingImageManager()

    // Photos AND videos (stories take both, like every big app).
    private static let mediaPredicate = NSPredicate(
        format: "mediaType == %d OR mediaType == %d",
        PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)

    func load() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            guard status == .authorized || status == .limited else { return }
            let opts = PHFetchOptions()
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            opts.predicate = Self.mediaPredicate
            let result = PHAsset.fetchAssets(with: opts)
            // THE WHOLE LIBRARY (owner 2026-08-04: "mediapicker is showing small media only, it's
            // not showing all media in my phone"). It used to stop at 300, which is a couple of
            // months for most people and reads as the picker being broken rather than capped.
            //
            // Safe to take them all: a PHAsset is a lightweight reference, not an image, and the
            // grid is lazy — only the tiles on screen ever ask PhotoKit for pixels. The old cap was
            // guarding a cost that the grid was already avoiding.
            var arr: [PHAsset] = []
            arr.reserveCapacity(result.count)
            result.enumerateObjects { a, _, _ in arr.append(a) }
            Task { @MainActor in self.assets = arr }
        }
    }

    func loadAlbums() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            guard status == .authorized || status == .limited else { return }
            var out: [AlbumInfo] = []
            let imgOpts = PHFetchOptions()
            imgOpts.predicate = Self.mediaPredicate
            func collect(_ collections: PHFetchResult<PHAssetCollection>) {
                collections.enumerateObjects { coll, _, _ in
                    let assets = PHAsset.fetchAssets(in: coll, options: imgOpts)
                    guard assets.count > 0 else { return }
                    out.append(AlbumInfo(id: coll.localIdentifier, collection: coll,
                                         title: coll.localizedTitle ?? "Album",
                                         count: assets.count, cover: assets.firstObject))
                }
            }
            collect(PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: nil))
            collect(PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil))
            Task { @MainActor in self.albums = out }
        }
    }

    func assets(in collection: PHAssetCollection) -> [PHAsset] {
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.predicate = Self.mediaPredicate
        let result = PHAsset.fetchAssets(in: collection, options: opts)
        var arr: [PHAsset] = []
        result.enumerateObjects { a, _, _ in arr.append(a) }
        return arr
    }

    func thumbnail(_ asset: PHAsset, size: CGSize) async -> UIImage? {
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.resizeMode = .fast
        opts.isNetworkAccessAllowed = true
        return await withCheckedContinuation { cont in
            manager.requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: opts) { img, _ in
                cont.resume(returning: img)
            }
        }
    }

    func fullImage(_ asset: PHAsset) async -> UIImage? {
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.isNetworkAccessAllowed = true
        return await withCheckedContinuation { cont in
            manager.requestImage(for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .aspectFit, options: opts) { img, _ in
                cont.resume(returning: img)
            }
        }
    }

    // Resolve a picked video asset to a playable file URL. Plain assets hand back their file
    // directly (AVURLAsset); edited/slow-mo ones come back as an AVComposition, so fall back to a
    // passthrough export into a temp file. iCloud-offloaded videos download first (network allowed).
    func videoURL(_ asset: PHAsset) async -> URL? {
        let opts = PHVideoRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.isNetworkAccessAllowed = true
        let av: AVAsset? = await withCheckedContinuation { cont in
            var resumed = false   // PhotoKit can call back more than once (degraded → final)
            manager.requestAVAsset(forVideo: asset, options: opts) { av, _, _ in
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: av)
            }
        }
        guard let av else { return nil }
        if let urlAsset = av as? AVURLAsset { return urlAsset.url }
        // AVComposition (slow-mo / edited): export as-is to a temp mp4.
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("story-pick-\(UUID().uuidString).mp4")
        guard let session = AVAssetExportSession(asset: av, presetName: AVAssetExportPresetPassthrough) else { return nil }
        do { try await session.export(to: out, as: .mp4) } catch { return nil }
        return out
    }
}
