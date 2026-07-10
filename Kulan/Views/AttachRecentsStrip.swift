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
    var onPickMultiple: ([UIImage]) -> Void = { _ in }   // "Select" mode: send several photos at once

    @State private var status: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var assets: [PHAsset] = []
    @State private var loadingPick = false   // fetching the full-size asset after a tap
    @State private var selecting = false             // multi-select mode (the "Select" button)
    @State private var selectedIds: [String] = []    // chosen photo asset ids, in tap order
    @State private var showAlbums = false
    @State private var albumTitle = "Recents"
    @State private var selectedAlbum: PHAssetCollection?   // nil = the newest across the whole library
    @State private var albums: [AttachAlbum] = []

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)   // 3 per row = bigger tiles

    var body: some View {
        VStack(spacing: 0) {
            header
            if showAlbums { albumsList } else { grid }
        }
        .overlay { if loadingPick { ProgressView().tint(.secondary) } }
        .task { if status == .authorized || status == .limited { load(); loadAlbums() } }
    }

    // X close (48pt glass) + a "Recents ▾" title + a right-side Select / Send (N) / Cancel button.
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
                Button { onClose() } label: {
                    Image(systemName: "xmark").font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 48, height: 48)
                        .liquidGlass(Circle(), interactive: true)
                }
                Spacer()
                selectButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // Right-side action: "Select" → enters multi-select; then "Send (N)" once photos are chosen, or
    // "Cancel" if none. Matches Telegram/WhatsApp's recents multi-select.
    @ViewBuilder private var selectButton: some View {
        if selecting {
            if selectedIds.isEmpty {
                Button { selecting = false } label: {
                    Text("Cancel").font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                        .frame(height: 36).padding(.horizontal, 14)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
            } else {
                Button { sendSelected() } label: {
                    Text("Send \(selectedIds.count)").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        .frame(height: 36).padding(.horizontal, 16)
                        .background(Color(hex: 0x3DA1FD), in: Capsule())
                }
            }
        } else {
            Button { selecting = true } label: {
                Text("Select").font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                    .frame(height: 36).padding(.horizontal, 14)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }
        }
    }

    private var grid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: cols, spacing: 6) {
                cameraTile                                   // first cell = Camera (Telegram/WhatsApp)
                switch status {
                case .authorized, .limited:
                    ForEach(assets, id: \.localIdentifier) { a in
                        RecentThumb(asset: a, selecting: selecting,
                                    selectionNumber: selectionIndex(a)) {
                            if selecting { toggle(a) } else { pick(a) }
                        }
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
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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

    // 1-based position of an asset in the current selection (nil = not selected). Photos only.
    private func selectionIndex(_ a: PHAsset) -> Int? {
        guard a.mediaType == .image, let i = selectedIds.firstIndex(of: a.localIdentifier) else { return nil }
        return i + 1
    }

    private func toggle(_ a: PHAsset) {
        guard a.mediaType == .image else { return }   // albums are photos only
        if let i = selectedIds.firstIndex(of: a.localIdentifier) { selectedIds.remove(at: i) }
        else { selectedIds.append(a.localIdentifier) }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    // Load every selected photo (in tap order) and hand them to the parent to send as a batch.
    private func sendSelected() {
        let ids = selectedIds
        let byId = Dictionary(uniqueKeysWithValues: assets.map { ($0.localIdentifier, $0) })
        loadingPick = true
        Task {
            var imgs: [UIImage] = []
            for id in ids {
                if let a = byId[id], let ui = await Self.fullImage(a) { imgs.append(ui) }
            }
            await MainActor.run {
                loadingPick = false
                selecting = false
                selectedIds = []
                if !imgs.isEmpty { onPickMultiple(imgs) }
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
    var selecting: Bool = false
    var selectionNumber: Int? = nil
    let onTap: () -> Void
    @State private var image: UIImage?

    private var durationLabel: String {
        let d = Int(asset.duration.rounded())
        return String(format: "%d:%02d", d / 60, d % 60)
    }

    var body: some View {
        Button(action: onTap) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(Color.secondary.opacity(0.12))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {   // hairline so light thumbs don't dissolve into the sheet
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
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
                // Multi-select: a numbered blue badge when chosen, an empty ring otherwise; selected
                // thumbs dim + inset slightly (Photos-style).
                .overlay {
                    if selecting {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.black.opacity(selectionNumber != nil ? 0.25 : 0.0))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if selecting {
                        ZStack {
                            Circle().fill(selectionNumber != nil ? Color(hex: 0x3DA1FD) : Color.black.opacity(0.25))
                                .frame(width: 24, height: 24)
                            Circle().stroke(.white, lineWidth: 1.5).frame(width: 24, height: 24)
                            if let n = selectionNumber {
                                Text("\(n)").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                            }
                        }
                        .padding(6)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
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
