import AVFoundation
import UIKit

// Prepares a picked gallery video for sending: transcodes to 720p H.264 mp4 (bounded
// size, plays on every device, strips HDR/HEVC oddities) and grabs a thumbnail +
// duration + pixel size for the bubble. Runs entirely on-device.
enum VideoTranscoder {
    struct Prepared {
        let data: Data        // the transcoded mp4 bytes (to encrypt + upload)
        let thumbnail: Data   // JPEG first frame (bubble + chat-list preview)
        let duration: Double  // seconds
        let width: Double     // thumbnail pixel size → natural aspect bubble
        let height: Double
    }

    static func prepare(_ url: URL) async -> Prepared? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration > 0 else { return nil }

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("send-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: out)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else { return nil }
        session.shouldOptimizeForNetworkUse = true
        do { try await session.export(to: out, as: .mp4) } catch { return nil }
        guard let data = try? Data(contentsOf: out) else { return nil }
        try? FileManager.default.removeItem(at: out)

        // Thumbnail just after the start (frame 0 is often black), rotation-corrected.
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1600, height: 1600)
        let t = CMTime(seconds: min(0.1, duration / 2), preferredTimescale: 600)
        guard let cg = try? await gen.image(at: t).image,
              let thumb = UIImage(cgImage: cg).jpegData(compressionQuality: 0.72) else { return nil }
        return Prepared(data: data, thumbnail: thumb, duration: duration,
                        width: Double(cg.width), height: Double(cg.height))
    }
}
