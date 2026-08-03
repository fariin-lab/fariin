import SwiftUI
import Photos
import AVFoundation

// ADD STORY IS THE CAMERA (owner, 2026-08-03, with his reference shot: "when i click add story show
// this page this camera, old page remove"). The picker page that used to open first is now the
// LIBRARY behind the camera's bottom-left button, which is where every story camera keeps it.
//
// This type stays the flow's container because it owns every onward presentation — editor, video
// editor, text composer, audience sheet — and those must all hang off ONE view. The camera is simply
// its root now instead of a cover it raised.
//
//  • Camera: capture → StoryEditorView.
//  • CAMERA / TEXT switch → StoryTextComposer → audience sheet.
//  • Library button → the Photos / Albums grid, which is the only path that also takes VIDEO.
struct AddStorySheet: View {
    var onPosted: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = PhotoGridStore()
    @State private var tab = 0                 // 0 = Photos, 1 = Albums
    @State private var openAlbum: AlbumInfo?
    @State private var editorImage: EditorImage?
    @State private var editorVideo: EditorVideo?
    @State private var loadingVideo = false   // brief spinner while a (possibly iCloud) video resolves
    /// Picked in the library SHEET, opened once it has closed. A full-screen editor asked for while
    /// the sheet above it is still dismissing is the presentation that silently never appears — the
    /// same rule the camera cover used to need here.
    @State private var pendingLibraryImage: UIImage?
    @State private var pendingLibraryVideo: URL?
    @State private var pendingTextStory: StoryShareData?   // text story held until the composer cover dismisses
    @State private var shareTextStory: StoryShareData?     // then shown to the audience sheet
    @State private var showLibrary = false
    @State private var showText = false

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 2), count: 4)

    var body: some View {
        StoryCameraView(
            onCapture: { d in if let ui = UIImage(data: d) { editorImage = EditorImage(ui) } },
            onClose: { dismiss() },
            onTextMode: { showText = true },
            onLibrary: { showLibrary = true })
        .fullScreenCover(item: $editorImage) { item in
            StoryEditorView(source: item.image, onPosted: { onPosted(); dismiss() })
        }
        .fullScreenCover(item: $editorVideo) { item in
            StoryVideoEditorView(url: item.url, onPosted: { onPosted(); dismiss() })
        }
        .sheet(isPresented: $showLibrary, onDismiss: {
            if let ui = pendingLibraryImage { pendingLibraryImage = nil; editorImage = EditorImage(ui) }
            else if let url = pendingLibraryVideo { pendingLibraryVideo = nil; editorVideo = EditorVideo(url) }
        }) { libraryPage }
        // Text story → audience sheet (was posting straight to "everyone", ignoring audience — M4).
        .fullScreenCover(isPresented: $showText, onDismiss: {
            if let s = pendingTextStory { pendingTextStory = nil; shareTextStory = s }
        }) {
            StoryTextComposer(onShare: { d in pendingTextStory = StoryShareData(data: d); showText = false },
                              onClose: { showText = false })
        }
        .sheet(item: $shareTextStory) { s in
            ShareStorySheet(image: s.data, onPosted: { onPosted(); dismiss() })
        }
    }

    // MARK: - The library, behind the camera's bottom-left button

    private var libraryPage: some View {
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
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button { showLibrary = false } label: { Image(systemName: "xmark") } } }
            .navigationDestination(item: $openAlbum) { album in albumGrid(album) }
            .overlay { if loadingVideo { ProgressView().controlSize(.large).tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(.black.opacity(0.35)) } }
            // Asked for HERE, not on the camera: opening the camera should not raise a photo-library
            // permission prompt for a screen that is not showing the library yet.
            .task { store.load(); store.loadAlbums() }
        }
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
            // Held, then opened when this sheet has closed — see pendingLibraryImage. The resolve
            // still happens HERE, with its spinner, because an iCloud video can take a moment and
            // closing first would leave the camera sitting there looking like nothing happened.
            .onTapGesture {
                if asset.mediaType == .video {
                    guard !loadingVideo else { return }
                    loadingVideo = true
                    Task {
                        let url = await store.videoURL(asset)
                        loadingVideo = false
                        if let url { pendingLibraryVideo = url; showLibrary = false }
                    }
                } else {
                    Task {
                        if let ui = await store.fullImage(asset) { pendingLibraryImage = ui; showLibrary = false }
                    }
                }
            }
    }

    private func durationLabel(_ s: TimeInterval) -> String {
        let t = Int(s.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    struct EditorImage: Identifiable { let id = UUID(); let image: UIImage; init(_ i: UIImage) { image = i } }
    struct EditorVideo: Identifiable { let id = UUID(); let url: URL; init(_ u: URL) { url = u } }

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
            var arr: [PHAsset] = []
            result.enumerateObjects { a, _, _ in arr.append(a) }
            let limited = Array(arr.prefix(300))
            Task { @MainActor in self.assets = limited }
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
