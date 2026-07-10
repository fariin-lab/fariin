import SwiftUI
import Photos
import AVFoundation
import UIKit

// Telegram/WhatsApp-style recents strip for the attach panel: the newest camera-roll
// photos + videos, one tap to send. Asks for read access on first use; with Limited
// access it simply shows whatever the user granted. Photos open the chat editor
// (crop/caption); videos go straight into the send pipeline.
struct AttachRecentsStrip: View {
    var onCamera: () -> Void = {}
    var onClose: () -> Void = {}
    var onPickPhoto: (UIImage) -> Void
    var onPickVideo: (URL) -> Void
    var onSendAlbum: ([UIImage], String) -> Void = { _, _ in }   // multi-select → send with a caption
    var onOpenAlbum: ([UIImage]) -> Void = { _ in }              // tapping a photo WHILE selecting → open the approval/paging page
    @Binding var hasSelection: Bool   // ≥1 selected → parent hides the source row (Photos/Files/…)

    @State private var status: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var assets: [PHAsset] = []
    @State private var loadingPick = false   // fetching the full-size asset after a tap
    @State private var selectedIds: [String] = []    // chosen asset ids, in tap order (checkbox taps)
    @State private var caption = ""                  // caption for the selected batch
    @State private var showAlbums = false
    @State private var albumTitle = "Recents"
    @State private var selectedAlbum: PHAssetCollection?   // nil = the newest across the whole library
    @State private var albums: [AttachAlbum] = []

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)   // 3 per row = bigger tiles

    var body: some View {
        VStack(spacing: 0) {
            header
            if showAlbums { albumsList } else { grid }
            // ≥1 selected → a caption + Send bar (the parent hides the source row in its place).
            if !selectedIds.isEmpty { captionBar }
        }
        .overlay { if loadingPick { ProgressView().tint(.secondary) } }
        .task { if status == .authorized || status == .limited { load(); loadAlbums() } }
        .onChange(of: selectedIds.isEmpty) { _, empty in hasSelection = !empty }
    }

    // X close (48pt glass) + a "Recents ▾" title. (Selection is per-thumbnail via the checkbox — no
    // separate Select button; tapping the photo itself opens it.)
    private var header: some View {
        ZStack {
            Button { withAnimation(.snappy(duration: 0.25)) { showAlbums.toggle() } } label: {
                HStack(spacing: 5) {
                    Text(albumTitle).font(.headline)
                    Image(systemName: "chevron.down").font(.system(size: 13, weight: .bold))
                        .rotationEffect(.degrees(showAlbums ? 180 : 0))
                }
                .foregroundStyle(.primary)
            }
            HStack {
                // Inside a specific album (folder) the X becomes a BACK arrow → returns to Recents;
                // at the top it's the close X.
                Button {
                    if selectedAlbum != nil || showAlbums {
                        selectedAlbum = nil
                        albumTitle = "Recents"
                        withAnimation(.snappy(duration: 0.25)) { showAlbums = false }
                        load()
                    } else {
                        onClose()
                    }
                } label: {
                    Image(systemName: (selectedAlbum != nil || showAlbums) ? "chevron.left" : "xmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 48, height: 48)
                        .liquidGlass(Circle(), interactive: true)
                }
                Spacer()
                // How many photos are selected (right side) — a Liquid Glass count pill.
                if !selectedIds.isEmpty {
                    Text("\(selectedIds.count) selected")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                        .frame(height: 40).padding(.horizontal, 14)
                        .liquidGlass(Capsule(), interactive: false)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // Caption + Send bar shown while items are selected (replaces the source row). The selected COUNT is
    // shown at the header top-right (not on the send button); the send button is real Liquid Glass.
    private var captionBar: some View {
        HStack(spacing: 10) {
            TextField("", text: $caption,
                      prompt: Text("Add a caption…").foregroundColor(Color(.systemGray)))
                .foregroundStyle(.primary)
                .padding(.horizontal, 16).frame(height: 46)
                .liquidGlass(Capsule(), interactive: true)   // real native Liquid Glass
            Button { sendSelected() } label: {
                Image(systemName: "arrow.up").font(.system(size: 19, weight: .bold))
                    .foregroundStyle(Color(hex: 0x3DA1FD))
                    .frame(width: 46, height: 46)
                    .liquidGlass(Circle(), interactive: true)   // real Liquid Glass send button (no count)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4)
    }

    private var grid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: cols, spacing: 6) {
                cameraTile                                   // first cell = Camera (Telegram/WhatsApp)
                switch status {
                case .authorized, .limited:
                    ForEach(assets, id: \.localIdentifier) { a in
                        // Tap the PHOTO → single editor when nothing is selected; if a selection is active,
                        // open the multi-image approval (paging) of the selected set instead. Tap the
                        // CHECKBOX → (de)select. Separate, never conflict.
                        RecentThumb(asset: a, selectionNumber: selectionIndex(a),
                                    onOpen: { selectedIds.isEmpty ? pick(a) : openSelected() },
                                    onToggle: { toggle(a) })
                    }
                case .notDetermined:
                    accessTile("Allow Photos", icon: "photo.on.rectangle.angled") { request() }
                default:
                    accessTile("Settings", icon: "photo.on.rectangle.angled") {
                        if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 2)
        }
    }

    // Native-style album list (Recents, Favorites, Videos, Selfies, Live Photos, Panoramas, user albums).
    private var albumsList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(albums) { album in
                    Button { selectAlbum(album) } label: {
                        HStack(spacing: 14) {
                            AlbumThumb(collection: album.collection)
                            Text(album.title).font(.system(size: 17)).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 78)
                }
            }
        }
    }

    private func selectAlbum(_ album: AttachAlbum) {
        selectedAlbum = album.isAllRecents ? nil : album.collection
        albumTitle = album.title
        withAnimation(.snappy(duration: 0.25)) { showAlbums = false }
        load()
    }

    // The Camera tile is the first cell of the grid; tap to open the camera.
    private var cameraTile: some View {
        Button(action: onCamera) {
            Color.clear.aspectRatio(1, contentMode: .fit)
                .overlay {
                    VStack(spacing: 6) {
                        Image(systemName: "camera.fill").font(.system(size: 21, weight: .medium))
                        Text("Camera").font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.primary)
                }
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func accessTile(_ text: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Color.clear.aspectRatio(1, contentMode: .fit)
                .overlay {
                    VStack(spacing: 6) {
                        Image(systemName: icon).font(.system(size: 19))
                        Text(text).font(.system(size: 10, weight: .medium)).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.secondary).padding(4)
                }
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func request() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { s in
            DispatchQueue.main.async {
                status = s
                if s == .authorized || s == .limited { load() }
            }
        }
    }

    private func load() {
        let f = PHFetchOptions()
        f.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        f.fetchLimit = 60
        let res = selectedAlbum.map { PHAsset.fetchAssets(in: $0, options: f) } ?? PHAsset.fetchAssets(with: f)
        var out: [PHAsset] = []
        res.enumerateObjects { a, _, _ in
            if a.mediaType == .image || a.mediaType == .video { out.append(a) }
        }
        assets = out
    }

    // Build the album list: Recents (whole library) + non-empty smart albums + user albums.
    private func loadAlbums() {
        var out: [AttachAlbum] = [AttachAlbum(id: "recents", title: "Recents", collection: nil, isAllRecents: true)]
        let smart: [(PHAssetCollectionSubtype, String)] = [
            (.smartAlbumFavorites, "Favorites"), (.smartAlbumVideos, "Videos"),
            (.smartAlbumSelfPortraits, "Selfies"), (.smartAlbumLivePhotos, "Live Photos"),
            (.smartAlbumPanoramas, "Panoramas"), (.smartAlbumScreenshots, "Screenshots"),
        ]
        for (subtype, name) in smart {
            if let c = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil).firstObject,
               PHAsset.fetchAssets(in: c, options: nil).count > 0 {
                out.append(AttachAlbum(id: c.localIdentifier, title: name, collection: c, isAllRecents: false))
            }
        }
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil).enumerateObjects { c, _, _ in
            if PHAsset.fetchAssets(in: c, options: nil).count > 0 {
                out.append(AttachAlbum(id: c.localIdentifier, title: c.localizedTitle ?? "Album", collection: c, isAllRecents: false))
            }
        }
        albums = out
    }

    private func pick(_ a: PHAsset) {
        loadingPick = true
        Task {
            defer { Task { @MainActor in loadingPick = false } }
            if a.mediaType == .video {
                if let url = await Self.videoURL(a) { await MainActor.run { onPickVideo(url) } }
            } else if let ui = await Self.fullImage(a) {
                await MainActor.run { onPickPhoto(ui) }
            }
        }
    }

    // MARK: Multi-select

    // 1-based position of an asset in the current selection (nil = not selected). Photos AND videos.
    private func selectionIndex(_ a: PHAsset) -> Int? {
        guard let i = selectedIds.firstIndex(of: a.localIdentifier) else { return nil }
        return i + 1
    }

    private func toggle(_ a: PHAsset) {
        if let i = selectedIds.firstIndex(of: a.localIdentifier) { selectedIds.remove(at: i) }
        else { selectedIds.append(a.localIdentifier) }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    // Tapping a photo while a selection is active → load the selected PHOTOS (in order) and open the
    // multi-image approval page (paging + per-image edit + one caption).
    private func openSelected() {
        let ids = selectedIds
        let byId = Dictionary(uniqueKeysWithValues: assets.map { ($0.localIdentifier, $0) })
        loadingPick = true
        Task {
            var imgs: [UIImage] = []
            for id in ids {
                if let a = byId[id], a.mediaType == .image, let ui = await Self.fullImage(a) { imgs.append(ui) }
            }
            await MainActor.run {
                loadingPick = false
                if imgs.isEmpty { return }
                selectedIds = []; caption = ""; hasSelection = false
                onOpenAlbum(imgs)
            }
        }
    }

    // Load every selected item (in tap order): photos go out as an album (or the editor for one), each
    // selected VIDEO is sent on its own (the album carries images only — Signal/WhatsApp do the same).
    private func sendSelected() {
        let ids = selectedIds
        let byId = Dictionary(uniqueKeysWithValues: assets.map { ($0.localIdentifier, $0) })
        loadingPick = true
        Task {
            var imgs: [UIImage] = []
            var videos: [URL] = []
            for id in ids {
                guard let a = byId[id] else { continue }
                if a.mediaType == .video {
                    if let url = await Self.videoURL(a) { videos.append(url) }
                } else if let ui = await Self.fullImage(a) {
                    imgs.append(ui)
                }
            }
            let cap = caption.trimmingCharacters(in: .whitespacesAndNewlines)
            await MainActor.run {
                loadingPick = false
                selectedIds = []
                caption = ""
                hasSelection = false
                for url in videos { onPickVideo(url) }
                if !imgs.isEmpty { onSendAlbum(imgs, cap) }
            }
        }
    }

    // Full-quality photo bytes (may pull from iCloud — network allowed).
    private static func fullImage(_ asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { cont in
            let o = PHImageRequestOptions()
            o.deliveryMode = .highQualityFormat   // single callback
            o.isNetworkAccessAllowed = true
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: o) { data, _, _, _ in
                cont.resume(returning: data.flatMap(UIImage.init(data:)))
            }
        }
    }

    // Copy the picked video to a temp file the transcoder can read after the request ends.
    private static func videoURL(_ asset: PHAsset) async -> URL? {
        await withCheckedContinuation { cont in
            let o = PHVideoRequestOptions()
            o.deliveryMode = .mediumQualityFormat
            o.isNetworkAccessAllowed = true
            PHImageManager.default().requestAVAsset(forVideo: asset, options: o) { av, _, _ in
                guard let urlAsset = av as? AVURLAsset else { cont.resume(returning: nil); return }
                let ext = urlAsset.url.pathExtension.isEmpty ? "mov" : urlAsset.url.pathExtension
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent("pick-\(UUID().uuidString).\(ext)")
                do {
                    try FileManager.default.copyItem(at: urlAsset.url, to: dest)
                    cont.resume(returning: dest)
                } catch { cont.resume(returning: nil) }
            }
        }
    }
}

// One album row's model. `collection == nil` (isAllRecents) = the whole library ("Recents").
struct AttachAlbum: Identifiable {
    let id: String
    let title: String
    let collection: PHAssetCollection?
    let isAllRecents: Bool
}

// Album cover thumbnail (newest asset in the album / library).
private struct AlbumThumb: View {
    let collection: PHAssetCollection?
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Rectangle().fill(Color.secondary.opacity(0.12)) }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task {
            let f = PHFetchOptions()
            f.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            f.fetchLimit = 1
            let asset = collection.map { PHAsset.fetchAssets(in: $0, options: f).firstObject } ?? PHAsset.fetchAssets(with: f).firstObject
            guard let a = asset else { return }
            let o = PHImageRequestOptions(); o.deliveryMode = .opportunistic; o.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(for: a, targetSize: CGSize(width: 150, height: 150),
                                                  contentMode: .aspectFill, options: o) { img, _ in if let img { image = img } }
        }
    }
}

// One thumbnail cell; videos wear a length chip. Flexible size: it fills its grid column as a
// square (Color.clear.aspectRatio keeps it 1:1 whatever the column width).
private struct RecentThumb: View {
    let asset: PHAsset
    var selectionNumber: Int? = nil
    let onOpen: () -> Void      // tap the PHOTO → open it
    let onToggle: () -> Void    // tap the CHECKBOX → (de)select
    @State private var image: UIImage?

    private var durationLabel: String {
        let d = Int(asset.duration.rounded())
        return String(format: "%d:%02d", d / 60, d % 60)
    }
    private var selected: Bool { selectionNumber != nil }

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Rectangle().fill(Color.secondary.opacity(0.12))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {   // hairline so light thumbs don't dissolve into the sheet
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(selected ? Color(hex: 0x3DA1FD) : Color.primary.opacity(0.06),
                            lineWidth: selected ? 3 : 1)
            }
            .overlay(alignment: .bottomTrailing) {
                if asset.mediaType == .video {
                    HStack(spacing: 3) {
                        Image(systemName: "video.fill").font(.system(size: 9))
                        Text(durationLabel).font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(4)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            // Tapping the PHOTO opens it (separate from the checkbox below).
            .onTapGesture { onOpen() }
            // Always-visible selection checkbox (top-trailing): tap to (de)select — its own hit area.
            .overlay(alignment: .topTrailing) {
                Button(action: onToggle) {
                    ZStack {
                        Circle().fill(selected ? Color(hex: 0x3DA1FD) : Color.black.opacity(0.35))
                            .frame(width: 26, height: 26)
                        Circle().stroke(.white, lineWidth: 1.5).frame(width: 26, height: 26)
                        if let n = selectionNumber {
                            Text("\(n)").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                        }
                    }
                    .frame(width: 40, height: 40)          // bigger hit target than the visible circle
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .task(id: asset.localIdentifier) {
            let o = PHImageRequestOptions()
            o.deliveryMode = .opportunistic   // fast blurry first, sharp after
            o.resizeMode = .fast
            o.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(for: asset,
                                                  targetSize: CGSize(width: 300, height: 300),
                                                  contentMode: .aspectFill, options: o) { img, _ in
                if let img { image = img }
            }
        }
    }
}
