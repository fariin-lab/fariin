import SwiftUI
import Photos
import AVFoundation

// "Add to Story" picker — clean + minimalist with a Photos / Albums top tab.
//  • Photos: a Text card + Camera tile + a 4-col grid of recent photos.
//  • Albums: your photo albums; tap one to browse its grid.
// Picking/capturing opens StoryEditorView.
struct AddStorySheet: View {
    var onPosted: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = PhotoGridStore()
    @State private var tab = 0                 // 0 = Photos, 1 = Albums
    @State private var openAlbum: AlbumInfo?
    @State private var editorImage: EditorImage?
    @State private var editorVideo: EditorVideo?
    @State private var loadingVideo = false   // brief spinner while a (possibly iCloud) video resolves
    @State private var pendingCapture: UIImage?   // camera shot held until the camera cover dismisses
    @State private var pendingTextMode = false    // "Aa" from the camera held until the camera cover dismisses
    @State private var pendingTextStory: StoryShareData?   // text story held until the composer cover dismisses
    @State private var shareTextStory: StoryShareData?     // then shown to the audience sheet
    @State private var showCamera = false
    @State private var showText = false

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
            .fullScreenCover(item: $editorImage) { item in
                StoryEditorView(source: item.image, onPosted: { onPosted(); dismiss() })
            }
            .fullScreenCover(item: $editorVideo) { item in
                StoryVideoEditorView(url: item.url, onPosted: { onPosted(); dismiss() })
            }
            .overlay { if loadingVideo { ProgressView().controlSize(.large).tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(.black.opacity(0.35)) } }
            // Stash the capture + dismiss the camera; present the editor in onDismiss so two
            // fullScreenCovers never fight (which silently dropped the captured shot).
            .fullScreenCover(isPresented: $showCamera, onDismiss: {
                if let ui = pendingCapture { pendingCapture = nil; editorImage = EditorImage(ui) }
                // Same pattern for "Aa": toggling showText WHILE the camera cover was still
                // dismissing intermittently dropped the text composer (two covers fighting).
                else if pendingTextMode { pendingTextMode = false; showText = true }
            }) {
                StoryCameraView(onCapture: { d in if let ui = UIImage(data: d) { pendingCapture = ui }; showCamera = false },
                                onClose: { showCamera = false },
                                onTextMode: { pendingTextMode = true; showCamera = false })
            }
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
            .task { store.load(); store.loadAlbums() }
        }
    }

    // MARK: - Photos tab
    private var photosTab: some View {
        ScrollView {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    quickCard("Aa", "Text", .green) { showText = true }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            LazyVGrid(columns: cols, spacing: 2) {
                cameraTile
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
            // Video tiles get the standard duration badge (bottom-right, like Photos/WhatsApp).
            .overlay(alignment: .bottomTrailing) {
                if asset.mediaType == .video {
                    Text(durationLabel(asset.duration))
                        .font(.caption2.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))
                        .padding(4)
                }
            }
            .onTapGesture {
                if asset.mediaType == .video {
                    guard !loadingVideo else { return }
                    loadingVideo = true
                    Task {
                        let url = await store.videoURL(asset)
                        loadingVideo = false
                        if let url { editorVideo = EditorVideo(url) }
                    }
                } else {
                    Task { if let ui = await store.fullImage(asset) { editorImage = EditorImage(ui) } }
                }
            }
    }

    private func durationLabel(_ s: TimeInterval) -> String {
        let t = Int(s.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    struct EditorImage: Identifiable { let id = UUID(); let image: UIImage; init(_ i: UIImage) { image = i } }
    struct EditorVideo: Identifiable { let id = UUID(); let url: URL; init(_ u: URL) { url = u } }

    private var cameraTile: some View {
        Button { showCamera = true } label: {
            ZStack {
                Color(.systemGray6)
                VStack(spacing: 6) {
                    Image(systemName: "camera.fill").font(.system(size: 20, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 50, height: 50).background(.white, in: Circle())
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                    Text("Camera").font(.caption).foregroundStyle(.primary)
                }
            }
            .aspectRatio(1, contentMode: .fill).clipped()
        }
        .buttonStyle(.plain)
    }

    private func quickCard(_ glyph: String, _ label: String, _ color: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Text(glyph).font(.system(size: 26, weight: .bold)).foregroundStyle(color)
                Text(label).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
            }
            .frame(width: 110, height: 90)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(.primary.opacity(0.08), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
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
