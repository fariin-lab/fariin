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
    var onPickPhoto: (UIImage) -> Void
    var onPickVideo: (URL) -> Void

    @State private var status: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var assets: [PHAsset] = []
    @State private var loadingPick = false   // fetching the full-size asset after a tap

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: cols, spacing: 6) {
                cameraTile                                   // first cell = Camera (Telegram/WhatsApp)
                switch status {
                case .authorized, .limited:
                    ForEach(assets, id: \.localIdentifier) { a in
                        RecentThumb(asset: a) { pick(a) }
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
        .overlay { if loadingPick { ProgressView().tint(.secondary) } }
        .task { if status == .authorized || status == .limited { load() } }
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
        f.fetchLimit = 40
        let res = PHAsset.fetchAssets(with: f)
        var out: [PHAsset] = []
        res.enumerateObjects { a, _, _ in
            if a.mediaType == .image || a.mediaType == .video { out.append(a) }
        }
        assets = out
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

// One thumbnail cell; videos wear a length chip. Flexible size: it fills its grid column as a
// square (Color.clear.aspectRatio keeps it 1:1 whatever the column width).
private struct RecentThumb: View {
    let asset: PHAsset
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
